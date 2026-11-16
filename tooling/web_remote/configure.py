#!/usr/bin/env python3
"""Write a disabled, private Web endpoint configuration without handling secrets."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import tempfile


def configuration(arguments):
    hostname = arguments.hostname
    labels = hostname.split(".")
    if (not 2 <= len(hostname) <= 253 or len(labels) < 2
            or labels[-1] in {"local", "localhost"}
            or not re.search("[a-z]", labels[-1])
            or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                   for label in labels)):
        raise ValueError("Use a lowercase DNS hostname covered by the HTTPS certificate.")
    address = ipaddress.IPv4Address(arguments.address)
    if not any(address in ipaddress.IPv4Network(block) for block in (
            "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("The bind address must be a private LAN IPv4 address.")
    if not 1024 <= arguments.port <= 65535:
        raise ValueError("Use an unprivileged port from 1024 through 65535.")
    if arguments.interface and not re.fullmatch(r"[A-Za-z0-9]{1,32}", arguments.interface):
        raise ValueError("Invalid interface name.")
    result = {
        "schemaVersion": 1, "enabled": False,
        "endpoint": {"hostname": hostname, "port": arguments.port, "bindAddress": str(address),
                     "certificateChain": str(arguments.certificate_chain.absolute()),
                     "privateKey": str(arguments.private_key.absolute())},
    }
    if arguments.interface:
        result["interfaceName"] = arguments.interface
    if arguments.zone_id or arguments.record_id:
        if not all(re.fullmatch(r"[a-f0-9]{32}", value or "")
                   for value in (arguments.zone_id, arguments.record_id)):
            raise ValueError("Provide both exact Cloudflare zone and DNS record identifiers.")
        result["dns"] = {"zoneID": arguments.zone_id, "recordID": arguments.record_id,
                         "hostname": hostname}
    return result


def write_configuration(root, value):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = root.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077):
        raise ValueError("The Web setup directory must be owned by you with mode 0700.")
    descriptor, temporary = tempfile.mkstemp(prefix=".setup-", dir=root)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
        # Exclusive publication never replaces existing settings or follows a symlink.
        os.link(temporary, root / "configuration.json", follow_symlinks=False)
    finally:
        os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", type=int, default=47625)
    parser.add_argument("--interface")
    parser.add_argument("--certificate-chain", type=Path, required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--zone-id")
    parser.add_argument("--record-id")
    parser.add_argument("--root", type=Path, default=(
        Path.home() / "Library/Application Support/SofaRemote/Web"))
    arguments = parser.parse_args()
    try:
        write_configuration(arguments.root, configuration(arguments))
    except (OSError, ValueError):
        parser.exit(1, "Web setup was not saved. Check the arguments and private directory; "
                    "existing configuration is never overwritten.\n")
    print("Saved disabled Web setup. Use the Mac menu's Reload setup, then Enable Web remote.")


if __name__ == "__main__":
    main()
