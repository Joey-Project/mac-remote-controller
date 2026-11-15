"""Check one private Web certificate using an isolated Certbot installation."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import tempfile
import time


def require_private(path: Path, *, directory: bool = False) -> None:
    metadata = path.lstat()
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not expected_type(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) & 0o077
    ):
        raise ValueError("Expected an owned private directory or file.")


def terminate(child: subprocess.Popen) -> None:
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def bounded_run(command: list[str], output_path: Path, logs: Path, seconds: float = 240) -> int:
    """Retain at most 256 KiB of output; terminate on deadline or a 2 MiB log budget."""
    child = subprocess.Popen(
        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, start_new_session=True,
    )
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    started = time.monotonic()
    retained = 0
    stopped = False
    try:
        with output_path.open("wb") as output:
            while selector.get_map():
                internal_bytes = sum(path.stat().st_size for path in logs.iterdir() if path.is_file())
                if time.monotonic() - started >= seconds or internal_bytes > 2 * 1024 * 1024:
                    stopped = True
                    break
                for key, _ in selector.select(timeout=0.2):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    available = 256 * 1024 - retained
                    output.write(chunk[:available])
                    retained += min(len(chunk), available)
                    if len(chunk) > available:
                        stopped = True
                        break
                if stopped:
                    break
        if stopped:
            terminate(child)
        try:
            result = child.wait(timeout=max(0.1, seconds - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            terminate(child)
            child.wait()
            stopped = True
            result = 124
        return 124 if stopped else result
    finally:
        if child.poll() is None:
            terminate(child)
            child.wait()
        selector.close()
        child.stdout.close()


def command_for(root: Path) -> list[str]:
    return [
        str(root / "Runtime/bin/certbot"), "renew",
        "--config", str(root / "acme-client.ini"),
        "--config-dir", str(root / "acme-production"),
        "--work-dir", str(root / "acme-production-work"),
        "--logs-dir", str(root / "acme-production-logs"),
        "--max-log-backups", "1", "--non-interactive", "--quiet",
        "--cert-name", "sofaremote-lan",
        "--dns-cloudflare-credentials", str(root / "cloudflare-credentials.ini"),
    ]


def record_status(root: Path, result: dict) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".certificate-status-", dir=root)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(result, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, root / "certificate-status.json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def maintain(root: Path) -> int:
    os.umask(0o077)
    require_private(root, directory=True)
    require_private(root / "cloudflare-credentials.ini")
    lock = os.open(root / "certificate-maintenance.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "a") as owned_lock:
        try:
            fcntl.flock(owned_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        certificate = root / "acme-production/live/sofaremote-lan/cert.pem"
        before = hashlib.sha256(certificate.read_bytes()).hexdigest()
        logs = root / "acme-production-logs"
        result = bounded_run(command_for(root), root / "certificate-check.output", logs)
        after = hashlib.sha256(certificate.read_bytes()).hexdigest()
        record_status(root, {
            "checkedAtUnix": int(time.time()), "exitCode": result,
            "certificateChanged": before != after,
            "certificateSHA256": after,
        })
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    arguments = parser.parse_args()
    signal.signal(signal.SIGTERM, handle_termination)
    try:
        return maintain(arguments.root.absolute())
    except Exception:
        # Provider output stays private. Never serialize exception payloads or credentials.
        print("Web certificate check failed. Inspect its private status and bounded logs.")
        return 1


def handle_termination(signum: int, _frame) -> None:
    # Let bounded_run's finally block retire its separate child process group.
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    raise SystemExit(main())
