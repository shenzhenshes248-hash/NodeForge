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
    local dry_run=0 argo_only=0 subscription_only=0
    case ${1:-} in
        '') ;;
        --dry-run) dry_run=1 ;;
        --argo) argo_only=1 ;;
        --subscription) subscription_only=1 ;;
        *) die 'Usage: bash install.sh [--dry-run|--argo|--subscription]' ;;
    esac
    (( $# <= 1 )) || die 'Too many arguments'
    preflight
    if (( dry_run )); then
        info "Preflight passed: $NF_OS $NF_OS_VERSION / $NF_ARCH"
        info 'Would install dependencies, verify official Xray/cloudflared, then install Reality, HY2 and independent Argo services.'
        return
    fi
    acquire_lock
    if (( ! argo_only && ! subscription_only )); then install_dependencies; fi
    init_workspace
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'log ERROR "Installation failed at line $LINENO (command and secrets suppressed)"' ERR
    if (( ! argo_only && ! subscription_only )); then install_nodeforge; fi
    if (( ! subscription_only )); then install_argo; fi
    install_subscription
}
main "$@"
