#!/usr/bin/env python3
"""Exercise real TLS/HTTP/WebSocket framing against a desktop-free Swift fixture."""

import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import time
import uuid


class SocketClient:
    def __init__(self, context, port, authority, origin, cookie=None):
        self.socket = context.wrap_socket(
            socket.create_connection(("127.0.0.1", port), timeout=3),
            server_hostname="remote.example.test",
        )
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            "GET /remote HTTP/1.1", f"Host: {authority}", f"Origin: {origin}",
            "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13",
            f"Sec-WebSocket-Key: {key}",
        ]
        if cookie:
            lines.append(f"Cookie: {cookie}")
        self.socket.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        response = bytearray()
        while not response.endswith(b"\r\n\r\n") and len(response) < 8192:
            try:
                response.extend(self.exact(1))
            except EOFError:
                break
        self.upgraded = response.startswith(b"HTTP/1.1 101 ")
        if self.upgraded:
            expected = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest())
            assert expected in response, "Invalid WebSocket upgrade digest"

    def exact(self, count):
        value = bytearray()
        while len(value) < count:
            part = self.socket.recv(count - len(value))
            if not part:
                raise EOFError("Socket closed")
            value.extend(part)
        return bytes(value)

    def send(self, value):
        payload = json.dumps(value, separators=(",", ":")).encode()
        mask = os.urandom(4)
        length = len(payload)
        header = bytes([0x81, 0x80 | length]) if length < 126 else (
            bytes([0x81, 0xFE]) + struct.pack("!H", length)
        )
        self.socket.sendall(header + mask + bytes(
            byte ^ mask[index % 4] for index, byte in enumerate(payload)
        ))

    def receive(self):
        first, second = self.exact(2)
        assert not second & 0x80, "Server must not mask frames"
        count = second & 0x7F
        if count == 126:
            count = struct.unpack("!H", self.exact(2))[0]
        if count == 127:
            count = struct.unpack("!Q", self.exact(8))[0]
        assert count <= 65536
        data = self.exact(count)
        return first & 0x0F, data

    def message(self):
        opcode, data = self.receive()
        assert opcode == 1, "Expected a text message"
        value = json.loads(data)
        assert "authToken" not in value, "Credential escaped into JavaScript"
        return value

    def close(self):
        self.socket.close()


def wait_for(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError("Fixture condition timed out")


def exercise(fixture, assets, root, unlock_allowed):
    certificate = root / "certificate.pem"
    key = root / "key.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/CN=remote.example.test", "-addext",
        "subjectAltName=DNS:remote.example.test,IP:127.0.0.1",
        "-keyout", str(key), "-out", str(certificate),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    key.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    authority = f"remote.example.test:{port}"
    origin = f"https://{authority}"
    evidence = root / "evidence.json"
    configuration = root / "fixture.json"
    configuration.write_text(json.dumps({
        "endpoint": {"hostname": "remote.example.test", "port": port,
                     "bindAddress": "192.168.1.10", "certificateChain": str(certificate),
                     "privateKey": str(key)},
        "assetsDirectory": str(assets), "evidenceFile": str(evidence),
        "loopbackOnly": True, "restartOnce": True,
        "unlockAllowed": unlock_allowed,
    }))
    context = ssl.create_default_context(cafile=str(certificate))
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    child = subprocess.Popen([str(fixture), str(configuration)], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def state():
        return json.loads(evidence.read_text()) if evidence.exists() else {}

    def request(method, path, body=None, cookie=None, source=origin):
        headers = {"Host": authority}
        if source:
            headers["Origin"] = source
        if cookie:
            headers["Cookie"] = cookie
        if body is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(body)
        connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=3)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read(65537)
            return response.status, response.getheaders(), payload
        finally:
            connection.close()

    try:
        wait_for(lambda: state().get("ready") or child.poll() is not None, seconds=15)
        assert child.poll() is None, "Fixture did not start"
        assert state()["fixtureOnly"] and state()["desktopEvents"] == 0
        try:
            with ssl.create_default_context().wrap_socket(
                socket.create_connection(("127.0.0.1", port), timeout=3),
                server_hostname="remote.example.test",
            ):
                raise AssertionError("An untrusted certificate was accepted")
        except ssl.SSLCertVerificationError:
            pass
        status, headers, body = request("GET", "/")
        assert status == 200 and b"Sofa Remote" in body
        header_map = {name.lower(): value for name, value in headers}
        assert "frame-ancestors 'none'" in header_map["content-security-policy"]
        assert header_map["cache-control"] == "no-store"
        assert request("POST", "/api/pairing/start", {"name": "Attacker"},
                       source="https://other.example.test")[0] == 403
        assert request("POST", "/api/pairing/start", {"name": "No origin"}, source=None)[0] == 403
        anonymous = SocketClient(context, port, authority, origin)
        assert not anonymous.upgraded
        anonymous.close()
        status, headers, body = request("POST", "/api/pairing/start", {"name": "Transport test"})
        assert status == 200
        pairing = json.loads(body)
        assert "code" not in pairing and "pairingCode" not in pairing
        cookie_header = next(value for name, value in headers if name.lower() == "set-cookie")
        assert all(flag in cookie_header for flag in ["Secure", "HttpOnly", "SameSite=Strict", "Path=/"])
        owner_cookie = cookie_header.split(";", 1)[0]
        code = wait_for(lambda: state().get("pairingCode"))
        confirmation = {"requestId": pairing["requestId"], "code": code}
        assert request("POST", "/api/pairing/confirm", confirmation)[0] == 410
        wrong = dict(confirmation, code="0000" if code != "0000" else "0001")
        assert request("POST", "/api/pairing/confirm", wrong, cookie=owner_cookie)[0] == 403
        status, headers, body = request("POST", "/api/pairing/confirm", confirmation,
                                        cookie=owner_cookie)
        assert status == 200 and json.loads(body) == {"paired": True}
        cookie = next(value.split(";", 1)[0] for name, value in headers
                      if name.lower() == "set-cookie" and value.startswith("__Host-sofaremote="))
        assert request("POST", "/api/pairing/confirm", confirmation, cookie=owner_cookie)[0] == 410
        assert json.loads(request("GET", "/api/status", cookie=cookie)[2])["paired"]
        client = SocketClient(context, port, authority, origin, cookie)
        assert client.upgraded
        welcome = client.message()
        assert welcome["type"] == "welcome"
        assert "keyboardControls.v1" in welcome["state"]["capabilities"]
        assert welcome["state"]["mediaTargets"][0]["capabilities"]["playerVolumeMaximum"] == 4
        session = welcome["connectionId"]
        # The Web benchmark uses the companion's authenticated no-op protocol,
        # not a local JavaScript echo or unauthenticated HTTP timing request.
        events_before_probes = state()["events"]
        for sequence in range(1, 94):
            request_id = str(uuid.uuid4())
            client.send({"protocolVersion": 1, "type": "ping", "connectionId": session,
                         "requestId": request_id, "sequence": sequence})
            assert client.message() == {
                "protocolVersion": 1, "type": "pong", "connectionId": session,
                "requestId": request_id, "sequence": sequence,
            }, "Probe reply must match its authenticated session, request and sequence"
        assert state()["events"] == events_before_probes, "Benchmark produced input or audio events"
        client.close()
        client = SocketClient(context, port, authority, origin, cookie)
        session = client.message()["connectionId"]
        keyboard_commands = [
            *({"name": "keyboard.key", "key": key}
              for key in ["tab", "forward-delete", "home", "end", "page-up", "page-down"]),
            *({"name": "keyboard.shortcut", "keyboardShortcut": shortcut}
              for shortcut in ["copy", "cut", "paste", "select-all", "undo", "redo", "find", "previous-field"]),
        ]
        for sequence, command in enumerate([
            {"name": "pointer.move", "x": 3, "y": -2},
            {"name": "keyboard.key", "key": "left"},
            {"name": "keyboard.text", "text": "transport fixture"},
            *keyboard_commands,
            {"name": "pointer.button.down", "button": "left"},
        ], 1):
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": sequence, "command": command})
            result = client.message()
            assert result["type"] == "result" and result["sequence"] == sequence
        wait_for(lambda: state()["heldButtons"] == 1)
        recorded_keyboard = [event for event in state()["events"]
                             if event["name"] == "keyboard.shortcut"
                             or event["name"] == "keyboard.key" and event["key"] != "left"]
        assert recorded_keyboard == keyboard_commands, "Keyboard controls changed or repeated"
        client.close()
        wait_for(lambda: state()["releasedButtonsOnClose"] == 1)
        client = SocketClient(context, port, authority, origin, cookie)
        session = client.message()["connectionId"]
        for sequence, (target, action, value, rejected) in enumerate([
            ("iina:fixture", "previous", None, False),
            ("iina:fixture", "seek", -10, False),
            ("iina:fixture", "playPause", None, False),
            ("iina:fixture", "seek", 10, False),
            ("iina:fixture", "next", None, False),
            ("iina:fixture", "setVolume", 1.2, False),
            ("iina:fixture", "setVolume", 4, False),
            ("iina:fixture", "setVolume", 4.1, True),
            ("iina:closed", "playPause", None, True),
            ("chrome:fixture", "next", None, True),
            ("chrome:fixture", "setVolume", 1, True),
            ("chrome:fixture", "playPause", None, False),
        ], 1):
            media = {"targetId": target, "action": action}
            if value is not None:
                media["value"] = value
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": sequence,
                         "command": {"name": "media.control", "mediaRequest": media}})
            result = client.message()
            assert result["type"] == "result" and result["sequence"] == sequence
            assert (result.get("error", {}).get("code") == "media_unavailable") == rejected
            snapshot = client.message()
            assert snapshot["type"] == "state"
            if action == "setVolume" and not rejected:
                assert snapshot["state"]["mediaTargets"][0]["playerVolume"] == value
        client.close()
        def completed_media_events():
            events = [event for event in state()["events"] if event["name"] == "media.control"]
            # The socket acknowledgement can arrive before the atomic evidence-file write.
            # Wait for the final accepted action, not merely a nonempty partial history.
            return events if events and (events[-1]["targetId"], events[-1]["action"]) == (
                "chrome:fixture", "playPause") else None

        events = wait_for(completed_media_events)
        expected = [("iina:fixture", action) for action in [
            "previous", "seek", "playPause", "seek", "next", "setVolume", "setVolume"
        ]] + [("chrome:fixture", "playPause")]
        assert [(event["targetId"], event["action"]) for event in events] == expected, (
            f"Rejected actions were executed or accepted media was lost: {len(events)} events")
        assert float(events[1]["value"]) == -10 and float(events[3]["value"]) == 10
        client = SocketClient(context, port, authority, origin, cookie)
        welcome = client.message()
        assert welcome["state"]["supportsGestures"] is True
        session = welcome["connectionId"]
        shortcuts = ["previous-space", "mission-control", "app-expose", "next-space"]
        for sequence, shortcut in enumerate(shortcuts, 1):
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": sequence,
                         "command": {"name": "system.shortcut", "shortcut": shortcut}})
            result = client.message()
            assert result["type"] == "result" and result["sequence"] == sequence
            assert "error" not in result
        client.close()

        def completed_desktop_events():
            events = [event for event in state()["events"] if event["name"] == "system.shortcut"]
            return events if events and events[-1].get("shortcut") == "next-space" else None

        assert wait_for(completed_desktop_events) == [
            {"name": "system.shortcut", "shortcut": shortcut} for shortcut in shortcuts
        ], "Desktop actions were changed, repeated or synthesized as keyboard commands"
        for command in [
            {"name": "system.shortcut", "shortcut": "control+up"},
            {"name": "system.shortcut", "shortcut": "mission-control", "key": "up"},
            {"name": "keyboard.shortcut", "keyboardShortcut": "command-down"},
            {"name": "keyboard.shortcut", "keyboardShortcut": "copy", "keyCode": 8},
            {"name": "keyboard.shortcut", "keyboardShortcut": "paste", "text": None},
            {"name": "gesture.frame", "gesture": {
                "id": str(uuid.uuid4()), "kind": "horizontalSwipe", "phase": "began", "value": 0,
                "timestamp": 1,
            }},
        ]:
            client = SocketClient(context, port, authority, origin, cookie)
            session = client.message()["connectionId"]
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": 1, "command": command})
            assert client.receive()[0] == 8, "Browser escaped the fixed desktop-action allowlist"
            client.close()
        client = SocketClient(context, port, authority, origin, cookie)
        welcome = client.message()
        assert "simulatedGestures.v1" in welcome["state"]["capabilities"]
        session = welcome["connectionId"]
        gesture_id = str(uuid.uuid4())
        for sequence, (phase, value) in enumerate([
            ("began", 0), ("changed", 0.2), ("ended", 0.4),
            ("began", 0), ("changed", -0.2), ("cancelled", -0.2),
        ], 1):
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": sequence,
                         "command": {"name": "gesture.frame", "gesture": {
                             "id": gesture_id, "kind": "magnify", "phase": phase,
                             "value": value, "timestamp": sequence,
                         }}})
            result = client.message()
            assert result["type"] == "result" and result["sequence"] == sequence
            assert "error" not in result
        client.close()

        def completed_pinch_events():
            events = [event for event in state()["events"] if event["name"] == "gesture.frame"]
            return events if len(events) == 6 else None

        pinch_events = wait_for(completed_pinch_events)
        assert [event["phase"] for event in pinch_events] == [
            "began", "changed", "ended", "began", "changed", "cancelled"]
        assert all(event["gestureID"] == gesture_id and event["kind"] == "magnify" for event in pinch_events)
        assert [float(event["value"]) for event in pinch_events] == [0, 0.2, 0.4, 0, -0.2, -0.2]
        for invalid in [
            {"id": gesture_id, "kind": "magnify", "phase": "began", "value": 0.2, "timestamp": 1},
            {"id": gesture_id, "kind": "magnify", "phase": "changed", "value": 4.1, "timestamp": 2},
            {"id": gesture_id, "kind": "magnify", "phase": "changed", "value": 0.2, "timestamp": 2, "key": "up"},
        ]:
            client = SocketClient(context, port, authority, origin, cookie)
            session = client.message()["connectionId"]
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": 1,
                         "command": {"name": "gesture.frame", "gesture": invalid}})
            assert client.receive()[0] == 8, "Invalid phased magnification escaped validation"
            client.close()
        client = SocketClient(context, port, authority, origin, cookie)
        welcome = client.message()
        assert welcome["state"]["unlockAvailable"] is unlock_allowed
        session = welcome["connectionId"]
        session_actions = ["session.lock", "display.off", "display.wake",
                           "session.lock-display-off", "session.unlock"]
        snapshots = [(True, False), (True, True), (True, False), (True, True),
                     (not unlock_allowed, not unlock_allowed)]
        for sequence, (name, expected) in enumerate(zip(session_actions, snapshots), 1):
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": sequence, "command": {"name": name}})
            result = client.message()
            assert result["type"] == "result" and result["sequence"] == sequence
            rejected = name == "session.unlock" and not unlock_allowed
            assert ("error" in result) is rejected
            snapshot = client.message()
            assert snapshot["type"] == "state"
            assert (snapshot["state"]["sessionLocked"], snapshot["state"]["displayAsleep"]) == expected
        # A permission rejection leaves the authenticated connection usable.
        client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                     "requestId": str(uuid.uuid4()), "sequence": 6,
                     "command": {"name": "keyboard.key", "key": "escape"}})
        assert "error" not in client.message()
        client.close()
        expected_events = [{"name": name} for name in session_actions
                           if unlock_allowed or name != "session.unlock"]

        def completed_session_events():
            current = state()
            events = [event for event in current["events"] if event["name"] in session_actions]
            return events if len(events) >= len(expected_events) and current["deniedSessionCommands"] == int(not unlock_allowed) else None

        assert wait_for(completed_session_events) == expected_events, "A denied or duplicate session action executed"
        for name in session_actions:
            client = SocketClient(context, port, authority, origin, cookie)
            session = client.message()["connectionId"]
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": 1,
                         "command": {"name": name, "value": 1}})
            assert client.receive()[0] == 8, "A parameterized session action escaped validation"
            client.close()
        for name in ["system.sleep", "session.login", "display.shell"]:
            client = SocketClient(context, port, authority, origin, cookie)
            session = client.message()["connectionId"]
            client.send({"protocolVersion": 1, "type": "command", "connectionId": session,
                         "requestId": str(uuid.uuid4()), "sequence": 1, "command": {"name": name}})
            assert client.receive()[0] == 8, "An arbitrary power command escaped the scope"
            client.close()
        client = SocketClient(context, port, authority, origin, cookie)
        client.message()
        assert request("POST", "/api/pairing/forget", {}, cookie=cookie)[0] == 200
        assert client.receive()[0] == 8, "Revocation left an active socket"
        client.close()
        rejected = SocketClient(context, port, authority, origin, cookie)
        assert not rejected.upgraded, "Revoked cookie reconnected"
        rejected.close()
        assert state()["desktopEvents"] == 0
        print(f"TLS, PIN, WSS input/media/desktop/session, scope and revocation passed; unlock allowed={unlock_allowed}.")
    finally:
        if child.poll() is None:
            child.send_signal(signal.SIGTERM)
        try:
            result = child.wait(timeout=5)
            assert result == 0, "Fixture did not stop cleanly"
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="sofa-web-transport-") as directory:
        for allowed in [False, True]:
            root = Path(directory) / str(allowed)
            root.mkdir()
            exercise(args.fixture.resolve(), args.assets.resolve(), root, allowed)


if __name__ == "__main__":
    main()
