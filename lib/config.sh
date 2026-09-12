#!/usr/bin/env bash
set -Eeuo pipefail

validate_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
validate_short_id() { [[ $1 =~ ^[0-9a-f]{16}$ ]]; }
load_existing() {
    require_regular "$NF_STATE"
    jq -e '.owner == "NodeForge" and .schema == 1 and (.user_created | type == "boolean")' "$NF_STATE" >/dev/null || die 'Invalid ownership record'
    local path expected actual
    for path in "$NF_CONFIG" "$NF_BIN" "$NF_UNIT" "$NF_LICENSE"; do require_regular "$path"; done
    expected=$(jq -r '.config_sha256' "$NF_STATE") actual=$(sha256_file "$NF_CONFIG")
    [[ $expected == "$actual" ]] || die 'Configuration changed outside NodeForge; refusing to overwrite or emit stale credentials'
    expected=$(jq -r '.binary_sha256' "$NF_STATE") actual=$(sha256_file "$NF_BIN")
    [[ $expected == "$actual" ]] || die 'Installed binary differs from recorded checksum'
    expected=$(jq -r '.unit_sha256' "$NF_STATE") actual=$(sha256_file "$NF_UNIT")
    [[ $expected == "$actual" ]] || die 'Service unit changed outside NodeForge'
    expected=$(jq -r '.license_sha256' "$NF_STATE") actual=$(sha256_file "$NF_LICENSE")
    [[ $expected == "$actual" ]] || die 'Installed Xray license changed outside NodeForge'
    NF_VERSION=$(jq -er '.version' "$NF_STATE")
    NF_PUBLIC_KEY=$(jq -er '.public_key' "$NF_STATE")
    NF_SERVER_IP=$(jq -er '.server_ip' "$NF_STATE")
    NF_USER_CREATED=$(jq -r '.user_created' "$NF_STATE")
    NF_UUID=$(jq -er '.inbounds[0].settings.clients[0].id' "$NF_CONFIG")
    NF_PORT=$(jq -er '.inbounds[0].port' "$NF_CONFIG")
    NF_PRIVATE_KEY=$(jq -er '.inbounds[0].streamSettings.realitySettings.privateKey' "$NF_CONFIG")
    NF_SHORT_ID=$(jq -er '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$NF_CONFIG")
    NF_TARGET=$(jq -er '.inbounds[0].streamSettings.realitySettings.target' "$NF_CONFIG")
    NF_SNI=$(jq -er '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$NF_CONFIG")
    NF_LISTEN=$(jq -er '.inbounds[0].listen' "$NF_CONFIG")
    NF_EXISTING=1
}
apply_overrides() {
    NF_UUID=${NODEFORGE_UUID:-$NF_UUID}
    NF_SHORT_ID=${NODEFORGE_SHORT_ID:-$NF_SHORT_ID}
    NF_PORT=${NODEFORGE_PORT:-$NF_PORT}
    if [[ -n ${NODEFORGE_REALITY_TARGET:-} ]]; then
        NF_TARGET=$NODEFORGE_REALITY_TARGET
        parse_reality_target "$NF_TARGET"
        if [[ -z ${NODEFORGE_SERVER_NAME:-} ]]; then
            [[ $NF_TARGET_HOST != *:* && ! $NF_TARGET_HOST =~ ^[0-9.]+$ ]] || die 'IP target requires NODEFORGE_SERVER_NAME'
            NF_SNI=$NF_TARGET_HOST
        fi
    fi
    NF_SNI=${NODEFORGE_SERVER_NAME:-$NF_SNI}
    validate_uuid "$NF_UUID" || die 'Invalid UUID'
    validate_short_id "$NF_SHORT_ID" || die 'shortId must be exactly 16 lowercase hex characters'
    validate_port "$NF_PORT" || die 'Port must be in 1024-65535 (random default: 20000-50000)'
}
generate_config() {
    local output=$1
    # Private key is read from a protected file, not exposed in process arguments.
    printf '%s' "$NF_PRIVATE_KEY" > "$NF_WORK/private-key"
    jq --arg uuid "$NF_UUID" --argjson port "$NF_PORT" --arg target "$NF_TARGET" \
        --arg sni "$NF_SNI" --arg sid "$NF_SHORT_ID" --arg listen "$NF_LISTEN" \
        --rawfile private "$NF_WORK/private-key" \
        '.inbounds[0].port=$port | .inbounds[0].listen=$listen |
         .inbounds[0].settings.clients[0].id=$uuid |
         .inbounds[0].streamSettings.realitySettings |=
         (.target=$target | .serverNames=[$sni] | .privateKey=$private | .shortIds=[$sid])' \
        "$NF_SOURCE/templates/vless-reality.json" > "$output"
    chmod 600 "$output"
    rm -f -- "$NF_WORK/private-key"
    jq -e . "$output" >/dev/null
}
write_state() {
    jq -n --arg version "$NF_VERSION" --arg public "$NF_PUBLIC_KEY" --arg ip "$NF_SERVER_IP" \
        --arg config "$(sha256_file "$NF_CONFIG")" --arg binary "$(sha256_file "$NF_BIN")" \
        --arg unit "$(sha256_file "$NF_UNIT")" --arg license "$(sha256_file "$NF_LICENSE")" --argjson user "$NF_USER_CREATED" \
        '{owner:"NodeForge",schema:1,version:$version,public_key:$public,server_ip:$ip,user_created:$user,
          config_sha256:$config,binary_sha256:$binary,unit_sha256:$unit,license_sha256:$license}' > "$NF_WORK/state.json"
    atomic_install "$NF_WORK/state.json" "$NF_STATE" 600 root root
}
