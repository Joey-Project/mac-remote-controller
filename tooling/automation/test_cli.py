"""Exercise the compiled CLI against a real, owner-private Unix socket."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True, type=Path)
OPTIONS, REMAINING = parser.parse_known_args()
BINARY = OPTIONS.binary.resolve(strict=True)


@contextmanager
def endpoint(outcome='ok'):
    root = Path(tempfile.mkdtemp(prefix='src-', dir='/tmp'))
    os.chmod(root, 0o700)
    address = root / 'control.sock'
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(address))
    os.chmod(address, 0o600)
    listener.listen(2)
    listener.settimeout(0.1)
    stop = threading.Event()
    seen = []

    def serve():
        while not stop.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with connection:
                connection.settimeout(2)
                data = b''
                while b'\n' not in data and len(data) < 16384:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                if data:
                    seen.append(json.loads(data))
                    response = dict(version=1, outcome=outcome, values={'fixture': 'ready'})
                    connection.sendall(json.dumps(response).encode() + b'\n')

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    try:
        yield address, seen
    finally:
        stop.set()
        worker.join(timeout=2.5)
        listener.close()
        shutil.rmtree(root)


class CLITests(unittest.TestCase):
    def invoke(self, address, *arguments):
        return subprocess.run([str(BINARY), '--socket', str(address), *arguments],
                              capture_output=True, timeout=5)

    def test_status_and_typed_control_arguments_round_trip(self):
        with endpoint() as (address, seen):
            status = self.invoke(address, 'status')
            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertEqual(json.loads(status.stdout)['values'], {'fixture': 'ready'})
            action = self.invoke(address, 'invoke', 'device.unlock', '--value', 'true', '--device', 'fixture-device')
            self.assertEqual(action.returncode, 0, action.stderr)
            self.assertEqual(seen[-1], dict(version=1, operation='invoke', control='device.unlock',
                                            value='true', deviceID='fixture-device'))

    def test_invalid_arguments_do_not_connect(self):
        with endpoint() as (address, seen):
            for arguments in [('invoke', 'not-a-control'), ('status', '--value', 'true'),
                              ('invoke', 'web.enabled', '--value', 'true', '--value', 'false')]:
                result = self.invoke(address, *arguments)
                self.assertEqual(result.returncode, 2)
            self.assertEqual(seen, [])

    def test_unavailable_action_is_reported_without_retry(self):
        with endpoint('unavailable') as (address, seen):
            result = self.invoke(address, 'invoke', 'web.reload')
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)['outcome'], 'unavailable')
            self.assertEqual(len(seen), 1)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *REMAINING])
