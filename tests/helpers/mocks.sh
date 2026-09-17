#!/usr/bin/env bash
set -Eeuo pipefail

# All privileged/network operations are intercepted. No test calls host systemd.
trusted_directory() { [[ -d $1 && ! -L $1 ]] || die 'Unsafe mock directory'; }
trusted_file() { require_regular "$1"; }
systemctl() {
    printf '%s\n' "$*" >> "$NF_TEST_ROOT/systemctl.calls"
    case $1 in
        is-active)
            if [[ ${3:-} == "$NF_HYSTERIA_SERVICE" ]]; then [[ -f $NF_TEST_ROOT/hysteria-active ]]; else [[ -f $NF_TEST_ROOT/active ]]; fi ;;
        is-enabled)
            if [[ ${3:-} == "$NF_HYSTERIA_SERVICE" ]]; then [[ -f $NF_TEST_ROOT/hysteria-enabled ]]; else [[ -f $NF_TEST_ROOT/enabled ]]; fi ;;
        start|restart)
            if [[ $2 == "$NF_HYSTERIA_SERVICE" && -f $NF_TEST_ROOT/fail-hysteria-start ]]; then return 1; fi
            if [[ -f $NF_TEST_ROOT/fail-start ]]; then rm -f "$NF_TEST_ROOT/fail-start"; return 1; fi
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then touch "$NF_TEST_ROOT/hysteria-active"; else touch "$NF_TEST_ROOT/active"; fi ;;
        stop)
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then rm -f "$NF_TEST_ROOT/hysteria-active"; else rm -f "$NF_TEST_ROOT/active"; fi ;;
        enable)
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then touch "$NF_TEST_ROOT/hysteria-enabled"; else touch "$NF_TEST_ROOT/enabled"; fi ;;
        disable)
            if [[ $2 == "$NF_HYSTERIA_SERVICE" ]]; then rm -f "$NF_TEST_ROOT/hysteria-enabled"; else rm -f "$NF_TEST_ROOT/enabled"; fi ;;
        daemon-reload) ;;
        *) printf 'Unexpected systemctl invocation\n' >&2; return 1 ;;
    esac
}
install() {
    fixture_install "$@"
}
fixture_install() {
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
ss() {
    if [[ $* == *-lun* ]]; then printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n' "$NF_HYSTERIA_PORT"
    else printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$NF_PORT"; fi
}
port_available() { [[ $1 != 29999 ]]; }
udp_port_available() { [[ ! -f $NF_TEST_ROOT/occupied-udp-443 ]]; }
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
fetch_hysteria() {
    NF_HYSTERIA_VERSION=$1
    cat > "$NF_WORK/hysteria" <<'EOF'
#!/usr/bin/env bash
printf 'Version: v2.12.3\n'
EOF
    chmod 755 "$NF_WORK/hysteria"
    NF_HYSTERIA_CANDIDATE_BIN=$NF_WORK/hysteria
}
hysteria_pin() { printf '%064d\n' 0; }
generate_hysteria_identity() {
    NF_HYSTERIA_PASSWORD=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456
    printf 'mock certificate\n' > "$NF_WORK/hysteria.crt"
    printf 'mock key\n' > "$NF_WORK/hysteria.key"
    chmod 600 "$NF_WORK/hysteria.crt" "$NF_WORK/hysteria.key"
    NF_HYSTERIA_PIN=$(hysteria_pin "$NF_WORK/hysteria.crt")
    NF_HYSTERIA_CANDIDATE_CERT=$NF_WORK/hysteria.crt
    NF_HYSTERIA_CANDIDATE_KEY=$NF_WORK/hysteria.key
}
