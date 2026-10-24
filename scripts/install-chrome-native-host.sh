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

manifest_directory="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
manifest_path="${manifest_directory}/${host_name}.json"
mkdir -p "$manifest_directory"
temporary_manifest="${manifest_path}.tmp.$$"
trap 'rm -f "$temporary_manifest"' EXIT HUP INT TERM
cat > "$temporary_manifest" <<EOF
{
  "name": "${host_name}",
  "description": "Sofa Remote local media bridge",
  "path": "${host_binary}",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://${extension_id}/"]
}
EOF
chmod 600 "$temporary_manifest"
mv "$temporary_manifest" "$manifest_path"
printf 'Registered Sofa Remote native messaging host for extension %s.\n' "$extension_id"
