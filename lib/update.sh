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
update_cleanup() {
    local status=${1:-$?}
    trap - EXIT INT TERM
    if [[ ${NF_UPDATE_ACTIVE:-0} == 1 ]]; then
        warn "Update failed; rollback target: $NF_UPDATE_PREVIOUS_VERSION"
        if [[ ${NF_UPDATE_SWITCHED:-0} == 1 ]]; then
            if ! restore_snapshot_file "$NF_WORK/old-launcher" "$NF_CLI"; then
                log ERROR "CLI restore failed; old runtime and recovery files retained at $NF_WORK"
                exit 1
            fi
        fi
        if ! runtime_rollback_cleanup keep-cli; then
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
    local target old_source=$NF_SOURCE old_version=$NF_NODEFORGE_VERSION old_runtime=$NF_RUNTIME file
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
    NF_UPDATE_ACTIVE=0
    # Retire only the old, validated inventory after the new CLI passes checks.
    # Failure to retire does not undo a healthy update or delete unknown files.
    (
        NF_SOURCE=$old_source NF_NODEFORGE_VERSION=$old_version
        runtime_paths
        runtime_validate
        while IFS= read -r file; do rm -f -- "$old_runtime/$file" || exit 1; done < <(runtime_files)
        rm -f -- "$old_runtime/.inventory" || exit 1
        rmdir -- "$old_runtime/lib" "$old_runtime/templates" "$old_runtime/tools" "$old_runtime/trust" "$old_runtime"
    ) || warn 'Updated successfully; old runtime cleanup incomplete, preserved remaining files'
    printf 'NodeForge updated: %s -> %s; version and status healthy\n' "$old_version" "$target"
)
