#!/usr/bin/env bash
set -Eeuo pipefail

uri_encode() { jq -rn --arg value "$1" '$value|@uri'; }
node_link() {
    local address=$NF_SERVER_IP link
    [[ $address != *:* ]] || address=[$address]
    link="vless://$NF_UUID@$address:$NF_PORT?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=$(uri_encode "$NF_SNI")&pbk=$(uri_encode "$NF_PUBLIC_KEY")&sid=$NF_SHORT_ID#NodeForge"
    printf '%s\n' "$link"
}
hysteria_link() {
    local address=$NF_SERVER_IP
    [[ $address != *:* ]] || address=[$address]
    printf 'hysteria2://%s@%s:%s?mport=%s&insecure=1&pinSHA256=%s#NodeForge-HY2\n' \
        "$(uri_encode "$NF_HYSTERIA_PASSWORD")" "$address" "$NF_HYSTERIA_PORT" \
        "$(uri_encode "$NF_HYSTERIA_PORTS")" "$(uri_encode "$NF_HYSTERIA_PIN")"
}
print_node() {
    local link hy_link
    link=$(node_link)
    hy_link=$(hysteria_link)
    printf '\nServer IP: %s\nPort: %s\nUUID: %s\nReality Public Key: %s\nShort ID: %s\nSNI/serverName: %s\nFlow: xtls-rprx-vision\n\n%s\n\nHysteria 2 UDP: %s\nPort hopping: %s\nClient hop interval: %ss (v2rayN default)\nCertificate pinSHA256: %s\n\n%s\n' \
        "$NF_SERVER_IP" "$NF_PORT" "$NF_UUID" "$NF_PUBLIC_KEY" "$NF_SHORT_ID" "$NF_SNI" "$link" \
        "$NF_HYSTERIA_PORT" "$NF_HYSTERIA_PORTS" "$NF_HYSTERIA_CLIENT_HOP_INTERVAL" "$NF_HYSTERIA_PIN" "$hy_link"
    warn 'Share link is a credential. Local checks do not verify cloud firewall or external client connectivity.'
}
