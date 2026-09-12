#!/usr/bin/env bash
set -Eeuo pipefail

assert_eq() { [[ $1 == "$2" ]] || { printf 'Expected %s, got %s\n' "$1" "$2" >&2; return 1; }; }
assert_fails() {
    local status
    set +e
    ( set -e; "$@" ) > "$NF_WORK/expected-failure.log" 2>&1
    status=$?
    set -e
    if (( status == 0 )); then
        printf 'Expected failure: %s\n' "$1" >&2
        return 1
    fi
}
