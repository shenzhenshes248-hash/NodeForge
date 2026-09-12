#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
NF_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/common.sh
source "$NF_SOURCE/lib/common.sh"
load_modules
init_workspace
trap cleanup EXIT
detect_platform /etc/os-release "$(uname -m)"
fetch_xray "$NF_DEFAULT_VERSION"
generate_identity
NF_PORT=23456 NF_TARGET=www.microsoft.com:443 NF_SNI=www.microsoft.com NF_LISTEN=0.0.0.0
validate_uuid "$NF_UUID"
validate_short_id "$NF_SHORT_ID"
generate_config "$NF_WORK/config.json"
test_xray_config "$NF_CANDIDATE_BIN" "$NF_WORK/config.json"
printf 'PASS official Release checksum, UUID/X25519 CLI and real configuration validation\n'
