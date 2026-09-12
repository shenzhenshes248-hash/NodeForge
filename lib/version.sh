#!/usr/bin/env bash
set -Eeuo pipefail

load_nodeforge_version() {
    require_regular "$NF_SOURCE/VERSION"
    NF_NODEFORGE_VERSION=$(cat -- "$NF_SOURCE/VERSION")
    [[ $NF_NODEFORGE_VERSION =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-dev)?$ ]] || die 'Invalid NodeForge VERSION file'
}
