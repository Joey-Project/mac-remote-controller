"""Build native runtime grant tests without installation or system mutation."""
import argparse
from pathlib import Path
import subprocess

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    native = root / "packages/apple-core/Sources/UnlockNative"
    runtime = root / "apps/macos/UnlockRuntime"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True, timeout=10).strip()
    binary = args.output.absolute() / "runtime-tests"
    subprocess.run(["xcrun", "clang", "-isysroot", sdk, "-mmacosx-version-min=14.0", "-fobjc-arc",
        "-Wall", "-Wextra", "-Werror", "-Wpedantic", "-I", str(native / "include"),
        str(native / "UnlockGrant.m"), str(runtime / "RuntimeTests.m"), "-framework", "Foundation",
        "-framework", "IOKit", "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary), str(args.output.absolute() / "fixtures")], check=True, timeout=20)


if __name__ == "__main__":
    main()
