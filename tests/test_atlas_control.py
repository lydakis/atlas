import socket
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from atlas_control import (  # noqa: E402
    _delete_managed_tree,
    _pause_environment,
    _read_request,
    _replace_btrfs_root,
    _reset_environment,
    handle_request,
)


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
        self.snapshot_calls = []

    def request(self, peer_uid, payload, peer_cgroup="", allow_management=True):
        return handle_request(
            peer_uid=peer_uid,
            peer_cgroup=peer_cgroup,
            request=payload,
            contract=CONTRACT,
            reset_environment=(
                lambda environment: self.reset_names.append(environment["name"])
            )
            if allow_management
            else None,
            create_snapshot=(
                lambda environment, snapshot: self.snapshot_calls.append(
                    ("create", environment["name"], snapshot)
                )
            )
            if allow_management
            else None,
            list_snapshots=(
                lambda environment: ["baseline", "working"]
            )
            if allow_management
            else None,
            restore_snapshot=(
                lambda environment, snapshot: self.snapshot_calls.append(
                    ("restore", environment["name"], snapshot)
                )
            )
            if allow_management
            else None,
            delete_snapshot=(
                lambda environment, snapshot: self.snapshot_calls.append(
                    ("delete", environment["name"], snapshot)
                )
            )
            if allow_management
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
        self.assertEqual(self.reset_names, [])

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
                self.assertEqual(self.snapshot_calls[-1], call)

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

    def _btrfs_runtime_fixture(self, temporary_directory):
        environment, runtime_root, lock_root, root, ready, outside = self._runtime_fixture(
            temporary_directory
        )
        expected_seed_id = "a" * 64
        seed = root.parent / "seed"
        (seed / "etc" / "atlas").mkdir(parents=True)
        (seed / "etc" / "atlas" / "seed-id").write_text(
            f"{expected_seed_id}\n", encoding="utf-8"
        )
        snapshots = root.parent / "snapshots"
        snapshots.mkdir()
        environment["runtime"]["storage"] = {
            "adapter": "btrfs-subvolume",
            "seedHostPath": str(seed),
            "snapshotsHostPath": str(snapshots),
            "seed": {"id": expected_seed_id},
            "seedPrepareCommand": "/bin/prepare-seed",
        }
        mountinfo = Path(temporary_directory) / "empty-mountinfo"
        mountinfo.touch()
        return environment, runtime_root, lock_root, root, ready, seed, outside, mountinfo

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

    def test_btrfs_root_replacement_uses_a_writable_snapshot_and_removes_old_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            parent = Path(temporary_directory)
            source = parent / "seed"
            source.mkdir()
            root = parent / "rootfs"
            root.mkdir()
            (root / "old-state").write_text("old", encoding="utf-8")
            ready = parent / "rootfs.ready"
            ready.write_text("ready\n", encoding="utf-8")

            def create_snapshot(snapshot_source, destination, _btrfs, *, readonly):
                self.assertEqual(snapshot_source, source)
                self.assertFalse(readonly)
                destination.mkdir()
                (destination / "seed-state").write_text("fresh", encoding="utf-8")

            def delete_tree(path, adapter, _btrfs):
                self.assertEqual(adapter, "btrfs-subvolume")
                shutil.rmtree(path)

            with (
                mock.patch("atlas_control._require_btrfs_subvolume"),
                mock.patch("atlas_control._btrfs_snapshot", side_effect=create_snapshot),
                mock.patch("atlas_control._delete_managed_tree", side_effect=delete_tree),
            ):
                _replace_btrfs_root(
                    source=source,
                    root=root,
                    ready=ready,
                    btrfs="/bin/btrfs",
                )

            self.assertEqual((root / "seed-state").read_text(encoding="utf-8"), "fresh")
            self.assertFalse((root / "old-state").exists())
            self.assertTrue(ready.is_file())
            self.assertEqual(list(parent.glob(".deleting-*")), [])
            self.assertEqual(list(parent.glob(".rootfs.*")), [])

    def test_btrfs_cleanup_recursively_deletes_nested_subvolumes_and_commits(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory) / "rootfs"
            root.mkdir()
            with (
                mock.patch("atlas_control._is_btrfs_subvolume", return_value=True),
                mock.patch("atlas_control._run_btrfs") as run_btrfs,
            ):
                _delete_managed_tree(root, "btrfs-subvolume", "/bin/btrfs")

            run_btrfs.assert_called_once_with(
                "/bin/btrfs",
                "subvolume",
                "delete",
                "--recursive",
                "--commit-after",
                "--",
                str(root),
            )

    def test_pause_quiesces_an_activating_environment(self):
        states = iter(["activating", "inactive"])
        commands = []

        def run(command, **_kwargs):
            commands.append(command)
            if command[1] == "show":
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout=f"{next(states)}\n",
                )
            if command[1] == "is-active":
                return subprocess.CompletedProcess(command, 3)
            if command[1] == "stop":
                return subprocess.CompletedProcess(command, 0)
            raise AssertionError(f"unexpected command: {command}")

        with mock.patch("atlas_control.subprocess.run", side_effect=run):
            should_resume = _pause_environment(
                "/bin/systemctl",
                "atlas-environment-shared\\x2ddev.service",
            )

        self.assertTrue(should_resume)
        self.assertIn(
            [
                "/bin/systemctl",
                "stop",
                "atlas-environment-shared\\x2ddev.service",
            ],
            commands,
        )

    def test_reset_reconstructs_a_btrfs_root_from_the_applied_seed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            (
                environment,
                runtime_root,
                lock_root,
                root,
                ready,
                seed,
                outside,
                empty_mountinfo,
            ) = self._btrfs_runtime_fixture(temporary_directory)
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
                subprocess.CompletedProcess([], 0),
            ]

            with (
                mock.patch("atlas_control.subprocess.run", side_effect=completed) as run,
                mock.patch("atlas_control._require_btrfs_subvolume"),
                mock.patch("atlas_control._replace_btrfs_root") as replace,
            ):
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(lock_root),
                    systemctl="/bin/systemctl",
                    btrfs="/bin/btrfs",
                    mountinfo_path=str(empty_mountinfo),
                )

            replace.assert_called_once_with(
                source=seed,
                root=root,
                ready=ready,
                btrfs="/bin/btrfs",
            )
            self.assertEqual(run.call_args_list[2].args[0], ["/bin/prepare-seed"])
            self.assertEqual((outside / "repository").read_text(), "durable")

    def test_reset_reconstructs_a_missing_btrfs_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            (
                environment,
                runtime_root,
                lock_root,
                root,
                ready,
                seed,
                outside,
                empty_mountinfo,
            ) = self._btrfs_runtime_fixture(temporary_directory)
            root.rmdir()
            ready.unlink()
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
                subprocess.CompletedProcess([], 0),
            ]

            with (
                mock.patch("atlas_control.subprocess.run", side_effect=completed),
                mock.patch("atlas_control._require_btrfs_subvolume"),
                mock.patch("atlas_control._replace_btrfs_root") as replace,
            ):
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(lock_root),
                    systemctl="/bin/systemctl",
                    btrfs="/bin/btrfs",
                    mountinfo_path=str(empty_mountinfo),
                )

            replace.assert_called_once_with(
                source=seed,
                root=root,
                ready=ready,
                btrfs="/bin/btrfs",
            )
            self.assertEqual((outside / "repository").read_text(), "durable")

    def test_reset_reconstructs_a_btrfs_root_without_a_ready_marker(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            (
                environment,
                runtime_root,
                lock_root,
                root,
                ready,
                seed,
                outside,
                empty_mountinfo,
            ) = self._btrfs_runtime_fixture(temporary_directory)
            ready.unlink()
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
                subprocess.CompletedProcess([], 0),
            ]

            with (
                mock.patch("atlas_control.subprocess.run", side_effect=completed),
                mock.patch("atlas_control._require_btrfs_subvolume"),
                mock.patch("atlas_control._replace_btrfs_root") as replace,
            ):
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(lock_root),
                    systemctl="/bin/systemctl",
                    btrfs="/bin/btrfs",
                    mountinfo_path=str(empty_mountinfo),
                )

            replace.assert_called_once_with(
                source=seed,
                root=root,
                ready=ready,
                btrfs="/bin/btrfs",
            )
            self.assertEqual((outside / "repository").read_text(), "durable")

    def test_reset_refuses_a_seed_preparer_that_leaves_the_wrong_seed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            expected_seed_id = "a" * 64
            environment, runtime_root, lock_root, root, _ready, outside = self._runtime_fixture(
                temporary_directory
            )
            seed = root.parent / "seed"
            (seed / "etc" / "atlas").mkdir(parents=True)
            (seed / "etc" / "atlas" / "seed-id").write_text(
                f"{'b' * 64}\n", encoding="utf-8"
            )
            snapshots = root.parent / "snapshots"
            snapshots.mkdir()
            environment["runtime"]["storage"] = {
                "adapter": "btrfs-subvolume",
                "seedHostPath": str(seed),
                "snapshotsHostPath": str(snapshots),
                "seed": {"id": expected_seed_id},
                "seedPrepareCommand": "/bin/prepare-seed",
            }
            empty_mountinfo = Path(temporary_directory) / "empty-mountinfo"
            empty_mountinfo.touch()
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
                subprocess.CompletedProcess([], 0),
            ]

            with (
                mock.patch("atlas_control.subprocess.run", side_effect=completed),
                mock.patch("atlas_control._require_btrfs_subvolume"),
                mock.patch("atlas_control._replace_btrfs_root") as replace,
            ):
                with self.assertRaisesRegex(RuntimeError, "expected applied seed"):
                    _reset_environment(
                        environment,
                        runtime_root=str(runtime_root),
                        lock_root=str(lock_root),
                        systemctl="/bin/systemctl",
                        btrfs="/bin/btrfs",
                        mountinfo_path=str(empty_mountinfo),
                    )

            replace.assert_not_called()
            self.assertEqual((outside / "repository").read_text(), "durable")

    def test_reset_cleans_interrupted_bootstrap_directories(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, outside = self._runtime_fixture(
                temporary_directory
            )
            interrupted = root.parent / ".rootfs.interrupted"
            interrupted.mkdir()
            (interrupted / "partial-root").write_text("partial", encoding="utf-8")
            interrupted_seed = root.parent / ".seed.interrupted"
            interrupted_seed.mkdir()
            (interrupted_seed / "partial-seed").write_text("partial", encoding="utf-8")
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
            ]
            empty_mountinfo = Path(temporary_directory) / "empty-mountinfo"
            empty_mountinfo.touch()

            with mock.patch("atlas_control.subprocess.run", side_effect=completed):
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(lock_root),
                    systemctl="/bin/systemctl",
                    mountinfo_path=str(empty_mountinfo),
                )

            self.assertFalse(interrupted.exists())
            self.assertFalse(interrupted_seed.exists())
            self.assertEqual((outside / "repository").read_text(), "durable")

    def test_reset_refuses_a_symbolic_link_at_the_managed_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, outside = self._runtime_fixture(
                temporary_directory
            )
            root.rmdir()
            root.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "symbolic link"):
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(lock_root),
                    systemctl="/bin/systemctl",
                )

            self.assertTrue(root.is_symlink())
            self.assertEqual((outside / "repository").read_text(), "durable")
            self.assertTrue(ready.exists())

    def test_reset_refuses_a_non_directory_at_the_managed_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, outside = self._runtime_fixture(
                temporary_directory
            )
            root.rmdir()
            root.write_text("not a root directory", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "directory"):
                _reset_environment(
                    environment,
                    runtime_root=str(runtime_root),
                    lock_root=str(lock_root),
                    systemctl="/bin/systemctl",
                )

            self.assertEqual(root.read_text(encoding="utf-8"), "not a root directory")
            self.assertEqual((outside / "repository").read_text(), "durable")
            self.assertTrue(ready.exists())

    def test_reset_refuses_when_mount_state_cannot_be_inspected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment, runtime_root, lock_root, root, ready, outside = self._runtime_fixture(
                temporary_directory
            )
            missing_mountinfo = Path(temporary_directory) / "missing-mountinfo"
            completed = [
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 3),
            ]

            with mock.patch("atlas_control.subprocess.run", side_effect=completed):
                with self.assertRaisesRegex(RuntimeError, "inspect mount state"):
                    _reset_environment(
                        environment,
                        runtime_root=str(runtime_root),
                        lock_root=str(lock_root),
                        systemctl="/bin/systemctl",
                        mountinfo_path=str(missing_mountinfo),
                    )

            self.assertTrue(root.is_dir())
            self.assertTrue(ready.exists())
            self.assertEqual((outside / "repository").read_text(), "durable")

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
