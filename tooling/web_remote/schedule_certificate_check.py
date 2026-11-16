#!/usr/bin/env python3
"""Install one user LaunchAgent for an already configured Web certificate."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

from certificate_maintenance import require_private

LABEL = "com.joeyteng.sofaremote.web-certificate"


def job(root):
    return {
        "Label": LABEL,
        "ProgramArguments": [str(root / "Runtime/bin/python"),
                             str(root / "certificate_maintenance.py"), "--root", str(root)],
        "RunAtLoad": True, "StartInterval": 86400, "ProcessType": "Standard",
        "LowPriorityIO": True, "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
    }


def install(root):
    require_private(root, directory=True)
    require_private(root / "cloudflare-credentials.ini")
    for path in [root / "Runtime/bin/python", root / "Runtime/bin/certbot",
                 root / "acme-production/live/sofaremote-lan/cert.pem",
                 root / "acme-client.ini"]:
        if not path.is_file():
            raise ValueError("Complete certificate setup before scheduling checks.")
    agents = Path.home() / "Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    destination = agents / f"{LABEL}.plist"
    if destination.exists() or destination.is_symlink():
        raise FileExistsError("The certificate job already exists; it was not changed.")
    shutil.copyfile(Path(__file__).with_name("certificate_maintenance.py"),
                    root / "certificate_maintenance.py")
    (root / "certificate_maintenance.py").chmod(0o600)
    with destination.open("xb") as output:
        plistlib.dump(job(root), output)
    destination.chmod(0o600)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(destination)],
                   check=True, timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=(
        Path.home() / "Library/Application Support/SofaRemote/Web"))
    args = parser.parse_args()
    os.umask(0o077)
    try:
        install(args.root.absolute())
    except (OSError, ValueError, subprocess.SubprocessError):
        parser.exit(1, "Certificate check was not started. Existing jobs were not replaced; "
                    "check private setup paths and the user LaunchAgent.\n")
    print("Installed the daily Web certificate check. Phone renewal is unchanged.")


if __name__ == "__main__":
    main()
