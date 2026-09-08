"""Durable receipts for independently supervised lifecycle workers.

These are management execution records, not agent tasks or environments.
An ambiguous result retains the interlock; it never triggers mutation replay.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import tempfile
import uuid
from contextlib import contextmanager
from pathlib import Path

from .lifecycle import ControlOperationError, DEFAULT_LOCK_ROOT

DEFAULT_OPERATION_ROOT = "/var/lib/atlas/operations"


def assert_admitted(environment_id):
    active = Path(DEFAULT_OPERATION_ROOT) / "active" / _identifier(environment_id)
    try:
        identifier = json.loads(active.read_text())
    except FileNotFoundError:
        return
    if _identifier(identifier) != os.environ.get("ATLAS_OPERATION_ID"):
        status = OperationStore(root=DEFAULT_OPERATION_ROOT).inspect(identifier)
        if status.get("environmentId") == environment_id and status.get("status") in ("succeeded", "failed"):
            return  # Result is durable; admission cleanup may have been interrupted.
        raise ControlOperationError("lifecycle_busy", f"management operation {identifier} retains authority")


def _identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9-]{1,64}", value):
        raise ValueError("invalid operation identity")
    return value


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write(path, value):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def launch_worker(identifier):
    # A separate unit is deliberately not PartOf atlas-manage.service.
    subprocess.run(
        ["systemctl", "start", "--no-block", f"atlas-operation@{_identifier(identifier)}.service"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10,
    )


class OperationStore:
    def __init__(self, root=DEFAULT_OPERATION_ROOT, lock_root=DEFAULT_LOCK_ROOT, launch=launch_worker):
        self.root = Path(root)
        self.lock_root = Path(lock_root)
        self.launch = launch

    def active_path(self, environment_id):
        return self.root / "active" / _identifier(environment_id)

    def _record_path(self, identifier):
        return self.root / f"{_identifier(identifier)}.json"

    @contextmanager
    def _lock(self, path):
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ControlOperationError("lifecycle_busy", "another lifecycle operation is active") from error
            yield
        finally:
            os.close(descriptor)

    def submit(self, environment_id, payload):
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        (self.root / "active").mkdir(mode=0o700, exist_ok=True)
        self.lock_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        active = self.active_path(environment_id)
        with self._lock(self.lock_root / f"{_identifier(environment_id)}.lock"):
            if active.exists():
                identifier = json.loads(active.read_text())
                status = self.inspect(_identifier(identifier))
                if status.get("environmentId") == environment_id and status.get("status") in ("succeeded", "failed"):
                    active.unlink()
                else:
                    raise ControlOperationError("lifecycle_busy", f"inspect management operation {identifier} before retrying")
            identifier = str(uuid.uuid4())
            record = {"id": identifier, "environmentId": environment_id, "status": "pending", "payload": payload}
            _write(self._record_path(identifier), record)
            # Publish admission before launching. A lost launch acknowledgement
            # can be recovered using this same identity, never a fresh mutation.
            _write(active, identifier)
        try:
            self.launch(identifier)
        except (OSError, subprocess.SubprocessError):
            pass  # Pending receipt remains inspectable and restartable.
        return self.inspect(identifier)

    def inspect(self, identifier):
        record = json.loads(self._record_path(identifier).read_text())
        return {key: record[key] for key in ("id", "environmentId", "status", "response") if key in record}

    def recover_status(self, identifier):
        status = self.inspect(identifier)
        if status["status"] in ("succeeded", "failed"):
            # Recover a crash between result commit and admission cleanup.
            self._clear_admission(status)
        if status["status"] == "pending":
            self.launch(identifier)  # Same unit and receipt; execute is once-only.
        elif status["status"] == "running":
            result = subprocess.run(
                ["systemctl", "show", f"atlas-operation@{_identifier(identifier)}.service", "--property=ActiveState", "--value"],
                capture_output=True, text=True, check=True, timeout=10,
            )
            # Read again: the worker may have committed its result during show.
            status = self.inspect(identifier)
            if status["status"] == "running" and result.stdout.strip() not in ("active", "activating", "deactivating"):
                status["status"] = "unknown"
        return status

    def _clear_admission(self, record):
        try:
            with self._lock(self.lock_root / f"{_identifier(record['environmentId'])}.lock"):
                active = self.active_path(record["environmentId"])
                if active.exists() and json.loads(active.read_text()) == record["id"]:
                    active.unlink()
                    _sync_directory(active.parent)
        except ControlOperationError:
            pass  # A later inspect retries cleanup without disturbing its owner.

    def execute(self, identifier, execute):
        with self._lock(self.root / f"{_identifier(identifier)}.lock"):
            path = self._record_path(identifier)
            record = json.loads(path.read_text())
            if record["status"] != "pending":
                return  # Never replay a started operation, even after a crash.
            active = self.active_path(record["environmentId"])
            if json.loads(active.read_text()) != identifier:
                raise RuntimeError("operation admission changed")
            record["status"] = "running"
            _write(path, record)
            try:
                response = execute(record["payload"])
            except Exception:
                response = {"ok": False, "error": {"code": "internal_error", "message": "operation outcome is unknown"}}
            record["response"] = response
            # Known preflight failures did not submit a mutation. All other
            # failures conservatively retain admission for reconciliation.
            safe_failure = response.get("error", {}).get("code") in {
                "conflict", "reset_required", "invalid_request", "not_found", "forbidden", "unavailable", "incus_timeout", "incus_query_failed", "verification_failed", "lifecycle_busy", "preflight_failed",
            }
            record["status"] = "succeeded" if response.get("ok") else "failed" if safe_failure else "unknown"
            _write(path, record)
            if record["status"] != "unknown":
                self._clear_admission(record)
