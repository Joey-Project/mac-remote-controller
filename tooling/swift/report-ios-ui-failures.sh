#!/usr/bin/env bash
set -euo pipefail

summary_path="${1-}"

escape_workflow_value() {
    local value="$1"
    value="${value//%/%25}"
    value="${value//$'\r'/%0D}"
    value="${value//$'\n'/%0A}"
    printf '%s' "$value"
}

emit_warning() {
    printf '::warning title=iOS Simulator test summary::%s\n' "$(escape_workflow_value "$1")"
}

if [[ -z "$summary_path" || ! -f "$summary_path" ]]; then
    emit_warning 'The xcresult XCTest summary is missing; see the original xcodebuild failure.'
    exit 0
fi

if ! failed_tests="$(plutil -extract failedTests raw -o - "$summary_path" 2>/dev/null)"; then
    emit_warning 'The xcresult XCTest summary is unreadable; see the original xcodebuild failure.'
    exit 0
fi

if [[ ! "$failed_tests" =~ ^[0-9]+$ ]]; then
    emit_warning 'The xcresult XCTest summary has an invalid failedTests count.'
    exit 0
fi
if (( failed_tests == 0 )); then
    exit 0
fi
model_name="$(plutil -extract devicesAndConfigurations.0.device.modelName raw -o - "$summary_path" 2>/dev/null || true)"
reported=0

for ((index = 0; index < 10; index += 1)); do
    identifier="$(plutil -extract "testFailures.$index.testIdentifierString" raw -o - "$summary_path" 2>/dev/null || true)"
    failure_text="$(plutil -extract "testFailures.$index.failureText" raw -o - "$summary_path" 2>/dev/null || true)"
    if [[ -z "$identifier" && -z "$failure_text" ]]; then
        break
    fi
    [[ -n "$identifier" ]] || identifier="Unidentified XCTest failure $((index + 1))"
    [[ -n "$failure_text" ]] || failure_text='No failure text was present in the xcresult summary.'

    message=''
    if [[ -n "$model_name" ]]; then
        message="[$model_name] "
    fi
    message+="$identifier: $failure_text"
    if (( ${#message} > 1300 )); then
        message="${message:0:1297}..."
    fi
    message="$(escape_workflow_value "$message")"
    printf '::error title=iOS Simulator XCTest failure::%s\n' "$message"
    reported=$((reported + 1))
done

if (( reported == 0 && failed_tests > 0 )); then
    emit_warning "xcresult reports $failed_tests failed test(s) but contains no readable testFailures entries."
fi
