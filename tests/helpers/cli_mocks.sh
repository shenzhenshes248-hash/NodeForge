#!/usr/bin/env bash
set -Eeuo pipefail
source "$NF_SOURCE/tests/helpers/mocks.sh"

# Fixture service queries supplement the M1 mutations, with no host access.
systemctl() {
    printf '%s\n' "$*" >> "$NF_TEST_ROOT/systemctl.calls"
    case $1 in
        show)
            [[ ( $2 == "$NF_SERVICE" || $2 == "$NF_HYSTERIA_SERVICE" ) && $3 == -p && $5 == --value ]] || return 1
            local marker=active unit=$NF_UNIT pid=12345
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then marker=hysteria-active unit=$NF_HYSTERIA_UNIT pid=22345; fi
            case $4 in
                LoadState) if [[ -f $NF_TEST_ROOT/missing-service ]]; then printf 'not-found\n'; else printf 'loaded\n'; fi ;;
                FragmentPath) if [[ -f $NF_TEST_ROOT/wrong-unit ]]; then printf '/unknown.service\n'; else printf '%s\n' "$unit"; fi ;;
                ActiveState) if [[ -f $NF_TEST_ROOT/$marker ]]; then printf 'active\n'; else printf 'inactive\n'; fi ;;
                SubState) if [[ -f $NF_TEST_ROOT/$marker ]]; then printf 'running\n'; else printf 'dead\n'; fi ;;
                MainPID) if [[ -f $NF_TEST_ROOT/zero-pid ]]; then printf '0\n'; else printf '%s\n' "$pid"; fi ;;
                DropInPaths) if [[ -f $NF_TEST_ROOT/dropin ]]; then printf '/other.conf\n'; fi ;;
                NeedDaemonReload) if [[ -f $NF_TEST_ROOT/stale-unit ]]; then printf 'yes\n'; else printf 'no\n'; fi ;;
                *) return 1 ;;
            esac ;;
        is-active)
            if [[ ${3:-} == "$NF_HYSTERIA_SERVICE" ]]; then [[ -f $NF_TEST_ROOT/hysteria-active ]]; else [[ -f $NF_TEST_ROOT/active ]]; fi ;;
        is-enabled)
            if [[ ${3:-} == "$NF_HYSTERIA_SERVICE" ]]; then [[ -f $NF_TEST_ROOT/hysteria-enabled ]]; else [[ -f $NF_TEST_ROOT/enabled ]]; fi ;;
        restart|start)
            if [[ -f $NF_TEST_ROOT/fail-restart ]]; then
                printf '%s\n' "${NF_ERROR_SENTINEL:-mock restart error}" >&2
                return 1
            fi
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then touch "$NF_TEST_ROOT/hysteria-active"; else touch "$NF_TEST_ROOT/active"; fi
            if [[ -f $NF_TEST_ROOT/fail-post-active ]]; then rm -f "$NF_TEST_ROOT/active" "$NF_TEST_ROOT/hysteria-active"; fi ;;
        stop)
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then rm -f "$NF_TEST_ROOT/hysteria-active"; else rm -f "$NF_TEST_ROOT/active"; fi ;;
        enable)
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then touch "$NF_TEST_ROOT/hysteria-enabled"; else touch "$NF_TEST_ROOT/enabled"; fi ;;
        disable)
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then rm -f "$NF_TEST_ROOT/hysteria-enabled"; else rm -f "$NF_TEST_ROOT/enabled"; fi ;;
        daemon-reload) : ;;
        *) return 1 ;;
    esac
}
readlink() {
    if [[ ${3:-} == /proc/12345/exe ]]; then
        if [[ -f $NF_TEST_ROOT/wrong-exe ]]; then printf '/unknown/binary\n'; else printf '%s\n' "$NF_BIN"; fi
    elif [[ ${3:-} == /proc/22345/exe ]]; then
        # Assigned by the shared test setup.
        # shellcheck disable=SC2153
        if [[ -f $NF_TEST_ROOT/wrong-exe ]]; then printf '/unknown/binary\n'; else printf '%s\n' "$NF_HYSTERIA_BIN"; fi
    else command readlink "$@"; fi
}
ss() {
    [[ ! -f $NF_TEST_ROOT/missing-listener ]] || return 0
    if [[ $* == *-lunp* ]]; then
        local hy_pid=22345
        [[ ! -f $NF_TEST_ROOT/wrong-pid ]] || hy_pid=54321
        printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:* users:(("hysteria",pid=%s,fd=3))\n' "$NF_HYSTERIA_PORT" "$hy_pid"
        return
    fi
    local pid=12345 address=$NF_LISTEN
    [[ ! -f $NF_TEST_ROOT/wrong-pid ]] || pid=54321
    [[ ! -f $NF_TEST_ROOT/wrong-address ]] || address=127.0.0.1
    if [[ -f $NF_TEST_ROOT/dual-stack ]]; then
        [[ $1 != -4 ]] || return 0
        local v6only=0
        [[ ! -f $NF_TEST_ROOT/v6-only ]] || v6only=1
        printf 'LISTEN 0 128 [::]:%s *:* users:(("xray",pid=%s,fd=3)) v6only:%s\n' "$NF_PORT" "$pid" "$v6only"
        return
    fi
    printf 'LISTEN 0 128 %s:%s 0.0.0.0:* users:(("xray",pid=%s,fd=3))\n' "$address" "$NF_PORT" "$pid"
}
timeout() { shift; "$@"; }
preflight() { check_paths "${1:-}"; }
check_directory_permissions() { :; }
cli_require_root() { [[ ! -f $NF_TEST_ROOT/nonroot ]] || die 'NodeForge: this command must be run as root'; }
acquire_lock() { printf '%s\n' "${1:-exclusive}" >> "$NF_TEST_ROOT/locks.calls"; }
