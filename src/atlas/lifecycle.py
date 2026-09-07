"""Incus lifecycle orchestration behind the Atlas control protocol."""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any


DEFAULT_LOCK_ROOT = "/run/atlas/locks"
INCUS_QUERY_TIMEOUT_SECONDS = 60
MAX_INCUS_DIAGNOSTIC_BYTES = 4096
SNAPSHOT_CONFIGURATION_MISMATCH = 20
VolumeFingerprint = (
    tuple[Path, str, str]
    | tuple[Path, str, int, int]
)


class ControlOperationError(Exception):
    """An expected lifecycle error safe to return to the local operator."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _incus_environment_state(environment: dict[str, Any]) -> dict[str, str]:
    environment_id = environment.get("id")
    if not isinstance(environment_id, str) or re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        environment_id,
    ) is None:
        raise ValueError("environment identity is invalid")

    name = environment.get("name")
    runtime = environment.get("runtime")
    if not isinstance(runtime, dict) or runtime.get("backend") != "incus-container":
        raise ValueError("environment runtime must use Incus")
    layout_id = runtime.get("layoutId")
    if not isinstance(layout_id, str) or re.fullmatch(r"[0-9a-f]{64}", layout_id) is None:
        raise ValueError("environment Incus layout identity is invalid")
    instance = runtime.get("instance")
    if (
        not isinstance(name, str)
        or re.fullmatch(r"[a-z][a-z0-9-]{0,19}", name) is None
        or not isinstance(instance, dict)
        or instance.get("name") != f"atlas-{name}"
    ):
        raise ValueError("environment Incus instance identity is invalid")

    commands = {}
    for key, description in (
        ("resetCommand", "reconcile"),
        ("verifyCommand", "verify"),
    ):
        command = instance.get(key)
        if (
            not isinstance(command, str)
            or not command.startswith("/nix/store/")
            or not Path(command).is_absolute()
            or os.path.normpath(command) != command
        ):
            raise ValueError(f"environment Incus {description} command is invalid")
        commands[key] = command

    return {
        "environment_id": environment_id,
        "instance": instance["name"],
        "layout_id": layout_id,
        "reset_command": commands["resetCommand"],
        "verify_command": commands["verifyCommand"],
    }


def _bounded_diagnostic(stderr: str | None) -> str:
    diagnostic = (stderr or "").strip()
    encoded = diagnostic.encode("utf-8", errors="replace")
    if len(encoded) <= MAX_INCUS_DIAGNOSTIC_BYTES:
        return diagnostic
    truncated = encoded[:MAX_INCUS_DIAGNOSTIC_BYTES].decode(
        "utf-8", errors="replace"
    )
    return f"{truncated}\n[truncated]"


def _run_incus(
    incus: str, *arguments: str, capture: bool = False, query: bool = False
) -> str:
    # Only read-only queries can safely time out here. Killing a mutation's CLI
    # does not cancel server-side work or make it safe to release its lock.
    try:
        result = subprocess.run(
            [incus, "--force-local", *arguments],
            check=False,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=INCUS_QUERY_TIMEOUT_SECONDS if query else None,
        )
    except subprocess.TimeoutExpired as error:
        # Even complete-looking partial output must not establish absence.
        raise ControlOperationError(
            "incus_timeout", "Incus query timed out; object state is unknown"
        ) from error
    if result.returncode != 0:
        diagnostic = _bounded_diagnostic(result.stderr)
        if diagnostic:
            print(f"atlas-lifecycle: Incus failed: {diagnostic}", file=sys.stderr)
        raise ControlOperationError(
            "incus_failed", "Incus could not complete the lifecycle operation"
        )
    return result.stdout if capture else ""


def _run_reset_command(command: str, lock_fd: int) -> None:
    environment = os.environ.copy()
    environment["ATLAS_LIFECYCLE_LOCK_FD"] = str(lock_fd)
    result = subprocess.run(
        [command],
        check=False,
        env=environment,
        pass_fds=(lock_fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = _bounded_diagnostic(result.stderr)
        if diagnostic:
            print(f"atlas-lifecycle: Incus reset failed: {diagnostic}", file=sys.stderr)
        raise ControlOperationError(
            "incus_failed", "Incus could not reset the environment"
        )


def _run_verify_command(
    command: str, lock_fd: int, instance: str, snapshot: str
) -> None:
    environment = os.environ.copy()
    environment["ATLAS_LIFECYCLE_LOCK_FD"] = str(lock_fd)
    result = subprocess.run(
        [command, instance, snapshot],
        check=False,
        env=environment,
        pass_fds=(lock_fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = _bounded_diagnostic(result.stderr)
        if diagnostic:
            print(
                f"atlas-lifecycle: Incus snapshot verification failed: {diagnostic}",
                file=sys.stderr,
            )
        if result.returncode == SNAPSHOT_CONFIGURATION_MISMATCH:
            raise ControlOperationError(
                "reset_required",
                "snapshot does not match the current environment layout",
            )
        raise ControlOperationError(
            "incus_failed", "Incus could not verify the snapshot"
        )


def _btrfs_subvolume_uuid(path: Path, btrfs: str | None) -> str | None:
    if btrfs is None:
        return None
    result = subprocess.run(
        [btrfs, "subvolume", "show", str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError("Atlas could not verify a Btrfs subvolume identity")
    match = re.search(
        r"^\s*UUID:\s+([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s*$",
        result.stdout,
        flags=re.MULTILINE,
    )
    if match is None:
        raise RuntimeError("Atlas could not read a Btrfs subvolume identity")
    return match.group(1).lower()


def _path_fingerprint(path: Path, btrfs: str | None) -> VolumeFingerprint:
    subvolume_uuid = _btrfs_subvolume_uuid(path, btrfs)
    if subvolume_uuid is not None:
        return path, "btrfs-subvolume", subvolume_uuid
    metadata = path.stat(follow_symlinks=False)
    return path, "directory", metadata.st_dev, metadata.st_ino


def _owner_home_fingerprint(
    environment: dict[str, Any], btrfs: str | None
) -> VolumeFingerprint | None:
    composition = environment.get("homeComposition", {})
    if not isinstance(composition, dict) or not composition.get("durable", False):
        return None
    raw_path = composition.get("durableHostPath")
    if not isinstance(raw_path, str) or not Path(raw_path).is_absolute():
        raise ValueError("durable owner home path is invalid")
    path = Path(raw_path)
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError("Atlas could not verify the durable owner home")
    return _path_fingerprint(path, btrfs)


def _require_preserved_owner_home(
    environment: dict[str, Any],
    before: VolumeFingerprint | None,
    btrfs: str | None,
) -> bool:
    after = _owner_home_fingerprint(environment, btrfs)
    if before != after:
        raise RuntimeError("Atlas durable owner home changed during the lifecycle operation")
    return before is not None


def _declared_volume_fingerprints(
    environment: dict[str, Any], btrfs: str | None
) -> dict[str, VolumeFingerprint]:
    fingerprints: dict[str, VolumeFingerprint] = {}
    volumes = environment.get("volumes", [])
    if not isinstance(volumes, list):
        raise ValueError("declared environment volumes are invalid")
    for volume in volumes:
        if not isinstance(volume, dict):
            raise ValueError("declared environment volume is invalid")
        name = volume.get("name")
        raw_path = volume.get("hostPath")
        if (
            not isinstance(name, str)
            or not name
            or name in fingerprints
            or not isinstance(raw_path, str)
            or not Path(raw_path).is_absolute()
        ):
            raise ValueError("declared environment volume is invalid")
        path = Path(raw_path)
        if path.is_symlink() or not path.is_dir():
            raise RuntimeError(f"Atlas could not verify declared volume {name}")
        fingerprints[name] = _path_fingerprint(path, btrfs)
    return fingerprints


def _require_preserved_volumes(
    environment: dict[str, Any],
    before: dict[str, VolumeFingerprint],
    btrfs: str | None,
) -> None:
    if before != _declared_volume_fingerprints(environment, btrfs):
        raise RuntimeError("Atlas declared volume changed during the lifecycle operation")


def _snapshot_inventory(incus: str, instance: str) -> list[str]:
    raw_snapshots = _run_incus(
        incus,
        "snapshot",
        "list",
        instance,
        "--format=json",
        capture=True,
        query=True,
    )
    try:
        records = json.loads(raw_snapshots)
    except (json.JSONDecodeError, TypeError) as error:
        raise RuntimeError("Incus returned an invalid snapshot inventory") from error
    if not isinstance(records, list):
        raise RuntimeError("Incus returned an invalid snapshot inventory")
    names = []
    for record in records:
        name = record.get("name") if isinstance(record, dict) else None
        if not isinstance(name, str) or re.fullmatch(
            r"[a-z][a-z0-9-]{0,39}", name
        ) is None:
            raise RuntimeError("Incus returned an invalid snapshot identity")
        names.append(name)
    return sorted(names)


def _object_inventory(incus: str, kind: str, name: str | None = None) -> list[str]:
    """Only a successful, valid inventory can establish object absence."""
    if kind == "instance":
        pattern = re.escape(name).replace(r"\-", "-") if name else "atlas-.*"
        arguments = ["list", f"^{pattern}$"]
    elif kind == "volume":
        arguments = ["storage", "volume", "list", "atlas"]
    elif kind == "acl":
        arguments = ["network", "acl", "list"]
    else:
        raise ValueError("unsupported Incus inventory kind")
    raw_instances = _run_incus(
        incus, *arguments, "--format=json", capture=True, query=True
    )
    try:
        records = json.loads(raw_instances)
    except (json.JSONDecodeError, TypeError) as error:
        raise RuntimeError("Incus returned an invalid object inventory") from error
    if not isinstance(records, list):
        raise RuntimeError("Incus returned an invalid object inventory")
    names = set()
    identities = set()
    for record in records:
        if not isinstance(record, dict):
            raise RuntimeError("Incus returned an invalid object identity")
        record_name = record.get("name")
        if not isinstance(record_name, str) or not record_name or any(
            character.isspace() for character in record_name
        ):
            raise RuntimeError("Incus returned an invalid object identity")
        volume_type = record.get("type") if kind == "volume" else None
        if kind == "volume" and volume_type not in ("custom", "container", "virtual-machine", "image"):
            raise RuntimeError("Incus returned an invalid volume type")
        identity = (volume_type, record_name)
        if identity in identities:
            raise RuntimeError("Incus returned an ambiguous object inventory")
        identities.add(identity)
        if kind == "instance" and (
            (name is not None and record_name != name)
            or (name is None and not record_name.startswith("atlas-"))
        ):
            raise RuntimeError("Incus returned an unexpected instance identity")
        if kind != "volume" or volume_type == "custom":
            names.add(record_name)
    return sorted(names)


def _instance_exists(incus: str, instance: str) -> bool:
    return instance in _object_inventory(incus, "instance", instance)


@contextmanager
def _lifecycle_lock(environment_id: str, lock_root: str):
    locks = Path(lock_root)
    locks.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = locks / f"{environment_id}.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        yield lock_fd
    finally:
        os.close(lock_fd)


class EnvironmentLifecycle:
    """Reset and snapshot operations for one declared Incus environment."""

    def __init__(
        self,
        *,
        lock_root: str = DEFAULT_LOCK_ROOT,
        incus: str = "incus",
        btrfs: str | None = None,
        snapshots_enabled: bool = False,
    ):
        self.lock_root = lock_root
        self.incus = incus
        self.btrfs = btrfs
        self.snapshots_enabled = snapshots_enabled

    def reset(self, environment: dict[str, Any]) -> bool:
        state = _incus_environment_state(environment)
        with _lifecycle_lock(state["environment_id"], self.lock_root) as lock_fd:
            snapshots = (
                _snapshot_inventory(self.incus, state["instance"])
                if _instance_exists(self.incus, state["instance"])
                else []
            )
            if snapshots:
                raise ControlOperationError(
                    "conflict", "delete named snapshots before reset"
                )
            owner_home_before = _owner_home_fingerprint(environment, self.btrfs)
            volumes_before = _declared_volume_fingerprints(environment, self.btrfs)
            _run_reset_command(state["reset_command"], lock_fd)
            preserved_owner_home = _require_preserved_owner_home(
                environment, owner_home_before, self.btrfs
            )
            _require_preserved_volumes(environment, volumes_before, self.btrfs)
            return preserved_owner_home

    def create_snapshot(self, environment: dict[str, Any], snapshot: str) -> None:
        state = _incus_environment_state(environment)
        with _lifecycle_lock(state["environment_id"], self.lock_root):
            _run_incus(
                self.incus, "snapshot", "create", state["instance"], snapshot
            )

    def list_snapshots(self, environment: dict[str, Any]) -> list[str]:
        state = _incus_environment_state(environment)
        with _lifecycle_lock(state["environment_id"], self.lock_root):
            return _snapshot_inventory(self.incus, state["instance"])

    def restore_snapshot(self, environment: dict[str, Any], snapshot: str) -> bool:
        state = _incus_environment_state(environment)
        with _lifecycle_lock(state["environment_id"], self.lock_root) as lock_fd:
            _run_verify_command(
                state["verify_command"],
                lock_fd,
                state["instance"],
                snapshot,
            )
            owner_home_before = _owner_home_fingerprint(environment, self.btrfs)
            volumes_before = _declared_volume_fingerprints(environment, self.btrfs)
            _run_incus(
                self.incus, "snapshot", "restore", state["instance"], snapshot
            )
            preserved_owner_home = _require_preserved_owner_home(
                environment, owner_home_before, self.btrfs
            )
            _require_preserved_volumes(environment, volumes_before, self.btrfs)
            return preserved_owner_home

    def delete_snapshot(self, environment: dict[str, Any], snapshot: str) -> None:
        state = _incus_environment_state(environment)
        with _lifecycle_lock(state["environment_id"], self.lock_root):
            _run_incus(
                self.incus, "snapshot", "delete", state["instance"], snapshot
            )


def _query_main() -> int:
    """Private generated-service entry point, not part of the control protocol."""
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--incus", required=True)
    parser.add_argument("kind", choices=("instance", "volume", "acl"))
    parser.add_argument("name", nargs="?")
    arguments = parser.parse_args()
    try:
        names = _object_inventory(arguments.incus, arguments.kind, arguments.name)
    except (ControlOperationError, RuntimeError, OSError) as error:
        print(f"Atlas inventory failed: {error}", file=sys.stderr)
        return 1
    if arguments.name is None:
        for name in names:
            print(name)
    else:
        print("present" if arguments.name in names else "absent")
    return 0


if __name__ == "__main__":
    sys.exit(_query_main())
