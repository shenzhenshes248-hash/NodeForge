#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
install_nodeforge > "$NF_WORK/install-output"
hy_before=$(sha256sum "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")
# Only host/network effects are mocked; the real switch, transforms, ownership
# records and rollback execute against the fixture installation.
# Invoked by warp_switch from the sourced module.
# shellcheck disable=SC2329
warp_connect() { :; }
# shellcheck disable=SC2329
warp_cli() { :; }
warp-cli() { :; }
# Called by warp_status before the later registration-test mock replaces it.
# shellcheck disable=SC2329
curl() { printf '203.0.113.1\n'; }
test_xray_config() { jq -e . "$2" >/dev/null; }
eval "$(declare -f systemctl | sed '1s/systemctl/single_systemctl/')"
systemctl() {
    local action=$1 service
    shift
    if [[ $action == stop || $action == start ]] && [[ " $* " == *" $NF_HYSTERIA_SERVICE "* ]]; then
        printf '%s\n' "$action" >> "$NF_TEST_ROOT/warp-hy-actions"
    fi
    case $action in
        stop|start)
            for service in "$@"; do single_systemctl "$action" "$service"; done ;;
        *) single_systemctl "$action" "$@" ;;
    esac
}
warp_load
assert_eq disabled "$NF_WARP_MODE"
warp_switch enabled
cli_load_state
warp_load
assert_eq enabled "$NF_WARP_MODE"
generate_config "$NF_WORK/regenerated.json"
jq -e '.outbounds[0].protocol == "socks"' "$NF_WORK/regenerated.json" >/dev/null
jq -e '.outbounds[0].protocol == "socks" and .outbounds[1].protocol == "blackhole"' "$NF_CONFIG" >/dev/null
assert_eq "$hy_before" "$(sha256sum "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
assert_not_contains 'disableUDP' "$NF_HYSTERIA_CONFIG"
[[ ! -e $NF_TEST_ROOT/warp-hy-actions ]]
warp_status > "$NF_WORK/on-status"
grep -qx 'Reality: WARP' "$NF_WORK/on-status"
grep -qx 'Argo: WARP' "$NF_WORK/on-status"
grep -qx 'HY2: direct (VPS, TCP/UDP)' "$NF_WORK/on-status"
before=$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_WARP_STATE")
warp_switch enabled
assert_eq "$before" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_WARP_STATE")"
# Failed disable must restore the WARP-only policy and matching checksums.
touch "$NF_TEST_ROOT/fail-restart"
assert_fails warp_switch disabled
rm "$NF_TEST_ROOT/fail-restart"
assert_eq "$before" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_WARP_STATE")"
warp_switch disabled
cli_load_state
warp_load
assert_eq disabled "$NF_WARP_MODE"
warp_status > "$NF_WORK/off-status"
grep -qx 'Reality: direct' "$NF_WORK/off-status"
grep -qx 'Argo: direct' "$NF_WORK/off-status"
grep -qx 'HY2: direct (VPS, TCP/UDP)' "$NF_WORK/off-status"
jq -e '.outbounds == [{tag:"direct",protocol:"freedom"}] and (has("routing") | not)' "$NF_CONFIG" >/dev/null
assert_not_contains 'disableUDP' "$NF_HYSTERIA_CONFIG"
# JSON formatting can change, but a repeated operation must not rewrite files.
before=$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")
warp_switch disabled
assert_eq "$before" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
printf 'PASS: WARP default, enable/disable, idempotency and rollback\n'
assert_eq "$hy_before" "$(sha256sum "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
[[ ! -e $NF_TEST_ROOT/warp-hy-actions ]]

# An existing v0.6.0 ON installation is migrated even on repeated enable.
warp_switch enabled
cat >> "$NF_HYSTERIA_CONFIG" <<'LEGACY'
# NodeForge WARP outbound
disableUDP: true
outbounds:
  - name: warp
    type: socks5
    socks5:
      addr: 127.0.0.1:40000
LEGACY
write_hysteria_state
warp_switch enabled
cli_load_state
assert_eq "$hy_before" "$(sha256sum "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
assert_eq $'stop\nstart' "$(cat "$NF_TEST_ROOT/warp-hy-actions")"
rm "$NF_TEST_ROOT/warp-hy-actions"
warp_switch enabled
warp_switch disabled
[[ ! -e $NF_TEST_ROOT/warp-hy-actions ]]
printf 'PASS: HY2 remains direct without restarts; legacy WARP policy restored\n'

# Missing consumer registration is created once; unrelated errors never replace it.
source "$NF_SOURCE/lib/warp.sh"
warp_install() { :; }
warp_cli() {
    case "$*" in
        'registration show')
            if [[ -f $NF_TEST_ROOT/registered ]]; then printf 'Account type: Free\n'
            else printf 'Error: Missing registration\n'; return 1; fi ;;
        'registration new') printf 'new\n' >> "$NF_TEST_ROOT/registrations"; touch "$NF_TEST_ROOT/registered" ;;
        'mode --help') printf 'proxy\n' ;;
        'tunnel protocol set --help') printf 'MASQUE\n' ;;
        settings) printf 'Mode: WarpProxy on port 40000\nWARP tunnel protocol: MASQUE\n' ;;
        status) printf 'Status update: Connected\nNetwork: healthy\n' ;;
        *) : ;;
    esac
}
curl() { printf 'warp=on\n'; }
warp_connect
warp_connect
assert_eq 1 "$(wc -l < "$NF_TEST_ROOT/registrations" | tr -d ' ')"
warp_cli() { printf 'Error: daemon unavailable\n'; return 1; }
assert_fails warp_connect
printf 'PASS: WARP registration and current CLI configuration\n'
