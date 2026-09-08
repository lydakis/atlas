import base64
import fcntl
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from atlas.controllers import ControllerStore
from atlas.control import handle_request
from atlas.lifecycle import ControlOperationError


def public_key(byte=1):
    blob = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + bytes([byte]) * 32
    return "ssh-ed25519 " + base64.b64encode(blob).decode()


class ControllerTests(unittest.TestCase):
    def test_contended_registry_rejects_mutation_without_lost_updates(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ControllerStore(directory)
            with Path(directory, "registry.lock").open("w") as owner:
                fcntl.flock(owner, fcntl.LOCK_EX)
                with self.assertRaises(ControlOperationError) as error:
                    store.pair("laptop", public_key())
                self.assertEqual(error.exception.code, "controller_busy")
            self.assertEqual(store.list(), [])
            store.pair("laptop", public_key())

    def test_pair_revoke_and_explicit_repair_persist(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ControllerStore(directory)
            paired = store.pair("laptop", public_key())
            self.assertEqual(store.pair("laptop", public_key()), paired)
            reopened = ControllerStore(directory)
            self.assertEqual(reopened.list(), [paired])
            revoked = reopened.revoke(paired["id"])
            self.assertEqual(revoked["status"], "revoked")
            self.assertEqual(reopened.revoke(paired["id"]), revoked)
            self.assertEqual(store.list(), [revoked])
            repaired = store.pair("laptop", public_key())
            self.assertEqual(repaired["id"], paired["id"])
            self.assertGreater(repaired["generation"], paired["generation"])

    def test_key_and_name_cannot_silently_replace_an_active_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ControllerStore(directory)
            paired = store.pair("laptop", public_key())
            for name, key in (("laptop", public_key(2)), ("other", public_key())):
                with self.assertRaises(ControlOperationError):
                    store.pair(name, key)
            self.assertEqual(store.list(), [paired])

    def test_invalid_keys_and_names_do_not_create_records(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ControllerStore(directory)
            for key in ("secret", public_key() + "\n" + public_key(2), "ssh-ed25519 AAAA", "ssh-rsa AAAA"):
                with self.assertRaises(ValueError):
                    store.pair("laptop", key)
            with self.assertRaises(ValueError):
                store.pair("../outside", public_key())
            self.assertEqual(store.list(), [])

    def test_corrupt_store_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "controllers.json").write_text('{"version": 999}')
            with self.assertRaises(ValueError):
                ControllerStore(directory).list()

    def test_all_registry_operations_require_root_management_surface(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ControllerStore(directory)
            for operation, fields in (("list", {}), ("pair", {"name": "laptop", "publicKey": public_key()}), ("revoke", {"id": "missing"})):
                request = {"version": 1, "operation": "controller." + operation, **fields}
                for uid, registry in ((1000, store), (0, None)):
                    response = handle_request(peer_uid=uid, request=request, contract={"environments": {}}, controllers=registry)
                    self.assertEqual(response["error"]["code"], "forbidden")
            response = handle_request(peer_uid=0, request={"version": 1, "operation": "controller.pair", "name": "laptop", "publicKey": public_key()}, contract={"environments": {}}, controllers=store)
            self.assertTrue(response["ok"])
            self.assertEqual(len(store.list()), 1)
