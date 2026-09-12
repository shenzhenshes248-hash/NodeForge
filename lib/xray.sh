#!/usr/bin/env bash
set -Eeuo pipefail

download_https() {
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 180 --retry 2 --output "$2" "$1"
}
verify_checksum() {
    local archive=$1 checksum=$2 expected actual
    # Official v26.9.9 .dgst format, exactly one SHA2-256 line required.
    expected=$(awk '/^SHA2-256= / { print $2; count++ } END { if (count != 1) exit 1 }' "$checksum") || die 'Missing or ambiguous official SHA2-256 checksum'
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die 'Malformed official SHA-256 checksum'
    actual=$(sha256_file "$archive")
    [[ ${expected,,} == "$actual" ]] || die 'Xray checksum mismatch'
}
fetch_xray() {
    local version=$1 asset url
    [[ $version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die 'Invalid Xray version tag'
    asset=Xray-linux-$NF_ARCH.zip
    url=https://github.com/XTLS/Xray-core/releases/download/$version/$asset
    info "Downloading official Xray $version ($NF_ARCH)"
    download_https "$url" "$NF_WORK/xray.zip"
    download_https "$url.dgst" "$NF_WORK/xray.zip.dgst"
    verify_checksum "$NF_WORK/xray.zip" "$NF_WORK/xray.zip.dgst"
    # Extract named data only, never arbitrary archive paths or scripts.
    [[ $(unzip -Z1 "$NF_WORK/xray.zip" | awk '$0 == "xray" {n++} END {print n+0}') == 1 ]] || die 'Release must contain exactly one xray binary'
    unzip -p "$NF_WORK/xray.zip" xray > "$NF_WORK/xray"
    unzip -p "$NF_WORK/xray.zip" LICENSE > "$NF_WORK/LICENSE.xray"
    [[ -s $NF_WORK/LICENSE.xray ]] || die 'Release license is missing'
    chmod 755 "$NF_WORK/xray"
    "$NF_WORK/xray" version > "$NF_WORK/version.txt"
    grep -q "^Xray ${version#v} " "$NF_WORK/version.txt" || die 'Binary version differs from selected Release'
    NF_CANDIDATE_BIN=$NF_WORK/xray
    NF_CANDIDATE_LICENSE=$NF_WORK/LICENSE.xray
}
generate_identity() {
    NF_UUID=$("$NF_CANDIDATE_BIN" uuid)
    "$NF_CANDIDATE_BIN" x25519 > "$NF_WORK/key-output"
    chmod 600 "$NF_WORK/key-output"
    NF_PRIVATE_KEY=$(sed -n 's/^PrivateKey: //p' "$NF_WORK/key-output")
    NF_PUBLIC_KEY=$(sed -n 's/^Password (PublicKey): //p' "$NF_WORK/key-output")
    [[ $NF_PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $NF_PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Unexpected Xray x25519 output; unsupported CLI format'
    NF_SHORT_ID=$(openssl rand -hex 8)
    rm -f -- "$NF_WORK/key-output"
}
test_xray_config() {
    local binary=$1 config=$2
    # Raw core errors may contain configuration values; keep them out of logs.
    if ! "$binary" run -test -config "$config" > "$NF_WORK/config-test.log" 2>&1; then
        die 'Xray rejected the candidate configuration (raw output suppressed to protect secrets)'
    fi
}
