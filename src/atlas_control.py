#!/usr/bin/env python3
"""Local control surfaces for the Atlas Environment Entry adapter."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable


PROTOCOL_VERSION = 1
DEFAULT_SOCKET = "/run/atlas/control.sock"
DEFAULT_MANAGEMENT_SOCKET = "/run/atlas/manage.sock"
DEFAULT_CONTRACT = "/etc/atlas/control-contract.json"
DEFAULT_RUNTIME_ROOT = "/var/lib/atlas/environments"
DEFAULT_LOCK_ROOT = "/run/atlas/locks"
DEFAULT_MOUNTINFO = "/proc/self/mountinfo"
MAX_REQUEST_BYTES = 64 * 1024
REQUEST_DEADLINE_SECONDS = 2.0
MAX_CONCURRENT_CONNECTIONS = 16


class ControlOperationError(Exception):
    """An expected lifecycle error safe to return to the local operator."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _success(result: Any) -> dict[str, Any]:
    return {"ok": True, "result": result}


def _error(code: str, message: str) -> dict[str, Any]:
    return {"ok": False, "error": {"code": code, "message": message}}


def _has_exact_keys(request: dict[str, Any], expected: set[str]) -> bool:
    return set(request) == expected


def _unified_cgroup_path(peer_cgroup: str) -> str:
    """Return the cgroup v2 path from /proc/PID/cgroup, or fail closed."""
    for line in peer_cgroup.splitlines():
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0" and fields[1] == "":
            path = fields[2]
            return path if path.startswith("/") else ""
    return ""


def _environment_for_peer(
    *,
    peer_uid: int,
    peer_cgroup: str,
    contract: dict[str, Any],
) -> str | None:
    name = contract.get("environmentByUid", {}).get(str(peer_uid))
    if name is not None:
        return name

    path = _unified_cgroup_path(peer_cgroup)
    if not path:
        return None

    matches = {
        environment_name
        for prefix, environment_name in contract.get(
            "environmentByCgroupPrefix", {}
        ).items()
        if path == prefix or path.startswith(f"{prefix}/")
    }
    return next(iter(matches)) if len(matches) == 1 else None


def handle_request(
    *,
    peer_uid: int,
    peer_cgroup: str = "",
    request: Any,
    contract: dict[str, Any],
    reset_environment: Callable[[dict[str, Any]], None] | None = None,
    create_snapshot: Callable[[dict[str, Any], str], None] | None = None,
    list_snapshots: Callable[[dict[str, Any]], list[str]] | None = None,
    restore_snapshot: Callable[[dict[str, Any], str], None] | None = None,
    delete_snapshot: Callable[[dict[str, Any], str], None] | None = None,
) -> dict[str, Any]:
    """Handle one request using identity supplied by the kernel."""
    if not isinstance(request, dict):
        return _error("invalid_request", "request must be a JSON object")
    if request.get("version") != PROTOCOL_VERSION:
        return _error(
            "unsupported_version",
            f"protocol version {PROTOCOL_VERSION} is required",
        )

    environments = contract["environments"]
    operation = request.get("operation")

    if operation == "doctor":
        if not _has_exact_keys(request, {"version", "operation"}):
            return _error("invalid_request", "doctor accepts no additional fields")
        return _success(contract["doctor"])

    if operation == "environment.list":
        if not _has_exact_keys(request, {"version", "operation"}):
            return _error(
                "invalid_request",
                "environment.list accepts no additional fields",
            )
        return _success([environments[name] for name in sorted(environments)])

    if operation == "environment.inspect":
        if not _has_exact_keys(request, {"version", "operation", "name"}):
            return _error(
                "invalid_request",
                "environment.inspect requires exactly one name",
            )
        name = request["name"]
        if not isinstance(name, str) or name not in environments:
            return _error("not_found", "environment does not exist")
        return _success(environments[name])

    if operation == "environment.inspect-self":
        if not _has_exact_keys(request, {"version", "operation"}):
            return _error(
                "invalid_request",
                "environment.inspect-self accepts no caller-authored identity",
            )
        name = _environment_for_peer(
            peer_uid=peer_uid,
            peer_cgroup=peer_cgroup,
            contract=contract,
        )
        if name is None or name not in environments:
            return _error(
                "unknown_peer",
                "the socket peer is not an Atlas environment principal",
            )
        return _success(environments[name])

    if operation == "environment.reset":
        if not _has_exact_keys(request, {"version", "operation", "name"}):
            return _error(
                "invalid_request",
                "environment.reset requires exactly one name",
            )
        if peer_uid != 0:
            return _error("forbidden", "environment.reset requires host root")
        if reset_environment is None:
            return _error("unavailable", "reset is unavailable on this control surface")
        name = request["name"]
        if not isinstance(name, str) or name not in environments:
            return _error("not_found", "environment does not exist")
        environment = environments[name]
        reset_environment(environment)
        return _success(
            {
                "name": name,
                "preservedVolumes": sorted(
                    mount["name"] for mount in environment.get("volumes", [])
                ),
                "reset": True,
            }
        )

    snapshot_callbacks = {
        "environment.snapshot.create": create_snapshot,
        "environment.snapshot.list": list_snapshots,
        "environment.snapshot.restore": restore_snapshot,
        "environment.snapshot.delete": delete_snapshot,
    }
    if operation in snapshot_callbacks:
        expected = {"version", "operation", "name"}
        if operation != "environment.snapshot.list":
            expected.add("snapshot")
        if not _has_exact_keys(request, expected):
            return _error(
                "invalid_request",
                f"{operation} requires exactly {', '.join(sorted(expected - {'version', 'operation'}))}",
            )
        if peer_uid != 0:
            return _error("forbidden", "environment snapshot management requires host root")
        callback = snapshot_callbacks[operation]
        if callback is None:
            return _error("unavailable", "environment snapshots are unavailable")
        name = request["name"]
        if not isinstance(name, str) or name not in environments:
            return _error("not_found", "environment does not exist")
        environment = environments[name]

        if operation == "environment.snapshot.list":
            try:
                snapshots = callback(environment)
            except ControlOperationError as error:
                return _error(error.code, error.message)
            return _success({"name": name, "snapshots": sorted(snapshots)})

        snapshot = request["snapshot"]
        if not isinstance(snapshot, str) or re.fullmatch(
            r"[a-z][a-z0-9-]{0,39}", snapshot
        ) is None:
            return _error(
                "invalid_request",
                "snapshot must be a lowercase slug of at most 40 characters",
            )
        try:
            callback(environment, snapshot)
        except ControlOperationError as error:
            return _error(error.code, error.message)
        if operation == "environment.snapshot.create":
            result = {"created": True, "name": name, "snapshot": snapshot}
        elif operation == "environment.snapshot.restore":
            result = {
                "name": name,
                "preservedVolumes": sorted(
                    mount["name"] for mount in environment.get("volumes", [])
                ),
                "restored": True,
                "snapshot": snapshot,
            }
        else:
            result = {"deleted": True, "name": name, "snapshot": snapshot}
        return _success(result)

    return _error("unknown_operation", "operation is not supported")


def _load_json(path: str) -> Any:
    with Path(path).open("r", encoding="utf-8") as file:
        return json.load(file)


def _read_request(
    connection: socket.socket,
    *,
    timeout_seconds: float = REQUEST_DEADLINE_SECONDS,
) -> Any:
    chunks: list[bytes] = []
    received = 0
    deadline = time.monotonic() + timeout_seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("request deadline exceeded")
        connection.settimeout(remaining)
        try:
            chunk = connection.recv(min(65536, MAX_REQUEST_BYTES + 1 - received))
        except TimeoutError as error:
            raise ValueError("request deadline exceeded") from error
        if not chunk:
            break
        chunks.append(chunk)
        received += len(chunk)
        if received > MAX_REQUEST_BYTES:
            raise ValueError("request exceeds maximum size")
        if b"\n" in chunk:
            break

    payload = b"".join(chunks).split(b"\n", 1)[0]
    if not payload:
        raise ValueError("request is empty")
    return json.loads(payload)


def _peer_credentials(connection: socket.socket) -> tuple[int, int]:
    if not hasattr(socket, "SO_PEERCRED"):
        raise RuntimeError("SO_PEERCRED is required")
    credentials = connection.getsockopt(
        socket.SOL_SOCKET,
        socket.SO_PEERCRED,
        struct.calcsize("iII"),
    )
    pid, uid, _gid = struct.unpack("iII", credentials)
    return pid, uid


def _peer_cgroup(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/cgroup").read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return ""


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
        if (
            not isinstance(seed_preparer, str)
            or not Path(seed_preparer).is_absolute()
        ):
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


def _run_btrfs(
    btrfs: str,
    *arguments: str,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [btrfs, *arguments],
        check=check,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _is_btrfs_subvolume(path: Path, btrfs: str) -> bool:
    if path.is_symlink() or not path.is_dir():
        return False
    return _run_btrfs(btrfs, "subvolume", "show", str(path), check=False).returncode == 0


def _require_btrfs_subvolume(path: Path, btrfs: str, label: str) -> None:
    if not _is_btrfs_subvolume(path, btrfs):
        raise RuntimeError(f"Atlas refused {label} that is not a Btrfs subvolume")


def _delete_managed_tree(path: Path, adapter: str, btrfs: str) -> None:
    if not path.exists():
        return
    if adapter == "btrfs-subvolume" and _is_btrfs_subvolume(path, btrfs):
        _run_btrfs(
            btrfs,
            "subvolume",
            "delete",
            "--recursive",
            "--commit-after",
            "--",
            str(path),
        )
    else:
        shutil.rmtree(path)


def _btrfs_snapshot(source: Path, destination: Path, btrfs: str, *, readonly: bool) -> None:
    arguments = ["subvolume", "snapshot"]
    if readonly:
        arguments.append("-r")
    arguments.extend(["--", str(source), str(destination)])
    _run_btrfs(btrfs, *arguments)


def _btrfs_has_nested_subvolumes(path: Path, btrfs: str) -> bool:
    result = subprocess.run(
        [btrfs, "subvolume", "list", "-o", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return bool(result.stdout.strip())


def _replace_btrfs_root(
    *,
    source: Path,
    root: Path,
    ready: Path,
    btrfs: str,
) -> None:
    _require_btrfs_subvolume(source, btrfs, "snapshot source")
    if root.exists():
        _require_btrfs_subvolume(root, btrfs, "environment root")

    candidate = root.parent / f".rootfs.{uuid.uuid4()}"
    tombstone = root.parent / f".deleting-{uuid.uuid4()}"
    _btrfs_snapshot(source, candidate, btrfs, readonly=False)
    moved_root = False
    try:
        if root.exists():
            root.rename(tombstone)
            moved_root = True
        candidate.rename(root)
    except Exception:
        if moved_root and not root.exists() and tombstone.exists():
            tombstone.rename(root)
        if candidate.exists():
            _delete_managed_tree(candidate, "btrfs-subvolume", btrfs)
        raise

    ready.touch(mode=0o600, exist_ok=True)
    os.chmod(ready, 0o600)
    if tombstone.exists():
        try:
            _delete_managed_tree(tombstone, "btrfs-subvolume", btrfs)
        except (OSError, subprocess.SubprocessError) as error:
            print(
                f"atlas-control: deferred Btrfs tombstone cleanup: {error}",
                file=sys.stderr,
            )


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
        raise RuntimeError("Atlas seed preparer did not materialize an applied seed") from error
    if actual_seed_id != state["seed_id"]:
        raise RuntimeError("Atlas seed preparer did not materialize the expected applied seed")
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

        if adapter == "btrfs-subvolume":
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
        raise RuntimeError(
            f"environment service remains {stopped_state} after stop"
        )
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


def _activation_socket() -> socket.socket:
    listen_pid = int(os.environ.get("LISTEN_PID", "0"))
    listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    if listen_pid != os.getpid() or listen_fds != 1:
        raise RuntimeError("atlas serve requires exactly one systemd socket")
    return socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)


def _serve_connection(connection: socket.socket, args: argparse.Namespace) -> None:
    with connection:
        try:
            peer_pid, peer_uid = _peer_credentials(connection)
            contract = _load_json(args.contract)
            reset = None
            create_snapshot = None
            list_snapshots = None
            restore_snapshot = None
            delete_snapshot = None
            if args.management:
                reset = lambda environment: _reset_environment(
                    environment,
                    runtime_root=args.runtime_root,
                    lock_root=args.lock_root,
                    systemctl=args.systemctl,
                    btrfs=args.btrfs,
                )
                if contract.get("doctor", {}).get("storage", {}).get("snapshots"):
                    create_snapshot = lambda environment, snapshot: _create_environment_snapshot(
                        environment,
                        snapshot,
                        runtime_root=args.runtime_root,
                        lock_root=args.lock_root,
                        systemctl=args.systemctl,
                        btrfs=args.btrfs,
                    )
                    list_snapshots = lambda environment: _list_environment_snapshots(
                        environment,
                        runtime_root=args.runtime_root,
                        lock_root=args.lock_root,
                        btrfs=args.btrfs,
                    )
                    restore_snapshot = lambda environment, snapshot: _restore_environment_snapshot(
                        environment,
                        snapshot,
                        runtime_root=args.runtime_root,
                        lock_root=args.lock_root,
                        systemctl=args.systemctl,
                        btrfs=args.btrfs,
                    )
                    delete_snapshot = lambda environment, snapshot: _delete_environment_snapshot(
                        environment,
                        snapshot,
                        runtime_root=args.runtime_root,
                        lock_root=args.lock_root,
                        btrfs=args.btrfs,
                    )
            response = handle_request(
                peer_uid=peer_uid,
                peer_cgroup=_peer_cgroup(peer_pid),
                request=_read_request(connection),
                contract=contract,
                reset_environment=reset,
                create_snapshot=create_snapshot,
                list_snapshots=list_snapshots,
                restore_snapshot=restore_snapshot,
                delete_snapshot=delete_snapshot,
            )
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as error:
            response = _error("invalid_request", str(error))
        except Exception as error:  # Keep the daemon alive; disclose no internals.
            print(f"atlas-control: {type(error).__name__}: {error}", file=sys.stderr)
            response = _error("internal_error", "request could not be processed")
        try:
            connection.sendall(json.dumps(response, sort_keys=True).encode() + b"\n")
        except OSError:
            pass


def serve(args: argparse.Namespace) -> int:
    listener = _activation_socket()
    slots = threading.BoundedSemaphore(MAX_CONCURRENT_CONNECTIONS)

    def run(connection: socket.socket) -> None:
        try:
            _serve_connection(connection, args)
        finally:
            slots.release()

    while True:
        connection, _address = listener.accept()
        if not slots.acquire(blocking=False):
            connection.close()
            continue
        threading.Thread(target=run, args=(connection,), daemon=True).start()


def _request(socket_path: str, payload: dict[str, Any]) -> dict[str, Any]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(socket_path)
        connection.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
        connection.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks))


def _print_response(response: dict[str, Any], as_json: bool) -> int:
    if as_json:
        print(json.dumps(response, indent=2, sort_keys=True))
    elif response.get("ok"):
        print(json.dumps(response["result"], indent=2, sort_keys=True))
    else:
        error = response.get("error", {})
        print(
            f"atlas: {error.get('code', 'error')}: {error.get('message', '')}",
            file=sys.stderr,
        )
    return 0 if response.get("ok") else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="atlas")
    parser.add_argument("--socket", default=None, help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor_parser = subparsers.add_parser("doctor")
    doctor_parser.add_argument("--json", action="store_true")

    environment_parser = subparsers.add_parser("environment")
    environment_subparsers = environment_parser.add_subparsers(
        dest="environment_command", required=True
    )
    list_parser = environment_subparsers.add_parser("list")
    list_parser.add_argument("--json", action="store_true")
    inspect_parser = environment_subparsers.add_parser("inspect")
    inspect_parser.add_argument("subject")
    inspect_parser.add_argument("--json", action="store_true")
    reset_parser = environment_subparsers.add_parser("reset")
    reset_parser.add_argument("name")
    reset_parser.add_argument("--json", action="store_true")
    snapshot_parser = environment_subparsers.add_parser("snapshot")
    snapshot_subparsers = snapshot_parser.add_subparsers(
        dest="snapshot_command", required=True
    )
    for snapshot_command in ("create", "restore", "delete"):
        operation_parser = snapshot_subparsers.add_parser(snapshot_command)
        operation_parser.add_argument("name")
        operation_parser.add_argument("snapshot")
        operation_parser.add_argument("--json", action="store_true")
    snapshot_list_parser = snapshot_subparsers.add_parser("list")
    snapshot_list_parser.add_argument("name")
    snapshot_list_parser.add_argument("--json", action="store_true")

    serve_parser = subparsers.add_parser("serve", help=argparse.SUPPRESS)
    serve_parser.add_argument("--management", action="store_true")
    serve_parser.add_argument("--contract", default=DEFAULT_CONTRACT)
    serve_parser.add_argument("--runtime-root", default=DEFAULT_RUNTIME_ROOT)
    serve_parser.add_argument("--lock-root", default=DEFAULT_LOCK_ROOT)
    serve_parser.add_argument("--systemctl", default="systemctl")
    serve_parser.add_argument("--btrfs", default="btrfs")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "serve":
        return serve(args)

    if args.command == "doctor":
        payload = {"version": PROTOCOL_VERSION, "operation": "doctor"}
    elif args.environment_command == "list":
        payload = {"version": PROTOCOL_VERSION, "operation": "environment.list"}
    elif args.environment_command == "inspect" and args.subject == "self":
        payload = {"version": PROTOCOL_VERSION, "operation": "environment.inspect-self"}
    elif args.environment_command == "inspect":
        payload = {
            "version": PROTOCOL_VERSION,
            "operation": "environment.inspect",
            "name": args.subject,
        }
    elif args.environment_command == "snapshot":
        payload = {
            "version": PROTOCOL_VERSION,
            "operation": f"environment.snapshot.{args.snapshot_command}",
            "name": args.name,
        }
        if args.snapshot_command != "list":
            payload["snapshot"] = args.snapshot
    else:
        payload = {
            "version": PROTOCOL_VERSION,
            "operation": "environment.reset",
            "name": args.name,
        }

    socket_path = args.socket
    if socket_path is None:
        socket_path = (
            DEFAULT_MANAGEMENT_SOCKET
            if payload["operation"] == "environment.reset"
            or payload["operation"].startswith("environment.snapshot.")
            else DEFAULT_SOCKET
        )
    try:
        return _print_response(_request(socket_path, payload), args.json)
    except (ConnectionError, FileNotFoundError, json.JSONDecodeError) as error:
        print(f"atlas: control socket unavailable: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
