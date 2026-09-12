#!/usr/bin/env bash
set -Eeuo pipefail

cli_help() {
    printf 'NodeForge %s\n\nUsage: nodeforge <command>\n\nCommands:\n  status\n  info\n  link\n  restart\n  uninstall\n  version\n' "$NF_NODEFORGE_VERSION"
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
    cmp -s "$NF_UNIT" "$NF_SOURCE/templates/nodeforge-xray.service" || die 'Unsupported managed service unit'
}
cli_status() {
    cli_load_state
    if ! managed_service_healthy; then die 'Status: unhealthy (service or owned listener validation failed)'; fi
    printf 'NodeForge: installed\nState schema: 1\nXray service: active\nListener: active\nStatus: healthy\n'
}
cli_info() {
    cli_load_state
    printf 'NodeForge version: %s\nState schema: 1\nXray version: %s\nService: %s\nProtocol: VLESS + TCP/RAW + REALITY + XTLS Vision\nListen: %s\nPort: %s\nConfig: %s\nState: %s\nBinary: %s\n' \
        "$NF_NODEFORGE_VERSION" "$NF_XRAY_VERSION" "$NF_SERVICE" "$NF_LISTEN" "$NF_PORT" "$NF_CONFIG" "$NF_STATE" "$NF_BIN"
    if managed_service_healthy; then printf 'Service/listener: healthy\n'
    else die 'Service/listener: unhealthy'; fi
}
cli_link() {
    cli_load_state
    node_link
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
    printf 'NodeForge: restarted; service and listener healthy\n'
}
cli_uninstall() {
    # Shared M1 uninstall transaction/ownership path; all modules already loaded.
    preflight uninstall
    [[ ! -e $NF_PENDING ]] || die 'Pending recovery requires the local source installer'
    if [[ -e $NF_STATE || -L $NF_STATE ]]; then cli_load_state; fi
    init_workspace
    trap cleanup EXIT
    uninstall_nodeforge
}
cli_main() {
    (( $# <= 1 )) || die 'Usage: nodeforge <command>'
    case ${1:-} in
        ''|help|--help) cli_help; return ;;
        version) printf 'NodeForge %s\n' "$NF_NODEFORGE_VERSION"; return ;;
        status|info|link|restart|uninstall) ;;
        *) die 'Unknown command; use nodeforge --help' ;;
    esac
    cli_require_root
    local command=$1
    case $command in
        status|info|link) acquire_lock shared ;;
        restart|uninstall) acquire_lock ;;
    esac
    # Literal dispatch only; no state-controlled targets, paths, or function names.
    case $command in
        status) cli_status ;; info) cli_info ;; link) cli_link ;;
        restart) cli_restart ;; uninstall) cli_uninstall ;;
    esac
}
