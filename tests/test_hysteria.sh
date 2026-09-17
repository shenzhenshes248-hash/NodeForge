#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"

install_nodeforge > "$NF_WORK/output"
grep -Fxq 'listen: :443,20000-50000' "$NF_HYSTERIA_CONFIG"
grep -Fxq '  type: password' "$NF_HYSTERIA_CONFIG"
grep -Fxq 'User=root' "$NF_HYSTERIA_UNIT"
grep -Fxq 'ExecStart=/usr/local/nodeforge/bin/hysteria server -c /etc/nodeforge/hysteria.yaml' "$NF_HYSTERIA_UNIT"
grep -Fxq 'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE' "$NF_HYSTERIA_UNIT"
for path in "$NF_HYSTERIA_BIN" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY" "$NF_HYSTERIA_UNIT" "$NF_HYSTERIA_STATE"; do
    [[ -f $path ]]
done
jq -e '.version == "v2.12.3" and .listen == "443,20000-50000" and .ports == "20000-50000" and (.hop_min == null) and (.hop_max == null)' "$NF_HYSTERIA_STATE" >/dev/null
grep -Eq '^hysteria2://[^@]+@8[.]8[.]8[.]8:443[?]mport=20000-50000&insecure=1&pinSHA256=[0-9a-f]{64}#NodeForge-HY2$' "$NF_WORK/output"

# A Hysteria startup failure removes all newly-created HY2 and Reality assets.
uninstall_nodeforge
touch "$NF_TEST_ROOT/fail-hysteria-start"
set +e
( set -e; trap cleanup EXIT; install_nodeforge ) > "$NF_WORK/hysteria-failure" 2>&1
status=$?
set -e
[[ $status != 0 ]]
[[ ! -e $NF_HYSTERIA_BIN && ! -e $NF_HYSTERIA_CONFIG && ! -e $NF_HYSTERIA_STATE && ! -e $NF_STATE && ! -d $NF_PENDING ]]
rm "$NF_TEST_ROOT/fail-hysteria-start"

# UDP 443 conflicts fail before publishing managed files.
init_workspace
touch "$NF_TEST_ROOT/occupied-udp-443"
assert_fails install_nodeforge
[[ ! -e $NF_HYSTERIA_BIN && ! -e $NF_STATE ]]
printf 'PASS official Hysteria install, native port hopping, share link and rollback\n'
