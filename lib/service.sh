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
