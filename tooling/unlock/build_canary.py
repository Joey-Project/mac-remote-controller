"""Build and test an inert Authorization Services canary without installation."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys


def run(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    if result.returncode:
        sys.stderr.write(result.stdout.decode(errors="replace")[-16000:])
        raise SystemExit(f"Build/check failed ({result.returncode}).")
    return result.stdout.decode(errors="replace").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("The native canary requires the macOS SDK.")
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve().parents[2] / "apps/macos/UnlockCanary"
    compiler = run(["xcrun", "--find", "clang"])
    sdk = run(["xcrun", "--show-sdk-path"])
    flags = [compiler, "-isysroot", sdk, "-mmacosx-version-min=14.0", "-fobjc-arc",
        "-Wall", "-Wextra", "-Werror", "-Wpedantic", "-ferror-limit=8",
        "-framework", "Foundation", "-framework", "IOKit", "-framework", "Security"]
    common = str(source / "CanaryGrant.m")
    bundle = output / "SofaRemoteUnlockCanary.bundle"
    contents = bundle / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    info = {"CFBundleIdentifier": "com.joeyteng.sofaremote.unlock.canary-plugin",
        "CFBundleExecutable": "SofaRemoteUnlockCanary", "CFBundleName": "Sofa Remote Authorization Canary",
        "CFBundlePackageType": "BNDL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0"}
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    executable = contents / "MacOS/SofaRemoteUnlockCanary"
    run([*flags, "-bundle", common, str(source / "AuthorizationPlugin.m"), "-o", str(executable)])
    probe = output / "sofa-unlock-canary"
    run([*flags, common, str(source / "CanaryProbe.m"), "-o", str(probe)])
    tests = output / "canary-tests"
    run([*flags, common, str(source / "AuthorizationPlugin.m"), str(source / "CanaryTests.m"), "-o", str(tests)])
    for path, identifier in ((bundle, info["CFBundleIdentifier"]),
        (probe, "com.joeyteng.sofaremote.unlock.canary-probe")):
        run(["codesign", "--sign", "-", "--timestamp=none", "--identifier", identifier, str(path)])
        run(["codesign", "--verify", "--strict", str(path)])
    summary = run([str(tests), str(output / "test-fixtures")])
    receipt = {"status": "passed", "checks": summary, "compiler": run([compiler, "--version"]).splitlines()[0],
        "artifacts": {str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (executable, probe)}, "installed": False}
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
