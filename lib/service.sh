#!/usr/bin/env bash
set -Eeuo pipefail

ensure_service_user() {
    if [[ $NF_EXISTING == 1 ]]; then
        getent passwd nodeforge >/dev/null || die 'Managed service user is missing'
        [[ $(id -u nodeforge) != 0 ]] || die 'Service must not run as root'
        return
    fi
    ! getent passwd nodeforge >/dev/null || die 'Unmanaged nodeforge user already exists'
    ! getent group nodeforge >/dev/null || die 'Unmanaged nodeforge group already exists'
    # Journal intent before creation, so interrupted installs can be recovered.
    touch "$NF_PENDING/user-created"
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin nodeforge
    NF_USER_CREATED=true
}
activate_service() {
    systemctl daemon-reload
    systemctl enable "$NF_SERVICE"
    systemctl restart "$NF_SERVICE"
    check_service_health
}
check_service_health() {
    local attempt
    for attempt in 1 2 3; do
        sleep 1
        systemctl is-active --quiet "$NF_SERVICE" || die 'Xray service did not remain active'
    done
    ss -H -ltn "sport = :$NF_PORT" | grep -q . || die 'Xray TCP listener was not found'
}

# Management checks require both systemd ownership and an owned TCP socket.
# Keep M1 activation checks unchanged; CLI uses this stricter local observation.
managed_service_loaded() {
    local load fragment dropins reload
    load=$(timeout 3 systemctl show "$NF_SERVICE" -p LoadState --value 2>/dev/null) || return 1
    fragment=$(timeout 3 systemctl show "$NF_SERVICE" -p FragmentPath --value 2>/dev/null) || return 1
    dropins=$(timeout 3 systemctl show "$NF_SERVICE" -p DropInPaths --value 2>/dev/null) || return 1
    reload=$(timeout 3 systemctl show "$NF_SERVICE" -p NeedDaemonReload --value 2>/dev/null) || return 1
    [[ $load == loaded && $fragment == "$NF_UNIT" && -z $dropins && $reload == no ]]
}
managed_service_healthy() {
    local active sub pid executable sockets family=4 after
    managed_service_loaded || return 1
    active=$(timeout 3 systemctl show "$NF_SERVICE" -p ActiveState --value 2>/dev/null) || return 1
    sub=$(timeout 3 systemctl show "$NF_SERVICE" -p SubState --value 2>/dev/null) || return 1
    pid=$(timeout 3 systemctl show "$NF_SERVICE" -p MainPID --value 2>/dev/null) || return 1
    [[ $active == active && $sub == running && $pid =~ ^[1-9][0-9]*$ ]] || return 1
    executable=$(readlink -e -- "/proc/$pid/exe") || return 1
    [[ $executable == "$NF_BIN" ]] || return 1
    [[ $NF_LISTEN != :: ]] || family=6
    sockets=$(timeout 3 ss "-$family" -H -ltnp "sport = :$NF_PORT" 2>/dev/null) || return 1
    # Linux may expose an IPv4 wildcard as an IPv6 dual-stack socket.
    # Require the socket's v6only:0 attribute, not the host-wide default.
    if [[ $NF_LISTEN == 0.0.0.0 && -z $sockets ]]; then
        family=6
        sockets=$(timeout 3 ss -6 -H -ltnpe "sport = :$NF_PORT" 2>/dev/null) || return 1
    fi
    printf '%s\n' "$sockets" | python3 "$NF_SOURCE/lib/management.py" listener "$NF_LISTEN" "$NF_PORT" "$pid" "$family" 2>/dev/null || return 1
    # Fail closed if the process changed while inspecting its listener.
    after=$(timeout 3 systemctl show "$NF_SERVICE" -p MainPID --value 2>/dev/null) || return 1
    [[ $after == "$pid" ]] && timeout 3 systemctl is-active --quiet "$NF_SERVICE" 2>/dev/null
}
wait_managed_service() {
    local attempt deadline=$((SECONDS + 15))
    for attempt in {1..10}; do
        if managed_service_healthy; then return 0; fi
        (( SECONDS < deadline )) || return 1
        sleep 1
    done
    return 1
}
