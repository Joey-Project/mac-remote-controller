"""Check one private Web certificate using an isolated Certbot installation."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import tempfile
import time

LOG_BUDGET = 2 * 1024 * 1024
CERTBOT_LOG = re.compile(r"letsencrypt\.log(?:\.[0-9]+)?\Z")


def require_private(path: Path, *, directory: bool = False) -> None:
    require_private_metadata(path.lstat(), directory=directory)


def require_private_metadata(metadata, *, directory: bool = False) -> None:
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not expected_type(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) & 0o077
    ):
        raise ValueError("Expected an owned private directory or file.")


def log_entries(directory: int):
    """Bound the scan and reject managed symlinks rather than following them."""
    files = []
    with os.scandir(directory) as entries:
        for index, entry in enumerate(entries):
            if index >= 1024:
                raise ValueError("Unexpected certificate log inventory.")
            try:
                metadata = entry.stat(follow_symlinks=False)
            except FileNotFoundError:
                # Certbot may rotate a file while the active attempt is measured.
                continue
            if CERTBOT_LOG.fullmatch(entry.name):
                require_private_metadata(metadata)
            if stat.S_ISREG(metadata.st_mode):
                files.append((entry.name, metadata.st_size))
    return files


def recover_log_budget(directory: int) -> None:
    files = log_entries(directory)
    if sum(size for _, size in files) <= LOG_BUDGET:
        return
    for name, _ in files:
        if not CERTBOT_LOG.fullmatch(name):
            continue
        descriptor = os.open(name, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            # Trim only this opened, owned, private regular log object. Other
            # files and symlink targets are untouched; timestamp changes do not
            # affect this access policy. The separate bounded output is retained.
            require_private_metadata(os.fstat(descriptor))
            os.ftruncate(descriptor, 0)
        finally:
            os.close(descriptor)
    if sum(size for _, size in log_entries(directory)) > LOG_BUDGET:
        raise ValueError("Non-Certbot files exceed the certificate log budget.")


def terminate(child: subprocess.Popen) -> None:
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def bounded_run(command: list[str], output_path: Path, logs: Path, seconds: float = 240) -> int:
    """Retain at most 256 KiB of output; terminate on deadline or a 2 MiB log budget."""
    directory = os.open(logs, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        require_private_metadata(os.fstat(directory), directory=True)
        # Recover before spawning: previous verbose failures cannot starve every
        # later renewal attempt before Certbot gets a chance to rotate its logs.
        recover_log_budget(directory)
        return run_child(command, output_path, directory, seconds)
    finally:
        os.close(directory)


def run_child(command: list[str], output_path: Path, directory: int, seconds: float) -> int:
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
                internal_bytes = sum(size for _, size in log_entries(directory))
                if time.monotonic() - started >= seconds or internal_bytes > LOG_BUDGET:
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
