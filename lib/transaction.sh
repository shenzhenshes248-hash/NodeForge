#!/usr/bin/env bash
set -Eeuo pipefail

atomic_install() {
    local source=$1 destination=$2 mode=$3 owner=$4 group=$5 temporary
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    if ! install -m "$mode" -o "$owner" -g "$group" -- "$source" "$temporary" || ! mv -fT -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
}
snapshot_files() {
    local directory=$1
    cp -p -- "$NF_CONFIG" "$directory/xray.json"
    cp -p -- "$NF_BIN" "$directory/xray"
    cp -p -- "$NF_UNIT" "$directory/unit"
    cp -p -- "$NF_STATE" "$directory/state.json"
    cp -p -- "$NF_LICENSE" "$directory/LICENSE.xray"
    if [[ $NF_HYSTERIA_EXISTING == 1 ]]; then
        cp -p -- "$NF_HYSTERIA_BIN" "$directory/hysteria"
        cp -p -- "$NF_HYSTERIA_CONFIG" "$directory/hysteria.yaml"
        cp -p -- "$NF_HYSTERIA_CERT" "$directory/hysteria.crt"
        cp -p -- "$NF_HYSTERIA_KEY" "$directory/hysteria.key"
        cp -p -- "$NF_HYSTERIA_UNIT" "$directory/hysteria-unit"
        cp -p -- "$NF_HYSTERIA_STATE" "$directory/hysteria.json"
    fi
}
begin_transaction() {
    local active=false enabled=false hysteria_active=false hysteria_enabled=false stage
    systemctl is-active --quiet "$NF_SERVICE" && active=true
    systemctl is-enabled --quiet "$NF_SERVICE" && enabled=true
    systemctl is-active --quiet "$NF_HYSTERIA_SERVICE" && hysteria_active=true
    systemctl is-enabled --quiet "$NF_HYSTERIA_SERVICE" && hysteria_enabled=true
    install -d -m 700 "$NF_DATA_DIR" "$NF_DATA_DIR/backups"
    stage=$(mktemp -d "$NF_DATA_DIR/.snapshot.XXXXXX")
    if [[ $NF_EXISTING == 1 ]]; then snapshot_files "$stage"; fi
    jq -n --argjson existing "$NF_EXISTING" --argjson active "$active" --argjson enabled "$enabled" \
      --argjson hysteria_existing "$NF_HYSTERIA_EXISTING" --argjson hysteria_active "$hysteria_active" \
      --argjson hysteria_enabled "$hysteria_enabled" \
      '{owner:"NodeForge",schema:1,existing:$existing,active:$active,enabled:$enabled,
        hysteria_existing:$hysteria_existing,hysteria_active:$hysteria_active,hysteria_enabled:$hysteria_enabled}' > "$stage/original.json"
    touch "$stage/ready"
    mv -T -- "$stage" "$NF_PENDING"
    NF_TRANSACTION=1
}
restore_snapshot_file() {
    local source=$1 destination=$2 temporary
    ( require_regular "$source" ) || return 1
    temporary=$(mktemp "${destination}.restore.XXXXXX") || return 1
    if ! cp -p -- "$source" "$temporary" || ! mv -fT -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
}
remove_service_user() {
    # Never remove home directories or any data owned by the account.
    if getent passwd nodeforge >/dev/null; then
        [[ $(id -u nodeforge) != 0 ]] || return 1
        if ! find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
            -uid "$(id -u nodeforge)" -print -quit > "$NF_WORK/remaining-user-files" 2>/dev/null; then
            warn 'Cannot prove service account is unused; retaining account'
            return 1
        fi
        if [[ -s $NF_WORK/remaining-user-files ]]; then
            warn 'Service account still owns files outside the removed installation; retaining account'
            return 1
        fi
        userdel nodeforge || return 1
    fi
    if getent group nodeforge >/dev/null; then groupdel nodeforge || return 1; fi
}
rollback() {
    if ! rollback_restore; then
        log ERROR 'Recovery incomplete; pending transaction/evidence retained.'
        return 1
    fi
}
rollback_restore() {
    local existing active enabled hysteria_existing hysteria_active hysteria_enabled
    warn 'Restoring the previous NodeForge installation'
    if [[ -e $NF_PENDING/rollback-complete || -L $NF_PENDING/rollback-complete ]]; then
        rollback_discard_pending || return 1
        NF_TRANSACTION=0
        return 0
    fi
    [[ ! -L $NF_PENDING && -f $NF_PENDING/ready ]] || return 1
    ( require_regular "$NF_PENDING/original.json" ) || return 1
    jq -e '.owner == "NodeForge" and .schema == 1 and (.existing == 0 or .existing == 1) and
      (.active|type == "boolean") and (.enabled|type == "boolean") and
      ((.hysteria_existing // 0) == 0 or (.hysteria_existing // 0) == 1) and
      ((.hysteria_active // false)|type == "boolean") and ((.hysteria_enabled // false)|type == "boolean")' \
      "$NF_PENDING/original.json" >/dev/null || return 1
    existing=$(jq -r '.existing' "$NF_PENDING/original.json") || return 1
    active=$(jq -r '.active' "$NF_PENDING/original.json") || return 1
    enabled=$(jq -r '.enabled' "$NF_PENDING/original.json") || return 1
    hysteria_existing=$(jq -r '.hysteria_existing // 0' "$NF_PENDING/original.json") || return 1
    hysteria_active=$(jq -r '.hysteria_active // false' "$NF_PENDING/original.json") || return 1
    hysteria_enabled=$(jq -r '.hysteria_enabled // false' "$NF_PENDING/original.json") || return 1
    if [[ -e $NF_PENDING/cli-created || -L $NF_PENDING/cli-created ]]; then runtime_rollback_cleanup || return 1; fi
    if [[ $hysteria_existing == 1 || -f $NF_HYSTERIA_UNIT ]]; then
        systemctl stop "$NF_HYSTERIA_SERVICE" || return 1
    fi
    if [[ $existing == 1 || -f $NF_UNIT ]]; then
        systemctl daemon-reload || return 1
        systemctl stop "$NF_SERVICE" || return 1
    fi
    if [[ $existing == 1 ]]; then
        restore_snapshot_file "$NF_PENDING/xray.json" "$NF_CONFIG" || return 1
        restore_snapshot_file "$NF_PENDING/xray" "$NF_BIN" || return 1
        restore_snapshot_file "$NF_PENDING/unit" "$NF_UNIT" || return 1
        restore_snapshot_file "$NF_PENDING/state.json" "$NF_STATE" || return 1
        restore_snapshot_file "$NF_PENDING/LICENSE.xray" "$NF_LICENSE" || return 1
    else
        if [[ -f $NF_UNIT ]]; then systemctl disable "$NF_SERVICE" >/dev/null 2>&1 || return 1; fi
        rm -f -- "$NF_CONFIG" "$NF_BIN" "$NF_LICENSE" "$NF_UNIT" "$NF_STATE" || return 1
        if [[ -f $NF_PENDING/user-created ]]; then remove_service_user || return 1; fi
    fi
    if [[ $hysteria_existing == 1 ]]; then
        restore_snapshot_file "$NF_PENDING/hysteria" "$NF_HYSTERIA_BIN" || return 1
        restore_snapshot_file "$NF_PENDING/hysteria.yaml" "$NF_HYSTERIA_CONFIG" || return 1
        restore_snapshot_file "$NF_PENDING/hysteria.crt" "$NF_HYSTERIA_CERT" || return 1
        restore_snapshot_file "$NF_PENDING/hysteria.key" "$NF_HYSTERIA_KEY" || return 1
        restore_snapshot_file "$NF_PENDING/hysteria-unit" "$NF_HYSTERIA_UNIT" || return 1
        restore_snapshot_file "$NF_PENDING/hysteria.json" "$NF_HYSTERIA_STATE" || return 1
    else
        if [[ -f $NF_HYSTERIA_UNIT ]]; then systemctl disable "$NF_HYSTERIA_SERVICE" >/dev/null 2>&1 || return 1; fi
        rm -f -- "$NF_HYSTERIA_BIN" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY" \
          "$NF_HYSTERIA_UNIT" "$NF_HYSTERIA_STATE" || return 1
    fi
    systemctl daemon-reload || return 1
    if [[ $existing == 1 ]]; then
        if [[ $enabled == true ]]; then systemctl enable "$NF_SERVICE" || return 1
        else systemctl disable "$NF_SERVICE" || return 1; fi
        if [[ $active == true ]]; then
            systemctl start "$NF_SERVICE" || return 1
            systemctl is-active --quiet "$NF_SERVICE" || return 1
        fi
    fi
    if [[ $hysteria_existing == 1 ]]; then
        if [[ $hysteria_enabled == true ]]; then systemctl enable "$NF_HYSTERIA_SERVICE" || return 1
        else systemctl disable "$NF_HYSTERIA_SERVICE" || return 1; fi
        if [[ $hysteria_active == true ]]; then
            systemctl start "$NF_HYSTERIA_SERVICE" || return 1
            systemctl is-active --quiet "$NF_HYSTERIA_SERVICE" || return 1
        fi
    fi
    # Only after runtime/files/service have all been restored may evidence be
    # retired. A completion marker allows a failed retirement to be retried
    # without restoring from snapshot files already removed by retirement.
    printf 'NodeForge local rollback restored\n' > "$NF_WORK/rollback-complete" || return 1
    atomic_install "$NF_WORK/rollback-complete" "$NF_PENDING/rollback-complete" 600 root root || return 1
    rollback_discard_pending || return 1
    NF_TRANSACTION=0
    if [[ $existing == 0 ]]; then
        rmdir -- "$NF_BIN_DIR/bin" "$NF_BIN_DIR" "$NF_CONFIG_DIR" "$NF_DATA_DIR/backups" "$NF_DATA_DIR" 2>/dev/null || true
    fi
}
rollback_discard_pending() {
    local path name
    [[ -d $NF_PENDING && ! -L $NF_PENDING ]] || return 1
    ( trusted_file "$NF_PENDING/rollback-complete" ) || return 1
    [[ $(cat "$NF_PENDING/rollback-complete") == 'NodeForge local rollback restored' ]] || return 1
    # Reject unknown contents before retiring any snapshot/reference files.
    for path in "$NF_PENDING"/* "$NF_PENDING"/.[!.]* "$NF_PENDING"/..?*; do
        [[ -e $path || -L $path ]] || continue
        name=${path##*/}
        case $name in
            xray.json|xray|unit|state.json|LICENSE.xray|hysteria|hysteria.yaml|hysteria.crt|hysteria.key|hysteria-unit|hysteria.json|original.json|ready|user-created|cli-created|rollback-complete) ;;
            *) return 1 ;;
        esac
        ( require_regular "$path" ) || return 1
    done
    for name in xray.json xray unit state.json LICENSE.xray hysteria hysteria.yaml hysteria.crt hysteria.key hysteria-unit hysteria.json original.json ready user-created cli-created; do
        rm -f -- "$NF_PENDING/$name" || return 1
    done
    rm -f -- "$NF_PENDING/rollback-complete" || return 1
    if ! rmdir -- "$NF_PENDING"; then
        # Preserve the completed-recovery reference if directory retirement fails.
        printf 'NodeForge local rollback restored\n' > "$NF_PENDING/rollback-complete" || return 1
        return 1
    fi
}
finish_transaction() {
    local destination
    destination=$(mktemp -d "$NF_DATA_DIR/backups/install-XXXXXXXX")
    rmdir -- "$destination"
    mv -T -- "$NF_PENDING" "$destination"
    NF_TRANSACTION=0
}
install_nodeforge() {
    check_paths
    if [[ -d $NF_PENDING ]]; then
        NF_TRANSACTION=1
        rollback || die 'Interrupted installation could not be recovered'
    fi
    runtime_preinstall
    NF_USER_CREATED=false
    if [[ -f $NF_STATE ]]; then
        load_existing
        ensure_service_user
    else
        NF_XRAY_VERSION=$NF_DEFAULT_XRAY_VERSION
        NF_TARGET=$NF_DEFAULT_TARGET NF_SNI=$NF_DEFAULT_SNI
        NF_PORT='' NF_UUID='' NF_SHORT_ID='' NF_LISTEN=0.0.0.0
        NF_SERVER_IP=''
    fi
    local old_port=$NF_PORT old_version=$NF_XRAY_VERSION
    NF_XRAY_VERSION=${NODEFORGE_XRAY_VERSION:-$NF_XRAY_VERSION}
    if [[ $NF_EXISTING == 1 && $NF_XRAY_VERSION == "$old_version" ]]; then
        NF_CANDIDATE_BIN=$NF_BIN
        NF_CANDIDATE_LICENSE=$NF_LICENSE
    else
        fetch_xray "$NF_XRAY_VERSION"
    fi
    if [[ $NF_EXISTING == 0 ]]; then
        generate_identity
        NF_PORT=${NODEFORGE_PORT:-$(choose_port)}
    fi
    apply_overrides
    resolve_server_ip
    prepare_hysteria
    # Bind IPv6 explicitly when publishing an IPv6 endpoint; Linux also accepts
    # IPv4-mapped connections with its default dual-stack setting.
    if [[ $NF_SERVER_IP == *:* ]]; then NF_LISTEN=::; else NF_LISTEN=0.0.0.0; fi
    generate_config "$NF_WORK/candidate.json"
    test_xray_config "$NF_CANDIDATE_BIN" "$NF_WORK/candidate.json"
    if [[ $NF_EXISTING == 1 ]] && cmp -s "$NF_CONFIG" "$NF_WORK/candidate.json" && [[ $NF_XRAY_VERSION == "$old_version" ]]; then
        begin_transaction
        # No restart of a healthy service, no key rotation, no implicit upgrade.
        systemctl enable "$NF_SERVICE"
        systemctl start "$NF_SERVICE"
        check_service_health
        write_state
        install_hysteria
        install_cli_runtime
        finish_transaction
        info 'Existing configuration preserved; protected backup created'
        print_node
        return
    fi
    if [[ $NF_EXISTING == 0 || $NF_PORT != "$old_port" ]]; then
        port_available "$NF_PORT" || die 'Requested TCP port is already occupied'
    fi
    validate_reality_target
    begin_transaction
    ensure_service_user
    install -d -m 755 "$NF_BIN_DIR" "$NF_BIN_DIR/bin"
    install -d -m 750 -o root -g nodeforge "$NF_CONFIG_DIR"
    atomic_install "$NF_CANDIDATE_BIN" "$NF_BIN" 755 root root
    atomic_install "$NF_CANDIDATE_LICENSE" "$NF_LICENSE" 644 root root
    atomic_install "$NF_WORK/candidate.json" "$NF_CONFIG" 600 nodeforge nodeforge
    atomic_install "$NF_SOURCE/templates/nodeforge-xray.service" "$NF_UNIT" 644 root root
    # Validate the exact final path as the service user before starting it.
    if ! runuser -u nodeforge -- "$NF_BIN" run -test -config "$NF_CONFIG" > "$NF_WORK/final-test.log" 2>&1; then
        die 'Final configuration is not readable/valid for the service user'
    fi
    write_state
    activate_service
    install_hysteria
    install_cli_runtime
    finish_transaction
    info 'NodeForge installed; local service checks passed'
    print_node
}
uninstall_nodeforge() {
    # A completed uninstall may leave deliberately preserved unknown directories.
    # Do not claim or erase them on repeated uninstall.
    if [[ ! -e $NF_STATE && ! -L $NF_STATE && ! -e $NF_HYSTERIA_STATE && ! -L $NF_HYSTERIA_STATE && ! -e $NF_PENDING && ! -L $NF_PENDING ]]; then
        [[ ! -e $NF_CLI && ! -L $NF_CLI ]] || die 'CLI exists without an ownership state'
        info 'NodeForge is not installed'
        return
    fi
    check_paths
    if [[ -d $NF_PENDING ]]; then
        NF_TRANSACTION=1
        rollback || die 'Recover the pending installation before uninstalling'
    fi
    if [[ ! -f $NF_STATE ]]; then info 'NodeForge is not installed'; return; fi
    load_existing
    load_hysteria
    runtime_preuninstall
    warp_load
    if [[ -e $NF_WARP_STATE ]]; then
        if command -v warp-cli >/dev/null; then warp_cli disconnect >/dev/null; fi
        rm -f -- "$NF_WARP_STATE"
    fi
    uninstall_subscription
    uninstall_argo
    systemctl stop "$NF_HYSTERIA_SERVICE"
    systemctl disable "$NF_HYSTERIA_SERVICE"
    systemctl stop "$NF_SERVICE"
    systemctl disable "$NF_SERVICE"
    rm -f -- "$NF_HYSTERIA_UNIT" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY" \
      "$NF_HYSTERIA_BIN" "$NF_HYSTERIA_STATE" "$NF_UNIT" "$NF_CONFIG" "$NF_BIN" "$NF_LICENSE"
    systemctl daemon-reload
    runtime_remove
    # Remove only recognized backup files; never recursively erase an unknown tree.
    local directory file
    if [[ -d $NF_DATA_DIR/backups ]]; then
        while IFS= read -r -d '' directory; do
            [[ ! -L $directory && -f $directory/original.json && ! -L $directory/original.json ]] || continue
            jq -e '.owner == "NodeForge" and .schema == 1' "$directory/original.json" >/dev/null || continue
            for file in xray.json xray unit state.json LICENSE.xray hysteria hysteria.yaml hysteria.crt hysteria.key hysteria-unit hysteria.json original.json ready user-created cli-created; do
                if [[ -f $directory/$file && ! -L $directory/$file ]]; then rm -f -- "$directory/$file"; fi
            done
            rmdir -- "$directory" 2>/dev/null || warn "Preserved unknown backup contents: $directory"
        done < <(find "$NF_DATA_DIR/backups" -mindepth 1 -maxdepth 1 -type d -name 'install-*' -print0)
    fi
    rm -f -- "$NF_STATE"
    rmdir -- "$NF_BIN_DIR/bin" "$NF_BIN_DIR" "$NF_CONFIG_DIR" "$NF_DATA_DIR/backups" "$NF_DATA_DIR" 2>/dev/null || warn 'Preserved nonempty directories containing unknown files'
    if [[ $NF_USER_CREATED == true ]]; then
        remove_service_user || warn 'Could not remove service account; no user data was deleted'
    fi
    info 'NodeForge removed; distribution packages and unrelated data preserved'
}
