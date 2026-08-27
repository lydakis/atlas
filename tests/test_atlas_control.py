import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from atlas_control import _read_request, _reset_environment, handle_request  # noqa: E402


SHARED_CGROUP = (
    "/atlas.slice/atlas-environments.slice/"
    "atlas-environments-shared\\x2ddev.slice/"
    "atlas-environment-shared\\x2ddev.service"
)
RESTRICTED_CGROUP = (
    "/atlas.slice/atlas-environments.slice/"
    "atlas-environments-restricted.slice/"
    "atlas-environment-restricted.service"
)

ENVIRONMENTS = {
    "restricted": {
        "id": "22222222-2222-4222-8222-222222222222",
        "name": "restricted",
        "uid": 23002,
        "process": {
            "cgroupPrefix": RESTRICTED_CGROUP,
            "serviceUnit": "atlas-environment-restricted.service",
        },
        "variables": {"DEMO_SCOPE": "restricted"},
        "volumes": [],
    },
    "shared-dev": {
        "id": "11111111-1111-4111-8111-111111111111",
        "name": "shared-dev",
        "uid": 23001,
        "process": {
            "cgroupPrefix": SHARED_CGROUP,
            "serviceUnit": "atlas-environment-shared\\x2ddev.service",
        },
        "variables": {
            "DEMO_API_ORIGIN": "https://example.invalid",
            "DEMO_OVERRIDE": "instance",
        },
        "volumes": [
            {
                "access": "read-write",
                "name": "projects",
                "target": "/home/agent/work",
            }
        ],
    },
}

DOCTOR = {
    "status": "experimental",
    "composition": {"declarative": True, "runtimeCreation": False},
}

CONTRACT = {
    "doctor": DOCTOR,
    "environments": ENVIRONMENTS,
    "environmentByUid": {"23001": "shared-dev", "23002": "restricted"},
    "environmentByCgroupPrefix": {
        RESTRICTED_CGROUP: "restricted",
        SHARED_CGROUP: "shared-dev",
    },
}


class AtlasControlProtocolTests(unittest.TestCase):
    def setUp(self):
        self.reset_names = []

    def request(self, peer_uid, payload, peer_cgroup="", allow_reset=True):
        return handle_request(
            peer_uid=peer_uid,
            peer_cgroup=peer_cgroup,
            request=payload,
            contract=CONTRACT,
            reset_environment=(
                lambda environment: self.reset_names.append(environment["name"])
            )
            if allow_reset
            else None,
        )

    def test_inspect_self_derives_environment_from_peer_uid(self):
        response = self.request(
            23001,
            {"version": 1, "operation": "environment.inspect-self"},
        )
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["name"], "shared-dev")
        self.assertNotIn("peerUid", response["result"])

    def test_inspect_self_derives_namespaced_environment_from_anchored_cgroup(self):
        response = self.request(
            65534,
            {"version": 1, "operation": "environment.inspect-self"},
            f"0::{SHARED_CGROUP}/payload/agent.scope\n",
        )
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["name"], "shared-dev")

    def test_descendant_cgroup_named_for_another_environment_cannot_forge_identity(self):
        response = self.request(
            65534,
            {"version": 1, "operation": "environment.inspect-self"},
            f"0::{RESTRICTED_CGROUP}{SHARED_CGROUP}/payload\n",
        )
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["name"], "restricted")

    def test_exact_unit_name_under_an_untrusted_parent_does_not_confer_identity(self):
        response = self.request(
            65534,
            {"version": 1, "operation": "environment.inspect-self"},
            "0::/user.slice/user-1000.slice/atlas-environment-shared\\x2ddev.service\n",
        )
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "unknown_peer")

    def test_inspect_self_rejects_caller_authored_identity(self):
        for field, value in (
            ("environment", "restricted"),
            ("environmentId", ENVIRONMENTS["restricted"]["id"]),
            ("peerUid", 23002),
            ("project", "trusted-project"),
            ("agent", "trusted-agent"),
        ):
            with self.subTest(field=field):
                response = self.request(
                    23001,
                    {
                        "version": 1,
                        "operation": "environment.inspect-self",
                        field: value,
                    },
                )
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "invalid_request")

    def test_unknown_peer_fails_closed(self):
        response = self.request(
            65534,
            {"version": 1, "operation": "environment.inspect-self"},
            "0::/user.slice/user-1000.slice/session-1.scope\n",
        )
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "unknown_peer")

    def test_named_inspection_is_public_but_confers_no_identity(self):
        response = self.request(
            65534,
            {"version": 1, "operation": "environment.inspect", "name": "shared-dev"},
        )
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["variables"]["DEMO_OVERRIDE"], "instance")

    def test_environment_list_is_deterministic(self):
        response = self.request(65534, {"version": 1, "operation": "environment.list"})
        self.assertTrue(response["ok"])
        self.assertEqual(
            [environment["name"] for environment in response["result"]],
            ["restricted", "shared-dev"],
        )

    def test_doctor_reports_adapter_capability(self):
        response = self.request(65534, {"version": 1, "operation": "doctor"})
        self.assertEqual(response, {"ok": True, "result": DOCTOR})

    def test_root_operator_can_reset_through_management_surface(self):
        response = self.request(
            0,
            {"version": 1, "operation": "environment.reset", "name": "shared-dev"},
        )
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["name"], "shared-dev")
        self.assertEqual(response["result"]["preservedVolumes"], ["projects"])
        self.assertEqual(self.reset_names, ["shared-dev"])

    def test_public_surface_does_not_expose_reset_even_to_root(self):
        response = self.request(
            0,
            {"version": 1, "operation": "environment.reset", "name": "shared-dev"},
            allow_reset=False,
        )
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "unavailable")

    def test_environment_cannot_reset_itself(self):
        response = self.request(
            23001,
            {"version": 1, "operation": "environment.reset", "name": "shared-dev"},
        )
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "forbidden")
        self.assertEqual(self.reset_names, [])

    def _runtime_fixture(self, temporary_directory):
        runtime_root = Path(temporary_directory) / "environments"
        runtime_parent = runtime_root / ENVIRONMENTS["shared-dev"]["id"]
        root = runtime_parent / "rootfs"
        root.mkdir(parents=True)
        ready = runtime_parent / "rootfs.ready"
        ready.write_text("ready\n", encoding="utf-8")
        lock_root = Path(temporary_directory) / "locks"
        outside = Path(temporary_directory) / "durable-volume"
        outside.mkdir()
        (outside / "repository").write_text("durable", encoding="utf-8")
        environment = {
            **ENVIRONMENTS["shared-dev"],
            "runtime": {
                "readyHostPath": str(ready),
                "rootHostPath": str(root),
            },
        }
        return environment, runtime_root, lock_root, root, ready, outside

    def test_reset_stops_and_verifies_instance_before_detaching_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, outside = self._runtime_fixture(
                temporary_directory
            )
            (root / "installed-tool").write_text("disposable", encoding="utf-8")
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
            ]
            empty_mountinfo = Path(temporary_directory) / "empty-mountinfo"
            empty_mountinfo.touch()

            with mock.patch("atlas_control.subprocess.run", side_effect=completed) as run:
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(lock_root),
                    systemctl="/bin/systemctl",
                    mountinfo_path=str(empty_mountinfo),
                )

            self.assertFalse(root.exists())
            self.assertFalse(ready.exists())
            self.assertEqual((outside / "repository").read_text(), "durable")
            self.assertEqual(
                run.call_args_list[0].args[0],
                ["/bin/systemctl", "stop", "atlas-environment-shared\\x2ddev.service"],
            )
            self.assertEqual(
                run.call_args_list[1].args[0],
                [
                    "/bin/systemctl",
                    "is-active",
                    "--quiet",
                    "atlas-environment-shared\\x2ddev.service",
                ],
            )
            self.assertEqual(list(root.parent.glob(".deleting-*")), [])

    def test_reset_preserves_root_when_stop_fails(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, _ = self._runtime_fixture(
                temporary_directory
            )
            with mock.patch(
                "atlas_control.subprocess.run",
                side_effect=subprocess.CalledProcessError(1, ["systemctl", "stop"]),
            ):
                with self.assertRaises(subprocess.CalledProcessError):
                    _reset_environment(
                        environment,
                        runtime_root=str(runtime_root),
                        lock_root=str(lock_root),
                        systemctl="/bin/systemctl",
                    )
            self.assertTrue(root.exists())
            self.assertTrue(ready.exists())

    def test_reset_preserves_root_when_instance_remains_active(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, _ = self._runtime_fixture(
                temporary_directory
            )
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 0),
            ]
            with mock.patch("atlas_control.subprocess.run", side_effect=completed):
                with self.assertRaisesRegex(RuntimeError, "remains active"):
                    _reset_environment(
                        environment,
                        runtime_root=str(runtime_root),
                        lock_root=str(lock_root),
                        systemctl="/bin/systemctl",
                    )
            self.assertTrue(root.exists())
            self.assertTrue(ready.exists())

    def test_reset_refuses_mounts_below_runtime_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, _ = self._runtime_fixture(
                temporary_directory
            )
            mountinfo = Path(temporary_directory) / "mountinfo"
            mountinfo.write_text(
                f"10 1 0:1 / {root}/home/agent/work rw - tmpfs tmpfs rw\n",
                encoding="utf-8",
            )
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
            ]
            with mock.patch("atlas_control.subprocess.run", side_effect=completed):
                with self.assertRaisesRegex(RuntimeError, "mounts remain"):
                    _reset_environment(
                        environment,
                        runtime_root=str(runtime_root),
                        lock_root=str(lock_root),
                        systemctl="/bin/systemctl",
                        mountinfo_path=str(mountinfo),
                    )
            self.assertTrue(root.exists())
            self.assertTrue(ready.exists())

    def test_reset_rejects_a_runtime_root_outside_the_managed_boundary(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            runtime_root = Path(temporary_directory) / "environments"
            outside = Path(temporary_directory) / "outside"
            outside.mkdir()
            environment = {
                **ENVIRONMENTS["shared-dev"],
                "runtime": {
                    "readyHostPath": str(outside / "ready"),
                    "rootHostPath": str(outside),
                },
            }
            with self.assertRaisesRegex(ValueError, "outside the managed boundary"):
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(Path(temporary_directory) / "locks"),
                    systemctl="/bin/systemctl",
                )
            self.assertTrue(outside.exists())

    def test_partial_request_expires_on_total_deadline(self):
        server, client = socket.socketpair()
        self.addCleanup(server.close)
        self.addCleanup(client.close)
        client.sendall(b"{")
        with self.assertRaisesRegex(ValueError, "deadline"):
            _read_request(server, timeout_seconds=0.01)

    def test_wrong_protocol_version_is_rejected(self):
        response = self.request(
            23001,
            {"version": 2, "operation": "environment.inspect-self"},
        )
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "unsupported_version")


if __name__ == "__main__":
    unittest.main()
