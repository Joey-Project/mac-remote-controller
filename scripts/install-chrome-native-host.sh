#!/bin/sh
set -eu

extension_id='bjplbbniljmmhclleegdfdonjmjlpnid'
host_name='com.joeyteng.sofaremote'
if [ "$#" -ne 1 ]; then
  printf 'Usage: %s /absolute/path/to/SofaRemoteNativeHost\n' "$0" >&2
  exit 2
fi
host_binary=$1
case "$host_binary" in
  /*) ;;
  *) printf 'The native host path must be absolute.\n' >&2; exit 2 ;;
esac
if [ ! -x "$host_binary" ]; then
  printf 'Native host is not executable: %s\n' "$host_binary" >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  printf 'Node.js 26 or newer is required to write the Native Messaging manifest.\n' >&2
  exit 2
fi

# This override is used by isolated tests to avoid touching a Chrome profile.
if [ -n "${SOFA_REMOTE_NATIVE_HOST_DIRECTORY:-}" ]; then
  manifest_directory=$SOFA_REMOTE_NATIVE_HOST_DIRECTORY
else
  manifest_directory="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
fi
manifest_path="${manifest_directory}/${host_name}.json"
mkdir -p "$manifest_directory"
temporary_manifest=$(mktemp "${manifest_path}.tmp.XXXXXX")
trap 'rm -f "$temporary_manifest"' EXIT HUP INT TERM
node -e 'const fs = require("node:fs"); const [manifestPath, hostBinary, hostName, extensionId] = process.argv.slice(1); const manifest = { name: hostName, description: "Sofa Remote local media bridge", path: hostBinary, type: "stdio", allowed_origins: ["chrome-extension://" + extensionId + "/"] }; fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n", { encoding: "utf8" });' "$temporary_manifest" "$host_binary" "$host_name" "$extension_id"
chmod 600 "$temporary_manifest"
mv "$temporary_manifest" "$manifest_path"
printf 'Registered Sofa Remote native messaging host for extension %s.\n' "$extension_id"
