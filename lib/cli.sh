#!/usr/bin/env bash
set -Eeuo pipefail

cli_help() {
    printf 'NodeForge %s\n\nUsage: nodeforge <command>\n\nCommands:\n  status\n  info\n  link\n  argo-edge <address|"">\n  warp <enable|disable|status>\n  restart\n  uninstall\n  update\n  xray-update\n  version\n' "$NF_NODEFORGE_VERSION"
}
cli_require_root() { (( EUID == 0 )) || die 'NodeForge: this command must be run as root'; }
cli_load_state() {
    check_paths
    check_directory_permissions
    [[ ! -e $NF_PENDING ]] || die 'Unfinished installation; management unavailable until installer recovery'
    [[ -f $NF_STATE && -r $NF_STATE ]] || die 'NodeForge: state unavailable; status unhealthy'
    state_schema_supported "$NF_STATE" || die 'Unsupported or invalid NodeForge state schema'
    python3 "$NF_SOURCE/lib/management.py" state "$NF_STATE" "$NF_CONFIG" "$NF_SOURCE/templates/vless-reality.json" || die 'NodeForge: invalid state/config; status unhealthy'
    load_existing
    load_hysteria
    cmp -s "$NF_UNIT" "$NF_SOURCE/templates/nodeforge-xray.service" || die 'Unsupported managed service unit'
    cmp -s "$NF_HYSTERIA_UNIT" "$NF_SOURCE/templates/nodeforge-hysteria.service" || die 'Unsupported managed Hysteria service unit'
}
cli_status() {
    cli_load_state
    if ! managed_service_healthy; then die 'Status: unhealthy (service or owned listener validation failed)'; fi
    if ! managed_hysteria_healthy; then die 'Status: unhealthy (Hysteria service or owned listener validation failed)'; fi
    printf 'NodeForge: installed\nState schema: 1\nXray service: active\nHysteria service: active\nTCP listener: active\nUDP listener: active\nStatus: healthy\n'
    argo_status
}
cli_info() {
    cli_load_state
    printf 'NodeForge version: %s\nState schema: 1\nXray version: %s\nXray service: %s\nReality protocol: VLESS + TCP/RAW + REALITY + XTLS Vision\nReality listen: %s\nReality port: %s\nHysteria version: %s\nHysteria service: %s\nHysteria UDP port: %s\nHysteria port hopping: %s\nHysteria client hop interval: %ss (v2rayN default)\nReality config: %s\nHysteria config: %s\nState: %s\nXray binary: %s\nHysteria binary: %s\n' \
        "$NF_NODEFORGE_VERSION" "$NF_XRAY_VERSION" "$NF_SERVICE" "$NF_LISTEN" "$NF_PORT" \
        "$NF_HYSTERIA_VERSION" "$NF_HYSTERIA_SERVICE" "$NF_HYSTERIA_PORT" "$NF_HYSTERIA_PORTS" \
        "$NF_HYSTERIA_CLIENT_HOP_INTERVAL" "$NF_CONFIG" "$NF_HYSTERIA_CONFIG" "$NF_STATE" "$NF_BIN" "$NF_HYSTERIA_BIN"
    if managed_service_healthy && managed_hysteria_healthy; then printf 'Services/listeners: healthy\n'
    else die 'Services/listeners: unhealthy'; fi
    argo_status
}
cli_link() {
    cli_load_state
    node_link
    hysteria_link
    argo_link
    subscription_link
}
cli_restart() {
    cli_load_state
    managed_service_loaded || die 'Managed systemd service is unavailable'
    # Test the exact final configuration as the service account; no raw diagnostics.
    if ! timeout 20 runuser -u nodeforge -- "$NF_BIN" run -test -config "$NF_CONFIG" >/dev/null 2>&1; then
        die 'Xray configuration test failed; service was not restarted'
    fi
    timeout 30 systemctl restart "$NF_SERVICE" >/dev/null 2>&1 || die 'Xray restart failed or timed out'
    wait_managed_service || die 'Xray post-restart validation failed'
    timeout 30 systemctl restart "$NF_HYSTERIA_SERVICE" >/dev/null 2>&1 || die 'Hysteria restart failed or timed out'
    managed_hysteria_healthy || die 'Hysteria post-restart validation failed'
    printf 'NodeForge: restarted; services and listeners healthy\n'
    argo_paths
    if [[ -d $NF_ARGO_DIR ]]; then
        if (load_argo); then
            timeout 30 systemctl restart "$NF_ARGO_XRAY_SERVICE" "$NF_ARGO_SERVICE" || warn 'Argo restart failed; Reality/HY2 restarted successfully'
        else warn 'Argo state invalid; skipped Argo restart'; fi
    fi
}
cli_uninstall() {
    # Shared M1 uninstall transaction/ownership path; all modules already loaded.
    preflight uninstall
    [[ ! -e $NF_PENDING ]] || die 'Pending recovery requires the local source installer'
    if [[ -e $NF_STATE || -L $NF_STATE || -e $NF_HYSTERIA_STATE || -L $NF_HYSTERIA_STATE ]]; then cli_load_state; fi
    init_workspace
    trap cleanup EXIT
    uninstall_nodeforge
}
cli_main() {
    if [[ ${1:-} == warp ]]; then
        (( $# == 2 )) || die 'Usage: nodeforge warp <enable|disable|status>'
        case $2 in enable|disable|status) ;; *) die 'Usage: nodeforge warp <enable|disable|status>' ;; esac
        cli_require_root
        if [[ $2 == status ]]; then acquire_lock shared; else acquire_lock; fi
        cli_warp "$2"
        return
    fi
    if [[ ${1:-} == argo-edge ]]; then
        (( $# == 2 )) || die 'Usage: nodeforge argo-edge <address|"">'
        cli_require_root
        acquire_lock
        cli_argo_edge "$2"
        return
    fi
    (( $# <= 1 )) || die 'Usage: nodeforge <command>'
    case ${1:-} in
        ''|help|--help) cli_help; return ;;
        version) printf 'NodeForge %s\n' "$NF_NODEFORGE_VERSION"; return ;;
        status|info|link|subscription-content|restart|uninstall|update|xray-update) ;;
        *) die 'Unknown command; use nodeforge --help' ;;
    esac
    cli_require_root
    local command=$1
    case $command in
        status|info|link|subscription-content) acquire_lock shared ;;
        restart|uninstall|update|xray-update) acquire_lock ;;
    esac
    # Literal dispatch only; no state-controlled targets, paths, or function names.
    case $command in
        status) cli_status ;; info) cli_info ;; link) cli_link ;;
        subscription-content) subscription_content ;;
        restart) cli_restart ;; uninstall) cli_uninstall ;; update) cli_update ;;
        xray-update) cli_xray_update ;;
    esac
}
