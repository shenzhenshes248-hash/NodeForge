#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"
install_nodeforge > "$NF_WORK/install-output"
before=$(sha256_file "$NF_STATE")
state_schema_supported "$NF_STATE"
validate_legacy_state_record "$NF_STATE"
load_existing
assert_eq "$before" "$(sha256_file "$NF_STATE")"
assert_eq "$NF_DEFAULT_XRAY_VERSION" "$NF_XRAY_VERSION"
# Phase 1 still writes exactly the M1 field set, with .version meaning Xray.
jq -e 'keys == ["binary_sha256","config_sha256","license_sha256","owner","public_key","schema","server_ip","unit_sha256","user_created","version"] and .schema == 1' "$NF_STATE" >/dev/null
NF_NODEFORGE_VERSION=v9.8.7-dev
write_state
assert_eq "$before" "$(sha256_file "$NF_STATE")"
for schema in 2 3 0 -1 1.5 '"1"' null true; do
    jq --argjson schema "$schema" '.schema=$schema' "$NF_STATE" > "$NF_WORK/unsupported.json"
    assert_fails state_schema_supported "$NF_WORK/unsupported.json"
    assert_fails validate_legacy_state_record "$NF_WORK/unsupported.json"
done
cp "$NF_STATE" "$NF_WORK/original.json"
jq '.schema=2' "$NF_WORK/original.json" > "$NF_STATE"
unsupported_hash=$(sha256_file "$NF_STATE")
assert_fails load_existing
assert_eq "$unsupported_hash" "$(sha256_file "$NF_STATE")"
printf '{broken' > "$NF_WORK/broken.json"
assert_fails state_schema_supported "$NF_WORK/broken.json"
printf '{}\n' > "$NF_WORK/broken.json"
assert_fails state_schema_supported "$NF_WORK/broken.json"
printf 'PASS legacy state compatibility; schema 2 refused without migration\n'
