#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
node_major="$(node -p 'process.versions.node.split(".")[0]')"
if ((node_major < 26)); then
    printf 'Bundling the Web remote requires Node.js 26 or newer.\n' >&2
    exit 1
fi
node "$repo_root/apps/web-remote/scripts/build.mjs"
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/WebRemote"
mkdir -p "$resources"
cp "$repo_root/apps/web-remote/dist/live/index.html" \
    "$repo_root/apps/web-remote/dist/live/app.js" \
    "$repo_root/apps/web-remote/dist/live/app.css" "$resources/"
