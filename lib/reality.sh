#!/usr/bin/env bash
set -Eeuo pipefail

valid_hostname() {
    local name=$1 label
    [[ ${#name} -le 253 && $name == *.* && $name != *..* ]] || return 1
    local -a labels
    IFS='.' read -r -a labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
    [[ $name != *. ]]
}
parse_reality_target() {
    local target=$1
    if [[ $target =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
        NF_TARGET_HOST=${BASH_REMATCH[1]} NF_TARGET_PORT=${BASH_REMATCH[2]}
    elif [[ $target =~ ^([a-zA-Z0-9.-]+):([0-9]+)$ ]]; then
        NF_TARGET_HOST=${BASH_REMATCH[1]} NF_TARGET_PORT=${BASH_REMATCH[2]}
        valid_hostname "$NF_TARGET_HOST" || die 'Invalid target hostname'
    else
        die 'REALITY target must be host:port or [IPv6]:port'
    fi
    if [[ ! $NF_TARGET_PORT =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$NF_TARGET_PORT > 65535 )); then
        die 'Invalid target port'
    fi
}
validate_reality_target() {
    parse_reality_target "$NF_TARGET"
    valid_hostname "$NF_SNI" || die 'SNI must be an explicit DNS hostname without wildcards'
    [[ ! $NF_SNI =~ ^[0-9.]+$ ]] || die 'SNI must be a DNS hostname, not an IP literal'
    timeout 15 python3 "$NF_SOURCE/lib/network.py" target-addresses "$NF_TARGET_HOST" "$NF_TARGET_PORT" || die 'Target DNS/public-address validation failed'
    if ! timeout 20 openssl s_client -connect "$NF_TARGET" -servername "$NF_SNI" \
        -tls1_3 -alpn h2 -verify_hostname "$NF_SNI" -verify_return_error \
        -CApath /etc/ssl/certs < /dev/null > "$NF_WORK/target-test.log" 2>&1; then
        die 'REALITY target failed TLS 1.3/certificate validation; set NODEFORGE_REALITY_TARGET and NODEFORGE_SERVER_NAME'
    fi
    grep -q 'ALPN protocol: h2' "$NF_WORK/target-test.log" || die 'REALITY target must negotiate HTTP/2'
}
