#!/usr/bin/env bash
set -Eeuo pipefail

init_paths() {
    NF_BIN_DIR=/usr/local/nodeforge
    NF_CONFIG_DIR=/etc/nodeforge
    NF_DATA_DIR=/var/lib/nodeforge
    NF_UNIT=/etc/systemd/system/nodeforge-xray.service
    NF_BIN=$NF_BIN_DIR/bin/xray
    NF_LICENSE=$NF_BIN_DIR/LICENSE.xray
    NF_CONFIG=$NF_CONFIG_DIR/xray.json
    NF_STATE=$NF_DATA_DIR/state.json
    NF_PENDING=$NF_DATA_DIR/pending
    NF_DEFAULT_XRAY_VERSION=v26.9.9
    NF_DEFAULT_TARGET=www.microsoft.com:443
    NF_DEFAULT_SNI=www.microsoft.com
    NF_SERVICE=nodeforge-xray.service
    NF_CLI=/usr/local/bin/nodeforge
    NF_TRANSACTION=0
    NF_EXISTING=0
}
