#!/usr/bin/env bash
# Installer entry-point mocks are invoked by the sourced main function.
# shellcheck disable=SC2329
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
export MSYS2_ARG_CONV_EXCL=/nodeforge-argo

eval "$(declare -f systemctl | sed '1s/systemctl/core_systemctl/')"
systemctl() {
    if [[ $* != *nodeforge-argo* && $* != *nodeforge-subscription* ]]; then core_systemctl "$@"; return; fi
    printf '%s\n' "$*" >> "$NF_TEST_ROOT/argo-systemctl.calls"
    local action=$1 unit
    shift
    case $action in
        start|enable|stop|disable)
            for unit in "$@"; do
                case $action in
                    start) touch "$NF_TEST_ROOT/$unit.active" ;;
                    stop) rm -f "$NF_TEST_ROOT/$unit.active" ;;
                    enable|disable) : ;;
                esac
            done ;;
        is-active) [[ -f $NF_TEST_ROOT/$2.active ]] ;;
        show) printf '%032d\n' 1 ;;
        *) return 1 ;;
    esac
}
fetch_cloudflared() {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$NF_WORK/cloudflared"
    chmod 755 "$NF_WORK/cloudflared"
    NF_CLOUDFLARED_VERSION=2026.9.0
}

# One common core fixture, then one Argo profile at a time.
install_nodeforge > "$NF_WORK/core-output"
cat > "$NF_BIN" <<'CORE'
#!/usr/bin/env bash
case $1 in
    uuid) printf 'aaaa4567-e89b-42d3-a456-426614174000\n' ;;
    run) jq -e '.inbounds | length == 1 and .[0].listen == "127.0.0.1" and
        (.[0].streamSettings.network == "ws" or .[0].streamSettings.network == "xhttp")' "$4" >/dev/null ;;
esac
CORE
write_state
core_hashes=$(sha256sum "$NF_BIN" "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")
before_links=$(node_link; hysteria_link)
core_calls=$(sed '/^daemon-reload$/d' "$NF_TEST_ROOT/systemctl.calls")
NF_ARGO_CURRENT=$NF_TEST_ROOT/current.json
credentials=$NF_TEST_ROOT/tunnel.json
printf '{"TunnelID":"11111111-1111-4111-8111-111111111111","AccountTag":"fixture","TunnelSecret":"Zml4dHVyZQ=="}\n' > "$credentials"

# Exercise the real option parser without repeating core installation.
sed -n '/^main() {/,/^}/p' "$NF_SOURCE/install.sh" > "$NF_WORK/main.sh"
# shellcheck disable=SC1091
source "$NF_WORK/main.sh"
(
    preflight() { :; }
    install_dependencies() { :; }
    install_nodeforge() { :; }
    install_argo() { assert_eq xhttp "$NF_PROFILE"; }
    install_subscription() { :; }
    main --profile xhttp --argo-domain nodeforge.example.com --argo-credentials "$credentials"
)

for profile in ws xhttp; do
    if [[ $profile == ws ]]; then
        unset NF_REQUESTED_PROFILE NF_ARGO_DOMAIN NF_ARGO_CREDENTIALS
        domain=fresh.trycloudflare.com
    else
        NF_REQUESTED_PROFILE=xhttp NF_ARGO_DOMAIN=nodeforge.example.com NF_ARGO_CREDENTIALS=$credentials
        domain=nodeforge.example.com
    fi
    argo_select_profile
    assert_eq "$profile" "$NF_PROFILE"
    install_argo > "$NF_WORK/$profile-install"
    load_argo
    jq -e --arg profile "$profile" '.profile == $profile' "$NF_ARGO_DIR/state.json" >/dev/null
    jq -e --arg profile "$profile" '.inbounds | length == 1 and .[0].listen == "127.0.0.1" and
        .[0].streamSettings.network == $profile' "$NF_ARGO_DIR/xray.json" >/dev/null
    if [[ $profile == ws ]]; then
        assert_eq '{}' "$(cat "$NF_ARGO_DIR/cloudflared.yml")"
        [[ ! -e $NF_ARGO_DIR/credentials.json ]]
        # Old v0.4.1 had no profile field and different unit descriptions.
        jq 'del(.profile)' "$NF_ARGO_DIR/state.json" > "$NF_WORK/legacy-state"
        cp "$NF_WORK/legacy-state" "$NF_ARGO_DIR/state.json"
        sed 's/^Description=.*/Description=NodeForge cloudflared Quick Tunnel/' "$NF_ARGO_UNIT" > "$NF_WORK/legacy-unit"
        cp "$NF_WORK/legacy-unit" "$NF_ARGO_UNIT"
    else
        jq -e '.inbounds[0].streamSettings.xhttpSettings ==
            {path:"/nodeforge-argo",mode:"packet-up",extra:{noSSEHeader:false}}' "$NF_ARGO_DIR/xray.json" >/dev/null
        jq -e '.tunnel == "11111111-1111-4111-8111-111111111111" and
            .ingress[0].hostname == "nodeforge.example.com" and .ingress[1].service == "http_status:404"' "$NF_ARGO_DIR/cloudflared.yml" >/dev/null
        cmp "$credentials" "$NF_ARGO_DIR/credentials.json"
    fi
    jq -n --arg domain "$domain" '{domain:$domain,invocation_id:"00000000000000000000000000000001"}' > "$NF_ARGO_CURRENT"
    install_subscription > "$NF_WORK/$profile-subscription"
    subscription_content > "$NF_WORK/$profile-links"
    python3 - "$NF_WORK/$profile-links" "$profile" "$domain" <<'PY'
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import sys
lines=Path(sys.argv[1]).read_text().splitlines()
assert len(lines)==3
url=urlsplit(lines[2]); q=parse_qs(url.query)
assert url.hostname=='www.shopify.com' and url.port==443
assert q['type']==[sys.argv[2]] and q['host']==q['sni']==[sys.argv[3]]
assert q.get('mode')==(['packet-up'] if sys.argv[2]=='xhttp' else None)
PY
    if [[ $profile == ws ]]; then stable_url=$(subscription_url); else assert_eq "$stable_url" "$(subscription_url)"; fi
    assert_eq "$before_links" "$(head -2 "$NF_WORK/$profile-links")"
    identity=$(sha256_file "$NF_ARGO_DIR/xray.json")
    unset NF_REQUESTED_PROFILE NF_ARGO_DOMAIN NF_ARGO_CREDENTIALS
    install_argo > "$NF_WORK/$profile-repeat"
    assert_eq "$identity" "$(sha256_file "$NF_ARGO_DIR/xray.json")"
    if [[ $profile == ws ]]; then NF_REQUESTED_PROFILE=xhttp; else NF_REQUESTED_PROFILE=ws; fi
    assert_fails argo_select_profile
    unset NF_REQUESTED_PROFILE
    assert_eq "$core_hashes" "$(sha256sum "$NF_BIN" "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
    assert_eq "$core_calls" "$(sed '/^daemon-reload$/d' "$NF_TEST_ROOT/systemctl.calls")"
    uninstall_argo
    printf 'PASS %s profile generation, install, three-node subscription and default compatibility\n' "$profile"
done
