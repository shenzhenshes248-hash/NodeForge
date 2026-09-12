#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
NF_UUID=123e4567-e89b-42d3-a456-426614174000 NF_PORT=23456 NF_TARGET=example.com:443 NF_SNI=example.com
NF_SHORT_ID=0123456789abcdef NF_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA NF_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB NF_LISTEN=0.0.0.0
generate_config "$NF_WORK/generated.json"
jq -e '.inbounds[0] | .port == 23456 and .protocol == "vless" and .settings.decryption == "none" and
  .settings.clients[0].flow == "xtls-rprx-vision" and .streamSettings.network == "raw" and
  .streamSettings.security == "reality" and .streamSettings.realitySettings.serverNames == ["example.com"] and
  .streamSettings.realitySettings.shortIds == ["0123456789abcdef"]' "$NF_WORK/generated.json" >/dev/null
assert_eq 600 "$(stat -c %a "$NF_WORK/generated.json")"
[[ ! -e $NF_WORK/private-key ]]
NF_SNI='example.com", "injected":true'
generate_config "$NF_WORK/escaped.json"
assert_eq "$NF_SNI" "$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$NF_WORK/escaped.json")"
NF_SERVER_IP=2001:4860:4860::8888 NF_SNI=example.com
print_node > "$NF_WORK/output" 2>&1
assert_fails grep -q "$NF_PRIVATE_KEY" "$NF_WORK/output"
grep -Fq '@[2001:4860:4860::8888]:23456?' "$NF_WORK/output"
grep -Fq 'pbk=BBBBB' "$NF_WORK/output"
printf 'PASS config and sharing\n'
