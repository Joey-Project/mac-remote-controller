#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
version="0.65.1"
checksum="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
tool_dir="$repo_root/.codex-tmp/apple-tools/swiftlint-$version"
archive="$tool_dir/portable_swiftlint.zip"
binary="$tool_dir/swiftlint"
url="https://github.com/realm/SwiftLint/releases/download/$version/portable_swiftlint.zip"

for dependency in curl shasum unzip; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$dependency" >&2
        exit 1
    fi
done

mkdir -p "$tool_dir"

if [[ ! -f "$archive" ]]; then
    temporary_archive="$(mktemp "$tool_dir/portable_swiftlint.XXXXXX")"
    trap 'rm -f "$temporary_archive"' EXIT
    curl --fail --location --silent --show-error \
        --max-time 180 \
        --max-filesize 20971520 \
        --output "$temporary_archive" \
        "$url"
    if ! printf '%s  %s\n' "$checksum" "$temporary_archive" | shasum -a 256 --check >/dev/null 2>&1; then
        printf 'SwiftLint %s download failed SHA-256 verification.\n' "$version" >&2
        exit 1
    fi
    mv "$temporary_archive" "$archive"
    trap - EXIT
fi

if ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check >/dev/null 2>&1; then
    printf 'Cached SwiftLint %s archive failed SHA-256 verification: %s\n' "$version" "$archive" >&2
    exit 1
fi

unzip -oq "$archive" -d "$tool_dir"
if [[ ! -x "$binary" ]]; then
    chmod +x "$binary"
fi

actual_version="$("$binary" --version)"
if [[ "$actual_version" != "$version" ]]; then
    printf 'Expected SwiftLint %s, found %s in %s\n' "$version" "$actual_version" "$binary" >&2
    exit 1
fi

printf '%s\n' "$binary"
