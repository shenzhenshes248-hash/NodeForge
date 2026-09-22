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
    local dry_run=0 argo_only=0 subscription_only=0 enable_warp=0
    NF_REQUESTED_PROFILE='' NF_ARGO_DOMAIN='' NF_ARGO_CREDENTIALS=''
    while (( $# )); do
        case $1 in
            --dry-run) dry_run=1; shift ;;
            --argo) argo_only=1; shift ;;
            --subscription) subscription_only=1; shift ;;
            --warp) enable_warp=1; shift ;;
            --profile)
                (( $# >= 2 )) || die 'Missing --profile value'
                case $2 in ws|xhttp) NF_REQUESTED_PROFILE=$2 ;; *) die 'Profile must be ws or xhttp' ;; esac
                shift 2 ;;
            --argo-domain|--argo-credentials)
                (( $# >= 2 )) || die "Missing $1 value"
                if [[ $1 == --argo-domain ]]; then NF_ARGO_DOMAIN=$2; else NF_ARGO_CREDENTIALS=$2; fi
                shift 2 ;;
            *) die 'Usage: bash install.sh [--dry-run|--argo|--subscription] [--profile ws|xhttp] [--warp] [--argo-domain HOST --argo-credentials FILE]' ;;
        esac
    done
    (( ! argo_only || ! subscription_only )) || die '--argo and --subscription cannot be combined'
    preflight
    if (( dry_run )); then
        argo_select_profile
        info "Preflight passed: $NF_OS $NF_OS_VERSION / $NF_ARCH"
        info "Would install Reality, HY2 and Argo profile $NF_PROFILE."
        if (( enable_warp )); then info 'Would enable WARP after installation.'; fi
        return
    fi
    acquire_lock
    argo_select_profile
    if (( ! argo_only && ! subscription_only )); then install_dependencies; fi
    if (( ! subscription_only )); then argo_profile_validate; fi
    init_workspace
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'log ERROR "Installation failed at line $LINENO (command and secrets suppressed)"' ERR
    if (( ! argo_only && ! subscription_only )); then install_nodeforge; fi
    if (( ! subscription_only )); then install_argo; fi
    install_subscription
    if (( enable_warp )); then warp_switch enabled; fi
}
main "$@"
