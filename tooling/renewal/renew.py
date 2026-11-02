"""Opt-in, headless free-account renewal research. Does not schedule itself."""

import argparse
from contextlib import contextmanager
import ctypes
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import shutil
import stat
import struct
import subprocess
import sys
import time
import uuid

IOS_ID = "com.joeyteng.sofaremote.ios"
MAC_ID = "com.joeyteng.sofaremote.renewalprobe.mac"
PROBE_ID = "com.joeyteng.sofaremote.renewalprobe"
CONFIG_KEYS = {"probeApp", "iosApp", "deviceIdentifier", "deviceUDID", "runDirectory"}


class RenewalError(Exception):
    """Only fixed, non-secret diagnostic categories are exposed publicly."""


def require(condition, category):
    if not condition:
        raise RenewalError(category)


def now():
    return dt.datetime.now(dt.timezone.utc)


def utc(value):
    return value.replace(tzinfo=dt.timezone.utc)


def read_config(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as source:
        metadata = os.fstat(source.fileno())
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
            and stat.S_IMODE(metadata.st_mode) == 0o600, "configuration-must-be-owner-private")
        content = source.read(16385)
    require(len(content) <= 16384, "configuration-too-large")
    config = json.loads(content)
    require(isinstance(config, dict) and set(config) == CONFIG_KEYS, "unexpected-configuration-fields")
    require(all(isinstance(v, str) and v and "\0" not in v for v in config.values()), "invalid-configuration")
    for key in ("probeApp", "iosApp", "runDirectory"):
        require(Path(config[key]).is_absolute(), "absolute-path-required")
    return config


@contextmanager
def exclusive_probe(probe):
    """Serialize cooperating runs, including those using different run directories."""
    fd = os.open(probe.parent / ".SofaRenewalProbe.renewal.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        metadata = os.fstat(fd)
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
            and stat.S_IMODE(metadata.st_mode) == 0o600, "unsafe-renewal-lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RenewalError("renewal-already-running") from None
        yield
    finally:
        os.close(fd)


def identifier(profile):
    entitlements = profile["Entitlements"]
    return entitlements.get("application-identifier", entitlements.get("com.apple.application-identifier"))


def validate_profile(profile, team, bundle, device, certificate, previous, started):
    require(profile["TeamIdentifier"] == [team] and identifier(profile) == f"{team}.{bundle}", "profile-identity-mismatch")
    require(device in profile.get("ProvisionedDevices", []), "profile-device-mismatch")
    require(profile["DeveloperCertificates"] == [certificate], "profile-certificate-mismatch")
    require(utc(profile["CreationDate"]) >= started - dt.timedelta(seconds=1), "profile-not-newly-issued")
    require(utc(profile["ExpirationDate"]) > now(), "profile-expired")
    require(profile["ExpirationDate"] > previous["ExpirationDate"], "profile-expiration-did-not-advance")


def authorized_groups(entitlements, profile):
    allowed = profile["Entitlements"].get("keychain-access-groups", [])
    return all(any(rule == group or (rule.endswith("*") and group.startswith(rule[:-1])) for rule in allowed)
        for group in entitlements.get("keychain-access-groups", []))


def authorized_leaf(profile, leaf):
    require(leaf in profile["DeveloperCertificates"], "reference-certificate-mismatch")
    return leaf


def atomic_exchange(first, second):
    """Keep the stable app directory present across interrupted publication.

    Both sibling directories already exist. The single filesystem operation
    swaps them; the displaced app remains at the staging path for recovery.
    Cooperating callers hold exclusive_probe. No timestamp heuristic is used.
    """
    require(first.parent == second.parent, "atomic-adoption-needs-same-parent")
    library = ctypes.CDLL(None, use_errno=True)
    name = "renameatx_np" if sys.platform == "darwin" else "renameat2" if sys.platform.startswith("linux") else ""
    exchange = getattr(library, name, None) if name else None
    require(exchange is not None, "atomic-adoption-unavailable")
    exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    exchange.restype = ctypes.c_int
    parent = os.open(first.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        require(all(stat.S_ISDIR(os.stat(p.name, dir_fd=parent, follow_symlinks=False).st_mode) for p in (first, second)),
            "atomic-adoption-needs-app-directories")
        # Darwin RENAME_SWAP and Linux RENAME_EXCHANGE both use flag 2.
        if exchange(parent, os.fsencode(first.name), parent, os.fsencode(second.name), 2) != 0:
            raise RenewalError("atomic-adoption-exchange-failed")
    finally:
        os.close(parent)


def instruction_hash(path):
    require(path.stat().st_size <= 128 * 1024 * 1024, "executable-too-large")
    data = path.read_bytes()
    require(len(data) >= 32 and struct.unpack_from("<I", data)[0] == 0xFEEDFACF, "expected-arm64-mach-o")
    offset = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= len(data), "invalid-mach-o-command")
        if command == 0x19:
            require(size >= 72, "invalid-mach-o-segment")
            count = struct.unpack_from("<I", data, offset + 64)[0]
            require(72 + count * 80 <= size, "invalid-mach-o-sections")
            for index in range(count):
                section = offset + 72 + index * 80
                if data[section:section + 16].split(b"\0")[0] == b"__text" and data[section + 16:section + 32].split(b"\0")[0] == b"__TEXT":
                    length = struct.unpack_from("<Q", data, section + 40)[0]
                    start = struct.unpack_from("<I", data, section + 48)[0]
                    require(start + length <= len(data), "invalid-mach-o-section-range")
                    return hashlib.sha256(data[start:start + length]).hexdigest()
        offset += size
    raise RenewalError("executable-instructions-missing")


class CommandLog:
    def __init__(self, root):
        self.root = root
        self.remaining_log_bytes = 4 * 1024 * 1024
        self.sequence = 0

    def command(self, label, argv, seconds=30, environment=None):
        self.sequence += 1
        output = bytearray()
        deadline = time.monotonic() + seconds
        env = dict(os.environ)
        env.pop("XTL_DEBUG_ERRORS", None)
        env.update(environment or {})
        path = self.root / f"{self.sequence:02d}-{label}.log"
        count = 0
        with path.open("xb") as log, subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) as child:
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ, data=True)
            selector.register(child.stderr, selectors.EVENT_READ, data=False)
            try:
                while selector.get_map():
                    require(time.monotonic() < deadline, f"{label}-timeout")
                    for key, _ in selector.select(timeout=min(0.2, max(0, deadline - time.monotonic()))):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        count += len(chunk)
                        require(len(chunk) <= self.remaining_log_bytes and count <= 524288, "command-output-limit")
                        self.remaining_log_bytes -= len(chunk)
                        log.write(chunk)
                        if key.data:
                            output.extend(chunk)
                require(child.wait(timeout=max(0.1, deadline - time.monotonic())) == 0, f"{label}-failed")
            finally:
                selector.close()
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
        return bytes(output)


class Run(CommandLog):
    def __init__(self, config):
        self.config = config
        root = Path(config["runDirectory"]) / (now().strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
        root.mkdir(parents=True, mode=0o700)
        super().__init__(root)
        self.probe = Path(config["probeApp"])
        self.executable = self.probe / "Contents/MacOS/SofaRenewalProbe"
        self.summary = {"startedAt": now().isoformat(), "appLaunched": False, "appUninstalled": False}

    def profile(self, path):
        require(path.stat().st_size <= 1024 * 1024, "profile-too-large")
        return plistlib.loads(self.command("decode-profile", ["security", "cms", "-D", "-i", str(path)]))

    def entitlements(self, app):
        return plistlib.loads(self.command("read-entitlements", ["codesign", "-d", "--entitlements", ":-", str(app)]))

    def locked(self):
        roots = plistlib.loads(self.command("mac-lock", ["ioreg", "-n", "Root", "-d", "1", "-a"]))
        root = roots[0] if isinstance(roots, list) else roots
        session = next((s for s in root.get("IOConsoleUsers", []) if s.get("kCGSSessionUserIDKey") == os.getuid()), {})
        return session.get("CGSSessionScreenIsLocked")

    def verify_signature(self, app):
        self.command("verify-signature", ["codesign", "--verify", "--deep", "--strict", str(app)])

    def issue(self, target, reference):
        old = self.profile(reference / ("Contents/embedded.provisionprofile" if target == "mac" else "embedded.mobileprovision"))
        team, = old["TeamIdentifier"]
        bundle = MAC_ID if target == "mac" else IOS_ID
        require(identifier(old) == f"{team}.{bundle}", "reference-identity-mismatch")
        self.verify_signature(reference)
        prefix = self.root / "reference-leaf-"
        self.command("read-certificate", ["codesign", "-d", f"--extract-certificates={prefix}", str(reference)])
        certificate = authorized_leaf(old, Path(str(prefix) + "0").read_bytes())
        if target == "mac":
            hardware = json.loads(self.command("hardware", ["system_profiler", "SPHardwareDataType", "-json"]))["SPHardwareDataType"][0]
            devices = [v for k, v in hardware.items() if "udid" in k.lower() and v in old["ProvisionedDevices"]]
            require(len(devices) == 1, "mac-provisioning-udid-mismatch")
            device = devices[0]
        else:
            device = self.config["deviceUDID"]
            require(device in old["ProvisionedDevices"], "reference-device-mismatch")
        cert = self.root / "certificate.der"
        cert.write_bytes(certificate)
        out = self.root / "issued"
        config = self.root / "probe-configuration-private.json"
        config.write_text(json.dumps({"expectedTeamID": team, "targetUDID": device,
            "existingCertificatePath": str(cert), "probeBundleIdentifier": PROBE_ID, "outputDirectory": str(out)}))
        config.chmod(0o600)
        require(self.locked() is True, "mac-must-remain-locked")
        started = now()
        self.command("issue-profile", [str(self.executable), "ds", "renewal-probe", "mac-profile" if target == "mac" else "app-profile"],
            seconds=90, environment={"SOFA_RENEWAL_PROBE_CONFIG": str(config)})
        path = out / "probe.mobileprovision"
        profile = self.profile(path)
        validate_profile(profile, team, bundle, device, certificate, old, started)
        require(self.locked() is True, "mac-lock-state-changed")
        self.summary.update(target=target, previousExpiration=utc(old["ExpirationDate"]).isoformat(),
            creation=utc(profile["CreationDate"]).isoformat(), expiration=utc(profile["ExpirationDate"]).isoformat(),
            profileSHA256=hashlib.sha256(path.read_bytes()).hexdigest(), profileIdentityVerified=True)
        return path, profile, certificate

    def resign(self, source, profile_path, profile, certificate, mac=False):
        self.verify_signature(source)
        e = self.entitlements(source)
        require(identifier({"Entitlements": e}) == identifier(profile) and authorized_groups(e, profile), "entitlement-authorization-mismatch")
        destination = self.root / source.name
        shutil.copytree(source, destination, symlinks=True)
        require(not list(destination.rglob("*.appex")), "nested-extensions-require-separate-signing")
        executable_name = "SofaRenewalProbe" if mac else "SofaRemoteiOS"
        executable = Path("Contents/MacOS") / executable_name if mac else Path(executable_name)
        before = instruction_hash(source / executable)
        embedded = "Contents/embedded.provisionprofile" if mac else "embedded.mobileprovision"
        shutil.copyfile(profile_path, destination / embedded)
        entitlements = self.root / "entitlements-private.plist"
        entitlements.write_bytes(plistlib.dumps(e))
        self.command("resign", ["codesign", "--force", "--sign", hashlib.sha1(certificate).hexdigest().upper(),
            "--timestamp=none", "--entitlements", str(entitlements), str(destination)], seconds=45)
        self.verify_signature(destination)
        require(self.entitlements(destination) == e and instruction_hash(destination / executable) == before, "signed-payload-changed")
        prefix = self.root / "candidate-leaf-"
        self.command("candidate-certificate", ["codesign", "-d", f"--extract-certificates={prefix}", str(destination)])
        require(Path(str(prefix) + "0").read_bytes() == certificate, "candidate-certificate-mismatch")
        self.summary.update(signatureVerified=True, entitlementsAndInstructionsPreserved=True,
            candidateSHA256=hashlib.sha256((destination / executable).read_bytes()).hexdigest())
        return destination

    def device(self, label):
        state = {}
        for action, arguments in (("details", ["details"]), ("lockState", ["lockState"]), ("apps", ["apps", "--bundle-id", IOS_ID])):
            path = self.root / f"{label}-{action}-private.json"
            self.command(f"device-{action}", ["xcrun", "devicectl", "--timeout", "35", "--json-output", str(path),
                "device", "info", *arguments, "--device", self.config["deviceIdentifier"]], seconds=45)
            require(path.stat().st_size <= 1024 * 1024, "device-result-too-large")
            result = json.loads(path.read_text())["result"]
            if action == "details":
                state["transport"] = result.get("device", result).get("connectionProperties", {}).get("transportType")
            elif action == "lockState":
                state["locked"] = result.get("passcodeRequired")
            else:
                state["appCount"] = len([a for a in result.get("apps", []) if a.get("bundleIdentifier") == IOS_ID])
        return state

    def install(self, candidate):
        self.verify_signature(candidate)
        before = self.device("before")
        require(before["transport"] == "localNetwork" and before["locked"] is True, "locked-wifi-phone-required")
        require(self.locked() is True, "mac-must-remain-locked")
        self.command("install", ["xcrun", "devicectl", "--timeout", "120", "--json-output", str(self.root / "install-private.json"),
            "device", "install", "app", "--device", self.config["deviceIdentifier"], str(candidate)], seconds=130)
        self.summary["installationCommandSucceeded"] = True
        after = self.device("after")
        require(after["appCount"] == 1 and after["locked"] is True and after["transport"] == "localNetwork", "post-install-state-mismatch")
        require(self.locked() is True, "mac-lock-state-changed")
        self.summary.update(installedAppReadback=True, bothDevicesLocked=True, transport="localNetwork")

    def execute(self, action):
        self.verify_signature(self.probe)
        existing = self.profile(self.probe / "Contents/embedded.provisionprofile")
        probe_id = identifier(existing)
        require(isinstance(probe_id, str) and probe_id.split(".", 1)[-1] == MAC_ID, "unexpected-probe-identity")
        require(utc(existing["ExpirationDate"]) > now(), "mac-probe-expired-bootstrap-required")
        mac = action in ("mac-candidate", "mac-adopt")
        reference = self.probe if mac else Path(self.config["iosApp"])
        profile_path, profile, certificate = self.issue("mac" if mac else "ios", reference)
        candidate = self.resign(reference, profile_path, profile, certificate, mac=mac)
        if action == "ios-install":
            self.install(candidate)
        if action == "mac-adopt":
            # Check saved-session access in the signed candidate before replacing
            # the stable path. No account password or session token is exported.
            environment = {"SOFA_RENEWAL_PROBE_CONFIG": str(self.root / "probe-configuration-private.json")}
            response = self.command("candidate-session-check", [str(candidate / "Contents/MacOS/SofaRenewalProbe"),
                "ds", "renewal-probe", "inspect"], seconds=90, environment=environment)
            authenticated = any(json.loads(line).get("authenticatedToApple") is True
                for line in response.decode().splitlines() if line.startswith("{"))
            require(authenticated and self.locked() is True, "candidate-session-or-lock-check-failed")
            suffix = uuid.uuid4().hex
            staged = self.probe.with_name(f".renewal-{suffix}.app")
            self.summary.update(stagedProbe=str(staged))
            shutil.copytree(candidate, staged, symlinks=True)
            self.verify_signature(staged)
            (self.root / "adoption-prepared.json").write_text(json.dumps({"stableProbe": str(self.probe),
                "exchangePeer": str(staged), "candidateSHA256": self.summary["candidateSHA256"]}) + "\n")
            atomic_exchange(staged, self.probe)
            self.summary.update(macProbeUpdated=True, previousProbeBackup=str(staged))
            candidate = self.probe
        self.summary.update(status="passed", candidatePath=str(candidate), finishedAt=now().isoformat())

    def finish(self):
        (self.root / "receipt.json").write_text(json.dumps(self.summary, indent=2) + "\n")
        print(json.dumps(self.summary))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("ios-candidate", "ios-install", "mac-candidate", "mac-adopt"))
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    try:
        run = Run(read_config(args.config))
    except (RenewalError, OSError, ValueError, TypeError):
        print(json.dumps({"status": "failed", "category": "invalid-private-configuration"}))
        return 1
    try:
        with exclusive_probe(run.probe):
            run.execute(args.action)
    except (RenewalError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        run.summary.update(status="failed", category=str(error) if isinstance(error, RenewalError) else "validation-or-command-failed",
            finishedAt=now().isoformat())
        run.finish()
        return 1
    run.finish()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
