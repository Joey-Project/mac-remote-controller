"""Explicit administrator installation for an isolated authorization canary."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import resource
import stat
import subprocess
import sys
import tempfile

RIGHT = "com.joeyteng.sofaremote.unlock.canary"
STATE = Path("/private/var/db/com.joeyteng.sofaremote.unlock-canary")
PLUGIN = Path("/Library/Security/SecurityAgentPlugins/SofaRemoteUnlockCanary.bundle")
PROBE = Path("/Library/PrivilegedHelperTools/com.joeyteng.sofaremote.unlock-canary")
PLUGIN_FILES = ("Contents/Info.plist", "Contents/MacOS/SofaRemoteUnlockCanary", "Contents/_CodeSignature/CodeResources")
DEFINITION = {"class": "evaluate-mechanisms", "mechanisms": ["SofaRemoteUnlockCanary:canary,privileged"],
    "shared": False, "tries": 1, "timeout": 0}
METADATA = {"created", "modified", "version"}


class Refused(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def read_regular(path, maximum=8 * 1024 * 1024, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= maximum,
            "unexpected-artifact-type-or-size")
        require(not before.st_mode & 0o022, "artifact-is-writable-by-other-users")
        if private:
            require(before.st_uid == 0 and stat.S_IMODE(before.st_mode) == 0o600, "unsafe-private-receipt")
        body = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        require((before.st_dev, before.st_ino, before.st_uid, before.st_gid, before.st_mode, before.st_size)
            == (after.st_dev, after.st_ino, after.st_uid, after.st_gid, after.st_mode, after.st_size)
            and len(body) == before.st_size, "artifact-changed-during-read")
        return body


def snapshot(plugin, probe):
    return {**{name: read_regular(plugin / name) for name in PLUGIN_FILES}, "probe": read_regular(probe)}


def fingerprint(files):
    digest = hashlib.sha256()
    for name, body in sorted(files.items()):
        digest.update(name.encode() + b"\0" + len(body).to_bytes(8, "big") + body)
    return digest.hexdigest()


def limit_output():
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024, 512 * 1024))


def native(tool, arguments, body=None):
    require(tool in ("security", "codesign"), "unsupported-system-tool")
    if tool == "security" and arguments[1] != "read":
        require(arguments[:2] in (["authorizationdb", "write"], ["authorizationdb", "remove"])
            and arguments[2:] == [RIGHT], "only-the-dedicated-canary-right-may-change")
    binary = Path("/usr/bin") / tool
    info = binary.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
        "untrusted-system-tool")
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        result = subprocess.run([str(binary), *arguments], input=body, stdout=output, stderr=errors,
            timeout=15, preexec_fn=limit_output, env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"})
        output.seek(0)
        errors.seek(0)
        return result.returncode, output.read(512 * 1024), errors.read(512 * 1024)


def right_definition(name):
    require(name in (RIGHT, "system.login.screensaver"), "unsupported-right")
    code, output, error = native("security", ["authorizationdb", "read", name])
    if code and not output and error.strip() == b"NO (-60005)":
        return None
    require(code == 0 and 0 < len(output) <= 65536, "authorization-read-unavailable")
    result = plistlib.loads(output)
    require(isinstance(result, dict), "unexpected-authorization-definition")
    return result


def own_definition(value):
    return isinstance(value, dict) and {key: item for key, item in value.items() if key not in METADATA} == DEFINITION


def verify_signature(path):
    code, _, _ = native("codesign", ["--verify", "--strict", str(path)])
    require(code == 0, "signature-verification-failed")


def private_receipt(value):
    path = STATE / "receipt.json"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def publish(source, destination):
    # Darwin RENAME_EXCL is atomic and refuses an existing destination.
    function = ctypes.CDLL(None, use_errno=True).renamex_np
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    require(function(os.fsencode(source), os.fsencode(destination), 4) == 0, "exclusive-publication-failed")


def parent_is_protected(path):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
        "unsafe-installation-parent")


def remove_known_plugin(path):
    for name in PLUGIN_FILES:
        (path / name).unlink()
    for name in ("Contents/MacOS", "Contents/_CodeSignature", "Contents"):
        (path / name).rmdir()
    path.rmdir()


def install(build, expected):
    require(re.fullmatch(r"[a-f0-9]{64}", expected) is not None, "a-reviewed-build-fingerprint-is-required")
    files = snapshot(build / PLUGIN.name, build / "sofa-unlock-canary")
    require(fingerprint(files) == expected, "build-fingerprint-mismatch")
    info = plistlib.loads(files["Contents/Info.plist"])
    require(info.get("CFBundleIdentifier") == "com.joeyteng.sofaremote.unlock.canary-plugin"
        and info.get("CFBundleExecutable") == "SofaRemoteUnlockCanary", "unexpected-canary-identity")
    for parent in (PLUGIN.parent, PROBE.parent, STATE.parent):
        parent_is_protected(parent)
    require(not any(path.exists() or path.is_symlink() for path in (PLUGIN, PROBE, STATE)),
        "existing-installation-is-never-overwritten")
    require(right_definition(RIGHT) is None, "existing-canary-right-is-never-overwritten")
    baseline = right_definition("system.login.screensaver")
    require(baseline is not None, "system-policy-unavailable")
    STATE.mkdir(mode=0o700)
    # Retain intent even when staging or signature admission fails before publication.
    private_receipt({"version": 1, "phase": "prepared", "fingerprint": expected})
    staged_plugin, staged_probe = STATE / "staged-plugin.bundle", STATE / "staged-probe"
    for name in PLUGIN_FILES:
        target = staged_plugin / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(files[name])
        target.chmod(0o755 if name.endswith("SofaRemoteUnlockCanary") else 0o644)
    for path in (staged_plugin, staged_plugin / "Contents", staged_plugin / "Contents/MacOS",
        staged_plugin / "Contents/_CodeSignature"):
        path.chmod(0o755)
    staged_probe.write_bytes(files["probe"])
    staged_probe.chmod(0o755)
    verify_signature(staged_plugin)
    verify_signature(staged_probe)
    require(fingerprint(snapshot(staged_plugin, staged_probe)) == expected, "staged-artifact-mismatch")
    # A durable intent survives interruption. No recovery may overwrite a foreign right.
    published_plugin = published_probe = requested_right = False
    try:
        publish(staged_plugin, PLUGIN)
        published_plugin = True
        publish(staged_probe, PROBE)
        published_probe = True
        requested_right = True
        code, _, _ = native("security", ["authorizationdb", "write", RIGHT], plistlib.dumps(DEFINITION))
        current = right_definition(RIGHT)
        require(code == 0 and own_definition(current), "canary-right-registration-failed")
        require(right_definition("system.login.screensaver") == baseline, "system-policy-changed-during-installation")
        (STATE / "definition.plist").write_bytes(plistlib.dumps(current, sort_keys=True))
        (STATE / "definition.plist").chmod(0o600)
        with (STATE / "complete").open("x") as completion:
            completion.write(expected + "\n")
        (STATE / "complete").chmod(0o600)
    except Exception:
        # Preserve the intent on any incomplete recovery; never reset the system rule.
        if requested_right:
            current = right_definition(RIGHT)
            if current is not None:
                require(own_definition(current), "registration-conflict-requires-manual-recovery")
                native("security", ["authorizationdb", "remove", RIGHT])
                require(right_definition(RIGHT) is None, "canary-right-removal-unconfirmed")
        if published_probe:
            require(read_regular(PROBE) == files["probe"], "probe-replacement-conflict")
            PROBE.unlink()
        if published_plugin:
            current_files = {name: read_regular(PLUGIN / name) for name in PLUGIN_FILES}
            require(fingerprint({**current_files, "probe": files["probe"]}) == expected, "plugin-replacement-conflict")
            remove_known_plugin(PLUGIN)
        raise


def uninstall():
    parent_is_protected(STATE)
    require(stat.S_IMODE(STATE.stat().st_mode) == 0o700, "unsafe-state-directory")
    require({path.name for path in STATE.iterdir()}.issubset({"receipt.json", "definition.plist", "complete", "grant"}),
        "unknown-state-object-requires-manual-recovery")
    receipt = json.loads(read_regular(STATE / "receipt.json", 16384, private=True))
    expected = receipt.get("fingerprint")
    require(receipt.get("version") == 1 and isinstance(expected, str), "unrecognized-installation-receipt")
    require(read_regular(STATE / "complete", 128, private=True).decode().strip() == expected,
        "incomplete-installation-needs-manual-recovery")
    require(fingerprint(snapshot(PLUGIN, PROBE)) == expected, "installed-artifacts-have-changed")
    recorded = plistlib.loads(read_regular(STATE / "definition.plist", 65536, private=True))
    require(own_definition(recorded) and right_definition(RIGHT) == recorded, "authorization-definition-conflict")
    baseline = right_definition("system.login.screensaver")
    grant = STATE / "grant"
    if grant.exists() or grant.is_symlink():
        require(len(read_regular(grant, 128, private=True)) == 128, "unexpected-grant-object")
        grant.unlink()
    code, _, _ = native("security", ["authorizationdb", "remove", RIGHT])
    require(code == 0 and right_definition(RIGHT) is None, "canary-right-removal-unconfirmed")
    remove_known_plugin(PLUGIN)
    PROBE.unlink()
    require(right_definition("system.login.screensaver") == baseline, "system-policy-changed-during-removal")
    for name in ("definition.plist", "complete", "receipt.json"):
        (STATE / name).unlink()
    STATE.rmdir()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("plan", "install", "uninstall"))
    parser.add_argument("--build", type=Path)
    parser.add_argument("--expected-build-sha256")
    args = parser.parse_args()
    try:
        require(sys.platform == "darwin", "macos-required")
        if args.operation == "plan":
            require(args.build is not None, "build-directory-required")
            files = snapshot(args.build / PLUGIN.name, args.build / "sofa-unlock-canary")
            print(json.dumps({"status": "planned", "buildSHA256": fingerprint(files), "plugin": str(PLUGIN),
                "probe": str(PROBE), "state": str(STATE), "authorizationRight": RIGHT,
                "systemScreenLockPolicyChanges": False}))
            return 0
        require(os.geteuid() == 0, "administrator-authorization-required")
        if args.operation == "install":
            require(args.build is not None and args.expected_build_sha256 is not None, "reviewed-build-required")
            install(args.build, args.expected_build_sha256)
        else:
            uninstall()
        print(json.dumps({"status": "passed", "operation": args.operation, "authorizationRight": RIGHT}))
        return 0
    except Refused as error:
        print(json.dumps({"status": "failed", "category": str(error)}))
        return 1
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        print(json.dumps({"status": "failed", "category": "canary-operation-refused"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
