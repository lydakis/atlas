import tempfile
import io
import unittest
import json
import sys
import subprocess
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from atlas.operations import OperationStore, assert_admitted
from atlas.lifecycle import ControlOperationError
from atlas.control import handle_request, main, _execute_operation_payload


class OperationTests(unittest.TestCase):
    def test_poll_failure_retains_receipt_without_resubmitting(self):
        receipt = {"ok": True, "result": {"id": "accepted-id", "environmentId": "environment-a", "status": "running"}}
        failures = (
            ConnectionResetError("service restarted"),
            json.JSONDecodeError("empty response", "", 0),
            {"ok": False, "error": {"code": "internal_error", "message": "inspection failed"}},
        )
        for failure in failures:
            for wait in ([], ["--wait"]):
                with (
                    self.subTest(failure=failure, wait=wait),
                    mock.patch("atlas.control._request", side_effect=[receipt, failure]) as request,
                    mock.patch("atlas.control.time.sleep"),
                    mock.patch("sys.stdout", new_callable=io.StringIO) as output,
                    mock.patch("sys.stderr", new_callable=io.StringIO),
                ):
                    self.assertEqual(main(["environment", "reset", "demo", "--json", *wait]), 1)
                    response = json.loads(output.getvalue())
                    self.assertEqual(response["receipt"], receipt["result"])
                    self.assertEqual(response["error"]["code"], "operation_poll_failed")
                    self.assertIn("accepted-id", response["error"]["message"])
                    self.assertEqual([call.args[1]["operation"] for call in request.call_args_list], ["environment.reset", "operation.inspect"])

    def test_read_only_failures_release_admission_for_retry(self):
        for code in ("incus_query_failed", "verification_failed", "preflight_failed"):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
                operation = store.submit("environment-a", {})
                store.execute(operation["id"], lambda _: {"ok": False, "error": {"code": code, "message": "unavailable"}})
                self.assertEqual(store.inspect(operation["id"])["status"], "failed")
                store.submit("environment-a", {})

    def test_snapshot_preflight_errors_do_not_submit_mutations(self):
        for action, names, code in (("create", ["checkpoint"], "conflict"), ("restore", [], "not_found"), ("delete", [], "not_found")):
            payload = {"lifecycle": {}, "contract": {"environments": {"demo": {}}}, "request": {"operation": f"environment.snapshot.{action}", "name": "demo", "snapshot": "checkpoint"}}
            with mock.patch("atlas.control.EnvironmentLifecycle") as lifecycle, mock.patch("atlas.control.handle_request") as mutate:
                lifecycle.return_value.list_snapshots.return_value = names
                self.assertEqual(_execute_operation_payload(payload)["error"]["code"], code)
                mutate.assert_not_called()

    def test_no_wait_always_returns_receipt_even_if_already_complete(self):
        receipt = {"ok": True, "result": {"id": "example", "status": "succeeded", "response": {"ok": True, "result": {"reset": True}}}}
        with mock.patch("atlas.control._request", return_value=receipt), mock.patch("atlas.control._print_response", return_value=0) as output:
            self.assertEqual(main(["environment", "reset", "demo", "--no-wait"]), 0)
            output.assert_called_once_with(receipt, False)

    def test_default_client_wait_returns_receipt_without_cancelling(self):
        receipt = {"ok": True, "result": {"id": "example", "status": "running"}}
        with (
            mock.patch("atlas.control._request", return_value=receipt) as request,
            mock.patch("atlas.control.time.monotonic", side_effect=[0, 31]),
            mock.patch("atlas.control._print_response", return_value=0) as output,
        ):
            self.assertEqual(main(["environment", "reset", "demo"]), 0)
            request.assert_called_once()
            output.assert_called_once_with(receipt, False)

    def test_operation_receipts_are_root_management_only(self):
        contract = {"environments": {}}
        store = mock.Mock()
        request = {"version": 1, "operation": "operation.inspect", "id": "example"}
        for peer, operations in ((1000, store), (0, None)):
            response = handle_request(peer_uid=peer, request=request, contract=contract, operations=operations)
            self.assertEqual(response["error"]["code"], "forbidden")
        store.recover_status.assert_not_called()
        store.recover_status.return_value = {"id": "example", "status": "running"}
        response = handle_request(peer_uid=0, request=request, contract=contract, operations=store)
        self.assertEqual(response["result"]["status"], "running")

    def test_control_restart_keeps_operation_and_does_not_resubmit(self):
        with tempfile.TemporaryDirectory() as directory:
            launches = []
            root = Path(directory) / "operations"
            locks = Path(directory) / "locks"
            store = OperationStore(root, locks, launches.append)
            operation = store.submit("environment-a", {"request": "reset"})
            recovered = OperationStore(root, locks, launches.append)
            self.assertEqual(recovered.inspect(operation["id"])["status"], "pending")
            with self.assertRaises(ControlOperationError):
                recovered.submit("environment-a", {"request": "restore"})
            self.assertEqual(len(launches), 1)

    def test_worker_records_result_and_duplicate_execution_does_not_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            operation = store.submit("environment-a", {"request": "reset"})
            calls = []
            result = {"ok": True, "result": {"reset": True}}
            store.execute(operation["id"], lambda payload: calls.append(payload) or result)
            store.execute(operation["id"], lambda payload: self.fail("operation replayed"))
            self.assertEqual(store.inspect(operation["id"])["response"], result)
            self.assertEqual(len(calls), 1)
            self.assertFalse(store.active_path("environment-a").exists())

    def test_uncertain_failure_keeps_mutation_interlock(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            operation = store.submit("environment-a", {})
            store.execute(operation["id"], lambda _: {"ok": False, "error": {"code": "incus_failed", "message": "unknown"}})
            self.assertEqual(store.inspect(operation["id"])["status"], "unknown")
            with self.assertRaises(ControlOperationError):
                store.submit("environment-a", {})

    def test_ids_cannot_escape_store(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            with self.assertRaises(ValueError):
                store.inspect("../outside")

    def test_admission_blocks_other_callers_but_allows_own_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            operation = store.submit("environment-a", {})
            with mock.patch("atlas.operations.DEFAULT_OPERATION_ROOT", str(store.root)):
                with self.assertRaises(ControlOperationError):
                    assert_admitted("environment-a")
                assert_admitted("environment-b")
                with mock.patch.dict("os.environ", {"ATLAS_OPERATION_ID": operation["id"]}):
                    assert_admitted("environment-a")

    def test_started_worker_is_never_replayed_after_interruption(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            operation = store.submit("environment-a", {})
            def interrupted(_):
                raise KeyboardInterrupt()
            with self.assertRaises(KeyboardInterrupt):
                store.execute(operation["id"], interrupted)
            store.execute(operation["id"], lambda _: self.fail("interrupted mutation replayed"))
            self.assertEqual(store.inspect(operation["id"])["status"], "running")
            self.assertTrue(store.active_path("environment-a").exists())

    def test_saved_completion_cleans_admission_after_interrupted_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            operation = store.submit("environment-a", {})
            store.execute(operation["id"], lambda _: {"ok": True, "result": {}})
            store.active_path("environment-a").write_text(json.dumps(operation["id"]))
            self.assertEqual(store.recover_status(operation["id"])["status"], "succeeded")
            self.assertFalse(store.active_path("environment-a").exists())

    def test_old_completion_cannot_clear_a_new_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            old = store.submit("environment-a", {})
            store.execute(old["id"], lambda _: {"ok": True, "result": {}})
            new = store.submit("environment-a", {})
            store.recover_status(old["id"])
            self.assertEqual(json.loads(store.active_path("environment-a").read_text()), new["id"])

    def test_completed_receipt_does_not_block_next_request_after_cleanup_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", lambda _: None)
            old = store.submit("environment-a", {})
            store.execute(old["id"], lambda _: {"ok": True, "result": {}})
            store.active_path("environment-a").write_text(json.dumps(old["id"]))
            with mock.patch("atlas.operations.DEFAULT_OPERATION_ROOT", str(store.root)), mock.patch("atlas.operations.OperationStore", return_value=store):
                assert_admitted("environment-a")
            new = store.submit("environment-a", {})
            self.assertNotEqual(old["id"], new["id"])

    def test_missing_started_worker_reports_unknown_without_relaunch(self):
        with tempfile.TemporaryDirectory() as directory:
            launch = mock.Mock()
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", launch)
            operation = store.submit("environment-a", {})
            def interrupted(_):
                raise KeyboardInterrupt()
            with self.assertRaises(KeyboardInterrupt):
                store.execute(operation["id"], interrupted)
            with mock.patch("atlas.operations.subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout="inactive\n")):
                self.assertEqual(store.recover_status(operation["id"])["status"], "unknown")
            launch.assert_called_once_with(operation["id"])
            self.assertTrue(store.active_path("environment-a").exists())

    def test_lost_launch_acknowledgement_keeps_same_pending_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            launch = mock.Mock(side_effect=OSError("lost acknowledgement"))
            store = OperationStore(Path(directory) / "operations", Path(directory) / "locks", launch)
            operation = store.submit("environment-a", {})
            launch.side_effect = None
            self.assertEqual(store.recover_status(operation["id"])["status"], "pending")
            self.assertEqual(launch.call_args_list, [mock.call(operation["id"]), mock.call(operation["id"])])
