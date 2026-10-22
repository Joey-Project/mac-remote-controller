#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
output_root="$repo_root/.codex-tmp/apple-tools/UI-Tests"
derived_data="${IOS_UI_TEST_DERIVED_DATA:-$output_root/DerivedData}"
result_bundle="${IOS_UI_TEST_RESULT_BUNDLE:-$output_root/Results/$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult}"
created_devices=()
destinations=()

cleanup() {
    local device
    for device in "${created_devices[@]-}"; do
        [[ -n "$device" ]] || continue
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

muted="$(osascript -e 'set volume with output muted' -e 'output muted of (get volume settings)')"
if [[ "$muted" != "true" ]]; then
    printf 'System audio must be muted before UI tests.\n' >&2
    exit 1
fi

if [[ "$#" -gt 0 ]]; then
    # Explicit IDs reuse existing simulators; cleanup never deletes them.
    for device in "$@"; do
        destinations+=(-destination "platform=iOS Simulator,id=$device")
    done
else
    # No runtime argument selects the newest installed compatible runtime.
    for device_type in \
        com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
        com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro; do
        device="$(xcrun simctl create "Sofa Remote UI $$" "$device_type")"
        created_devices+=("$device")
        destinations+=(-destination "platform=iOS Simulator,id=$device")
    done
fi

mkdir -p "$(dirname -- "$result_bundle")" "$repo_root/.codex-tmp/apple-tools/SourcePackages"
printf 'UI test results: %s\n' "$result_bundle"
xcodebuild -quiet \
    -project "$repo_root/apps/ios/SofaRemoteiOS.xcodeproj" \
    -scheme SofaRemoteiOS \
    -configuration Debug \
    "${destinations[@]}" \
    -destination-timeout 90 \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$repo_root/.codex-tmp/apple-tools/SourcePackages" \
    -resultBundlePath "$result_bundle" \
    test CODE_SIGNING_ALLOWED=NO
