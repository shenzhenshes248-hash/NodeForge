#!/usr/bin/env bash
set -Eeuo pipefail

subscription_paths() {
    NF_SUB_DIR=$NF_BIN_DIR/subscription
    NF_SUB_CONFIG=$NF_CONFIG_DIR/subscription.json
    NF_SUB_UNIT=$(dirname "$NF_UNIT")/nodeforge-subscription.service
    NF_SUB_SERVICE=nodeforge-subscription.service
}

subscription_url() {
    subscription_paths
    [[ -e $NF_SUB_CONFIG ]] || return 0
    python3 "$NF_SOURCE/lib/subscription.py" url "$NF_SUB_CONFIG"
}

subscription_link() {
    local url
    if url=$(subscription_url) && [[ -n $url ]]; then printf 'Subscription URL: %s\n' "$url"; fi
    return 0
}

subscription_content() {
    cli_load_state
    local argo
    argo=$(argo_link)
    [[ -n $argo ]] || die 'Argo is not ready; subscription temporarily unavailable'
    node_link
    hysteria_link
    printf '%s\n' "$argo"
}

cli_argo_edge() {
    local address temporary destination=$NF_CONFIG_DIR/argo-edge.json
    cli_load_state
    load_argo
    address=$(python3 "$NF_SOURCE/lib/subscription.py" edge "$1") || die 'Invalid Argo edge address'
    [[ ! -L $destination ]] || die 'Unsafe Argo edge settings path'
    temporary=$(mktemp "$NF_CONFIG_DIR/.argo-edge.XXXXXX")
    jq -n --arg address "$address" '{address:$address}' > "$temporary"
    chmod 600 "$temporary"
    mv -fT "$temporary" "$destination"
    info 'Argo link address updated; Host/SNI still use the current Tunnel domain'
}

load_subscription() {
    subscription_paths
    trusted_directory "$NF_SUB_DIR"
    trusted_file "$NF_SUB_CONFIG"
    trusted_file "$NF_SUB_DIR/server.py"
    cmp -s "$NF_SUB_DIR/server.py" "$NF_SOURCE/lib/subscription.py" || die 'Subscription server changed outside NodeForge'
    cmp -s "$NF_SUB_UNIT" "$NF_SOURCE/templates/nodeforge-subscription.service" || die 'Unsupported subscription service unit'
    subscription_url >/dev/null
}

remove_subscription() {
    subscription_paths
    [[ -e $NF_SUB_CONFIG || -e $NF_SUB_DIR ]] || return 0
    if [[ -f $NF_SUB_UNIT ]]; then
        systemctl stop "$NF_SUB_SERVICE"
        systemctl disable "$NF_SUB_SERVICE"
    fi
    rm -f -- "$NF_SUB_UNIT" "$NF_SUB_CONFIG" "$NF_SUB_DIR/server.py"
    if [[ -d $NF_SUB_DIR ]]; then rmdir -- "$NF_SUB_DIR"; fi
    systemctl daemon-reload
}

subscription_install_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ ${NF_SUB_CREATED:-0} == 1 ]]; then
        remove_subscription || { log ERROR 'Subscription cleanup incomplete'; status=1; }
    fi
    update_cleanup "$status"
}

install_subscription() (
    cli_load_state
    load_argo
    subscription_paths
    init_workspace
    trap subscription_install_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -e $NF_SUB_CONFIG || -e $NF_SUB_DIR ]]; then
        load_subscription
    else
        [[ ! -L $NF_SUB_CONFIG && ! -L $NF_SUB_DIR && ! -e $NF_SUB_UNIT && ! -L $NF_SUB_UNIT ]] || die 'Unmanaged subscription paths exist'
        python3 "$NF_SOURCE/lib/subscription.py" create "$NF_SERVER_IP" > "$NF_WORK/subscription.json"
    fi
    argo_prepare_runtime
    if [[ ! -e $NF_SUB_CONFIG ]]; then
        NF_SUB_CREATED=1
        install -d -m 755 -o root -g root "$NF_SUB_DIR"
        atomic_install "$NF_SOURCE/lib/subscription.py" "$NF_SUB_DIR/server.py" 644 root root
        atomic_install "$NF_WORK/subscription.json" "$NF_SUB_CONFIG" 600 root root
        atomic_install "$NF_SOURCE/templates/nodeforge-subscription.service" "$NF_SUB_UNIT" 644 root root
    fi
    # Publish the CLI before serving requests using its new content command.
    if [[ ${NF_UPDATE_ACTIVE:-0} == 1 ]]; then
        runtime_launcher > "$NF_WORK/new-launcher"
        NF_UPDATE_SWITCHED=1
        atomic_install "$NF_WORK/new-launcher" "$NF_CLI" 755 root root
    fi
    systemctl daemon-reload
    systemctl enable "$NF_SUB_SERVICE"
    systemctl start "$NF_SUB_SERVICE"
    sleep 1
    systemctl is-active --quiet "$NF_SUB_SERVICE" || die 'Subscription server failed to start'
    NF_SUB_CREATED=0 NF_UPDATE_ACTIVE=0
    subscription_link
)

uninstall_subscription() {
    subscription_paths
    if [[ -e $NF_SUB_CONFIG || -e $NF_SUB_DIR ]]; then
        load_subscription
        remove_subscription
    fi
    rm -f -- "$NF_CONFIG_DIR/argo-edge.json"
}
