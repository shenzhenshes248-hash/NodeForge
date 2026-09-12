#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
printf 'test archive\n' > "$NF_WORK/archive"
printf 'SHA2-256= %s\n' "$(sha256_file "$NF_WORK/archive")" > "$NF_WORK/checksum"
verify_checksum "$NF_WORK/archive" "$NF_WORK/checksum"
assert_fails verify_checksum "$NF_WORK/archive" "$NF_SOURCE/tests/fixtures/releases/official-v26.9.9-linux-64.dgst"
printf 'SHA2-256= not-a-checksum\n' > "$NF_WORK/checksum"
assert_fails verify_checksum "$NF_WORK/archive" "$NF_WORK/checksum"
printf 'MD5= 123\n' > "$NF_WORK/checksum"
assert_fails verify_checksum "$NF_WORK/archive" "$NF_WORK/checksum"
printf 'SHA2-256= %s\nSHA2-256= %s\n' "$(sha256_file "$NF_WORK/archive")" "$(sha256_file "$NF_WORK/archive")" > "$NF_WORK/checksum"
assert_fails verify_checksum "$NF_WORK/archive" "$NF_WORK/checksum"
download_https() { return 1; }
NF_ARCH=64
assert_fails fetch_xray v26.9.9
assert_fails fetch_xray '../../bad'
printf 'PASS download verification\n'
