#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
build_root="$repo_root/.codex-tmp/apple-tools/integration-host"
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
helpers="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
plugin="$resources/UnlockRuntime/SofaRemoteUnlock.bundle"
mkdir -p "$helpers" "$plugin/Contents/MacOS" "$resources/PhoneRecovery"
cp "$repo_root/apps/macos/UnlockRuntime/Info.plist" "$plugin/Contents/Info.plist"
cp "$repo_root/tooling/renewal/renew.py" "$resources/PhoneRecovery/renew.py"
read -r -a architectures <<< "${ARCHS:-$(uname -m)}"
helper_slices=()
installer_slices=()
plugin_slices=()
for architecture in "${architectures[@]}"; do
    case "$architecture" in
        arm64|x86_64) ;;
        *) printf 'Unsupported unlock architecture: %s\n' "$architecture" >&2; exit 1 ;;
    esac
    triple="$architecture-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    arguments=(--configuration release --package-path "$repo_root/packages/apple-core"
        --scratch-path "$build_root/$architecture" --triple "$triple")
    swift build --quiet "${arguments[@]}" --product SofaRemoteUnlockHelper
    swift build --quiet "${arguments[@]}" --product SofaRemoteUnlockInstaller
    binaries="$(swift build "${arguments[@]}" --show-bin-path)"
    helper_slices+=("$binaries/SofaRemoteUnlockHelper")
    installer_slices+=("$binaries/SofaRemoteUnlockInstaller")
    slice="$build_root/$architecture/unlock-plugin.bundle-executable"
    xcrun clang -target "$triple" -isysroot "$(xcrun --show-sdk-path)" -fobjc-arc \
        -Wall -Wextra -Werror -Wpedantic -bundle \
        -I "$repo_root/packages/apple-core/Sources/UnlockNative/include" \
        "$repo_root/packages/apple-core/Sources/UnlockNative/UnlockGrant.m" \
        "$repo_root/apps/macos/UnlockRuntime/AuthorizationPlugin.m" \
        -framework Foundation -framework IOKit -framework Security -o "$slice"
    plugin_slices+=("$slice")
done
lipo -create "${helper_slices[@]}" -output "$helpers/SofaRemoteUnlockHelper"
lipo -create "${installer_slices[@]}" -output "$helpers/SofaRemoteUnlockInstaller"
lipo -create "${plugin_slices[@]}" -output "$plugin/Contents/MacOS/SofaRemoteUnlock"
chmod 755 "$helpers/SofaRemoteUnlockHelper" "$helpers/SofaRemoteUnlockInstaller"
# Ad-hoc designated requirements bind nested images to their exact slices,
# including when the outer companion uses a certificate-based identity.
codesign --force --sign - --timestamp=none \
    --identifier com.joeyteng.sofaremote.unlock.helper "$helpers/SofaRemoteUnlockHelper"
codesign --force --sign - --timestamp=none \
    --identifier com.joeyteng.sofaremote.unlock.installer "$helpers/SofaRemoteUnlockInstaller"
codesign --force --sign - --timestamp=none "$plugin"
codesign --verify --strict "$plugin"
codesign --verify --strict "$helpers/SofaRemoteUnlockHelper"
codesign --verify --strict "$helpers/SofaRemoteUnlockInstaller"
