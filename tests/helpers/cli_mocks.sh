#!/usr/bin/env bash
set -Eeuo pipefail
source "$NF_SOURCE/tests/helpers/mocks.sh"

# Fixture service queries supplement the M1 mutations, with no host access.
systemctl() {
    printf '%s\n' "$*" >> "$NF_TEST_ROOT/systemctl.calls"
    case $1 in
        show)
            [[ $2 == "$NF_SERVICE" && $3 == -p && $5 == --value ]] || return 1
            case $4 in
                LoadState) if [[ -f $NF_TEST_ROOT/missing-service ]]; then printf 'not-found\n'; else printf 'loaded\n'; fi ;;
                FragmentPath) if [[ -f $NF_TEST_ROOT/wrong-unit ]]; then printf '/unknown.service\n'; else printf '%s\n' "$NF_UNIT"; fi ;;
                ActiveState) if [[ -f $NF_TEST_ROOT/active ]]; then printf 'active\n'; else printf 'inactive\n'; fi ;;
                SubState) if [[ -f $NF_TEST_ROOT/active ]]; then printf 'running\n'; else printf 'dead\n'; fi ;;
                MainPID) if [[ -f $NF_TEST_ROOT/zero-pid ]]; then printf '0\n'; else printf '12345\n'; fi ;;
                DropInPaths) if [[ -f $NF_TEST_ROOT/dropin ]]; then printf '/other.conf\n'; fi ;;
                NeedDaemonReload) if [[ -f $NF_TEST_ROOT/stale-unit ]]; then printf 'yes\n'; else printf 'no\n'; fi ;;
                *) return 1 ;;
            esac ;;
        is-active) [[ -f $NF_TEST_ROOT/active ]] ;;
        is-enabled) [[ -f $NF_TEST_ROOT/enabled ]] ;;
        restart|start)
            if [[ -f $NF_TEST_ROOT/fail-restart ]]; then
                printf '%s\n' "${NF_ERROR_SENTINEL:-mock restart error}" >&2
                return 1
            fi
            touch "$NF_TEST_ROOT/active"
            if [[ -f $NF_TEST_ROOT/fail-post-active ]]; then rm "$NF_TEST_ROOT/active"; fi ;;
        stop) rm -f "$NF_TEST_ROOT/active" ;;
        enable) touch "$NF_TEST_ROOT/enabled" ;;
        disable) rm -f "$NF_TEST_ROOT/enabled" ;;
        daemon-reload) : ;;
        *) return 1 ;;
    esac
}
readlink() {
    if [[ ${3:-} == /proc/12345/exe ]]; then
        if [[ -f $NF_TEST_ROOT/wrong-exe ]]; then printf '/unknown/binary\n'; else printf '%s\n' "$NF_BIN"; fi
    else command readlink "$@"; fi
}
ss() {
    [[ ! -f $NF_TEST_ROOT/missing-listener ]] || return 0
    local pid=12345 address=$NF_LISTEN
    [[ ! -f $NF_TEST_ROOT/wrong-pid ]] || pid=54321
    [[ ! -f $NF_TEST_ROOT/wrong-address ]] || address=127.0.0.1
    printf 'LISTEN 0 128 %s:%s 0.0.0.0:* users:(("xray",pid=%s,fd=3))\n' "$address" "$NF_PORT" "$pid"
}
timeout() { shift; "$@"; }
preflight() { check_paths "${1:-}"; }
check_directory_permissions() { :; }
cli_require_root() { [[ ! -f $NF_TEST_ROOT/nonroot ]] || die 'NodeForge: this command must be run as root'; }
acquire_lock() { printf '%s\n' "${1:-exclusive}" >> "$NF_TEST_ROOT/locks.calls"; }
