#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
for os in debian12 ubuntu2404 ubuntu2204; do
    detect_platform "$NF_SOURCE/tests/fixtures/os-release/$os" x86_64
    assert_eq 64 "$NF_ARCH"
    detect_platform "$NF_SOURCE/tests/fixtures/os-release/$os" aarch64
    assert_eq arm64-v8a "$NF_ARCH"
done
assert_fails detect_platform "$NF_SOURCE/tests/fixtures/os-release/debian11" amd64
assert_fails detect_platform "$NF_SOURCE/tests/fixtures/os-release/fedora" amd64
assert_fails detect_platform "$NF_SOURCE/tests/fixtures/os-release/debian12" riscv64
# shellcheck disable=SC2016
printf 'ID=debian\nVERSION_ID="$(touch %s/pwned)"\n' "$NF_TEST_ROOT" > "$NF_WORK/os-release"
assert_fails detect_platform "$NF_WORK/os-release" amd64
[[ ! -e $NF_TEST_ROOT/pwned ]]
printf 'PASS platform\n'
