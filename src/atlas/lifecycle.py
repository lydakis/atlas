"""Environment lifecycle orchestration behind the Atlas control protocol."""

from __future__ import annotations

import fcntl
import os
import re
import shutil
import subprocess
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from .storage import (
    _btrfs_has_nested_subvolumes,
    _btrfs_snapshot,
    _delete_managed_tree,
    _replace_btrfs_root,
    _require_btrfs_subvolume,
)


DEFAULT_RUNTIME_ROOT = "/var/lib/atlas/environments"
DEFAULT_LOCK_ROOT = "/run/atlas/locks"
DEFAULT_MOUNTINFO = "/proc/self/mountinfo"


class ControlOperationError(Exception):
    """An expected lifecycle error safe to return to the local operator."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _mounts_below(root: Path, mountinfo_path: str) -> list[Path]:
    try:
        lines = Path(mountinfo_path).read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise RuntimeError("Atlas could not inspect mount state") from error
    root_prefix = f"{root}/"
    mounts = []
    for line in lines:
        fields = line.split()
        if len(fields) < 5:
            continue
        mount = Path(fields[4].replace("\\040", " "))
        if mount == root or str(mount).startswith(root_prefix):
            mounts.append(mount)
    return mounts


def _managed_environment_state(
    environment: dict[str, Any], runtime_root: str
) -> dict[str, Any]:
    environment_id = environment.get("id")
    if not isinstance(environment_id, str) or re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        environment_id,
    ) is None:
        raise ValueError("environment identity is invalid")

    parent = Path(runtime_root) / environment_id
    root = parent / "rootfs"
    ready = parent / "rootfs.ready"
    runtime = environment.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("environment runtime contract is invalid")
    if root != Path(runtime.get("rootHostPath", "")) or ready != Path(
        runtime.get("readyHostPath", "")
    ):
        raise ValueError("environment runtime root is outside the managed boundary")

    service = environment.get("process", {}).get("serviceUnit")
    if not isinstance(service, str) or re.fullmatch(
        r"atlas-environment-[A-Za-z0-9\\x]+\.service", service
    ) is None:
        raise ValueError("environment service unit is invalid")

    storage = runtime.get("storage", {})
    adapter = storage.get("adapter", "host-directory")
    if adapter not in {"host-directory", "btrfs-subvolume"}:
        raise ValueError("environment storage adapter is invalid")

    state = {
        "adapter": adapter,
        "environment_id": environment_id,
        "parent": parent,
        "ready": ready,
        "root": root,
        "service": service,
    }
    if adapter == "btrfs-subvolume":
        seed = parent / "seed"
        snapshots = parent / "snapshots"
        seed_record = storage.get("seed")
        seed_preparer = storage.get("seedPrepareCommand")
        if seed != Path(storage.get("seedHostPath", "")) or snapshots != Path(
            storage.get("snapshotsHostPath", "")
        ):
            raise ValueError("environment Btrfs paths are outside the managed boundary")
        if (
            not isinstance(seed_record, dict)
            or not isinstance(seed_record.get("id"), str)
            or re.fullmatch(r"[0-9a-f]{64}", seed_record["id"]) is None
        ):
            raise ValueError("environment seed identity is invalid")
        if not isinstance(seed_preparer, str) or not Path(seed_preparer).is_absolute():
            raise ValueError("environment seed preparer is invalid")
        state.update(
            {
                "seed": seed,
                "seed_id": seed_record["id"],
                "seed_preparer": seed_preparer,
                "snapshots": snapshots,
            }
        )
    return state


@contextmanager
def _lifecycle_lock(environment_id: str, lock_root: str):
    locks = Path(lock_root)
    locks.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = locks / f"{environment_id}.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(lock_fd)


def _require_managed_reset_paths(root: Path, ready: Path) -> None:
    parent = root.parent
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError("environment state parent must be a managed directory")
    if root.is_symlink():
        raise ValueError("environment runtime root cannot be a symbolic link")
    if root.exists() and not root.is_dir():
        raise ValueError("environment runtime root must be a directory")
    if ready.is_symlink():
        raise ValueError("environment readiness marker cannot be a symbolic link")
    if ready.exists() and not ready.is_file():
        raise ValueError("environment readiness marker must be a regular file")


def _remove_abandoned_roots(
    parent: Path,
    mountinfo_path: str,
    *,
    adapter: str = "host-directory",
    btrfs: str = "btrfs",
) -> None:
    for pattern in (".deleting-*", ".rootfs.*", ".seed.*"):
        for candidate in parent.glob(pattern):
            if candidate.is_symlink() or not candidate.is_dir():
                raise RuntimeError(
                    f"Atlas refused an invalid private lifecycle path: {candidate}"
                )
            mounts = _mounts_below(candidate, mountinfo_path)
            if mounts:
                raise RuntimeError(
                    f"mounts remain below private lifecycle path: {mounts}"
                )
            _delete_managed_tree(candidate, adapter, btrfs)


def _prepare_applied_seed(state: dict[str, Any], btrfs: str) -> None:
    subprocess.run(
        [state["seed_preparer"]],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    seed_id_path = state["seed"] / "etc" / "atlas" / "seed-id"
    try:
        actual_seed_id = seed_id_path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise RuntimeError(
            "Atlas seed preparer did not materialize an applied seed"
        ) from error
    if actual_seed_id != state["seed_id"]:
        raise RuntimeError(
            "Atlas seed preparer did not materialize the expected applied seed"
        )
    _require_btrfs_subvolume(state["seed"], btrfs, "applied seed")


def _reset_environment(
    environment: dict[str, Any],
    *,
    runtime_root: str,
    lock_root: str,
    systemctl: str,
    btrfs: str = "btrfs",
    mountinfo_path: str = DEFAULT_MOUNTINFO,
) -> None:
    state = _managed_environment_state(environment, runtime_root)
    root = state["root"]
    ready = state["ready"]
    service = state["service"]
    adapter = state["adapter"]

    with _lifecycle_lock(state["environment_id"], lock_root):
        _require_managed_reset_paths(root, ready)
        subprocess.run(
            [systemctl, "stop", service],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        active = subprocess.run(
            [systemctl, "is-active", "--quiet", service],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if active.returncode == 0:
            raise RuntimeError("environment service remains active after stop")

        mounts = _mounts_below(root, mountinfo_path)
        if mounts:
            raise RuntimeError(f"mounts remain below environment root: {mounts}")

        _remove_abandoned_roots(
            root.parent,
            mountinfo_path,
            adapter=adapter,
            btrfs=btrfs,
        )

        if adapter == "btrfs-subvolume":
            _prepare_applied_seed(state, btrfs)
            _replace_btrfs_root(
                source=state["seed"],
                root=root,
                ready=ready,
                btrfs=btrfs,
            )
        elif root.exists():
            tombstone = root.parent / f".deleting-{uuid.uuid4()}"
            root.rename(tombstone)
            ready.unlink(missing_ok=True)
            shutil.rmtree(tombstone)
        else:
            ready.unlink(missing_ok=True)


def _service_active_state(systemctl: str, service: str) -> str:
    result = subprocess.run(
        [systemctl, "show", service, "--property=ActiveState", "--value"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    state = result.stdout.strip()
    if not state:
        raise RuntimeError("environment service has no active state")
    return state


def _pause_environment(systemctl: str, service: str) -> bool:
    previous_state = _service_active_state(systemctl, service)
    should_resume = previous_state in {
        "active",
        "activating",
        "reloading",
        "refreshing",
    }
    subprocess.run(
        [systemctl, "stop", service],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    stopped_state = _service_active_state(systemctl, service)
    if stopped_state not in {"inactive", "failed"}:
        raise RuntimeError(f"environment service remains {stopped_state} after stop")
    return should_resume


def _resume_environment(systemctl: str, service: str, was_active: bool) -> None:
    if was_active:
        subprocess.run(
            [systemctl, "start", service],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def _require_snapshot_adapter(state: dict[str, Any]) -> None:
    if state["adapter"] != "btrfs-subvolume":
        raise ControlOperationError(
            "unsupported",
            "environment snapshots require the Btrfs storage adapter",
        )


def _require_snapshots_directory(state: dict[str, Any]) -> Path:
    snapshots = state["snapshots"]
    if snapshots.is_symlink():
        raise RuntimeError("Atlas refused a symbolic link at the snapshots directory")
    snapshots.mkdir(mode=0o700, parents=False, exist_ok=True)
    if not snapshots.is_dir():
        raise RuntimeError("Atlas snapshots path is not a directory")
    os.chmod(snapshots, 0o700)
    return snapshots


def _create_environment_snapshot(
    environment: dict[str, Any],
    snapshot: str,
    *,
    runtime_root: str,
    lock_root: str,
    systemctl: str,
    btrfs: str,
    mountinfo_path: str = DEFAULT_MOUNTINFO,
) -> None:
    state = _managed_environment_state(environment, runtime_root)
    _require_snapshot_adapter(state)
    with _lifecycle_lock(state["environment_id"], lock_root):
        _require_managed_reset_paths(state["root"], state["ready"])
        snapshots = _require_snapshots_directory(state)
        target = snapshots / snapshot
        if target.exists() or target.is_symlink():
            raise ControlOperationError("already_exists", "snapshot already exists")

        was_active = _pause_environment(systemctl, state["service"])
        try:
            if not state["root"].is_dir() or not state["ready"].is_file():
                raise ControlOperationError(
                    "not_initialized", "environment has no initialized root to snapshot"
                )
            if _mounts_below(state["root"], mountinfo_path):
                raise RuntimeError("mounts remain below environment root after stop")
            _require_btrfs_subvolume(state["root"], btrfs, "environment root")
            if _btrfs_has_nested_subvolumes(state["root"], btrfs):
                raise ControlOperationError(
                    "unsupported",
                    "environment root contains nested Btrfs subvolumes; root snapshots are non-recursive",
                )
            _btrfs_snapshot(state["root"], target, btrfs, readonly=True)
        finally:
            _resume_environment(systemctl, state["service"], was_active)


def _list_environment_snapshots(
    environment: dict[str, Any],
    *,
    runtime_root: str,
    lock_root: str,
    btrfs: str,
) -> list[str]:
    state = _managed_environment_state(environment, runtime_root)
    _require_snapshot_adapter(state)
    with _lifecycle_lock(state["environment_id"], lock_root):
        snapshots = _require_snapshots_directory(state)
        names = []
        for candidate in snapshots.iterdir():
            if candidate.is_symlink() or re.fullmatch(
                r"[a-z][a-z0-9-]{0,39}", candidate.name
            ) is None:
                raise RuntimeError("Atlas refused an invalid snapshot path")
            _require_btrfs_subvolume(candidate, btrfs, "environment snapshot")
            names.append(candidate.name)
        return sorted(names)


def _restore_environment_snapshot(
    environment: dict[str, Any],
    snapshot: str,
    *,
    runtime_root: str,
    lock_root: str,
    systemctl: str,
    btrfs: str,
    mountinfo_path: str = DEFAULT_MOUNTINFO,
) -> None:
    state = _managed_environment_state(environment, runtime_root)
    _require_snapshot_adapter(state)
    with _lifecycle_lock(state["environment_id"], lock_root):
        _require_managed_reset_paths(state["root"], state["ready"])
        snapshots = _require_snapshots_directory(state)
        source = snapshots / snapshot
        if not source.exists():
            raise ControlOperationError("not_found", "snapshot does not exist")
        _require_btrfs_subvolume(source, btrfs, "environment snapshot")

        was_active = _pause_environment(systemctl, state["service"])
        try:
            if _mounts_below(state["root"], mountinfo_path):
                raise RuntimeError("mounts remain below environment root after stop")
            _remove_abandoned_roots(
                state["parent"],
                mountinfo_path,
                adapter="btrfs-subvolume",
                btrfs=btrfs,
            )
            _replace_btrfs_root(
                source=source,
                root=state["root"],
                ready=state["ready"],
                btrfs=btrfs,
            )
        finally:
            _resume_environment(systemctl, state["service"], was_active)


def _delete_environment_snapshot(
    environment: dict[str, Any],
    snapshot: str,
    *,
    runtime_root: str,
    lock_root: str,
    btrfs: str,
) -> None:
    state = _managed_environment_state(environment, runtime_root)
    _require_snapshot_adapter(state)
    with _lifecycle_lock(state["environment_id"], lock_root):
        snapshots = _require_snapshots_directory(state)
        target = snapshots / snapshot
        if not target.exists():
            raise ControlOperationError("not_found", "snapshot does not exist")
        _require_btrfs_subvolume(target, btrfs, "environment snapshot")
        _delete_managed_tree(target, "btrfs-subvolume", btrfs)


class EnvironmentLifecycle:
    """Reset and snapshot operations for one declared environment contract."""

    def __init__(
        self,
        *,
        runtime_root: str = DEFAULT_RUNTIME_ROOT,
        lock_root: str = DEFAULT_LOCK_ROOT,
        systemctl: str = "systemctl",
        btrfs: str = "btrfs",
        mountinfo_path: str = DEFAULT_MOUNTINFO,
        snapshots_enabled: bool = False,
    ):
        self.runtime_root = runtime_root
        self.lock_root = lock_root
        self.systemctl = systemctl
        self.btrfs = btrfs
        self.mountinfo_path = mountinfo_path
        self.snapshots_enabled = snapshots_enabled

    def reset(self, environment: dict[str, Any]) -> None:
        _reset_environment(
            environment,
            runtime_root=self.runtime_root,
            lock_root=self.lock_root,
            systemctl=self.systemctl,
            btrfs=self.btrfs,
            mountinfo_path=self.mountinfo_path,
        )

    def create_snapshot(self, environment: dict[str, Any], snapshot: str) -> None:
        _create_environment_snapshot(
            environment,
            snapshot,
            runtime_root=self.runtime_root,
            lock_root=self.lock_root,
            systemctl=self.systemctl,
            btrfs=self.btrfs,
            mountinfo_path=self.mountinfo_path,
        )

    def list_snapshots(self, environment: dict[str, Any]) -> list[str]:
        return _list_environment_snapshots(
            environment,
            runtime_root=self.runtime_root,
            lock_root=self.lock_root,
            btrfs=self.btrfs,
        )

    def restore_snapshot(self, environment: dict[str, Any], snapshot: str) -> None:
        _restore_environment_snapshot(
            environment,
            snapshot,
            runtime_root=self.runtime_root,
            lock_root=self.lock_root,
            systemctl=self.systemctl,
            btrfs=self.btrfs,
            mountinfo_path=self.mountinfo_path,
        )

    def delete_snapshot(self, environment: dict[str, Any], snapshot: str) -> None:
        _delete_environment_snapshot(
            environment,
            snapshot,
            runtime_root=self.runtime_root,
            lock_root=self.lock_root,
            btrfs=self.btrfs,
        )
