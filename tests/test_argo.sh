#!/usr/bin/env bash
# Baseline runtime variables intentionally stay in the validation subshell.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
# Git Bash must not rewrite a WS URL path passed to Windows jq.exe.
export MSYS2_ARG_CONV_EXCL=/nodeforge-argo

# Keep the existing service fixture, adding independent Argo service state.
eval "$(declare -f systemctl | sed '1s/systemctl/core_systemctl/')"
systemctl() {
    if [[ $* != *nodeforge-argo* ]]; then core_systemctl "$@"; return; fi
    printf '%s\n' "$*" >> "$NF_TEST_ROOT/argo-systemctl.calls"
    local action=$1 unit
    shift
    case $action in
        start|restart|enable|stop|disable)
            for unit in "$@"; do
                case $action in
                    start|restart)
                        [[ ! -f $NF_TEST_ROOT/fail-argo-start ]] || return 1
                        touch "$NF_TEST_ROOT/$unit.active" ;;
                    enable) touch "$NF_TEST_ROOT/$unit.enabled" ;;
                    stop) rm -f "$NF_TEST_ROOT/$unit.active" ;;
                    disable) rm -f "$NF_TEST_ROOT/$unit.enabled" ;;
                esac
            done ;;
        is-active) [[ -f $NF_TEST_ROOT/$2.active ]] ;;
        show) printf '%032d\n' 1 ;;
        *) return 1 ;;
    esac
}

NF_ARCH=64
NF_ARGO_CURRENT=$NF_TEST_ROOT/current.json
install_nodeforge > "$NF_WORK/install-output"
# Xray fixture accepts the new schema as well as Reality; the real core gets a
# separate config validation in local/VPS acceptance, not a fake network test.
cat > "$NF_BIN" <<'CORE'
#!/usr/bin/env bash
case $1 in
    uuid) printf 'aaaa4567-e89b-42d3-a456-426614174000\n' ;;
    run) jq -e '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].streamSettings.network == "ws"' "$4" >/dev/null ;;
esac
CORE
write_state
core_hashes=$(sha256sum "$NF_BIN" "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")
before_links=$(node_link; hysteria_link)
cat > "$NF_TEST_ROOT/cloudflared" <<'CLOUDFLARED'
#!/usr/bin/env bash
printf 'cloudflared version 2026.9.0 (fixture)\n'
CLOUDFLARED
cloud_sha=$(sha256_file "$NF_TEST_ROOT/cloudflared")
download_https() {
    printf '%s\n' "$1" >> "$NF_TEST_ROOT/downloads"
    case $1 in
        https://api.github.com/repos/cloudflare/cloudflared/releases/latest)
            jq -n --arg sha "${NF_TEST_CLOUD_SHA:-$cloud_sha}" \
                '{tag_name:"2026.9.0",assets:[{name:"cloudflared-linux-amd64",digest:("sha256:"+$sha)},
                  {name:"cloudflared-linux-arm64",digest:("sha256:"+$sha)}]}' > "$2" ;;
        https://github.com/cloudflare/cloudflared/releases/download/2026.9.0/cloudflared-linux-*)
            cp "$NF_TEST_ROOT/cloudflared" "$2" ;;
        *) return 1 ;;
    esac
}

# Download mismatch fails before any service change; arm64 mapping is supported.
NF_TEST_CLOUD_SHA=$(printf '%064d' 0)
assert_fails fetch_cloudflared
unset NF_TEST_CLOUD_SHA
NF_ARCH=arm64-v8a
fetch_cloudflared
grep -q '/cloudflared-linux-arm64$' "$NF_TEST_ROOT/downloads"
NF_ARCH=64

# Recreate the baseline's immutable runtime inventory and launcher. This tests
# the source-only upgrade without relying on git or a downloaded release.
previous=$NF_APP/releases/v0.3.0
mv "$NF_RUNTIME" "$previous"
python3 - "$previous" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
(root / 'VERSION').write_text('v0.3.0\n')
common = root / 'lib/common.sh'
common.write_text(common.read_text().replace('update argo subscription cli', 'update subscription cli'))
runtime = root / 'lib/runtime.sh'
text = runtime.read_text()
text = text.replace('tools/release.py trust/release-ed25519.pub lib/argo.sh lib/argo_runtime.py \\\n'
                    '        lib/argo_ws.sh lib/argo_xhttp.sh templates/vless-ws.json templates/vless-xhttp.json \\\n'
                    '        templates/nodeforge-argo.service templates/nodeforge-argo-xray.service',
                    'tools/release.py trust/release-ed25519.pub')
runtime.write_text(text)
for file in ('lib/argo.sh', 'lib/argo_runtime.py', 'lib/argo_ws.sh', 'lib/argo_xhttp.sh',
             'templates/vless-ws.json', 'templates/vless-xhttp.json',
             'templates/nodeforge-argo.service', 'templates/nodeforge-argo-xray.service'):
    (root / file).unlink()
PY
declare -f trusted_directory trusted_file >> "$previous/lib/runtime.sh"
(
    NF_SOURCE=$previous NF_NODEFORGE_VERSION=v0.3.0
    source "$previous/lib/runtime.sh"
    runtime_paths
    runtime_inventory "$previous" > "$previous/.inventory"
    runtime_launcher > "$NF_CLI"
)
old_launcher=$(sha256_file "$NF_CLI")

# A failed Argo start removes only its own newly created files/services.
touch "$NF_TEST_ROOT/fail-argo-start"
set +e
(set -e; install_argo) > "$NF_WORK/failed-install" 2>&1
status=$?
set -e
[[ $status != 0 ]]
argo_paths
[[ ! -d $NF_ARGO_DIR && ! -e $NF_ARGO_UNIT && ! -e $NF_ARGO_XRAY_UNIT ]]
[[ ! -e $NF_RUNTIME && ! -e $NF_RUNTIME_STAGE ]]
assert_eq "$old_launcher" "$(sha256_file "$NF_CLI")"
assert_eq "$core_hashes" "$(sha256sum "$NF_BIN" "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
rm "$NF_TEST_ROOT/fail-argo-start"

core_calls=$(cat "$NF_TEST_ROOT/systemctl.calls")
install_argo > "$NF_WORK/argo-output"
runtime_validate
assert_eq "NodeForge $NF_NODEFORGE_VERSION" "$(bash "$NF_CLI" version)"
load_argo
[[ -f $NF_TEST_ROOT/nodeforge-argo.service.enabled && -f $NF_TEST_ROOT/nodeforge-argo-xray.service.enabled ]]
jq -e --argjson reality "$NF_PORT" '.inbounds[0] | .listen == "127.0.0.1" and
    .port >= 1024 and .port != $reality and .streamSettings.security == "none" and
    (.settings.clients[0] | has("flow") | not)' "$NF_ARGO_DIR/xray.json" >/dev/null
[[ $(jq -r '.inbounds[0].settings.clients[0].id' "$NF_ARGO_DIR/xray.json") != "$NF_UUID" ]]
assert_eq "$core_hashes" "$(sha256sum "$NF_BIN" "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
# Only daemon-reload is permitted in the existing services' log.
assert_eq "$(printf '%s\n' "$core_calls" | sed '/^daemon-reload$/d')" "$(sed '/^daemon-reload$/d' "$NF_TEST_ROOT/systemctl.calls")"
identity=$(sha256_file "$NF_ARGO_DIR/xray.json")
downloads=$(wc -l < "$NF_TEST_ROOT/downloads")
install_argo > "$NF_WORK/argo-again"
assert_eq "$identity" "$(sha256_file "$NF_ARGO_DIR/xray.json")"
assert_eq "$downloads" "$(wc -l < "$NF_TEST_ROOT/downloads")"

# Pending has no Argo URL; the other links remain unchanged.
assert_eq "$before_links" "$(cli_link 2>/dev/null)"
jq -n '{domain:"fresh.trycloudflare.com",invocation_id:"00000000000000000000000000000001"}' > "$NF_ARGO_CURRENT"
cli_link > "$NF_WORK/links"
python3 - "$NF_WORK/links" <<'PY'
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlsplit
lines = Path(sys.argv[1]).read_text().splitlines()
assert len(lines) == 3
url = urlsplit(lines[2])
assert url.scheme == 'vless' and url.hostname == 'www.shopify.com' and url.port == 443
query = parse_qs(url.query)
assert query == dict(encryption=['none'], type=['ws'], security=['tls'],
                    sni=['fresh.trycloudflare.com'], host=['fresh.trycloudflare.com'], path=['/nodeforge-argo']), query
PY
subscription_content > "$NF_WORK/subscription"
cmp "$NF_WORK/links" "$NF_WORK/subscription"
cli_argo_edge edge.example.com
subscription_content > "$NF_WORK/edge-subscription"
python3 - "$NF_WORK/links" "$NF_WORK/edge-subscription" <<'PY'
from pathlib import Path
import sys
from urllib.parse import urlsplit
before, after = [Path(p).read_text().splitlines() for p in sys.argv[1:]]
assert before[:2] == after[:2]
original, edge = urlsplit(before[2]), urlsplit(after[2])
assert edge.hostname == 'edge.example.com'
assert edge.query == original.query and edge.username == original.username and edge.port == 443
PY
cli_argo_edge ''
assert_eq "$(cat "$NF_WORK/links")" "$(subscription_content)"
jq '.invocation_id="old"' "$NF_ARGO_CURRENT" > "$NF_WORK/stale"
mv "$NF_WORK/stale" "$NF_ARGO_CURRENT"
assert_eq "$before_links" "$(cli_link 2>/dev/null)"
assert_fails subscription_content
uninstall_argo
[[ ! -d $NF_ARGO_DIR && ! -e $NF_ARGO_UNIT && ! -e $NF_ARGO_XRAY_UNIT ]]
assert_eq "$core_hashes" "$(sha256sum "$NF_BIN" "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
printf 'PASS Argo download, installation rollback, isolation, idempotency, links and uninstall\n'
