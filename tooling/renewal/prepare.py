"""Reconstruct the pinned MIT-licensed xtool research probe. No account access."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request

HERE = Path(__file__).resolve().parent
MAX_ARCHIVE = 32 * 1024 * 1024
MAX_SOURCE = 96 * 1024 * 1024


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract(archive_path, destination, commit):
    total = 0
    seen = set()
    with tarfile.open(archive_path) as archive:
        for index, item in enumerate(archive):
            parts = PurePosixPath(item.name).parts
            if index >= 6000 or not parts or parts[0] != f"xtool-{commit}" or ".." in parts:
                raise ValueError("Unexpected source archive member")
            relative = PurePosixPath(*parts[1:])
            if str(relative) in seen:
                raise ValueError("Duplicate archive member")
            seen.add(str(relative))
            path = destination.joinpath(*parts[1:])
            if item.isdir():
                path.mkdir(parents=True, exist_ok=True, mode=0o700)
            elif item.isfile():
                total += item.size
                if item.size > MAX_ARCHIVE or total > MAX_SOURCE:
                    raise ValueError("Source archive is too large")
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with archive.extractfile(item) as source, path.open("xb") as output:
                    shutil.copyfileobj(source, output, length=65536)
                path.chmod(0o700 if item.mode & 0o111 else 0o600)
            elif item.issym() and str(relative) == "macOS/XToolMac.xcodeproj/project.xcworkspace/xcshareddata/Package.resolved":
                # This documentation-project symlink is unnecessary for SwiftPM.
                continue
            else:
                raise ValueError("Unsupported source archive member")


def prepare(destination, archive_path=None):
    if destination.exists():
        raise ValueError("Choose a new destination; existing builds are preserved")
    manifest = json.loads((HERE / "upstream.json").read_text())
    if digest(HERE / "xtool.patch") != manifest["patchSHA256"] or digest(HERE / "Package.resolved") != manifest["resolvedSHA256"]:
        raise ValueError("Probe source inputs do not match their manifest")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sofa-renewal-", dir=destination.parent) as tmp:
        staging = Path(tmp)
        if archive_path is None:
            archive_path = staging / "source.tar.gz"
            deadline = time.monotonic() + 60
            count = 0
            with urllib.request.urlopen(manifest["archiveURL"], timeout=20) as response, archive_path.open("xb") as output:
                while chunk := response.read(65536):
                    count += len(chunk)
                    if count > MAX_ARCHIVE or time.monotonic() > deadline:
                        raise ValueError("Source download exceeds its budget")
                    output.write(chunk)
        if archive_path.stat().st_size > MAX_ARCHIVE or digest(archive_path) != manifest["archiveSHA256"]:
            raise ValueError("Source archive digest mismatch")
        source = staging / "source"
        source.mkdir(mode=0o700)
        extract(archive_path, source, manifest["commit"])
        for check in (True, False):
            command = ["git", "apply", "--unidiff-zero"]
            if check:
                command.append("--check")
            command.append(str(HERE / "xtool.patch"))
            subprocess.run(command, cwd=source, check=True, timeout=20, capture_output=True,
                env={"PATH": os.environ["PATH"], "GIT_CEILING_DIRECTORIES": str(staging)})
        shutil.copyfile(HERE / "Package.resolved", source / "Package.resolved")
        source.rename(destination)
    return {"upstreamCommit": manifest["commit"], "source": str(destination), "accountAccessed": False}


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=HERE / ".local/source")
    parser.add_argument("--archive", type=Path, help="Optional already-downloaded pinned archive")
    args = parser.parse_args()
    print(json.dumps(prepare(args.destination.resolve(), args.archive.resolve() if args.archive else None)))
