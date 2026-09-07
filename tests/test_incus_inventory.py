"""Failure contracts shared by reset and generated activation services."""

import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from atlas.lifecycle import ControlOperationError, _object_inventory, _snapshot_inventory


class InventoryTests(unittest.TestCase):
    def test_all_shell_readiness_and_lock_waits_are_bounded(self):
        source = (ROOT / "nixos/modules/atlas-environments.nix").read_text()
        readiness = re.findall(r"^\s*(incus --force-local admin waitready[^\n]*)$", source, re.M)
        locks = re.findall(r"^\s*(flock (?!-u\b)[^\n]*)$", source, re.M)
        self.assertTrue(readiness)
        self.assertTrue(locks)
        for command in readiness:
            self.assertEqual(shlex.split(command)[-2:], ["--timeout", "60"])
        for command in locks:
            self.assertEqual(shlex.split(command)[1:3], ["--wait", "60"])

    def test_readiness_failure_stops_activation_before_inventory_or_import(self):
        source = (ROOT / "nixos/modules/atlas-environments.nix").read_text()
        for service_name in ("atlas-incus-image", "atlas-incus-inventory"):
            with self.subTest(service=service_name), tempfile.TemporaryDirectory() as directory:
                service = source.split(f"        {service_name} = {{", 1)[1]
                script = service.split("          script = ''\n", 1)[1].split("\n          '';", 1)[0]
                # Only the preamble is reached on readiness failure. Keep the
                # actual service's error mode and command, then detect progress.
                lines = script.splitlines()
                stop = next(i for i, line in enumerate(lines) if "admin waitready" in line)
                preamble = "\n".join(lines[:stop + 1])
                incus = Path(directory) / "incus"
                incus.write_text("#!/bin/sh\nexit 1\n")
                incus.chmod(0o755)
                result = subprocess.run(
                    ["bash", "-c", preamble + "\necho unexpected-progress"],
                    capture_output=True, text=True,
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("unexpected-progress", result.stdout)

    def test_query_timeout_never_establishes_absence(self):
        for kind in ("instance", "volume", "acl", "snapshot"):
            with self.subTest(kind=kind), mock.patch(
                "atlas.lifecycle.subprocess.run",
                side_effect=subprocess.TimeoutExpired("incus", 60, output=b"[]\n"),
            ):
                with self.assertRaises(ControlOperationError) as raised:
                    if kind == "snapshot":
                        _snapshot_inventory("incus", "atlas-demo")
                    else:
                        _object_inventory("incus", kind, "atlas-demo")
                self.assertEqual(raised.exception.code, "incus_timeout")

    def test_stalled_query_process_is_reaped_and_next_query_can_recover(self):
        with tempfile.TemporaryDirectory() as directory:
            incus = Path(directory) / "incus"
            pid_file = Path(directory) / "pid"
            incus.write_text(
                f"#!{sys.executable}\n"
                "import os, time\n"
                f"open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
                "print('[]', flush=True)\n"
                "time.sleep(2)\n"
            )
            incus.chmod(0o755)
            with mock.patch("atlas.lifecycle.INCUS_QUERY_TIMEOUT_SECONDS", 0.5):
                with self.assertRaises(ControlOperationError) as raised:
                    _object_inventory(str(incus), "instance", "atlas-demo")
            self.assertEqual(raised.exception.code, "incus_timeout")
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)
            incus.write_text(f"#!{sys.executable}\nprint('[]')\n")
            self.assertEqual(_object_inventory(str(incus), "instance", "atlas-demo"), [])

    def test_absence_requires_a_successful_valid_inventory(self):
        for kind in ("instance", "volume", "acl"):
            for payload in ("null", "{}", "broken", '[{}]', '[{"name":"bad name"}]'):
                with self.subTest(kind=kind, payload=payload):
                    result = subprocess.CompletedProcess([], 0, payload, "")
                    with mock.patch("atlas.lifecycle.subprocess.run", return_value=result):
                        with self.assertRaises(RuntimeError):
                            _object_inventory("incus", kind, "atlas-demo")
            with self.subTest(kind=kind, unavailable=True):
                result = subprocess.CompletedProcess([], 1, "[]", "unavailable")
                with mock.patch("atlas.lifecycle.subprocess.run", return_value=result):
                    with self.assertRaises(ControlOperationError):
                        _object_inventory("incus", kind, "atlas-demo")
            with self.subTest(kind=kind, absent=True):
                result = subprocess.CompletedProcess([], 0, "[]", "")
                with mock.patch("atlas.lifecycle.subprocess.run", return_value=result):
                    self.assertEqual(_object_inventory("incus", kind, "atlas-demo"), [])

    def test_duplicate_and_unexpected_instances_are_rejected(self):
        for records in (
            [{"name": "atlas-other"}],
            [{"name": "atlas-demo"}, {"name": "atlas-demo"}],
        ):
            result = subprocess.CompletedProcess([], 0, json.dumps(records), "")
            with mock.patch("atlas.lifecycle.subprocess.run", return_value=result):
                with self.assertRaises(RuntimeError):
                    _object_inventory("incus", "instance", "atlas-demo")

    def test_volume_presence_does_not_confuse_custom_and_instance_volumes(self):
        records = [{"name": "atlas-demo", "type": "container"}]
        for custom in (False, True):
            if custom:
                records.append({"name": "atlas-demo", "type": "custom"})
            result = subprocess.CompletedProcess([], 0, json.dumps(records), "")
            with mock.patch("atlas.lifecycle.subprocess.run", return_value=result):
                self.assertEqual(
                    _object_inventory("incus", "volume", "atlas-demo"),
                    ["atlas-demo"] if custom else [],
                )

    def test_activation_inventory_cannot_succeed_when_listing_fails(self):
        # Execute the actual service body, substituting only Nix store paths.
        source = (ROOT / "nixos/modules/atlas-environments.nix").read_text()
        service = source.split("        atlas-incus-inventory = {", 1)[1]
        script = service.split("          script = ''\n", 1)[1].split("\n          '';", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            incus = Path(directory) / "incus"
            incus.write_text(
                "#!/bin/sh\n"
                'if [ "$2" = admin ]; then exit 0; fi\n'
                'if [ "$2" = list ]; then echo unavailable >&2; exit 1; fi\n'
                'echo "unexpected mutation" >&2; exit 99\n'
            )
            incus.chmod(0o755)
            command = shlex.join([
                sys.executable, "-I", str(ROOT / "src/atlas/lifecycle.py"),
                "--incus", str(incus),
            ])
            script = script.replace("${incusInventory}", command)
            script = script.replace("${incusDeclaredInstances}", "/dev/null")
            result = subprocess.run(
                ["bash", "-c", script], capture_output=True, text=True,
                env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Atlas inventory failed", result.stderr)
            self.assertNotIn("unexpected mutation", result.stderr)


if __name__ == "__main__":
    unittest.main()
