#!/usr/bin/env bash
set -Eeuo pipefail

argo_profile_template() { printf '%s\n' "$NF_SOURCE/templates/vless-ws.json"; }
argo_profile_query() { printf 'type=ws'; }
argo_profile_label() { printf 'WS+TLS'; }
argo_profile_path() { jq -er '.inbounds[0].streamSettings.wsSettings.path' "$NF_ARGO_DIR/xray.json"; }
argo_profile_validate() {
    [[ -z ${NF_ARGO_DOMAIN:-} && -z ${NF_ARGO_CREDENTIALS:-} ]] || die 'Named Tunnel arguments require --profile xhttp'
}
argo_profile_prepare() { printf '{}\n' > "$NF_WORK/cloudflared.yml"; }
