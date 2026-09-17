#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
# Exercise the real root predicate before substituting fixture authorization.
if (( EUID != 0 )); then assert_fails cli_require_root; fi
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
install_nodeforge > "$NF_WORK/install-output"
config_hash=$(sha256_file "$NF_CONFIG")
state_hash=$(sha256_file "$NF_STATE")
cli_main > "$NF_WORK/help"
grep -q 'Usage: nodeforge' "$NF_WORK/help"
cli_main --help > "$NF_WORK/help2"
cmp "$NF_WORK/help" "$NF_WORK/help2"
cli_main help > "$NF_WORK/help2"
cmp "$NF_WORK/help" "$NF_WORK/help2"
assert_eq "NodeForge $(cat "$NF_SOURCE/VERSION")" "$(cli_main version)"
assert_fails cli_main unknown
assert_fails cli_main status extra
cli_main status > "$NF_WORK/status"
grep -q '^Status: healthy$' "$NF_WORK/status"
cli_main info > "$NF_WORK/info"
grep -q '^Xray version: v26.9.9$' "$NF_WORK/info"
cli_main link > "$NF_WORK/link"
assert_eq 2 "$(wc -l < "$NF_WORK/link" | tr -d ' ')"
assert_eq "$(grep '^vless://' "$NF_WORK/install-output")" "$(sed -n '1p' "$NF_WORK/link")"
grep -Eq '^hysteria2://[^@]+@[^?]+[?]mport=20000-50000&insecure=1&pinSHA256=[0-9a-f]{64}#NodeForge-HY2$' "$NF_WORK/link"
for secret in "$NF_PRIVATE_KEY" "$NF_PUBLIC_KEY" "$NF_UUID" "$NF_SHORT_ID" "$NF_HYSTERIA_PASSWORD" 'vless://' 'hysteria2://'; do
    assert_fails grep -F "$secret" "$NF_WORK/status" "$NF_WORK/info"
done
assert_eq "$config_hash" "$(sha256_file "$NF_CONFIG")"
assert_eq "$state_hash" "$(sha256_file "$NF_STATE")"
# All root-only commands reject authorization before lock acquisition or mutation.
touch "$NF_TEST_ROOT/nonroot"
for command in status info link restart uninstall update xray-update; do
    assert_fails cli_main "$command"
    grep -q 'must be run as root' "$NF_WORK/expected-failure.log"
done
cli_main version >/dev/null
cli_main >/dev/null
rm "$NF_TEST_ROOT/nonroot"
for failure in missing-service wrong-unit missing-listener wrong-pid wrong-exe wrong-address zero-pid dropin stale-unit; do
    touch "$NF_TEST_ROOT/$failure"
    assert_fails cli_main status
    assert_not_contains 'Status: healthy' "$NF_WORK/expected-failure.log"
    rm "$NF_TEST_ROOT/$failure"
done
rm "$NF_TEST_ROOT/active"
assert_fails cli_main status
assert_fails cli_main info
touch "$NF_TEST_ROOT/active"
cp "$NF_STATE" "$NF_WORK/good-state"
cp "$NF_CONFIG" "$NF_WORK/good-config"
# Literal shell syntax is hostile fixture data, never an executable command.
# shellcheck disable=SC2016
for alteration in '.schema=2' '.schema=99' 'del(.public_key)' '.owner="other"' '.version="$(touch /bad)"'; do
    jq "$alteration" "$NF_WORK/good-state" > "$NF_STATE"
    for command in status info link restart uninstall; do assert_fails cli_main "$command"; done
done
printf '{bad PRIVATE-ERROR-SENTINEL' > "$NF_STATE"
assert_fails cli_main status
assert_not_contains PRIVATE-ERROR-SENTINEL "$NF_WORK/expected-failure.log"
rm "$NF_STATE"
assert_fails cli_main status
cp "$NF_WORK/good-state" "$NF_STATE"
# Matching file digests do not excuse a missing field or inconsistent identity.
jq 'del(.inbounds[0].settings.clients[0].id)' "$NF_WORK/good-config" > "$NF_CONFIG"
jq --arg hash "$(sha256_file "$NF_CONFIG")" '.config_sha256=$hash' "$NF_WORK/good-state" > "$NF_STATE"
assert_fails cli_main link
cp "$NF_WORK/good-config" "$NF_CONFIG"
jq '.public_key="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"' "$NF_WORK/good-state" > "$NF_STATE"
for command in status info link restart uninstall; do assert_fails cli_main "$command"; done
cp "$NF_WORK/good-state" "$NF_STATE"
printf '\n' >> "$NF_CONFIG"
assert_fails cli_main link
cp "$NF_WORK/good-config" "$NF_CONFIG"
touch "$NF_TEST_ROOT/fail-config"
restarts=$(grep -c '^restart ' "$NF_TEST_ROOT/systemctl.calls")
assert_fails cli_main restart
assert_eq "$restarts" "$(grep -c '^restart ' "$NF_TEST_ROOT/systemctl.calls")"
rm "$NF_TEST_ROOT/fail-config"
cli_main restart > "$NF_WORK/restart"
grep -q 'services and listeners healthy' "$NF_WORK/restart"
touch "$NF_TEST_ROOT/fail-restart"
assert_fails cli_main restart
rm "$NF_TEST_ROOT/fail-restart"
touch "$NF_TEST_ROOT/missing-listener"
assert_fails cli_main restart
rm "$NF_TEST_ROOT/missing-listener"
touch "$NF_TEST_ROOT/dual-stack"
cli_main status > "$NF_WORK/dual-status"
cli_main info > "$NF_WORK/dual-info"
cli_main restart > "$NF_WORK/dual-restart"
for failure in wrong-pid v6-only; do
    touch "$NF_TEST_ROOT/$failure"
    assert_fails cli_main status
    rm "$NF_TEST_ROOT/$failure"
done
rm "$NF_TEST_ROOT/dual-stack"
assert_eq "$config_hash" "$(sha256_file "$NF_CONFIG")"
assert_eq "$state_hash" "$(sha256_file "$NF_STATE")"
assert_fails grep -E '^(restart|stop|disable|show) .*other' "$NF_TEST_ROOT/systemctl.calls"
grep -q '^shared$' "$NF_TEST_ROOT/locks.calls"
grep -q '^exclusive$' "$NF_TEST_ROOT/locks.calls"
printf 'PASS CLI dispatch, state, privacy, link, permissions, health and restart\n'
