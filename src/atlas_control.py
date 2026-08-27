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
from pathlib import Path
from typing import Any, Callable


PROTOCOL_VERSION = 1
DEFAULT_SOCKET = "/run/atlas/control.sock"
DEFAULT_MANAGEMENT_SOCKET = "/run/atlas/manage.sock"
DEFAULT_CONTRACT = "/etc/atlas/control-contract.json"
DEFAULT_RUNTIME_ROOT = "/run/atlas/environments"
DEFAULT_LOCK_ROOT = "/run/atlas/locks"
DEFAULT_MOUNTINFO = "/proc/self/mountinfo"
MAX_REQUEST_BYTES = 64 * 1024
REQUEST_DEADLINE_SECONDS = 2.0
MAX_CONCURRENT_CONNECTIONS = 16


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
    except FileNotFoundError:
        return []
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


def _reset_environment(
    environment: dict[str, Any],
    *,
    runtime_root: str,
    lock_root: str,
    systemctl: str,
    mountinfo_path: str = DEFAULT_MOUNTINFO,
) -> None:
    environment_id = environment.get("id")
    if not isinstance(environment_id, str) or re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        environment_id,
    ) is None:
        raise ValueError("environment identity is invalid")

    root = Path(runtime_root) / environment_id / "rootfs"
    expected_root = Path(environment["runtime"]["rootHostPath"])
    ready = root.parent / "rootfs.ready"
    expected_ready = Path(environment["runtime"]["readyHostPath"])
    if root != expected_root or ready != expected_ready:
        raise ValueError("environment runtime root is outside the managed boundary")

    service = environment["process"]["serviceUnit"]
    if re.fullmatch(r"atlas-environment-[A-Za-z0-9\\x]+\.service", service) is None:
        raise ValueError("environment service unit is invalid")

    locks = Path(lock_root)
    locks.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = locks / f"{environment_id}.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
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

        if root.exists():
            tombstone = root.parent / f".deleting-{uuid.uuid4()}"
            root.rename(tombstone)
            ready.unlink(missing_ok=True)
            shutil.rmtree(tombstone)
        else:
            ready.unlink(missing_ok=True)
    finally:
        os.close(lock_fd)


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
            if args.management:
                reset = lambda environment: _reset_environment(
                    environment,
                    runtime_root=args.runtime_root,
                    lock_root=args.lock_root,
                    systemctl=args.systemctl,
                )
            response = handle_request(
                peer_uid=peer_uid,
                peer_cgroup=_peer_cgroup(peer_pid),
                request=_read_request(connection),
                contract=contract,
                reset_environment=reset,
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

    serve_parser = subparsers.add_parser("serve", help=argparse.SUPPRESS)
    serve_parser.add_argument("--management", action="store_true")
    serve_parser.add_argument("--contract", default=DEFAULT_CONTRACT)
    serve_parser.add_argument("--runtime-root", default=DEFAULT_RUNTIME_ROOT)
    serve_parser.add_argument("--lock-root", default=DEFAULT_LOCK_ROOT)
    serve_parser.add_argument("--systemctl", default="systemctl")
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
            else DEFAULT_SOCKET
        )
    try:
        return _print_response(_request(socket_path, payload), args.json)
    except (ConnectionError, FileNotFoundError, json.JSONDecodeError) as error:
        print(f"atlas: control socket unavailable: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
