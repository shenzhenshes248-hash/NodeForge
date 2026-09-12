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
assert_not_contains() {
    local needle=$1 file result
    shift
    for file in "$@"; do
        if grep -Fq -- "$needle" "$file"; then
            printf 'Forbidden value found in capture (value suppressed)\n' >&2
            return 1
        else
            result=$?
            (( result == 1 )) || return 1
        fi
    done
}
capture_command() {
    local prefix=$1
    shift
    set +e
    ( set -e; "$@" ) > "$prefix.stdout" 2> "$prefix.stderr"
    NF_CAPTURE_STATUS=$?
    set -e
}
