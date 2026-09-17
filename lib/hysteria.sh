#!/usr/bin/env bash
set -Eeuo pipefail

hysteria_asset() {
    case $NF_ARCH in
        64) printf 'hysteria-linux-amd64\n' ;;
        arm64-v8a) printf 'hysteria-linux-arm64\n' ;;
        *) die 'Unsupported Hysteria architecture' ;;
    esac
}

hysteria_checksum() {
    case $NF_ARCH in
        64) printf '8c7a68a906998b747a0db87586e364f995fbfddb95693ae6e2fdb68a6e920d3e\n' ;;
        arm64-v8a) printf 'c8dc653c3ba0a28d29a26b8fa52d2086f27c0927afddce95c09965e7174e78b0\n' ;;
        *) die 'Unsupported Hysteria architecture' ;;
    esac
}

fetch_hysteria() {
    local version=$1 asset expected actual binary_version
    [[ $version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die 'Invalid Hysteria version tag'
    asset=$(hysteria_asset)
    info "Downloading official Hysteria $version ($asset)"
    download_https "https://github.com/HyNetworks/hysteria/releases/download/app/$version/$asset" "$NF_WORK/hysteria"
    expected=$(hysteria_checksum)
    actual=$(sha256_file "$NF_WORK/hysteria")
    [[ $actual == "$expected" ]] || die 'Hysteria checksum mismatch'
    chmod 755 "$NF_WORK/hysteria"
    "$NF_WORK/hysteria" version > "$NF_WORK/hysteria-version"
    binary_version=$(awk '$1 == "Version:" {print $2; count++} END {if (count != 1) exit 1}' "$NF_WORK/hysteria-version") || die 'Unexpected Hysteria version output'
    [[ $binary_version == "$version" ]] || die 'Hysteria binary version differs from selected Release'
    NF_HYSTERIA_CANDIDATE_BIN=$NF_WORK/hysteria
}

hysteria_pin() {
    openssl x509 -in "$1" -outform DER | sha256sum | awk '{print $1}'
}

generate_hysteria_identity() {
    NF_HYSTERIA_PASSWORD=$(openssl rand -hex 16)
    [[ $NF_HYSTERIA_PASSWORD =~ ^[0-9a-f]{32}$ ]] || die 'Failed to generate Hysteria password'
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$NF_WORK/hysteria.key" -out "$NF_WORK/hysteria.crt" \
        -subj "/CN=$NF_SERVER_IP" -addext "subjectAltName=IP:$NF_SERVER_IP" >/dev/null 2>&1
    chmod 600 "$NF_WORK/hysteria.key" "$NF_WORK/hysteria.crt"
    NF_HYSTERIA_PIN=$(hysteria_pin "$NF_WORK/hysteria.crt")
    [[ $NF_HYSTERIA_PIN =~ ^[0-9a-f]{64}$ ]] || die 'Failed to derive Hysteria certificate pin'
    NF_HYSTERIA_CANDIDATE_CERT=$NF_WORK/hysteria.crt
    NF_HYSTERIA_CANDIDATE_KEY=$NF_WORK/hysteria.key
}

generate_hysteria_config() {
    cat > "$NF_WORK/hysteria.yaml" <<EOF
listen: :$NF_HYSTERIA_LISTEN
tls:
  cert: $NF_HYSTERIA_CERT
  key: $NF_HYSTERIA_KEY
auth:
  type: password
  password: $NF_HYSTERIA_PASSWORD
EOF
    chmod 600 "$NF_WORK/hysteria.yaml"
    NF_HYSTERIA_CANDIDATE_CONFIG=$NF_WORK/hysteria.yaml
}

load_hysteria() {
    local path expected actual
    require_regular "$NF_HYSTERIA_STATE"
    jq -e --arg listen "$NF_HYSTERIA_LISTEN" --arg ports "$NF_HYSTERIA_PORTS" \
      '.owner == "NodeForge" and .schema == 1 and (.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
       .listen == $listen and .ports == $ports and
       (.password | test("^[A-Za-z0-9]{32}$")) and (.pin_sha256 | test("^[0-9a-f]{64}$"))' \
      "$NF_HYSTERIA_STATE" >/dev/null || die 'Invalid Hysteria ownership record'
    # Assigned by init_paths in lib/defaults.sh.
    # shellcheck disable=SC2153
    for path in "$NF_HYSTERIA_BIN" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY" "$NF_HYSTERIA_UNIT"; do
        require_regular "$path"
    done
    for path in binary config cert key unit; do
        expected=$(jq -er ".${path}_sha256" "$NF_HYSTERIA_STATE")
        case $path in
            binary) actual=$(sha256_file "$NF_HYSTERIA_BIN") ;;
            config) actual=$(sha256_file "$NF_HYSTERIA_CONFIG") ;;
            cert) actual=$(sha256_file "$NF_HYSTERIA_CERT") ;;
            key) actual=$(sha256_file "$NF_HYSTERIA_KEY") ;;
            unit) actual=$(sha256_file "$NF_HYSTERIA_UNIT") ;;
        esac
        [[ $expected == "$actual" ]] || die "Installed Hysteria $path differs from recorded checksum"
    done
    NF_HYSTERIA_VERSION=$(jq -er '.version' "$NF_HYSTERIA_STATE")
    NF_HYSTERIA_PASSWORD=$(jq -er '.password' "$NF_HYSTERIA_STATE")
    NF_HYSTERIA_PIN=$(jq -er '.pin_sha256' "$NF_HYSTERIA_STATE")
    [[ $(hysteria_pin "$NF_HYSTERIA_CERT") == "$NF_HYSTERIA_PIN" ]] || die 'Hysteria certificate pin mismatch'
    NF_HYSTERIA_CANDIDATE_BIN=$NF_HYSTERIA_BIN
    NF_HYSTERIA_CANDIDATE_CONFIG=$NF_HYSTERIA_CONFIG
    NF_HYSTERIA_CANDIDATE_CERT=$NF_HYSTERIA_CERT
    NF_HYSTERIA_CANDIDATE_KEY=$NF_HYSTERIA_KEY
    NF_HYSTERIA_EXISTING=1
}

prepare_hysteria() {
    local path
    if [[ -f $NF_HYSTERIA_STATE ]]; then
        load_hysteria
        return
    fi
    for path in "$NF_HYSTERIA_BIN" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY" "$NF_HYSTERIA_UNIT"; do
        [[ ! -e $path ]] || die "Unmanaged Hysteria path exists: $path"
    done
    udp_port_available "$NF_HYSTERIA_PORT" || die 'UDP port 443 is already occupied'
    NF_HYSTERIA_VERSION=$NF_DEFAULT_HYSTERIA_VERSION
    fetch_hysteria "$NF_HYSTERIA_VERSION"
    generate_hysteria_identity
    generate_hysteria_config
}

write_hysteria_state() {
    jq -n --arg version "$NF_HYSTERIA_VERSION" --arg password "$NF_HYSTERIA_PASSWORD" \
      --arg pin "$NF_HYSTERIA_PIN" --arg listen "$NF_HYSTERIA_LISTEN" --arg ports "$NF_HYSTERIA_PORTS" \
      --arg binary "$(sha256_file "$NF_HYSTERIA_BIN")" --arg config "$(sha256_file "$NF_HYSTERIA_CONFIG")" \
      --arg cert "$(sha256_file "$NF_HYSTERIA_CERT")" --arg key "$(sha256_file "$NF_HYSTERIA_KEY")" \
      --arg unit "$(sha256_file "$NF_HYSTERIA_UNIT")" \
      '{owner:"NodeForge",schema:1,version:$version,password:$password,pin_sha256:$pin,
        listen:$listen,ports:$ports,binary_sha256:$binary,
        config_sha256:$config,cert_sha256:$cert,key_sha256:$key,unit_sha256:$unit}' > "$NF_WORK/hysteria-state.json"
    atomic_install "$NF_WORK/hysteria-state.json" "$NF_HYSTERIA_STATE" 600 root root
}

install_hysteria() {
    if [[ $NF_HYSTERIA_EXISTING == 0 ]]; then
        atomic_install "$NF_HYSTERIA_CANDIDATE_BIN" "$NF_HYSTERIA_BIN" 755 root root
        atomic_install "$NF_HYSTERIA_CANDIDATE_CONFIG" "$NF_HYSTERIA_CONFIG" 600 root root
        atomic_install "$NF_HYSTERIA_CANDIDATE_CERT" "$NF_HYSTERIA_CERT" 644 root root
        atomic_install "$NF_HYSTERIA_CANDIDATE_KEY" "$NF_HYSTERIA_KEY" 600 root root
        atomic_install "$NF_SOURCE/templates/nodeforge-hysteria.service" "$NF_HYSTERIA_UNIT" 644 root root
        write_hysteria_state
        activate_hysteria_service
    else
        systemctl enable "$NF_HYSTERIA_SERVICE"
        systemctl start "$NF_HYSTERIA_SERVICE"
        check_hysteria_health
    fi
}
