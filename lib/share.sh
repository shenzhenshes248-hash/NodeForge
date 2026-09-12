#!/usr/bin/env bash
set -Eeuo pipefail

uri_encode() { jq -rn --arg value "$1" '$value|@uri'; }
print_node() {
    local address=$NF_SERVER_IP link
    [[ $address != *:* ]] || address=[$address]
    link="vless://$NF_UUID@$address:$NF_PORT?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=$(uri_encode "$NF_SNI")&pbk=$(uri_encode "$NF_PUBLIC_KEY")&sid=$NF_SHORT_ID#NodeForge"
    printf '\nServer IP: %s\nPort: %s\nUUID: %s\nReality Public Key: %s\nShort ID: %s\nSNI/serverName: %s\nFlow: xtls-rprx-vision\n\n%s\n' \
        "$NF_SERVER_IP" "$NF_PORT" "$NF_UUID" "$NF_PUBLIC_KEY" "$NF_SHORT_ID" "$NF_SNI" "$link"
    warn 'Share link is a credential. Local checks do not verify cloud firewall or external client connectivity.'
}
