#!/usr/bin/env bash
# Retirement deliberately selects a version inside its own subshell only.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

# Fixed local install inventory. This is ownership metadata, not a signed release.
runtime_files() {
    printf '%s\n' VERSION nodeforge.sh templates/vless-reality.json templates/nodeforge-xray.service templates/nodeforge-hysteria.service \
        lib/common.sh lib/defaults.sh lib/version.sh lib/state.sh lib/system.sh lib/xray.sh \
        lib/hysteria.sh lib/reality.sh lib/config.sh lib/service.sh lib/transaction.sh lib/share.sh \
        lib/runtime.sh lib/update.sh lib/update.py lib/cli.sh lib/network.py lib/management.py \
        tools/release.py trust/release-ed25519.pub lib/argo.sh lib/argo_runtime.py \
        lib/argo_ws.sh lib/argo_xhttp.sh lib/argo_provision.py templates/vless-ws.json templates/vless-xhttp.json \
        templates/nodeforge-argo.service templates/nodeforge-argo-xray.service \
        lib/subscription.sh lib/subscription.py templates/nodeforge-subscription.service lib/warp.sh lib/diagnostics.sh
}
runtime_paths() {
    NF_APP=$NF_BIN_DIR/app
    NF_RUNTIME=$NF_APP/releases/$NF_NODEFORGE_VERSION
    NF_RUNTIME_STAGE=$NF_APP/releases/.pending-$NF_NODEFORGE_VERSION
}
trusted_directory() {
    local path=$1 mode
    [[ -d $path && ! -L $path ]] || die 'Unsafe management directory'
    [[ $(stat -c %u "$path") == 0 ]] || die 'Management directory must be root-owned'
    mode=$(stat -c %a "$path")
    (( (8#$mode & 0022) == 0 )) || die 'Management directory is writable by group/others'
}
trusted_file() {
    local mode
    require_regular "$1"
    [[ $(stat -c %u "$1") == 0 ]] || die 'Management file must be root-owned'
    mode=$(stat -c %a "$1")
    (( (8#$mode & 0022) == 0 )) || die 'Management file is writable by group/others'
}
runtime_check_paths() {
    local path
    runtime_paths
    for path in /usr /usr/local "$(dirname "$NF_CLI")" "$NF_BIN_DIR" "$NF_APP" "$NF_APP/releases" "$NF_RUNTIME" "$NF_RUNTIME/lib" "$NF_RUNTIME/templates" "$NF_RUNTIME/tools" "$NF_RUNTIME/trust" "$NF_RUNTIME_STAGE" "$NF_RUNTIME_STAGE/lib" "$NF_RUNTIME_STAGE/templates" "$NF_RUNTIME_STAGE/tools" "$NF_RUNTIME_STAGE/trust"; do
        [[ ! -L $path && ( ! -e $path || -d $path ) ]] || die 'Unsafe CLI installation path'
        if [[ -d $path ]]; then trusted_directory "$path"; fi
    done
    [[ ! -L $NF_CLI && ( ! -e $NF_CLI || -f $NF_CLI ) ]] || die 'Unsafe CLI entry path'
}
runtime_inventory() {
    local root=$1 file digest
    while IFS= read -r file; do
        ( require_regular "$root/$file" ) || return 1
        digest=$(sha256_file "$root/$file") || return 1
        printf '%s  %s\n' "$digest" "$file" || return 1
    done < <(runtime_files)
}
runtime_launcher() {
    # Version comes only from VERSION; the installed entry pins one module set.
    printf '#!/bin/bash\nset -Eeuo pipefail\nexec /bin/bash %q "$@"\n' "$NF_RUNTIME/nodeforge.sh"
}
runtime_validate() {
    local root=${1:-$NF_RUNTIME} file actual
    runtime_check_paths
    trusted_file "$root/.inventory"
    while IFS= read -r file; do trusted_file "$root/$file"; done < <(runtime_files)
    [[ $(cat "$root/VERSION") == "$NF_NODEFORGE_VERSION" ]] || die 'Runtime VERSION mismatch'
    actual=$(runtime_inventory "$root") || die 'Cannot read runtime inventory'
    [[ $actual == "$(cat "$root/.inventory")" ]] || die 'CLI runtime integrity check failed'
}
runtime_preinstall() {
    runtime_check_paths
    [[ ! -e $NF_RUNTIME_STAGE ]] || die 'Unowned runtime staging exists'
    if [[ -e $NF_RUNTIME ]]; then
        runtime_validate
        cmp -s <(runtime_inventory "$NF_SOURCE") "$NF_RUNTIME/.inventory" || die 'Installed CLI version differs from source; in-place runtime replacement is not supported'
        trusted_file "$NF_CLI"
        cmp -s <(runtime_launcher) "$NF_CLI" || die 'Unmanaged CLI entry'
    elif [[ -e $NF_CLI || -e $NF_APP ]]; then
        die 'Unmanaged CLI installation exists'
    fi
}
install_cli_runtime() {
    local file
    runtime_check_paths
    if [[ -e $NF_RUNTIME ]]; then
        ( runtime_preinstall ) || return 1
        return 0
    fi
    [[ ! -e $NF_RUNTIME_STAGE && ! -e $NF_RUNTIME && ! -e $NF_CLI ]] || return 1
    # Record intent before publishing anything; existing runtime is immutable.
    runtime_intent > "$NF_WORK/cli-intent" || return 1
    atomic_install "$NF_WORK/cli-intent" "$NF_PENDING/cli-created" 600 root root || return 1
    install -d -m 755 "$NF_APP" "$NF_APP/releases" "$(dirname "$NF_CLI")" || return 1
    runtime_stage || return 1
    runtime_publish || return 1
    runtime_launcher > "$NF_WORK/cli-entry" || return 1
    atomic_install "$NF_WORK/cli-entry" "$NF_CLI" 755 root root || return 1
}
runtime_stage() {
    local file expected actual
    install -d -m 755 "$NF_RUNTIME_STAGE" "$NF_RUNTIME_STAGE/lib" "$NF_RUNTIME_STAGE/templates" "$NF_RUNTIME_STAGE/tools" "$NF_RUNTIME_STAGE/trust" || return 1
    while IFS= read -r file; do
        ( require_regular "$NF_SOURCE/$file" ) || return 1
        install -m 644 -o root -g root "$NF_SOURCE/$file" "$NF_RUNTIME_STAGE/$file" || return 1
    done < <(runtime_files)
    runtime_inventory "$NF_RUNTIME_STAGE" > "$NF_RUNTIME_STAGE/.inventory" || return 1
    chmod 644 "$NF_RUNTIME_STAGE/.inventory" || return 1
    ( runtime_validate "$NF_RUNTIME_STAGE" ) || return 1
    expected=$(runtime_inventory "$NF_SOURCE") || return 1
    actual=$(runtime_inventory "$NF_RUNTIME_STAGE") || return 1
    [[ $actual == "$expected" ]] || return 1
}
runtime_publish() {
    python3 "$NF_SOURCE/lib/management.py" rename-directory "$NF_RUNTIME_STAGE" "$NF_RUNTIME"
}
# Retire only the existing validated inventory, preserving unknown contents.
runtime_retire_version() (
    local file NF_NODEFORGE_VERSION=$1 NF_APP NF_RUNTIME NF_RUNTIME_STAGE
    runtime_paths
    runtime_validate
    while IFS= read -r file; do rm -f -- "$NF_RUNTIME/$file" || return 1; done < <(runtime_files)
    rm -f -- "$NF_RUNTIME/.inventory" || return 1
    rmdir -- "$NF_RUNTIME/lib" "$NF_RUNTIME/templates" "$NF_RUNTIME/tools" "$NF_RUNTIME/trust" "$NF_RUNTIME"
)
runtime_intent() {
    printf 'NodeForge local runtime creation\nversion=%s\nparent=%s\nstage=%s\nfinal=%s\nlauncher=%s\n' \
        "$NF_NODEFORGE_VERSION" "$NF_APP/releases" "$NF_RUNTIME_STAGE" "$NF_RUNTIME" "$NF_CLI"
}
# Only used with an exact, protected creation record written before mkdir/copy.
# No paths are read from that record. Installed uninstall still uses inventory.
runtime_rollback_cleanup() {
    local root file keep_cli=${1:-no}
    runtime_paths
    ( runtime_check_paths; trusted_file "$NF_PENDING/cli-created" ) || return 1
    cmp -s <(runtime_intent) "$NF_PENDING/cli-created" || return 1
    # Validate every existing known path before deleting any of them.
    for root in "$NF_RUNTIME_STAGE" "$NF_RUNTIME"; do
        while IFS= read -r file; do
            if [[ -e $root/$file || -L $root/$file ]]; then
                ( trusted_file "$root/$file" ) || return 1
            fi
        done < <(runtime_files; printf '%s\n' .inventory)
    done
    if [[ $keep_cli != keep-cli && -e $NF_CLI ]]; then
        ( trusted_file "$NF_CLI" ) || return 1
        cmp -s <(runtime_launcher) "$NF_CLI" || return 1
        rm -f -- "$NF_CLI" || return 1
    fi
    for root in "$NF_RUNTIME_STAGE" "$NF_RUNTIME"; do
        [[ -d $root ]] || continue
        while IFS= read -r file; do rm -f -- "$root/$file" || return 1; done < <(runtime_files; printf '%s\n' .inventory)
        for file in lib templates tools trust; do
            if [[ -d $root/$file ]]; then rmdir -- "$root/$file" || return 1; fi
        done
        # Unknown contents are not erased; they keep recovery pending.
        rmdir -- "$root" || return 1
    done
    [[ $keep_cli != keep-cli ]] || return 0
    for root in "$NF_APP/releases" "$NF_APP"; do
        if [[ -d $root ]]; then rmdir -- "$root" || return 1; fi
    done
}
runtime_remove() {
    local file previous
    runtime_check_paths
    if [[ -e $NF_RUNTIME ]]; then runtime_validate; fi
    previous=$(update_previous_version) || return 1
    if [[ -n $previous ]]; then
        runtime_retire_version "$previous" || return 1
        rm -- "$NF_APP/previous" || return 1
    fi
    update_remove_trust || return 1
    if [[ -e $NF_CLI ]]; then
        trusted_file "$NF_CLI"
        cmp -s <(runtime_launcher) "$NF_CLI" || die 'Unmanaged CLI entry'
        rm -f -- "$NF_CLI" || return 1
    fi
    if [[ -d $NF_RUNTIME ]]; then
        # Delete only validated, explicitly named files; preserve unknown contents.
        while IFS= read -r file; do rm -f -- "$NF_RUNTIME/$file" || return 1; done < <(runtime_files)
        rm -f -- "$NF_RUNTIME/.inventory" || return 1
        rmdir -- "$NF_RUNTIME/lib" "$NF_RUNTIME/templates" "$NF_RUNTIME/tools" "$NF_RUNTIME/trust" "$NF_RUNTIME" 2>/dev/null || warn 'Preserved unknown CLI runtime files'
    fi
    rmdir -- "$NF_APP/releases" "$NF_APP" 2>/dev/null || true
}
runtime_preuninstall() {
    runtime_check_paths
    local previous
    previous=$(update_previous_version) || return 1
    [[ -z $previous ]] || update_validate_previous "$previous"
    if [[ -e $NF_RUNTIME ]]; then runtime_validate; fi
    if [[ -e $NF_CLI ]]; then
        [[ -d $NF_RUNTIME ]] || die 'CLI entry has no trusted runtime'
        trusted_file "$NF_CLI"
        cmp -s <(runtime_launcher) "$NF_CLI" || die 'Unmanaged CLI entry'
    fi
}
