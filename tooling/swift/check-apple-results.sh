#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    printf 'Expected build, renewal and UI job results.\n' >&2
    exit 64
fi

failed=0
for job in apple-build apple-renewal apple-ui; do
    result="$1"
    shift
    printf '%s: %s\n' "$job" "$result"
    if [[ "$result" != success ]]; then
        failed=1
    fi
done
exit "$failed"
