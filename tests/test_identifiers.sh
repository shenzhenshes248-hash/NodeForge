#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
validate_uuid 123e4567-e89b-42d3-a456-426614174000
assert_fails validate_uuid '123e4567-invalid'
validate_short_id 0123456789abcdef
assert_fails validate_short_id ''
assert_fails validate_short_id 123
assert_fails validate_short_id 0123456789abcdeg
for port in 1024 20000 50000 65535; do validate_port "$port"; done
for port in 0 80 65536 -1 020000 '20000;exit' 999999999999999999; do assert_fails validate_port "$port"; done
NF_CANDIDATE_BIN=$NF_WORK/fixture-xray
cp "$NF_SOURCE/tests/fixtures/xray/xray" "$NF_CANDIDATE_BIN"
chmod 755 "$NF_CANDIDATE_BIN"
generate_identity
validate_uuid "$NF_UUID"
validate_short_id "$NF_SHORT_ID"
assert_eq 43 "${#NF_PRIVATE_KEY}"
assert_eq 43 "${#NF_PUBLIC_KEY}"
[[ ! -e $NF_WORK/key-output ]]
printf 'PASS identifiers\n'
