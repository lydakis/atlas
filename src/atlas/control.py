"""Local control surfaces for the Atlas Environment Entry adapter."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from typing import Any

from .lifecycle import (
    DEFAULT_LOCK_ROOT,
    DEFAULT_RUNTIME_ROOT,
    ControlOperationError,
    EnvironmentLifecycle,
)


PROTOCOL_VERSION = 1
DEFAULT_SOCKET = "/run/atlas/control.sock"
DEFAULT_MANAGEMENT_SOCKET = "/run/atlas/manage.sock"
DEFAULT_CONTRACT = "/etc/atlas/control-contract.json"
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
    lifecycle: EnvironmentLifecycle | None = None,
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
        if lifecycle is None:
            return _error("unavailable", "reset is unavailable on this control surface")
        name = request["name"]
        if not isinstance(name, str) or name not in environments:
            return _error("not_found", "environment does not exist")
        environment = environments[name]
        lifecycle.reset(environment)
        return _success(
            {
                "name": name,
                "preservedVolumes": sorted(
                    mount["name"] for mount in environment.get("volumes", [])
                ),
                "reset": True,
            }
        )

    snapshot_methods = {
        "environment.snapshot.create": "create_snapshot",
        "environment.snapshot.list": "list_snapshots",
        "environment.snapshot.restore": "restore_snapshot",
        "environment.snapshot.delete": "delete_snapshot",
    }
    if operation in snapshot_methods:
        expected = {"version", "operation", "name"}
        if operation != "environment.snapshot.list":
            expected.add("snapshot")
        if not _has_exact_keys(request, expected):
            return _error(
                "invalid_request",
                f"{operation} requires exactly {', '.join(sorted(expected - {'version', 'operation'}))}",
            )
        if peer_uid != 0:
            return _error(
                "forbidden", "environment snapshot management requires host root"
            )
        if lifecycle is None or not lifecycle.snapshots_enabled:
            return _error("unavailable", "environment snapshots are unavailable")
        name = request["name"]
        if not isinstance(name, str) or name not in environments:
            return _error("not_found", "environment does not exist")
        environment = environments[name]

        if operation == "environment.snapshot.list":
            try:
                snapshots = lifecycle.list_snapshots(environment)
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
            method = getattr(lifecycle, snapshot_methods[operation])
            method(environment, snapshot)
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
            lifecycle = None
            if args.management:
                lifecycle = EnvironmentLifecycle(
                    runtime_root=args.runtime_root,
                    lock_root=args.lock_root,
                    systemctl=args.systemctl,
                    btrfs=args.btrfs,
                    snapshots_enabled=bool(
                        contract.get("doctor", {}).get("storage", {}).get("snapshots")
                    ),
                )
            response = handle_request(
                peer_uid=peer_uid,
                peer_cgroup=_peer_cgroup(peer_pid),
                request=_read_request(connection),
                contract=contract,
                lifecycle=lifecycle,
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
