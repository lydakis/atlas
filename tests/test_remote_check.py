import os
import stat
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
        (self.workspace / "scripts" / "remote-check").chmod(
            stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR
        )

        (self.workspace / ".gitignore").write_text("ignored-secret\n")
        (self.workspace / "tracked.txt").write_text("tracked\n")
        (self.workspace / "tracked-deleted.txt").write_text("delete me\n")
        (self.workspace / "untracked.txt").write_text("untracked\n")
        (self.workspace / "ignored-secret").write_text("must-not-upload\n")
        subprocess.run(["git", "init", "-q"], cwd=self.workspace, check=True)
        subprocess.run(
            ["git", "add", ".gitignore", "tracked.txt", "tracked-deleted.txt"],
            cwd=self.workspace,
            check=True,
        )
        (self.workspace / "tracked-deleted.txt").unlink()

        self.fake_bin = Path(self.temporary_directory.name) / "bin"
        self.fake_bin.mkdir()
        self._write_executable(
            "rsync",
            f"#!{sys.executable}\n"
            "import sys\n"
            "print('RSYNC_ARGS=' + repr(sys.argv[1:]))\n"
            "print('RSYNC_INPUT=' + repr(sys.stdin.buffer.read()))\n",
        )
        self._write_executable(
            "ssh",
            f"#!{sys.executable}\n"
            "import sys\n"
            "if 'mktemp -d' in sys.argv[-1]:\n"
            "    print('atlas-remote-check/worktree.ABC123')\n"
            "else:\n"
            "    print('SSH_ARGS=' + repr(sys.argv[1:]))\n",
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def _write_executable(self, name, contents):
        path = self.fake_bin / name
        path.write_text(contents)
        path.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)

    def run_remote_check(self, *arguments):
        environment = os.environ.copy()
        environment["PATH"] = f"{self.fake_bin}:{environment['PATH']}"
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

    def test_upload_manifest_excludes_git_ignored_files(self):
        output = self.run_remote_check()

        self.assertIn("--files-from=-", output)
        self.assertIn("--from0", output)
        self.assertIn("tracked.txt", output)
        self.assertIn("untracked.txt", output)
        self.assertNotIn("tracked-deleted.txt", output)
        self.assertNotIn("ignored-secret", output)

    def test_remote_nix_uses_path_flake_for_default_and_build(self):
        default_output = self.run_remote_check()
        build_output = self.run_remote_check(
            "build", ".#checks.x86_64-linux.installed-host", "--no-link"
        )

        self.assertIn("path:.", default_output)
        self.assertIn(
            "path:.#checks.x86_64-linux.installed-host", build_output
        )


if __name__ == "__main__":
    unittest.main()
