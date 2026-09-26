#!/usr/bin/env bash
# Staged validation intentionally changes paths only inside its subshell.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

cli_help() {
    printf 'NodeForge %s\n\nUsage: nodeforge <command>\n\nCommands:\n  status\n  doctor\n  info\n  link\n  argo-edge <address|"">\n  warp <enable|disable|status>\n  logs [reality|hy2|argo|warp] [-f]\n  backup\n  restore <backup-file>\n  restart\n  uninstall\n  update\n  rollback\n  xray-update\n  version\n' "$NF_NODEFORGE_VERSION"
}
cli_require_root() { (( EUID == 0 )) || die 'NodeForge: this command must be run as root'; }
cli_load_state() {
    check_paths
    check_directory_permissions
    [[ ! -e $NF_PENDING ]] || die 'Unfinished installation; management unavailable until installer recovery'
    [[ ! -e $NF_DATA_DIR/maintenance-restore || ${NF_MAINTENANCE_VALIDATING:-0} == 1 ]] || die 'Restore recovery pending; rerun nodeforge restore <backup-file>'
    [[ -f $NF_STATE && -r $NF_STATE ]] || die 'NodeForge: state unavailable; status unhealthy'
    state_schema_supported "$NF_STATE" || die 'Unsupported or invalid NodeForge state schema'
    python3 "$NF_SOURCE/lib/management.py" state "$NF_STATE" "$NF_CONFIG" "$NF_SOURCE/templates/vless-reality.json" || die 'NodeForge: invalid state/config; status unhealthy'
    load_existing
    load_hysteria
    cmp -s "$NF_UNIT" "$NF_SOURCE/templates/nodeforge-xray.service" || die 'Unsupported managed service unit'
    cmp -s "$NF_HYSTERIA_UNIT" "$NF_SOURCE/templates/nodeforge-hysteria.service" || die 'Unsupported managed Hysteria service unit'
}
cli_status() { cli_diagnostics status; }
cli_doctor() { cli_diagnostics doctor; }
cli_info() {
    cli_load_state
    # NF_HYSTERIA_PORT is assigned by init_paths in defaults.sh.
    # shellcheck disable=SC2153
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
    if [[ ${1:-} == logs ]]; then
        (( $# <= 3 )) || die 'Usage: nodeforge logs [reality|hy2|argo|warp] [-f]'
        cli_require_root
        shift
        cli_logs "$@"
        return
    fi
    if [[ ${1:-} == restore ]]; then
        (( $# == 2 )) || die 'Usage: nodeforge restore <backup-file>'
        cli_require_root
        acquire_lock
        cli_restore "$2"
        return
    fi
    if [[ ${1:-} == backup ]]; then
        (( $# == 1 )) || die 'Usage: nodeforge backup'
        cli_require_root
        acquire_lock
        cli_backup
        return
    fi
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
        status|doctor|info|link|subscription-content|restart|uninstall|update|rollback|xray-update) ;;
        *) die 'Unknown command; use nodeforge --help' ;;
    esac
    cli_require_root
    local command=$1
    case $command in
        status|doctor|info|link|subscription-content) acquire_lock shared ;;
        restart|uninstall|update|rollback|xray-update) acquire_lock ;;
    esac
    # Literal dispatch only; no state-controlled targets, paths, or function names.
    case $command in
        status) cli_status ;; doctor) cli_doctor ;; info) cli_info ;; link) cli_link ;;
        subscription-content) subscription_content ;;
        restart) cli_restart ;; uninstall) cli_uninstall ;; update) cli_update ;; rollback) cli_rollback ;;
        xray-update) cli_xray_update ;;
    esac
}

cli_logs() {
    local target=${1:-all} follow=${2:-} service load
    local -a services=() args=(--no-pager -n 100)
    [[ $target != -f ]] || { target=all; follow=-f; }
    [[ -z $follow || $follow == -f ]] || die 'Usage: nodeforge logs [reality|hy2|argo|warp] [-f]'
    case $target in
        all) services=("$NF_SERVICE" "$NF_HYSTERIA_SERVICE" nodeforge-argo.service warp-svc.service) ;;
        reality) services=("$NF_SERVICE") ;; hy2) services=("$NF_HYSTERIA_SERVICE") ;;
        argo) services=(nodeforge-argo.service) ;; warp) services=(warp-svc.service) ;;
        *) die 'Usage: nodeforge logs [reality|hy2|argo|warp] [-f]' ;;
    esac
    for service in "${services[@]}"; do
        load=$(systemctl show "$service" -p LoadState --value 2>/dev/null) || load=not-found
        if [[ $load == loaded ]]; then args+=(-u "$service")
        else printf 'NodeForge: service unavailable: %s\n' "$service" >&2; fi
    done
    (( ${#args[@]} > 3 )) || return 1
    [[ -z $follow ]] || args+=(-f)
    journalctl "${args[@]}"
}

# Fixed logical inventory derived from the existing modules, never archive paths.
maintenance_paths() {
    argo_paths
    subscription_paths
    NF_WARP_STATE=$NF_DATA_DIR/warp.json
    maintenance_names=(reality-config reality-state hy2-config hy2-state hy2-cert hy2-key
        argo-config argo-state argo-tunnel argo-credentials warp-state subscription argo-edge)
    maintenance_files=("$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE"
        "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY" "$NF_ARGO_DIR/xray.json" "$NF_ARGO_DIR/state.json"
        "$NF_ARGO_DIR/cloudflared.yml" "$NF_ARGO_DIR/credentials.json" "$NF_WARP_STATE"
        "$NF_SUB_CONFIG" "$NF_CONFIG_DIR/argo-edge.json")
}

maintenance_check_paths() {
    local path parent
    for path in "${maintenance_files[@]}"; do
        parent=$(dirname "$path")
        if [[ -e $parent || -L $parent ]]; then trusted_directory "$parent"; fi
        if [[ -e $path || -L $path ]]; then trusted_file "$path"; fi
    done
}

cli_backup() (
    cli_load_state
    maintenance_paths
    maintenance_check_paths
    warp_load
    [[ ! -d $NF_ARGO_DIR ]] || load_argo
    [[ ! -f $NF_SUB_CONFIG ]] || load_subscription
    local directory=$NF_DATA_DIR/backups output i
    [[ ! -L $directory ]] || die 'Unsafe backup directory'
    install -d -m 700 "$directory"
    trusted_directory "$directory"
    output=$directory/nodeforge-$(date -u +%Y%m%dT%H%M%SZ)-$$.tar.gz
    local -a pairs=()
    for i in "${!maintenance_names[@]}"; do pairs+=("${maintenance_names[$i]}" "${maintenance_files[$i]}"); done
    python3 "$NF_SOURCE/lib/management.py" backup-create "$output" "$NF_NODEFORGE_VERSION" "${pairs[@]}"
    printf 'NodeForge backup: %s\n' "$output"
)

maintenance_validate_stage() (
    local stage=$1 argo=$NF_ARGO_DIR file
    local NF_WORK=$stage
    NF_CONFIG=$stage/reality-config NF_STATE=$stage/reality-state
    NF_HYSTERIA_CONFIG=$stage/hy2-config NF_HYSTERIA_STATE=$stage/hy2-state
    NF_HYSTERIA_CERT=$stage/hy2-cert NF_HYSTERIA_KEY=$stage/hy2-key
    python3 "$NF_SOURCE/lib/management.py" state "$NF_STATE" "$NF_CONFIG" "$NF_SOURCE/templates/vless-reality.json"
    load_existing
    load_hysteria
    test_xray_config "$NF_BIN" "$NF_CONFIG"
    # Existing ownership loaders validate hashes against the installed binaries.
    if [[ -f $stage/argo-state ]]; then
        [[ -d $argo ]] || die 'Restore requires installed Argo runtime'
        mkdir "$stage/argo"
        for file in cloudflared xray runner.py; do cp -p "$argo/$file" "$stage/argo/$file"; done
        cp "$stage/argo-config" "$stage/argo/xray.json"
        cp "$stage/argo-state" "$stage/argo/state.json"
        cp "$stage/argo-tunnel" "$stage/argo/cloudflared.yml"
        [[ ! -f $stage/argo-credentials ]] || cp "$stage/argo-credentials" "$stage/argo/credentials.json"
        # Keep canonical service/unit paths while validating the staged inventory.
        # Invoked indirectly by the existing load_argo validator.
        # shellcheck disable=SC2329
        argo_paths() { NF_ARGO_DIR=$stage/argo; }
        load_argo
        test_xray_config "$argo/xray" "$stage/argo-config"
    elif [[ -d $argo ]]; then
        die 'Backup has no Argo state; restore requires matching installed components'
    fi
    python3 "$NF_SOURCE/lib/management.py" backup-validate "$stage" "$NF_CONFIG_DIR" "$argo" "$NF_SOURCE"
    if [[ -f $stage/subscription ]]; then
        [[ -f $NF_SUB_UNIT && -f $NF_SUB_DIR/server.py ]] || die 'Restore requires installed subscription runtime'
        cmp -s "$NF_SUB_UNIT" "$NF_SOURCE/templates/nodeforge-subscription.service"
    elif [[ -f $NF_SUB_UNIT ]]; then
        die 'Backup has no subscription configuration; restore requires matching installed components'
    fi
)

maintenance_warp_apply() {
    local attempt
    warp_load
    if [[ $NF_WARP_MODE == enabled ]]; then
        command -v warp-cli >/dev/null || die 'Restore requires existing official WARP installation/registration'
        warp_cli registration show >/dev/null || return 1
        timeout 30 systemctl start warp-svc.service >/dev/null || return 1
        warp_cli mode proxy >/dev/null || return 1
        warp_cli proxy port 40000 >/dev/null || return 1
        warp_cli tunnel protocol set MASQUE >/dev/null || return 1
        warp_cli connect >/dev/null || return 1
        for attempt in {1..15}; do
            [[ $(diagnostic_warp_connection enabled) != Connected ]] || return 0
            sleep 1
        done
        return 1
    elif command -v warp-cli >/dev/null; then
        warp_cli disconnect >/dev/null || return 1
    fi
}

maintenance_recover() {
    local i name result=0
    for i in "${maintenance_services[@]}"; do timeout 30 systemctl stop "$i" >/dev/null 2>&1 || return 1; done
    for i in "${!maintenance_names[@]}"; do
        name=${maintenance_names[$i]}
        if [[ -f $NF_RESTORE/old/$name ]]; then
            restore_snapshot_file "$NF_RESTORE/old/$name" "${maintenance_files[$i]}" || return 1
        elif [[ -f $NF_RESTORE/old/$name.absent ]]; then
            rm -f -- "${maintenance_files[$i]}" || return 1
        else return 1; fi
    done
    maintenance_warp_apply || result=1
    for i in "${maintenance_services[@]}"; do
        if [[ -f $NF_RESTORE/old/$i.active ]]; then
            timeout 30 systemctl restart "$i" >/dev/null 2>&1 || result=1
        else timeout 30 systemctl stop "$i" >/dev/null 2>&1 || result=1; fi
    done
    return "$result"
}

maintenance_restore_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -f $NF_RESTORE/ready ]]; then
        if ! maintenance_recover; then
            log ERROR "Restore recovery incomplete; original files retained at $NF_RESTORE; rerun restore to recover"
            exit 1
        fi
    fi
    rm -rf -- "$NF_RESTORE"
    exit "$status"
}

cli_restore() (
    cli_require_root
    check_paths
    check_directory_permissions
    [[ ! -e $NF_PENDING ]] || die 'Installer recovery is pending'
    maintenance_paths
    maintenance_check_paths
    NF_RESTORE=$NF_DATA_DIR/maintenance-restore
    maintenance_services=("$NF_SERVICE" "$NF_HYSTERIA_SERVICE")
    [[ ! -d $NF_ARGO_DIR ]] || maintenance_services+=("$NF_ARGO_XRAY_SERVICE" "$NF_ARGO_SERVICE")
    [[ ! -f $NF_SUB_UNIT ]] || maintenance_services+=("$NF_SUB_SERVICE")
    if [[ -e $NF_RESTORE || -L $NF_RESTORE ]]; then
        trusted_directory "$NF_RESTORE"
        [[ -f $NF_RESTORE/ready ]] || die "Incomplete staging retained at $NF_RESTORE; inspect before retrying"
        maintenance_recover || die "Cannot recover previous restore; originals retained at $NF_RESTORE"
        rm -rf -- "$NF_RESTORE"
    fi
    mkdir -m 700 "$NF_RESTORE"
    trap maintenance_restore_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    python3 "$NF_SOURCE/lib/management.py" backup-extract "$1" "$NF_RESTORE/stage"
    maintenance_validate_stage "$NF_RESTORE/stage"
    local i name mode group
    mkdir -m 700 "$NF_RESTORE/old"
    for i in "${!maintenance_names[@]}"; do
        name=${maintenance_names[$i]}
        if [[ -f ${maintenance_files[$i]} ]]; then cp -p "${maintenance_files[$i]}" "$NF_RESTORE/old/$name"
        else touch "$NF_RESTORE/old/$name.absent"; fi
    done
    for i in "${maintenance_services[@]}"; do
        if systemctl is-active --quiet "$i"; then touch "$NF_RESTORE/old/$i.active"; fi
    done
    touch "$NF_RESTORE/ready"
    for i in "${maintenance_services[@]}"; do timeout 30 systemctl stop "$i"; done
    for i in "${!maintenance_names[@]}"; do
        name=${maintenance_names[$i]}
        if [[ -f $NF_RESTORE/stage/$name ]]; then
            mode=600 group=root
            case $name in reality-config|argo-config|argo-tunnel|argo-credentials) mode=640 group=nodeforge ;; hy2-cert) mode=644 ;; esac
            atomic_install "$NF_RESTORE/stage/$name" "${maintenance_files[$i]}" "$mode" root "$group"
        else rm -f -- "${maintenance_files[$i]}"; fi
    done
    maintenance_warp_apply
    NF_MAINTENANCE_VALIDATING=1 cli_load_state
    [[ ! -d $NF_ARGO_DIR ]] || load_argo
    for i in "${maintenance_services[@]}"; do
        timeout 30 systemctl restart "$i"
        systemctl is-active --quiet "$i"
    done
    wait_managed_service
    managed_hysteria_healthy
    rm -- "$NF_RESTORE/ready"
    printf 'NodeForge: restored configuration, profile and identities; services healthy\n'
)
