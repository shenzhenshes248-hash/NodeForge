#!/usr/bin/env bash
# Each child intentionally owns its module/path variables; the EXIT trap runs
# in cli_update's own subshell. No child modifications are needed by the caller.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

update_trust() {
    local directory=$NF_CONFIG_DIR/trust
    [[ ! -L $directory && ( ! -e $directory || -d $directory ) ]] || return 1
    install -d -m 755 -o root -g root "$directory" || return 1
    trusted_directory "$directory"
    if [[ ! -e $directory/release-ed25519.pub && ! -L $directory/release-ed25519.pub ]]; then
        atomic_install "$NF_SOURCE/trust/release-ed25519.pub" "$directory/release-ed25519.pub" 644 root root || return 1
    fi
    trusted_file "$directory/release-ed25519.pub"
    cmp -s "$NF_SOURCE/trust/release-ed25519.pub" "$directory/release-ed25519.pub"
}
update_remove_trust() {
    local directory=$NF_CONFIG_DIR/trust
    [[ -e $directory || -L $directory ]] || return 0
    ( trusted_directory "$directory"; trusted_file "$directory/release-ed25519.pub" ) || return 1
    cmp -s "$NF_SOURCE/trust/release-ed25519.pub" "$directory/release-ed25519.pub" || return 1
    rm -f -- "$directory/release-ed25519.pub" || return 1
    rmdir -- "$directory" 2>/dev/null || warn 'Preserved unknown trust files'
}
update_check_runtime() (
    NF_SOURCE=$1
    # Invoke the canonical status function under the parent's exclusive lock.
    # A second CLI lock acquisition would deadlock/fail busy.
    source "$NF_SOURCE/lib/common.sh"
    load_modules
    cli_require_root
    cli_status >/dev/null
)
# This record selects one already-installed runtime, never a download or path.
update_previous_version() {
    local record=$NF_APP/previous version
    if [[ ! -e $record && ! -L $record ]]; then return 0; fi
    trusted_file "$record"
    version=$(cat "$record")
    [[ $version =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-dev)?$ && $version != "$NF_NODEFORGE_VERSION" ]] || die 'Invalid previous version record'
    printf '%s\n' "$version"
}
update_validate_previous() (
    NF_NODEFORGE_VERSION=$1
    runtime_paths
    runtime_validate
    cmp -s "$NF_RUNTIME/trust/release-ed25519.pub" "$NF_SOURCE/trust/release-ed25519.pub" || die 'Previous runtime trust anchor mismatch'
)
update_snapshot_previous() {
    if [[ -e $NF_APP/previous ]]; then cp -p "$NF_APP/previous" "$NF_WORK/old-previous"; fi
}
update_cleanup() {
    local status=${1:-$?}
    trap - EXIT INT TERM
    if [[ ${NF_UPDATE_ACTIVE:-0} == 1 ]]; then
        warn "${NF_SWITCH_OPERATION:-Update} failed; rollback target: $NF_UPDATE_PREVIOUS_VERSION"
        if [[ ${NF_UPDATE_SWITCHED:-0} == 1 ]]; then
            if ! restore_snapshot_file "$NF_WORK/old-launcher" "$NF_CLI"; then
                log ERROR "CLI restore failed; old runtime and recovery files retained at $NF_WORK"
                exit 1
            fi
        fi
        if [[ ${NF_UPDATE_METADATA_CHANGED:-0} == 1 ]]; then
            if [[ -f $NF_WORK/old-previous ]]; then
                restore_snapshot_file "$NF_WORK/old-previous" "$NF_APP/previous" || {
                    log ERROR "Previous version record recovery failed; evidence retained at $NF_WORK"
                    exit 1
                }
            else
                rm -f -- "$NF_APP/previous" || { log ERROR "Previous version record recovery failed; evidence retained at $NF_WORK"; exit 1; }
            fi
        fi
        # Manual rollback selects an existing runtime; never delete that target
        # when restoring the current launcher after a failed switch.
        if [[ ${NF_UPDATE_RETAIN_TARGET:-0} != 1 ]] && ! runtime_rollback_cleanup keep-cli; then
            log ERROR "Update cleanup incomplete; current CLI restored, evidence retained at $NF_WORK"
            exit 1
        fi
    fi
    rm -rf -- "$NF_WORK"
    exit "$status"
}
cli_update() (
    cli_load_state
    runtime_preinstall
    update_trust || die 'Cannot establish fixed update trust anchor'
    NF_UPDATE_PREVIOUS_VERSION=$NF_NODEFORGE_VERSION
    init_workspace
    trap update_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local target old_version=$NF_NODEFORGE_VERSION previous file
    previous=$(update_previous_version) || return 1
    [[ -z $previous ]] || update_validate_previous "$previous"
    update_snapshot_previous
    target=$(python3 "$NF_SOURCE/lib/update.py" "$NF_NODEFORGE_VERSION" "$NF_WORK" "$NF_CONFIG_DIR/trust/release-ed25519.pub") || return 1
    if [[ $target == "$old_version" ]]; then
        printf 'NodeForge %s is current; no update needed\n' "$old_version"
        return 0
    fi
    printf 'NodeForge update: %s -> %s\n' "$old_version" "$target"
    NF_SOURCE=$NF_WORK/extracted/nodeforge-$target
    load_nodeforge_version
    [[ $NF_NODEFORGE_VERSION == "$target" ]] || die 'Update VERSION mismatch'
    cmp -s "$NF_SOURCE/trust/release-ed25519.pub" "$NF_CONFIG_DIR/trust/release-ed25519.pub" || die 'Update cannot replace the trust anchor'
    runtime_check_paths
    [[ ! -e $NF_RUNTIME && ! -e $NF_RUNTIME_STAGE ]] || die 'Update target already exists; refusing conflict'
    # The old engine defines the file set and performs publication/rollback.
    while IFS= read -r file; do require_regular "$NF_SOURCE/$file"; done < <(runtime_files)
    NF_PENDING=$NF_WORK/runtime-transaction
    mkdir "$NF_PENDING"
    runtime_intent > "$NF_PENDING/cli-created"
    cp -p "$NF_CLI" "$NF_WORK/old-launcher"
    NF_UPDATE_ACTIVE=1
    runtime_stage || return 1
    runtime_publish || return 1
    update_check_runtime "$NF_RUNTIME" || return 1
    runtime_launcher > "$NF_WORK/new-launcher" || return 1
    NF_UPDATE_SWITCHED=1
    atomic_install "$NF_WORK/new-launcher" "$NF_CLI" 755 root root || return 1
    [[ $(bash "$NF_CLI" version) == "NodeForge $target" ]] || die 'Updated CLI version check failed'
    update_check_runtime "$NF_RUNTIME" || return 1
    printf '%s\n' "$old_version" > "$NF_WORK/new-previous"
    NF_UPDATE_METADATA_CHANGED=1
    atomic_install "$NF_WORK/new-previous" "$NF_APP/previous" 600 root root || return 1
    NF_UPDATE_ACTIVE=0
    # Keep the immediate predecessor only. Unknown files remain protected by
    # the same validated-inventory retirement used before previous retention.
    if [[ -n $previous ]]; then
        runtime_retire_version "$previous" || warn 'Updated successfully; older runtime cleanup incomplete, preserved remaining files'
    fi
    printf 'NodeForge updated: %s -> %s; version and status healthy\n' "$old_version" "$target"
)

cli_rollback() (
    cli_require_root
    runtime_preinstall
    local current=$NF_NODEFORGE_VERSION target
    target=$(update_previous_version) || return 1
    [[ -n $target ]] || die 'No rollback version available'
    cli_load_state
    update_validate_previous "$target"
    printf 'NodeForge rollback: %s -> %s\n' "$current" "$target"
    init_workspace
    trap update_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    NF_SWITCH_OPERATION=Rollback
    NF_UPDATE_PREVIOUS_VERSION=$current
    NF_UPDATE_RETAIN_TARGET=1
    update_snapshot_previous
    cp -p "$NF_CLI" "$NF_WORK/old-launcher"
    NF_NODEFORGE_VERSION=$target
    runtime_paths
    update_check_runtime "$NF_RUNTIME" || return 1
    runtime_launcher > "$NF_WORK/new-launcher" || return 1
    NF_UPDATE_ACTIVE=1
    NF_UPDATE_SWITCHED=1
    atomic_install "$NF_WORK/new-launcher" "$NF_CLI" 755 root root || return 1
    [[ $(bash "$NF_CLI" version) == "NodeForge $target" ]] || die 'Rollback CLI version check failed'
    update_check_runtime "$NF_RUNTIME" || return 1
    NF_UPDATE_METADATA_CHANGED=1
    rm -- "$NF_APP/previous" || return 1
    NF_UPDATE_ACTIVE=0
    runtime_retire_version "$current" || warn 'Rolled back successfully; newer runtime cleanup incomplete, preserved remaining files'
    printf 'NodeForge rolled back: %s -> %s; version and status healthy\n' "$current" "$target"
)
