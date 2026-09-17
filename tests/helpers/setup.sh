#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
NF_SOURCE=${NF_SOURCE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
# shellcheck source=lib/common.sh
source "$NF_SOURCE/lib/common.sh"
load_modules
# shellcheck source=tests/helpers/assertions.sh
source "$NF_SOURCE/tests/helpers/assertions.sh"
NF_TEST_ROOT=$(mktemp -d)
export NF_TEST_ROOT
NF_BIN_DIR=$NF_TEST_ROOT/usr/local/nodeforge
NF_CONFIG_DIR=$NF_TEST_ROOT/etc/nodeforge
NF_DATA_DIR=$NF_TEST_ROOT/var/lib/nodeforge
NF_BIN=$NF_BIN_DIR/bin/xray
NF_LICENSE=$NF_BIN_DIR/LICENSE.xray
NF_CONFIG=$NF_CONFIG_DIR/xray.json
NF_STATE=$NF_DATA_DIR/state.json
NF_PENDING=$NF_DATA_DIR/pending
NF_UNIT=$NF_TEST_ROOT/etc/systemd/system/nodeforge-xray.service
NF_HYSTERIA_UNIT=$NF_TEST_ROOT/etc/systemd/system/nodeforge-hysteria.service
NF_HYSTERIA_BIN=$NF_BIN_DIR/bin/hysteria
NF_HYSTERIA_CONFIG=$NF_CONFIG_DIR/hysteria.yaml
NF_HYSTERIA_CERT=$NF_CONFIG_DIR/hysteria.crt
NF_HYSTERIA_KEY=$NF_CONFIG_DIR/hysteria.key
NF_HYSTERIA_STATE=$NF_DATA_DIR/hysteria.json
NF_CLI=$NF_TEST_ROOT/usr/local/bin/nodeforge
mkdir -p "$(dirname "$NF_UNIT")"
init_workspace
trap 'rm -rf -- "$NF_TEST_ROOT" "$NF_WORK"' EXIT
unset NODEFORGE_PORT NODEFORGE_UUID NODEFORGE_SHORT_ID NODEFORGE_REALITY_TARGET NODEFORGE_SERVER_NAME NODEFORGE_SERVER_IP NODEFORGE_XRAY_VERSION
