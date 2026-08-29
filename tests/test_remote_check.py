import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
REMOTE_CHECK = REPOSITORY_ROOT / "scripts" / "remote-check"


class RemoteCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.workspace = Path(self.temporary_directory.name) / "workspace"
        self.workspace.mkdir()
        (self.workspace / "scripts").mkdir()
        (self.workspace / "scripts" / "remote-check").write_bytes(
            REMOTE_CHECK.read_bytes()
        )

        self.fake_bin = Path(self.temporary_directory.name) / "bin"
        self.fake_bin.mkdir()
        self._write_executable(
            "errand",
            f"#!{sys.executable}\n"
            "import os\n"
            "import sys\n"
            "print('ERRAND_CWD=' + os.getcwd())\n"
            "print('ERRAND_ARGS=' + repr(sys.argv[1:]))\n",
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def _write_executable(self, name, contents):
        path = self.fake_bin / name
        path.write_text(contents)
        path.chmod(0o700)

    def run_remote_check(self, *arguments, environment_overrides=None):
        environment = os.environ.copy()
        environment["PATH"] = f"{self.fake_bin}:{environment['PATH']}"
        environment.update(environment_overrides or {})
        return subprocess.run(
            [
                "bash",
                str(self.workspace / "scripts" / "remote-check"),
                *arguments,
            ],
            cwd=self.workspace,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def test_default_uses_errand_from_repository_root(self):
        output = self.run_remote_check()

        self.assertIn(f"ERRAND_CWD={self.workspace.resolve()}", output)
        self.assertIn("'--on', 'cabal', '--', '/usr/bin/nix'", output)
        self.assertIn("'flake', 'check', 'path:.'", output)

    def test_build_rewrites_local_flake_and_allows_destination_override(self):
        build_output = self.run_remote_check(
            "build",
            ".#checks.x86_64-linux.installed-host",
            "--no-link",
            environment_overrides={"ATLAS_ERRAND_HOST": "atlas-builder"},
        )

        self.assertIn("'--on', 'atlas-builder'", build_output)
        self.assertIn(
            "path:.#checks.x86_64-linux.installed-host", build_output
        )


if __name__ == "__main__":
    unittest.main()
