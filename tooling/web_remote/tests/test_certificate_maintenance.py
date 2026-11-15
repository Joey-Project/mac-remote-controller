import importlib.util
import os
import shlex
import signal
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "certificate_maintenance.py"
SPEC = importlib.util.spec_from_file_location("certificate_maintenance", SOURCE)
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)


class MaintenanceTests(unittest.TestCase):
    def test_oversized_history_does_not_starve_later_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir(mode=0o700)
            for name in ("letsencrypt.log", "letsencrypt.log.1"):
                path = logs / name
                path.touch(mode=0o600)
                with path.open("wb") as output:
                    output.truncate(maintenance.LOG_BUDGET)
            unrelated = logs / "operator-note.txt"
            unrelated.write_text("keep this diagnostic")
            for _ in range(2):
                code = maintenance.bounded_run(
                    [sys.executable, "-c", "raise SystemExit(7)"],
                    root / "output", logs, seconds=5,
                )
                self.assertEqual(code, 7)
            self.assertLessEqual(sum(path.stat().st_size for path in logs.iterdir()),
                                 maintenance.LOG_BUDGET)
            self.assertEqual(unrelated.read_text(), "keep this diagnostic")

    def test_log_recovery_never_follows_a_managed_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir(mode=0o700)
            outside = root / "keep"
            outside.write_bytes(b"unrelated contents")
            (logs / "letsencrypt.log").symlink_to(outside)
            with self.assertRaises(ValueError):
                maintenance.bounded_run([sys.executable, "-c", "raise SystemExit(7)"],
                                        root / "output", logs, seconds=5)
            self.assertEqual(outside.read_bytes(), b"unrelated contents")

    def test_sigterm_retires_the_owned_certbot_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "Runtime/bin"
            runtime.mkdir(parents=True)
            certificate = root / "acme-production/live/sofaremote-lan/cert.pem"
            certificate.parent.mkdir(parents=True)
            certificate.write_bytes(b"test certificate")
            (root / "cloudflare-credentials.ini").touch(mode=0o600)
            (root / "acme-production-logs").mkdir(mode=0o700)
            child_script = root / "child.py"
            child_script.write_text(
                "import os, pathlib, time\n"
                f"pathlib.Path({str(root / 'child.pid')!r}).write_text(str(os.getpid()))\n"
                "time.sleep(30)\n"
            )
            executable = runtime / "certbot"
            executable.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(child_script))}\n")
            executable.chmod(0o700)
            parent = subprocess.Popen([sys.executable, str(SOURCE), "--root", str(root)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            child_pid = None
            try:
                deadline = time.monotonic() + 10
                while not (root / "child.pid").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "child.pid").exists())
                child_pid = int((root / "child.pid").read_text())
                parent.send_signal(signal.SIGTERM)
                self.assertEqual(parent.wait(timeout=5), 128 + signal.SIGTERM)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait()
                if child_pid is not None:
                    try:
                        os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_bounded_output_and_timeout_terminate_the_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            logs = root / "logs"
            logs.mkdir(mode=0o700)
            code = maintenance.bounded_run(
                [sys.executable, "-c", "import time; time.sleep(30)"], output, logs, seconds=0.1,
            )
            self.assertEqual(code, 124)
            code = maintenance.bounded_run(
                [sys.executable, "-c", "print('x' * 300000)"], output, logs, seconds=5,
            )
            self.assertEqual(code, 124)
            self.assertLessEqual(output.stat().st_size, 256 * 1024)

    def test_success_is_returned_without_retries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir(mode=0o700)
            code = maintenance.bounded_run(
                [sys.executable, "-c", "raise SystemExit(7)"], root / "output", logs, seconds=5,
            )
            self.assertEqual(code, 7)

    def test_private_files_reject_public_access_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "credentials"
            file.touch(mode=0o600)
            maintenance.require_private(file)
            os.chmod(file, 0o644)
            with self.assertRaises(ValueError):
                maintenance.require_private(file)
            link = root / "link"
            link.symlink_to(file)
            with self.assertRaises(ValueError):
                maintenance.require_private(link)

    def test_command_has_only_a_credential_path_and_never_forces_renewal(self):
        root = Path("/private/web")
        command = maintenance.command_for(root)
        self.assertNotIn("--force-renewal", command)
        self.assertNotIn("--agree-tos", command)
        self.assertEqual(command.count("--dns-cloudflare-credentials"), 1)
        self.assertIn(str(root / "cloudflare-credentials.ini"), command)


if __name__ == "__main__":
    unittest.main()
