#!/usr/bin/env bash
set -Eeuo pipefail
set +x
set +a
unset NF_PRIVATE_KEY NF_PUBLIC_KEY
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
NF_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$NF_SOURCE/lib/common.sh"
load_modules
main() {
    local dry_run=0
    case ${1:-} in
        '') ;;
        --dry-run) dry_run=1 ;;
        *) die 'Usage: bash install.sh [--dry-run]' ;;
    esac
    (( $# <= 1 )) || die 'Too many arguments'
    preflight
    if (( dry_run )); then
        info "Preflight passed: $NF_OS $NF_OS_VERSION / $NF_ARCH"
        info 'Would install dependencies, verify official Xray, validate target/config, then commit service.'
        return
    fi
    acquire_lock
    install_dependencies
    init_workspace
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'log ERROR "Installation failed at line $LINENO (command and secrets suppressed)"' ERR
    install_nodeforge
}
main "$@"
