#!/usr/bin/env bash
set -Eeuo pipefail

argo_profile_template() { printf '%s\n' "$NF_SOURCE/templates/vless-xhttp.json"; }
argo_profile_query() { printf 'type=xhttp&mode=packet-up'; }
argo_profile_label() { printf 'XHTTP+TLS, packet-up'; }
argo_profile_path() { jq -er '.inbounds[0].streamSettings.xhttpSettings.path' "$NF_ARGO_DIR/xray.json"; }
argo_profile_validate() {
    if [[ -d $NF_ARGO_DIR ]]; then
        local domain
        domain=$(jq -er '.tunnel_domain' "$NF_ARGO_DIR/state.json") || die 'XHTTP requires a Named Tunnel; Quick Tunnel migration is not supported by this installer'
        [[ -z ${NF_ARGO_DOMAIN:-} || $NF_ARGO_DOMAIN == "$domain" ]] || die 'Installed Named Tunnel domain differs'
        if [[ -n ${NF_ARGO_CREDENTIALS:-} ]]; then
            cmp -s "$NF_ARGO_CREDENTIALS" "$NF_ARGO_DIR/credentials.json" || die 'Installed Named Tunnel credentials differ'
        fi
        return
    fi
    [[ -n ${NF_ARGO_DOMAIN:-} && -n ${NF_ARGO_CREDENTIALS:-} ]] || die 'XHTTP requires --argo-domain and --argo-credentials (Named Tunnel JSON)'
    [[ $NF_ARGO_DOMAIN =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ! $NF_ARGO_DOMAIN =~ ^[0-9.]+$ ]] || die 'Invalid Named Tunnel hostname'
    require_regular "$NF_ARGO_CREDENTIALS"
    jq -e '(.TunnelID | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.AccountTag | type == "string" and length > 0) and (.TunnelSecret | type == "string" and length > 0)' \
        "$NF_ARGO_CREDENTIALS" >/dev/null || die 'Invalid Named Tunnel credentials JSON'
}
argo_profile_prepare() {
    cp "$NF_ARGO_CREDENTIALS" "$NF_WORK/credentials.json"
    chmod 600 "$NF_WORK/credentials.json"
    jq -n --arg tunnel "$(jq -er '.TunnelID' "$NF_WORK/credentials.json")" \
        --arg credentials "$NF_ARGO_DIR/credentials.json" --arg domain "$NF_ARGO_DOMAIN" \
        --arg port "$(jq -r '.inbounds[0].port' "$NF_WORK/argo-xray.json")" \
        '{tunnel:$tunnel,"credentials-file":$credentials,ingress:[
            {hostname:$domain,service:("http://127.0.0.1:"+$port)},{service:"http_status:404"}]}' > "$NF_WORK/cloudflared.yml"
}
