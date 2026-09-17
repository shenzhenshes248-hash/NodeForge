#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$1" "$2" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
die() { log ERROR "$*"; exit 1; }
load_modules() {
    local module
    for module in defaults version state system xray hysteria reality config service transaction share runtime update cli; do
        # Modules are linted individually by tests/run.sh.
        # shellcheck disable=SC1090,SC1091
        source "$NF_SOURCE/lib/$module.sh"
    done
    init_paths
    load_nodeforge_version
}
init_workspace() { NF_WORK=$(mktemp -d); chmod 700 "$NF_WORK"; }
cleanup() {
    local status=$?
    trap - EXIT ERR INT TERM
    if [[ ${NF_TRANSACTION:-0} == 1 ]]; then
        if ! rollback; then
            log ERROR 'Rollback incomplete; protected transaction retained for recovery.'
            status=1
        fi
    fi
    if [[ -n ${NF_WORK:-} && -d $NF_WORK && ! -L $NF_WORK ]]; then
        rm -rf -- "$NF_WORK"
    fi
    exit "$status"
}
sha256_file() { sha256sum -- "$1" | awk '{print $1}'; }
require_regular() { [[ -f $1 && ! -L $1 ]] || die "Not a regular managed file: $1"; }
