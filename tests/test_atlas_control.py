import fcntl
import io
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from atlas.control import (  # noqa: E402
    DEFAULT_SOCKET,
    _read_request,
    build_parser,
    handle_request,
)
from atlas.lifecycle import (  # noqa: E402
    MAX_INCUS_DIAGNOSTIC_BYTES,
    ControlOperationError,
    EnvironmentLifecycle,
)


SHARED_CGROUP = "/lxc.payload.atlas-shared-dev"
RESTRICTED_CGROUP = "/lxc.payload.atlas-restricted"

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
        "homeComposition": {"durable": False, "resettablePaths": []},
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
        "homeComposition": {
            "durable": True,
            "durableHostPath": "/var/lib/atlas/volumes/owner/data",
            "resettablePaths": [".config"],
        },
        "volumes": [
            {
                "access": "read-write",
                "hostPath": "/var/lib/atlas/volumes/projects/data",
                "name": "projects",
                "target": "/home/owner/Projects",
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


class RecordingLifecycle:
    snapshots_enabled = True

    def __init__(self):
        self.reset_names = []
        self.snapshot_calls = []

    def reset(self, environment):
        self.reset_names.append(environment["name"])
        return bool(environment.get("homeComposition", {}).get("durable", False))

    def create_snapshot(self, environment, snapshot):
        self.snapshot_calls.append(("create", environment["name"], snapshot))

    def list_snapshots(self, _environment):
        return ["baseline", "working"]

    def restore_snapshot(self, environment, snapshot):
        self.snapshot_calls.append(("restore", environment["name"], snapshot))
        return bool(environment.get("homeComposition", {}).get("durable", False))

    def delete_snapshot(self, environment, snapshot):
        self.snapshot_calls.append(("delete", environment["name"], snapshot))


class AtlasControlProtocolTests(unittest.TestCase):
    def setUp(self):
        self.lifecycle = RecordingLifecycle()

    def request(self, peer_uid, payload, peer_cgroup="", allow_management=True):
        return handle_request(
            peer_uid=peer_uid,
            peer_cgroup=peer_cgroup,
            request=payload,
            contract=CONTRACT,
            lifecycle=self.lifecycle if allow_management else None,
        )

    def test_default_socket_uses_the_public_control_namespace(self):
        self.assertEqual(DEFAULT_SOCKET, "/run/atlas/public/control.sock")

    def test_inspect_self_derives_environment_from_peer_uid(self):
        response = self.request(
            23001,
            {"version": 1, "operation": "environment.inspect-self"},
        )
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["name"], "shared-dev")

    def test_host_bound_listener_confers_its_declared_environment_identity(self):
        response = handle_request(
            peer_uid=65534,
            peer_cgroup="0::/untrusted/proxy",
            request={"version": 1, "operation": "environment.inspect-self"},
            contract=CONTRACT,
            trusted_environment="shared-dev",
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
        self.assertTrue(response["result"]["preservedOwnerHome"])
        self.assertEqual(self.lifecycle.reset_names, ["shared-dev"])

    def test_reset_reports_when_an_environment_has_no_durable_owner_home(self):
        response = self.request(
            0,
            {"version": 1, "operation": "environment.reset", "name": "restricted"},
        )
        self.assertTrue(response["ok"])
        self.assertFalse(response["result"]["preservedOwnerHome"])

    def test_reset_returns_the_bounded_lifecycle_error(self):
        self.lifecycle.reset = mock.Mock(
            side_effect=ControlOperationError(
                "incus_failed", "Incus could not complete the requested operation"
            )
        )

        response = self.request(
            0,
            {"version": 1, "operation": "environment.reset", "name": "shared-dev"},
        )

        self.assertEqual(
            response,
            {
                "ok": False,
                "error": {
                    "code": "incus_failed",
                    "message": "Incus could not complete the requested operation",
                },
            },
        )

    def test_public_surface_does_not_expose_reset_even_to_root(self):
        response = self.request(
            0,
            {"version": 1, "operation": "environment.reset", "name": "shared-dev"},
            allow_management=False,
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
        self.assertEqual(self.lifecycle.reset_names, [])

    def test_root_operator_can_manage_environment_snapshots(self):
        cases = [
            (
                {"version": 1, "operation": "environment.snapshot.create", "name": "shared-dev", "snapshot": "baseline"},
                {"created": True, "name": "shared-dev", "snapshot": "baseline"},
                ("create", "shared-dev", "baseline"),
            ),
            (
                {"version": 1, "operation": "environment.snapshot.restore", "name": "shared-dev", "snapshot": "baseline"},
                {
                    "name": "shared-dev",
                    "preservedOwnerHome": True,
                    "preservedVolumes": ["projects"],
                    "restored": True,
                    "snapshot": "baseline",
                },
                ("restore", "shared-dev", "baseline"),
            ),
            (
                {"version": 1, "operation": "environment.snapshot.delete", "name": "shared-dev", "snapshot": "baseline"},
                {"deleted": True, "name": "shared-dev", "snapshot": "baseline"},
                ("delete", "shared-dev", "baseline"),
            ),
        ]
        for request, expected, call in cases:
            with self.subTest(operation=request["operation"]):
                response = self.request(0, request)
                self.assertEqual(response, {"ok": True, "result": expected})
                self.assertEqual(self.lifecycle.snapshot_calls[-1], call)

        listed = self.request(
            0,
            {"version": 1, "operation": "environment.snapshot.list", "name": "shared-dev"},
        )
        self.assertEqual(
            listed,
            {
                "ok": True,
                "result": {
                    "name": "shared-dev",
                    "snapshots": ["baseline", "working"],
                },
            },
        )

    def test_snapshot_management_rejects_unprivileged_or_public_callers(self):
        request = {
            "version": 1,
            "operation": "environment.snapshot.create",
            "name": "shared-dev",
            "snapshot": "baseline",
        }
        self.assertEqual(self.request(23001, request)["error"]["code"], "forbidden")
        self.assertEqual(
            self.request(0, request, allow_management=False)["error"]["code"],
            "unavailable",
        )

    def test_snapshot_names_are_bounded_slugs(self):
        for snapshot in ("../escape", ".hidden", "UPPER", "a" * 41):
            with self.subTest(snapshot=snapshot):
                response = self.request(
                    0,
                    {
                        "version": 1,
                        "operation": "environment.snapshot.create",
                        "name": "shared-dev",
                        "snapshot": snapshot,
                    },
                )
                self.assertEqual(response["error"]["code"], "invalid_request")


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

    def test_serve_rejects_combined_management_and_environment_identity(self):
        with (
            mock.patch("sys.stderr", io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            build_parser().parse_args(
                ["serve", "--management", "--environment", "shared-dev"]
            )


class EnvironmentLifecycleTests(unittest.TestCase):
    def fixture(self, temporary_directory):
        durable_home = Path(temporary_directory) / "durable-home"
        durable_home.mkdir()
        (durable_home / "repository").write_text("durable", encoding="utf-8")
        durable_volume = Path(temporary_directory) / "durable-volume"
        durable_volume.mkdir()
        (durable_volume / "source").write_text("durable", encoding="utf-8")
        environment = {
            **ENVIRONMENTS["shared-dev"],
            "homeComposition": {
                **ENVIRONMENTS["shared-dev"]["homeComposition"],
                "durableHostPath": str(durable_home),
            },
            "volumes": [
                {
                    **ENVIRONMENTS["shared-dev"]["volumes"][0],
                    "hostPath": str(durable_volume),
                }
            ],
            "runtime": {
                "backend": "incus-container",
                "layoutId": "f" * 64,
                "instance": {
                    "name": "atlas-shared-dev",
                    "resetCommand": "/nix/store/atlas-reconcile-shared-dev",
                    "verifyCommand": "/nix/store/atlas-verify-shared-dev",
                },
            },
        }
        lifecycle = EnvironmentLifecycle(
            lock_root=str(Path(temporary_directory) / "locks"),
            incus="/bin/incus",
            snapshots_enabled=True,
        )
        return lifecycle, environment, durable_home

    def test_reset_reconciles_instance_while_preserving_owner_home(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, durable_home = self.fixture(temporary_directory)
            completed = subprocess.CompletedProcess([], 0, stderr="")
            instances = subprocess.CompletedProcess(
                [], 0, stdout='[{"name":"atlas-shared-dev"}]\n', stderr=""
            )
            snapshots = subprocess.CompletedProcess([], 0, stdout="[]\n", stderr="")

            with mock.patch(
                "atlas.lifecycle.subprocess.run",
                side_effect=[instances, snapshots, completed],
            ) as run:
                preserved_owner_home = lifecycle.reset(environment)

            self.assertTrue(preserved_owner_home)
            self.assertEqual((durable_home / "repository").read_text(), "durable")
            self.assertEqual(
                [call.args[0] for call in run.call_args_list],
                [
                    [
                        "/bin/incus",
                        "--force-local",
                        "list",
                        "^atlas-shared-dev$",
                        "--format=json",
                    ],
                    [
                        "/bin/incus",
                        "--force-local",
                        "snapshot",
                        "list",
                        "atlas-shared-dev",
                        "--format=json",
                    ],
                    ["/nix/store/atlas-reconcile-shared-dev"],
                ],
            )
            reset_call = run.call_args_list[2]
            inherited_lock_fd = reset_call.kwargs["pass_fds"][0]
            self.assertEqual(
                reset_call.kwargs["env"]["ATLAS_LIFECYCLE_LOCK_FD"],
                str(inherited_lock_fd),
            )

    def test_reset_fails_if_a_declared_volume_is_replaced(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            durable_volume = Path(environment["volumes"][0]["hostPath"])

            def replace_volume(arguments, **_keywords):
                if arguments[0] == "/bin/incus":
                    if arguments[2] == "list":
                        return subprocess.CompletedProcess(
                            [],
                            0,
                            stdout='[{"name":"atlas-shared-dev"}]\n',
                            stderr="",
                        )
                    return subprocess.CompletedProcess(
                        [], 0, stdout="[]\n", stderr=""
                    )
                durable_volume.rename(durable_volume.with_name("replaced-volume"))
                durable_volume.mkdir()
                return subprocess.CompletedProcess([], 0, stderr="")

            with (
                mock.patch("atlas.lifecycle.subprocess.run", side_effect=replace_volume),
                self.assertRaisesRegex(RuntimeError, "declared volume changed"),
            ):
                lifecycle.reset(environment)

    def test_reset_refuses_to_destroy_named_snapshots(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            snapshots = subprocess.CompletedProcess(
                [], 0, stdout='[{"name":"baseline"}]\n', stderr=""
            )
            instances = subprocess.CompletedProcess(
                [], 0, stdout='[{"name":"atlas-shared-dev"}]\n', stderr=""
            )

            with (
                mock.patch(
                    "atlas.lifecycle.subprocess.run",
                    side_effect=[instances, snapshots],
                ) as run,
                self.assertRaisesRegex(
                    ControlOperationError, "delete named snapshots before reset"
                ) as raised,
            ):
                lifecycle.reset(environment)

            self.assertEqual(raised.exception.code, "conflict")
            self.assertEqual(
                [call.args[0] for call in run.call_args_list],
                [
                    [
                        "/bin/incus",
                        "--force-local",
                        "list",
                        "^atlas-shared-dev$",
                        "--format=json",
                    ],
                    [
                        "/bin/incus",
                        "--force-local",
                        "snapshot",
                        "list",
                        "atlas-shared-dev",
                        "--format=json",
                    ],
                ],
            )

    def test_reset_recreates_a_confirmed_missing_instance(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            missing = subprocess.CompletedProcess([], 0, stdout="[]\n", stderr="")
            completed = subprocess.CompletedProcess([], 0, stderr="")

            with mock.patch(
                "atlas.lifecycle.subprocess.run", side_effect=[missing, completed]
            ) as run:
                self.assertTrue(lifecycle.reset(environment))

            self.assertEqual(
                [call.args[0] for call in run.call_args_list],
                [
                    [
                        "/bin/incus",
                        "--force-local",
                        "list",
                        "^atlas-shared-dev$",
                        "--format=json",
                    ],
                    ["/nix/store/atlas-reconcile-shared-dev"],
                ],
            )

    def test_reset_fails_closed_when_instance_inventory_fails(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            failed = subprocess.CompletedProcess(
                [], 1, stdout="", stderr="Incus daemon unavailable"
            )

            with (
                mock.patch("atlas.lifecycle.subprocess.run", return_value=failed) as run,
                self.assertRaises(ControlOperationError) as raised,
            ):
                lifecycle.reset(environment)

            self.assertEqual(raised.exception.code, "incus_failed")
            self.assertEqual(len(run.call_args_list), 1)

    def test_reset_query_timeout_prevents_mutation_and_releases_lock(self):
        for snapshot_query in (False, True):
            with self.subTest(snapshot_query=snapshot_query), tempfile.TemporaryDirectory() as directory:
                lifecycle, environment, durable_home = self.fixture(directory)
                responses = []
                if snapshot_query:
                    responses.append(subprocess.CompletedProcess(
                        [], 0, stdout='[{"name":"atlas-shared-dev"}]', stderr=""
                    ))
                responses.append(subprocess.TimeoutExpired("incus", 60, output=b"[]"))
                with mock.patch("atlas.lifecycle.subprocess.run", side_effect=responses) as run:
                    with self.assertRaises(ControlOperationError) as raised:
                        lifecycle.reset(environment)
                self.assertEqual(raised.exception.code, "incus_timeout")
                self.assertEqual(run.call_count, len(responses))
                self.assertTrue(all(call.args[0][0] == "/bin/incus" for call in run.call_args_list))
                self.assertEqual((durable_home / "repository").read_text(), "durable")
                with (Path(lifecycle.lock_root) / f"{environment['id']}.lock").open() as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_busy_environment_rejects_lifecycle_requests_until_lock_released(self):
        with tempfile.TemporaryDirectory() as directory:
            lifecycle, environment, durable_home = self.fixture(directory)
            locks = Path(lifecycle.lock_root)
            locks.mkdir()
            lock_path = locks / f"{environment['id']}.lock"
            with lock_path.open("w") as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                operations = [
                    ("reset", ()),
                    ("list_snapshots", ()),
                    ("create_snapshot", ("checkpoint",)),
                    ("restore_snapshot", ("checkpoint",)),
                    ("delete_snapshot", ("checkpoint",)),
                ]
                with mock.patch("atlas.lifecycle.subprocess.run") as run:
                    for method, arguments in operations:
                        with self.subTest(method=method):
                            with self.assertRaises(ControlOperationError) as raised:
                                getattr(lifecycle, method)(environment, *arguments)
                            self.assertEqual(raised.exception.code, "lifecycle_busy")
                    run.assert_not_called()
                # A rejected contender must neither replace nor unlock the
                # active operation's lock.
                with lock_path.open() as contender:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual((durable_home / "repository").read_text(), "durable")
            with mock.patch(
                "atlas.lifecycle.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, stdout="[]", stderr=""),
            ):
                self.assertEqual(lifecycle.list_snapshots(environment), [])

    def test_reset_fingerprints_btrfs_volumes_by_subvolume_uuid(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            lifecycle.btrfs = "/bin/btrfs"
            first_uuid = "11111111-1111-4111-8111-111111111111"
            replacement_uuid = "22222222-2222-4222-8222-222222222222"
            responses = [
                subprocess.CompletedProcess(
                    [], 0, stdout='[{"name":"atlas-shared-dev"}]\n', stderr=""
                ),
                subprocess.CompletedProcess([], 0, stdout="[]\n", stderr=""),
                subprocess.CompletedProcess(
                    [], 0, stdout=f"\tUUID: {first_uuid}\n", stderr=""
                ),
                subprocess.CompletedProcess(
                    [], 0, stdout=f"\tUUID: {first_uuid}\n", stderr=""
                ),
                subprocess.CompletedProcess([], 0, stderr=""),
                subprocess.CompletedProcess(
                    [], 0, stdout=f"\tUUID: {first_uuid}\n", stderr=""
                ),
                subprocess.CompletedProcess(
                    [], 0, stdout=f"\tUUID: {replacement_uuid}\n", stderr=""
                ),
            ]

            with (
                mock.patch("atlas.lifecycle.subprocess.run", side_effect=responses),
                self.assertRaisesRegex(RuntimeError, "declared volume changed"),
            ):
                lifecycle.reset(environment)

    def test_reset_fails_closed_if_btrfs_identity_is_unreadable(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            lifecycle.btrfs = "/bin/btrfs"
            responses = [
                subprocess.CompletedProcess(
                    [], 0, stdout='[{"name":"atlas-shared-dev"}]\n', stderr=""
                ),
                subprocess.CompletedProcess([], 0, stdout="[]\n", stderr=""),
                subprocess.CompletedProcess([], 1, stdout="", stderr="not a subvolume"),
            ]

            with (
                mock.patch("atlas.lifecycle.subprocess.run", side_effect=responses) as run,
                self.assertRaisesRegex(RuntimeError, "Btrfs subvolume identity"),
            ):
                lifecycle.reset(environment)

            self.assertEqual(len(run.call_args_list), 3)

    def test_snapshot_operations_use_only_the_local_incus_daemon(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            list_result = subprocess.CompletedProcess(
                [], 0, stdout='[{"name":"baseline"},{"name":"later"}]\n', stderr=""
            )

            with mock.patch(
                "atlas.lifecycle.subprocess.run",
                side_effect=[
                    subprocess.CompletedProcess([], 0, stderr=""),
                    list_result,
                    subprocess.CompletedProcess([], 0, stderr=""),
                    subprocess.CompletedProcess([], 0, stderr=""),
                    subprocess.CompletedProcess([], 0, stderr=""),
                ],
            ) as run:
                lifecycle.create_snapshot(environment, "baseline")
                self.assertEqual(
                    lifecycle.list_snapshots(environment), ["baseline", "later"]
                )
                self.assertTrue(lifecycle.restore_snapshot(environment, "baseline"))
                lifecycle.delete_snapshot(environment, "later")

            self.assertEqual(
                [call.args[0] for call in run.call_args_list],
                [
                    [
                        "/bin/incus",
                        "--force-local",
                        "snapshot",
                        "create",
                        "atlas-shared-dev",
                        "baseline",
                    ],
                    [
                        "/bin/incus",
                        "--force-local",
                        "snapshot",
                        "list",
                        "atlas-shared-dev",
                        "--format=json",
                    ],
                    [
                        "/nix/store/atlas-verify-shared-dev",
                        "atlas-shared-dev",
                        "baseline",
                    ],
                    [
                        "/bin/incus",
                        "--force-local",
                        "snapshot",
                        "restore",
                        "atlas-shared-dev",
                        "baseline",
                    ],
                    [
                        "/bin/incus",
                        "--force-local",
                        "snapshot",
                        "delete",
                        "atlas-shared-dev",
                        "later",
                    ],
                ],
            )

    def test_snapshot_restore_rejects_a_stale_instance_layout(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            stale_layout = subprocess.CompletedProcess(
                [], 20, stderr="Atlas Incus snapshot configuration drifted"
            )

            with (
                mock.patch(
                    "atlas.lifecycle.subprocess.run", return_value=stale_layout
                ) as run,
                self.assertRaises(ControlOperationError) as raised,
            ):
                lifecycle.restore_snapshot(environment, "baseline")

            self.assertEqual(raised.exception.code, "reset_required")
            self.assertIn("current environment layout", raised.exception.message)
            run.assert_called_once_with(
                [
                    "/nix/store/atlas-verify-shared-dev",
                    "atlas-shared-dev",
                    "baseline",
                ],
                check=False,
                env=mock.ANY,
                pass_fds=mock.ANY,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )

    def test_snapshot_restore_reports_verifier_infrastructure_failure(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            failed = subprocess.CompletedProcess(
                [], 1, stderr="Incus daemon unavailable"
            )

            with (
                mock.patch("atlas.lifecycle.subprocess.run", return_value=failed),
                self.assertRaises(ControlOperationError) as raised,
            ):
                lifecycle.restore_snapshot(environment, "baseline")

            self.assertEqual(raised.exception.code, "incus_failed")
            self.assertEqual(raised.exception.message, "Incus could not verify the snapshot")

    def test_runtime_rejects_non_incus_and_untrusted_reconcile_commands(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            with mock.patch("atlas.lifecycle.subprocess.run") as run:
                environment["runtime"]["backend"] = "systemd-nspawn-service"
                with self.assertRaisesRegex(ValueError, "must use Incus"):
                    lifecycle.reset(environment)

                environment["runtime"]["backend"] = "incus-container"
                environment["runtime"]["instance"]["resetCommand"] = "reconcile"
                with self.assertRaisesRegex(ValueError, "reconcile command"):
                    lifecycle.reset(environment)

                environment["runtime"]["instance"]["resetCommand"] = (
                    "/nix/store/../usr/bin/reconcile"
                )
                with self.assertRaisesRegex(ValueError, "reconcile command"):
                    lifecycle.reset(environment)

                environment["runtime"]["instance"]["resetCommand"] = (
                    "/nix/store/atlas-reconcile-shared-dev"
                )
                environment["runtime"]["instance"]["verifyCommand"] = "verify"
                with self.assertRaisesRegex(ValueError, "verify command"):
                    lifecycle.restore_snapshot(environment, "baseline")

            run.assert_not_called()

    def test_incus_failure_is_bounded_in_logs_and_redacted_from_the_api(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lifecycle, environment, _durable_home = self.fixture(temporary_directory)
            diagnostic = "permission denied\n" + "x" * (
                MAX_INCUS_DIAGNOSTIC_BYTES + 128
            )
            completed = subprocess.CompletedProcess([], 1, stderr=diagnostic)
            stderr = io.StringIO()

            with (
                mock.patch("atlas.lifecycle.subprocess.run", return_value=completed),
                mock.patch("sys.stderr", stderr),
                self.assertRaises(ControlOperationError) as raised,
            ):
                lifecycle.create_snapshot(environment, "baseline")

            self.assertEqual(raised.exception.code, "incus_failed")
            self.assertNotIn("permission denied", raised.exception.message)
            self.assertIn("permission denied", stderr.getvalue())
            self.assertIn("[truncated]", stderr.getvalue())
            self.assertLess(
                len(stderr.getvalue()), MAX_INCUS_DIAGNOSTIC_BYTES + 256
            )


if __name__ == "__main__":
    unittest.main()
