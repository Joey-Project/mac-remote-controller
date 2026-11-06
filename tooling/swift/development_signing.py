"""Pin and verify certificate-signed Mac development builds; never install them."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "apps/macos/DevelopmentSigning.local.xcconfig"
BUILD = ROOT / ".codex-tmp/development-macos"
IDENTIFIER = "com.joeyteng.sofaremote.mac"
KEYS = {"CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM"}
FORBIDDEN_ENTITLEMENTS = (
    "com.apple.security.get-task-allow", "get-task-allow",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def output(arguments, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, check=True, timeout=45)
    require(len(result.stdout) + len(result.stderr) <= 1024 * 1024, "Tool output exceeded limit")
    return result


def parse_config(text):
    require(len(text) <= 4096, "Signing configuration is too large")
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        key, separator, value = line.partition("=")
        key, value = key.strip(), value.strip()
        require(separator and key in KEYS and key not in values, "Unexpected signing setting")
        values[key] = value
    require(set(values) == KEYS and values["CODE_SIGN_STYLE"] == "Manual", "Manual pinned signing is required")
    require(re.fullmatch(r"[A-F0-9]{40}", values["CODE_SIGN_IDENTITY"]), "An exact certificate SHA-1 is required")
    require(re.fullmatch(r"[A-Z0-9]{10}", values["DEVELOPMENT_TEAM"]), "An exact development Team is required")
    return values


def identities(text):
    return dict(re.findall(r'^\s*\d+\) ([A-F0-9]{40}) "(Apple Development: [^"\r\n]+)"\s*$', text, re.MULTILINE))


def available():
    return identities(output(["security", "find-identity", "-v", "-p", "codesigning"]).stdout.decode())


def read_config():
    require(CONFIG.is_file(), "Run configure first; unsigned and ad-hoc fallback are disabled")
    values = parse_config(CONFIG.read_text())
    require(values["CODE_SIGN_IDENTITY"] in available(), "Pinned Apple Development identity is unavailable; do not rotate it silently")
    return values


def configure(selected=None):
    candidates = available()
    if selected is None:
        require(len(candidates) == 1, "Select one Apple Development certificate with --identity SHA1")
        selected = next(iter(candidates))
    require(selected in candidates, "Selected Apple Development identity is unavailable")
    pem = output(["security", "find-certificate", "-a", "-p", "-c", candidates[selected]]).stdout
    certificates = [base64.b64decode(match) for match in re.findall(
        rb"-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)-----END CERTIFICATE-----", pem)]
    matching = [item for item in certificates if hashlib.sha1(item).hexdigest().upper() == selected]
    require(bool(matching), "Selected public certificate was not found")
    subject = output(["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "RFC2253"], matching[0]).stdout.decode()
    teams = re.findall(r"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)", subject)
    require(len(teams) == 1, "Certificate does not identify one development Team")
    text = ("// Generated locally; no private key or account credentials are stored here.\n"
            f"CODE_SIGN_STYLE = Manual\nCODE_SIGN_IDENTITY = {selected}\nDEVELOPMENT_TEAM = {teams[0]}\n")
    values = parse_config(text)
    if CONFIG.exists():
        require(parse_config(CONFIG.read_text()) == values, "Existing certificate pin differs; rotate it explicitly in the local configuration")
    else:
        # Exclusive creation preserves an existing pin, including concurrent setup.
        with CONFIG.open("x") as target:
            target.write(text)
    return {"configuration": str(CONFIG), "certificateSHA1": selected, "team": teams[0]}


def verify(app, values):
    app = Path(app)
    output(["codesign", "--verify", "--deep", "--strict", str(app)])
    requirement = (f'anchor apple generic and identifier "{IDENTIFIER}" '
                   f'and certificate leaf = H"{values["CODE_SIGN_IDENTITY"]}"')
    # The '=' prefix supplies an inline requirement rather than a filename.
    output(["codesign", "--verify", "--strict", "--test-requirement", "=" + requirement, str(app)])
    details = output(["codesign", "-d", "--verbose=4", "-r-", str(app)])
    text = (details.stdout + details.stderr).decode()
    require(f'TeamIdentifier={values["DEVELOPMENT_TEAM"]}\n' in text, "Unexpected signature Team")
    flags = re.search(r"\bflags=0x([0-9a-fA-F]+)", text)
    require(flags and int(flags[1], 16) & 0x10000, "Hardened Runtime is required")
    designated = re.findall(r"^(?:# )?designated => (.+)$", text, re.MULTILINE)
    require(len(designated) == 1 and "cdhash" not in designated[0], "Development identity must survive code changes")
    entitlements = output(["codesign", "-d", "--entitlements", ":-", str(app)]).stdout
    values_in_signature = plistlib.loads(entitlements) if entitlements.strip() else {}
    require(isinstance(values_in_signature, dict), "Invalid entitlements")
    require(all(key not in values_in_signature or values_in_signature[key] is False
                for key in FORBIDDEN_ENTITLEMENTS), "Debug or injection entitlements are not allowed")
    hashes = re.findall(r"^CDHash=([0-9a-f]+)$", text, re.MULTILINE)
    require(len(hashes) == 1, "Main code hash was not found")
    return {"app": str(app), "certificateSHA1": values["CODE_SIGN_IDENTITY"],
            "team": values["DEVELOPMENT_TEAM"], "designatedRequirement": designated[0],
            "cdhash": hashes[0], "strictSignatureVerified": True}


def build(configuration):
    values = read_config()
    subprocess.run([
        "xcodebuild", "-quiet", "-project", str(ROOT / "apps/macos/SofaRemoteMac.xcodeproj"),
        "-scheme", "SofaRemoteMac", "-configuration", configuration,
        "-destination", "generic/platform=macOS", "-derivedDataPath", str(BUILD / "DerivedData"),
        "-clonedSourcePackagesDirPath", str(ROOT / ".codex-tmp/apple-tools/SourcePackages"),
        "build", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
        "ENABLE_HARDENED_RUNTIME=YES", *(f"{key}={value}" for key, value in values.items()),
    ], check=True, timeout=1800)
    return verify(BUILD / f"DerivedData/Build/Products/{configuration}/SofaRemoteMac.app", values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("configure", help="Pin the existing Apple Development certificate locally")
    setup.add_argument("--identity", help="Exact uppercase certificate SHA-1; required if selection is ambiguous")
    compile_app = commands.add_parser("build", help="Build in a separate development directory and verify the pin")
    compile_app.add_argument("--configuration", choices=("Debug", "Release"), default="Debug")
    inspect = commands.add_parser("verify", help="Verify an app before or after a fixed-path installation")
    inspect.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "configure":
            result = configure(args.identity)
        elif args.command == "build":
            result = build(args.configuration)
        else:
            result = verify(args.app, read_config())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Development signing failed: {error}\n")
    print(json.dumps(result))


if __name__ == "__main__":
    os.umask(0o077)
    main()
