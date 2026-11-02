"""Embed the SwiftPM runtime into a normally provisioned Mac probe copy."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil

from renew import CommandLog, MAC_ID, RenewalError, now, require, utc


def package(app, build, destination):
    require(not destination.exists(), "destination-already-exists")
    destination.mkdir(parents=True, mode=0o700)
    log = CommandLog(destination)
    profile = plistlib.loads(log.command("decode", ["security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile")]))
    require(utc(profile["ExpirationDate"]) > now(), "bootstrap-profile-expired")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == MAC_ID, "unexpected-bootstrap-app")
    prefix = destination / "certificate-"
    log.command("certificate", ["codesign", "-d", f"--extract-certificates={prefix}", str(app)])
    certificate = Path(str(prefix) + "0").read_bytes()
    require(certificate in profile["DeveloperCertificates"], "bootstrap-certificate-mismatch")
    identity = hashlib.sha1(certificate).hexdigest().upper()
    target = destination / "SofaRenewalProbe.app"
    shutil.copytree(app, target, symlinks=True)
    executable = target / "Contents/MacOS/SofaRenewalProbe"
    frameworks = target / "Contents/Frameworks"
    frameworks.mkdir(mode=0o700)
    resources = target / "Contents/Resources"
    resources.mkdir(mode=0o700, exist_ok=True)
    names = []
    for source in sorted((build / "debug").glob("*.framework")):
        shutil.copytree(source, frameworks / source.name, symlinks=True)
        names.append(source.name)
    require(names == ["OpenSSL.framework", "libimobiledevice.framework", "libimobiledeviceGlue.framework", "plist.framework", "usbmuxd.framework"],
        "unexpected-swiftpm-framework-set")
    for source in (build / "debug").glob("*.bundle"):
        shutil.copytree(source, resources / source.name, symlinks=True)
    log.command("rpath", ["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)])
    log.command("swift-runtime", ["xcrun", "swift-stdlib-tool", "--copy", "--scan-executable", str(executable),
        "--scan-folder", str(frameworks), "--destination", str(frameworks), "--platform", "macosx", "--sign", identity], seconds=60)
    for name in names:
        log.command("sign-framework", ["codesign", "--force", "--sign", identity, "--timestamp=none", str(frameworks / name)])
    entitlements = log.command("entitlements", ["codesign", "-d", "--entitlements", ":-", str(app)])
    path = destination / "entitlements-private.plist"
    path.write_bytes(entitlements)
    log.command("sign-probe", ["codesign", "--force", "--sign", identity, "--timestamp=none", "--entitlements", str(path), str(target)])
    log.command("verify", ["codesign", "--verify", "--deep", "--strict", str(target)])
    log.command("keychain-canary", [str(executable), "ds", "renewal-probe", "storage"])
    receipt = {"probeApp": str(target), "expiration": utc(profile["ExpirationDate"]).isoformat(),
        "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(), "signatureVerified": True,
        "accountLoginPerformed": False}
    (destination / "package-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = package(args.app.resolve(), args.build_dir.resolve(), args.destination.resolve())
    except (RenewalError, OSError, ValueError, KeyError):
        raise SystemExit("Probe packaging failed; owner-private diagnostics remain at the destination.")
    print(json.dumps(result))
