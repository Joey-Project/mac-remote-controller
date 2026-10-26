#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
production_script="$script_dir/test-ios-ui.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/ios-ui-lifecycle.XXXXXX")"
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cleanup_test_root() {
    local status=$?
    trap - EXIT
    rm -rf -- "$test_root"
    exit "$status"
}
trap cleanup_test_root EXIT

cat >"$fake_bin/osascript" <<'FAKE_OSASCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'audio-muted-check\n' >>"$EVENT_LOG"
printf 'true\n'
FAKE_OSASCRIPT

cat >"$fake_bin/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
set -euo pipefail

case "${1-}:${2-}" in
    simctl:create)
        count=0
        if [[ -f "$CREATE_COUNTER" ]]; then
            read -r count <"$CREATE_COUNTER"
        fi
        count=$((count + 1))
        printf '%s\n' "$count" >"$CREATE_COUNTER"
        case "$count" in
            1) device_id=simulator-phone ;;
            2) device_id=simulator-tablet ;;
            *)
                printf 'unexpected simulator creation number: %s\n' "$count" >&2
                exit 90
                ;;
        esac
        printf 'create %s\n' "$device_id" >>"$EVENT_LOG"
        printf '%s\n' "$device_id"
        ;;
    simctl:bootstatus)
        printf 'boot %s\n' "${3-}" >>"$EVENT_LOG"
        ;;
    simctl:shutdown)
        device_id="${3-}"
        printf 'shutdown %s\n' "$device_id" >>"$EVENT_LOG"
        if [[ "$device_id" == "${FAIL_SHUTDOWN_ID-}" ]]; then
            exit "${FAIL_SHUTDOWN_STATUS:-41}"
        fi
        ;;
    simctl:delete)
        device_id="${3-}"
        printf 'delete %s\n' "$device_id" >>"$EVENT_LOG"
        if [[ "$device_id" == "${FAIL_DELETE_ID-}" ]]; then
            exit "${FAIL_DELETE_STATUS:-42}"
        fi
        ;;
    xcresulttool:get)
        printf 'xcresult-summary\n' >>"$EVENT_LOG"
        printf '{}\n'
        ;;
    *)
        printf 'unexpected xcrun invocation: %s\n' "$*" >&2
        exit 91
        ;;
esac
FAKE_XCRUN

cat >"$fake_bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/usr/bin/env bash
set -euo pipefail

destination=''
while (($# > 0)); do
    if [[ "$1" == '-destination' && $# -ge 2 ]]; then
        destination="$2"
        shift 2
    else
        shift
    fi
done
device_id="${destination##*id=}"
printf 'test %s\n' "$device_id" >>"$EVENT_LOG"
if [[ "$device_id" == "${FAIL_XCODEBUILD_ID-}" ]]; then
    exit "${FAIL_XCODEBUILD_STATUS:-65}"
fi
FAKE_XCODEBUILD

cat >"$fake_bin/plutil" <<'FAKE_PLUTIL'
#!/usr/bin/env bash
set -euo pipefail
case "${2-}" in
    failedTests) printf '1\n' ;;
    devicesAndConfigurations.0.device.modelName) printf 'Mock iPhone\n' ;;
    testFailures.0.testIdentifierString) printf 'LifecycleTests/testFailure\n' ;;
    testFailures.0.failureText) printf 'mock assertion failed\n' ;;
    *) exit 1 ;;
esac
FAKE_PLUTIL

chmod +x "$fake_bin/osascript" "$fake_bin/xcrun" "$fake_bin/xcodebuild" "$fake_bin/plutil"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -n "${CURRENT_OUTPUT-}" && -f "$CURRENT_OUTPUT" ]]; then
        cat "$CURRENT_OUTPUT" >&2
    fi
    if [[ -n "${CURRENT_EVENTS-}" && -f "$CURRENT_EVENTS" ]]; then
        cat "$CURRENT_EVENTS" >&2
    fi
    exit 1
}

run_production_script() {
    local name="$1"
    shift
    CURRENT_EVENTS="$test_root/$name.events"
    CURRENT_OUTPUT="$test_root/$name.output"
    : >"$CURRENT_EVENTS"
    local status=0
    if env \
        PATH="$fake_bin:$PATH" \
        EVENT_LOG="$CURRENT_EVENTS" \
        CREATE_COUNTER="$test_root/$name.create-counter" \
        FAIL_SHUTDOWN_ID="${FAIL_SHUTDOWN_ID-}" \
        FAIL_SHUTDOWN_STATUS="${FAIL_SHUTDOWN_STATUS-}" \
        FAIL_DELETE_ID="${FAIL_DELETE_ID-}" \
        FAIL_DELETE_STATUS="${FAIL_DELETE_STATUS-}" \
        FAIL_XCODEBUILD_ID="${FAIL_XCODEBUILD_ID-}" \
        FAIL_XCODEBUILD_STATUS="${FAIL_XCODEBUILD_STATUS-}" \
        IOS_UI_TEST_DERIVED_DATA="$test_root/$name-derived-data" \
        IOS_UI_TEST_RESULT_BUNDLE="$test_root/$name-results" \
        /bin/bash "$production_script" "$@" >"$CURRENT_OUTPUT" 2>&1; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

assert_contains() {
    local expected="$1"
    local events="$2"
    grep -Fxq -- "$expected" "$events" || fail "missing event: $expected"
}

assert_absent() {
    local unexpected="$1"
    local events="$2"
    if grep -Fxq -- "$unexpected" "$events"; then
        fail "unexpected event: $unexpected"
    fi
}

assert_output_contains() {
    local expected="$1"
    local output="$2"
    grep -Fq -- "$expected" "$output" || fail "missing output: $expected"
}

assert_before() {
    local first="$1"
    local second="$2"
    local events="$3"
    local first_line second_line
    first_line="$(grep -nFx -m 1 -- "$first" "$events" | cut -d: -f1)" || fail "missing event: $first"
    second_line="$(grep -nFx -m 1 -- "$second" "$events" | cut -d: -f1)" || fail "missing event: $second"
    if (( first_line >= second_line )); then
        fail "expected '$first' before '$second'"
    fi
}

status=0
FAIL_SHUTDOWN_ID=''
FAIL_DELETE_ID=''
FAIL_XCODEBUILD_ID=''
run_production_script default || status=$?
[[ "$status" -eq 0 ]] || fail "default destinations exited with status $status"
assert_contains 'test simulator-phone' "$CURRENT_EVENTS"
assert_contains 'test simulator-tablet' "$CURRENT_EVENTS"
assert_contains 'shutdown simulator-phone' "$CURRENT_EVENTS"
assert_contains 'delete simulator-phone' "$CURRENT_EVENTS"
assert_contains 'shutdown simulator-tablet' "$CURRENT_EVENTS"
assert_contains 'delete simulator-tablet' "$CURRENT_EVENTS"
assert_before 'shutdown simulator-phone' 'boot simulator-tablet' "$CURRENT_EVENTS"
assert_before 'delete simulator-phone' 'boot simulator-tablet' "$CURRENT_EVENTS"

status=0
FAIL_SHUTDOWN_ID=simulator-phone
run_production_script shutdown-failure || status=$?
[[ "$status" -ne 0 ]] || fail 'shutdown failure was reported as success'
assert_absent 'boot simulator-tablet' "$CURRENT_EVENTS"
assert_absent 'test simulator-tablet' "$CURRENT_EVENTS"

status=0
FAIL_SHUTDOWN_ID=''
FAIL_DELETE_ID=simulator-phone
run_production_script delete-failure || status=$?
[[ "$status" -ne 0 ]] || fail 'delete failure was reported as success'
assert_absent 'boot simulator-tablet' "$CURRENT_EVENTS"
assert_absent 'test simulator-tablet' "$CURRENT_EVENTS"

status=0
FAIL_DELETE_ID=simulator-phone
FAIL_XCODEBUILD_ID=simulator-phone
FAIL_XCODEBUILD_STATUS=65
run_production_script xcodebuild-failure || status=$?
[[ "$status" -eq 65 ]] || fail "cleanup replaced xcodebuild status 65 with $status"
assert_contains 'test simulator-phone' "$CURRENT_EVENTS"
assert_absent 'boot simulator-tablet' "$CURRENT_EVENTS"
assert_output_contains '::error title=iOS Simulator XCTest failure::[Mock iPhone] LifecycleTests/testFailure: mock assertion failed' "$CURRENT_OUTPUT"

status=0
FAIL_DELETE_ID=''
FAIL_XCODEBUILD_ID=simulator-explicit-a
FAIL_XCODEBUILD_STATUS=65
run_production_script explicit-failure simulator-explicit-a simulator-explicit-b || status=$?
[[ "$status" -eq 65 ]] || fail "explicit-ID failure returned status $status instead of 65"
assert_contains 'test simulator-explicit-a' "$CURRENT_EVENTS"
assert_absent 'shutdown simulator-explicit-a' "$CURRENT_EVENTS"
assert_absent 'delete simulator-explicit-a' "$CURRENT_EVENTS"
assert_absent 'shutdown simulator-explicit-b' "$CURRENT_EVENTS"
assert_absent 'delete simulator-explicit-b' "$CURRENT_EVENTS"

printf 'PASS: mocked iOS UI simulator lifecycle (5 scenarios)\n'
