"""Filesystem mechanics for Atlas environment lifecycle operations."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


MAX_BTRFS_DIAGNOSTIC_BYTES = 4096


def _run_btrfs(
    btrfs: str,
    *arguments: str,
    check: bool = True,
    capture_stdout: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    command = [btrfs, *arguments]
    result = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE if capture_stdout else subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raw_stderr = result.stderr or b""
        diagnostic = raw_stderr[:MAX_BTRFS_DIAGNOSTIC_BYTES].decode(
            "utf-8", errors="replace"
        )
        operation = " ".join(arguments[:2]) or "command"
        suffix = (
            " [truncated]"
            if len(raw_stderr) > MAX_BTRFS_DIAGNOSTIC_BYTES
            else ""
        )
        print(
            f"atlas-storage: btrfs {operation} failed with exit status "
            f"{result.returncode}: {diagnostic!r}{suffix}",
            file=sys.stderr,
        )
        raise subprocess.CalledProcessError(result.returncode, command)
    return result


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
    result = _run_btrfs(
        btrfs,
        "subvolume",
        "list",
        "-o",
        str(path),
        capture_stdout=True,
    )
    return bool((result.stdout or b"").strip())


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
