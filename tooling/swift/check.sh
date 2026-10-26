#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
tool_root="$repo_root/.codex-tmp/apple-tools"
swiftlint_version="0.65.1"

if ! command -v swift >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null 2>&1; then
    printf 'This check requires Xcode command line tools with swift and xcodebuild.\n' >&2
    exit 1
fi

mkdir -p "$tool_root"
mkdir -p "$tool_root/SourcePackages"
xcodebuild -version
printf 'Swift compiler: '
swift --version | sed -n '1p'
printf 'Swift formatter: '
swift format --version

swiftlint_bin=""
if installed_swiftlint="$(command -v swiftlint 2>/dev/null)"; then
    if [[ "$("$installed_swiftlint" --version)" == "$swiftlint_version" ]]; then
        swiftlint_bin="$installed_swiftlint"
    fi
fi

if [[ -z "$swiftlint_bin" ]]; then
    printf 'Preparing pinned SwiftLint %s in .codex-tmp/apple-tools.\n' "$swiftlint_version"
    swiftlint_bin="$("$script_dir/bootstrap-tools.sh")"
fi

if [[ "$("$swiftlint_bin" --version)" != "$swiftlint_version" ]]; then
    printf 'SwiftLint %s is required; found %s.\n' "$swiftlint_version" "$("$swiftlint_bin" --version)" >&2
    exit 1
fi
printf 'SwiftLint: %s (%s)\n' "$("$swiftlint_bin" --version)" "$swiftlint_bin"

printf '\n==> Swift format lint\n'
swift format lint \
    --strict \
    --recursive \
    "$repo_root/apps/macos/SofaRemoteMac" \
    "$repo_root/apps/ios/SofaRemoteiOS" \
    "$repo_root/apps/ios/SofaRemoteiOSUITests" \
    "$repo_root/packages/apple-core/Package.swift" \
    "$repo_root/packages/apple-core/Sources" \
    "$repo_root/packages/apple-core/Tests"

printf '\n==> SwiftLint\n'
for module in apps/macos apps/ios packages/apple-core; do
    (
        cd -- "$repo_root/$module"
        "$swiftlint_bin" lint --strict --quiet --no-cache
    )
done

printf '\n==> AppleCore package tests\n'
cmp "$repo_root/packages/protocol/fixtures/pointer-move.json" \
    "$repo_root/packages/apple-core/Tests/AppleCoreTests/Fixtures/pointer-move.json"
swift test \
    --package-path "$repo_root/packages/apple-core" \
    --scratch-path "$tool_root/apple-core-build" \
    --quiet

printf '\n==> macOS app builds and incremental signing\n'
mac_app_bundle="$tool_root/DerivedData/macOS/Build/Products/Debug/SofaRemoteMac.app"
for build_pass in 1 2; do
    printf 'macOS signed build %s/2\n' "$build_pass"
    xcodebuild -quiet \
        -project "$repo_root/apps/macos/SofaRemoteMac.xcodeproj" \
        -scheme SofaRemoteMac \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$tool_root/DerivedData/macOS" \
        -clonedSourcePackagesDirPath "$tool_root/SourcePackages" \
        build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
    codesign --verify --deep --strict "$mac_app_bundle"
done

printf '\n==> iOS app build (generic Simulator)\n'
xcodebuild -quiet \
    -project "$repo_root/apps/ios/SofaRemoteiOS.xcodeproj" \
    -scheme SofaRemoteiOS \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$tool_root/DerivedData/iOS" \
    -clonedSourcePackagesDirPath "$tool_root/SourcePackages" \
    build CODE_SIGNING_ALLOWED=NO

ios_info_plist="$tool_root/DerivedData/iOS/Build/Products/Debug-iphonesimulator/SofaRemoteiOS.app/Info.plist"
if [[ ! -f "$ios_info_plist" ]]; then
    printf 'Generated iOS app Info.plist was not found: %s\n' "$ios_info_plist" >&2
    exit 1
fi

mac_info_plist="$tool_root/DerivedData/macOS/Build/Products/Debug/SofaRemoteMac.app/Contents/Info.plist"
for app_info in "$ios_info_plist" "$mac_info_plist"; do
    if [[ "$(plutil -type NSBonjourServices "$app_info")" != "array" ]] || \
        [[ "$(plutil -extract NSBonjourServices.0 raw -o - "$app_info")" != "_sofaremote._tcp" ]]; then
        printf 'Expected Sofa Remote Bonjour service array in %s.\n' "$app_info" >&2
        exit 1
    fi
    test -n "$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$app_info")"
done
test -n "$(plutil -extract NSCameraUsageDescription raw -o - "$ios_info_plist")"

for generated_key in UIApplicationSceneManifest UILaunchScreen; do
    generated_type="$(plutil -type "$generated_key" "$ios_info_plist")"
    if [[ "$generated_type" != "dictionary" ]]; then
        printf 'Expected generated Info.plist key %s to be a dictionary, found %s.\n' \
            "$generated_key" "$generated_type" >&2
        exit 1
    fi
done

orientations_key='UISupportedInterfaceOrientations~ipad'
orientations_type="$(plutil -type "$orientations_key" "$ios_info_plist")"
orientations_count="$(plutil -extract "$orientations_key" raw -o - "$ios_info_plist")"
orientations_json="$(plutil -extract "$orientations_key" json -o - "$ios_info_plist")"
if [[ "$orientations_type" != "array" || "$orientations_count" != "4" ]]; then
    printf 'Expected %s to be a four-entry array; found type=%s count=%s.\n' \
        "$orientations_key" "$orientations_type" "$orientations_count" >&2
    exit 1
fi

for orientation in \
    UIInterfaceOrientationPortrait \
    UIInterfaceOrientationPortraitUpsideDown \
    UIInterfaceOrientationLandscapeLeft \
    UIInterfaceOrientationLandscapeRight; do
    if ! grep -Fq "\"$orientation\"" <<<"$orientations_json"; then
        printf 'Generated iPad orientation array is missing %s.\n' "$orientation" >&2
        exit 1
    fi
done

if fullscreen_value="$(plutil -extract UIRequiresFullScreen raw -o - "$ios_info_plist" 2>/dev/null)"; then
    if [[ "$fullscreen_value" == "true" || "$fullscreen_value" == "YES" ]]; then
        printf 'Generated Info.plist requires full-screen mode, disabling iPad multitasking.\n' >&2
        exit 1
    fi
fi
printf 'iOS Info.plist: generated scene/launch screens and four iPad orientations.\n'

printf '\nApple checks passed.\n'
