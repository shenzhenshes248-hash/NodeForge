#!/usr/bin/env bash
set -Eeuo pipefail

# All privileged/network operations are intercepted. No test calls host systemd.
systemctl() {
    printf '%s\n' "$*" >> "$NF_TEST_ROOT/systemctl.calls"
    case $1 in
        is-active) [[ -f $NF_TEST_ROOT/active ]] ;;
        is-enabled) [[ -f $NF_TEST_ROOT/enabled ]] ;;
        start|restart)
            if [[ -f $NF_TEST_ROOT/fail-start ]]; then rm -f "$NF_TEST_ROOT/fail-start"; return 1; fi
            touch "$NF_TEST_ROOT/active" ;;
        stop) rm -f "$NF_TEST_ROOT/active" ;;
        enable) touch "$NF_TEST_ROOT/enabled" ;;
        disable) rm -f "$NF_TEST_ROOT/enabled" ;;
        daemon-reload) ;;
        *) printf 'Unexpected systemctl invocation\n' >&2; return 1 ;;
    esac
}
install() {
    local mode=755 directory=0
    local -a args=()
    while (( $# )); do
        case $1 in -o|-g) shift 2 ;; -m) mode=$2; shift 2 ;; -d) directory=1; shift ;; --) shift ;; *) args+=("$1"); shift ;; esac
    done
    if (( directory )); then
        mkdir -p -- "${args[@]}"
        chmod "$mode" "${args[@]}"
    else
        cp -- "${args[@]}"
        chmod "$mode" "${args[1]}"
    fi
}
runuser() { [[ $1 == -u && $2 == nodeforge && $3 == -- ]] || return 1; shift 3; "$@"; }
getent() { [[ -f $NF_TEST_ROOT/user ]]; }
id() { printf '999\n'; }
useradd() { touch "$NF_TEST_ROOT/user"; }
userdel() { rm -f "$NF_TEST_ROOT/user"; }
groupdel() { :; }
remove_service_user() { rm -f "$NF_TEST_ROOT/user"; }
sleep() { :; }
ss() { printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$NF_PORT"; }
port_available() { [[ $1 != 29999 ]]; }
choose_port() { printf '23456\n'; }
resolve_server_ip() { NF_SERVER_IP=${NODEFORGE_SERVER_IP:-${NF_SERVER_IP:-8.8.8.8}}; }
validate_reality_target() { [[ ! -f $NF_TEST_ROOT/fail-target ]] || die 'Mock target failure'; }
fetch_xray() {
    [[ $1 =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die 'Invalid version'
    cp "$NF_SOURCE/tests/fixtures/xray/xray" "$NF_WORK/xray"
    chmod 755 "$NF_WORK/xray"
    NF_CANDIDATE_BIN=$NF_WORK/xray
    printf 'Mock upstream license\n' > "$NF_WORK/LICENSE.xray"
    NF_CANDIDATE_LICENSE=$NF_WORK/LICENSE.xray
}
