#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
node_major="$(node -p 'process.versions.node.split(".")[0]')"
if ((node_major < 26)); then
    printf 'Bundling media integrations requires Node.js 26 or newer.\n' >&2
    exit 1
fi

# The pinned workspace dependencies are installed before the Xcode build.
node "$repo_root/apps/chrome-extension/scripts/build.mjs"
node "$repo_root/apps/iina-plugin/scripts/build.mjs"
helper_build="$repo_root/.codex-tmp/apple-tools/integration-host"
swift build --quiet --configuration release \
    --package-path "$repo_root/packages/apple-core" \
    --scratch-path "$helper_build" --product SofaRemoteNativeHost

resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/MediaAdapters"
helpers="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
mkdir -p "$resources/ChromeExtension" "$resources/SofaRemote.iinaplugin" "$helpers"
cp "$repo_root/apps/chrome-extension/dist/manifest.json" \
    "$repo_root/apps/chrome-extension/dist/content-script.js" \
    "$repo_root/apps/chrome-extension/dist/service-worker.js" "$resources/ChromeExtension/"
cp "$repo_root/apps/iina-plugin/dist/SofaRemote.iinaplugin/Info.json" \
    "$repo_root/apps/iina-plugin/dist/SofaRemote.iinaplugin/main.js" \
    "$repo_root/apps/iina-plugin/dist/SofaRemote.iinaplugin/preferences.html" \
    "$resources/SofaRemote.iinaplugin/"
install -m 755 "$helper_build/release/SofaRemoteNativeHost" "$helpers/SofaRemoteNativeHost"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none \
    "$helpers/SofaRemoteNativeHost"
