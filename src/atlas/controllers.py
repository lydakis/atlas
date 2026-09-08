"""Host-local approval records. These do not authenticate a network peer."""

import base64
import binascii
import fcntl
import hashlib
import json
import os
import re
import tempfile
from contextlib import contextmanager
from pathlib import Path

from .lifecycle import ControlOperationError

DEFAULT_CONTROLLER_ROOT = "/var/lib/atlas/controllers"


def _name(value):
    if not isinstance(value, str) or re.fullmatch(r"[a-z][a-z0-9-]{0,39}", value) is None:
        raise ValueError("controller name must be a lowercase slug of at most 40 characters")
    return value


def _key(value):
    if not isinstance(value, str) or len(value) > 4096:
        raise ValueError("expected one OpenSSH Ed25519 public key")
    lines = value.strip().splitlines()
    fields = lines[0].split() if len(lines) == 1 else []
    if len(fields) < 2 or fields[0] != "ssh-ed25519":
        raise ValueError("expected one OpenSSH Ed25519 public key")
    try:
        blob = base64.b64decode(fields[1], validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("invalid public key encoding") from error
    prefix = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    if len(blob) != len(prefix) + 32 or not blob.startswith(prefix):
        raise ValueError("invalid Ed25519 public key structure")
    return hashlib.sha256(blob).hexdigest(), "ssh-ed25519 " + base64.b64encode(blob).decode()


class ControllerStore:
    def __init__(self, root=DEFAULT_CONTROLLER_ROOT):
        self.root = Path(root)

    @contextmanager
    def _locked(self):
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(self.root / "registry.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        except BlockingIOError as error:
            raise ControlOperationError("controller_busy", "controller registry is busy; retry later") from error
        finally:
            os.close(descriptor)

    def _read(self):
        try:
            state = json.loads((self.root / "controllers.json").read_text())
        except FileNotFoundError:
            return []
        if not isinstance(state, dict) or set(state) != {"version", "controllers"} or state["version"] != 1 or not isinstance(state["controllers"], list):
            raise ValueError("invalid controller registry")
        ids, names = set(), set()
        for record in state["controllers"]:
            if not isinstance(record, dict) or set(record) != {"id", "name", "publicKey", "status", "generation"}:
                raise ValueError("invalid controller record")
            identifier, key = _key(record["publicKey"])
            name = _name(record["name"])
            if record["id"] != identifier or record["publicKey"] != key or identifier in ids or record["status"] not in ("active", "revoked") or type(record["generation"]) is not int or record["generation"] < 1:
                raise ValueError("invalid controller record")
            ids.add(identifier)
            if record["status"] == "active":
                if name in names:
                    raise ValueError("duplicate active controller name")
                names.add(name)
        return state["controllers"]

    def _save(self, records):
        descriptor, temporary = tempfile.mkstemp(dir=self.root)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump({"version": 1, "controllers": records}, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.root / "controllers.json")
            directory = os.open(self.root, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def list(self):
        with self._locked():
            return sorted(self._read(), key=lambda record: (record["name"], record["id"]))

    def pair(self, name, public_key):
        name = _name(name)
        identifier, key = _key(public_key)
        with self._locked():
            records = self._read()
            previous = next((record for record in records if record["id"] == identifier), None)
            for record in records:
                if record["status"] == "active" and (record["name"] == name or record["id"] == identifier):
                    if record["name"] == name and record["id"] == identifier:
                        return record
                    raise ControlOperationError("conflict", "revoke the existing controller before replacing its name or key")
            paired = {"id": identifier, "name": name, "publicKey": key, "status": "active", "generation": previous["generation"] + 1 if previous else 1}
            self._save([record for record in records if record["id"] != identifier] + [paired])
            return paired

    def revoke(self, identifier):
        if not isinstance(identifier, str) or re.fullmatch(r"[0-9a-f]{64}", identifier) is None:
            raise ValueError("invalid controller identity")
        with self._locked():
            records = self._read()
            record = next((record for record in records if record["id"] == identifier), None)
            if record is None:
                raise ControlOperationError("not_found", "controller does not exist")
            if record["status"] != "revoked":
                record["status"] = "revoked"
                record["generation"] += 1
                self._save(records)
            return record
