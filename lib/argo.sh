#!/usr/bin/env bash
# The legacy runtime is sourced only inside its own validation subshell.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

argo_paths() {
    NF_ARGO_DIR=$NF_BIN_DIR/argo
    NF_ARGO_UNIT=$(dirname "$NF_UNIT")/nodeforge-argo.service
    NF_ARGO_XRAY_UNIT=$(dirname "$NF_UNIT")/nodeforge-argo-xray.service
    NF_ARGO_SERVICE=nodeforge-argo.service
    NF_ARGO_XRAY_SERVICE=nodeforge-argo-xray.service
    NF_ARGO_CURRENT=${NF_ARGO_CURRENT:-/run/nodeforge-argo/current.json}
}

argo_files() { printf '%s\n' cloudflared xray xray.json cloudflared.yml runner.py state.json credentials.json; }

argo_profile_load() {
    case $1 in
        ws) source "$NF_SOURCE/lib/argo_ws.sh" ;;
        xhttp) source "$NF_SOURCE/lib/argo_xhttp.sh" ;;
        *) die 'Profile must be ws or xhttp' ;;
    esac
}

argo_installed_profile() {
    jq -er '.inbounds[0].streamSettings.network | select(. == "ws" or . == "xhttp")' "$NF_ARGO_DIR/xray.json"
}

argo_select_profile() {
    argo_paths
    local installed requested=${NF_REQUESTED_PROFILE:-}
    if [[ -e $NF_ARGO_DIR || -L $NF_ARGO_DIR ]]; then
        load_argo
        installed=$(argo_installed_profile) || die 'Unsupported installed Argo transport'
        [[ -z $requested || $requested == "$installed" ]] || die "Installed profile is $installed; in-place profile switching is not supported"
        NF_PROFILE=$installed
    else
        NF_PROFILE=${requested:-ws}
    fi
    argo_profile_load "$NF_PROFILE"
}

fetch_cloudflared() {
    local asset expected version
    case $NF_ARCH in
        64) asset=cloudflared-linux-amd64 ;;
        arm64-v8a) asset=cloudflared-linux-arm64 ;;
        *) die 'Unsupported cloudflared architecture' ;;
    esac
    download_https https://api.github.com/repos/cloudflare/cloudflared/releases/latest "$NF_WORK/cloudflared-release.json"
    version=$(jq -er '.tag_name | select(test("^[0-9]{4}\\.[0-9]+\\.[0-9]+$"))' "$NF_WORK/cloudflared-release.json")
    expected=$(jq -er --arg asset "$asset" \
        '[.assets[] | select(.name == $asset) | .digest] | select(length == 1) | .[0] |
         select(test("^sha256:[0-9a-f]{64}$")) | ltrimstr("sha256:")' "$NF_WORK/cloudflared-release.json") || die 'Official cloudflared SHA-256 unavailable'
    download_https "https://github.com/cloudflare/cloudflared/releases/download/$version/$asset" "$NF_WORK/cloudflared"
    [[ $(sha256_file "$NF_WORK/cloudflared") == "$expected" ]] || die 'cloudflared checksum mismatch'
    chmod 755 "$NF_WORK/cloudflared"
    "$NF_WORK/cloudflared" --version > "$NF_WORK/cloudflared-version"
    grep -Fq "cloudflared version $version " "$NF_WORK/cloudflared-version" || die 'cloudflared version mismatch'
    NF_CLOUDFLARED_VERSION=$version
}

generate_argo_config() {
    local uuid port
    uuid=$("$NF_BIN" uuid)
    validate_uuid "$uuid" || die 'Invalid Argo UUID'
    port=$(python3 - "$NF_PORT" <<'PY'
import socket
import sys
for _ in range(100):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
        if port >= 1024 and port != int(sys.argv[1]):
            print(port)
            break
else:
    raise SystemExit('No independent Argo port available')
PY
    )
    jq --arg uuid "$uuid" --argjson port "$port" \
        '.inbounds[0].port=$port | .inbounds[0].settings.clients[0].id=$uuid' \
        "$(argo_profile_template)" > "$NF_WORK/argo-xray.json"
    warp_generate_xray "$NF_WORK/argo-xray.json"
    test_xray_config "$NF_BIN" "$NF_WORK/argo-xray.json"
}

load_argo() {
    argo_paths
    trusted_directory "$NF_ARGO_DIR"
    trusted_file "$NF_ARGO_DIR/state.json"
    jq -e '.owner == "NodeForge" and .schema == 1 and
        (.cloudflared_version | test("^[0-9]{4}\\.[0-9]+\\.[0-9]+$"))' "$NF_ARGO_DIR/state.json" >/dev/null || die 'Invalid Argo state'
    local file
    for file in cloudflared xray xray.json cloudflared.yml runner.py; do
        trusted_file "$NF_ARGO_DIR/$file"
        [[ $(sha256_file "$NF_ARGO_DIR/$file") == "$(jq -er --arg file "$file" '.files[$file]' "$NF_ARGO_DIR/state.json")" ]] || die "Argo $file changed outside NodeForge"
    done
    if jq -e '.tunnel_domain != null' "$NF_ARGO_DIR/state.json" >/dev/null; then
        trusted_file "$NF_ARGO_DIR/credentials.json"
        [[ $(sha256_file "$NF_ARGO_DIR/credentials.json") == "$(jq -er '.files["credentials.json"]' "$NF_ARGO_DIR/state.json")" ]] || die 'Argo tunnel credentials changed outside NodeForge'
    fi
    # v0.4.1 and early M5 differ only in their human-readable descriptions.
    cmp -s <(sed '/^Description=/d' "$NF_ARGO_UNIT") <(sed '/^Description=/d' "$NF_SOURCE/templates/nodeforge-argo.service") || die 'Unsupported Argo unit'
    cmp -s <(sed '/^Description=/d' "$NF_ARGO_XRAY_UNIT") <(sed '/^Description=/d' "$NF_SOURCE/templates/nodeforge-argo-xray.service") || die 'Unsupported Argo Xray unit'
}

argo_current_domain() {
    local invocation domain
    systemctl is-active --quiet "$NF_ARGO_SERVICE" || return 1
    systemctl is-active --quiet "$NF_ARGO_XRAY_SERVICE" || return 1
    invocation=$(systemctl show "$NF_ARGO_SERVICE" -p InvocationID --value) || return 1
    [[ $invocation =~ ^[0-9a-f]{32}$ ]] || return 1
    domain=$(jq -er --arg invocation "$invocation" \
        'select(.invocation_id == $invocation) | .domain |
         select(test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"))' \
        "$NF_ARGO_CURRENT" 2>/dev/null) || return 1
    if jq -e '.tunnel_domain != null' "$NF_ARGO_DIR/state.json" >/dev/null; then
        [[ $domain == "$(jq -er '.tunnel_domain' "$NF_ARGO_DIR/state.json")" ]] || return 1
    else
        [[ $domain == *.trycloudflare.com ]] || return 1
    fi
    # Do not emit the previous process's address across a service restart.
    [[ $(systemctl show "$NF_ARGO_SERVICE" -p InvocationID --value) == "$invocation" ]] || return 1
    printf '%s\n' "$domain"
}

argo_link() {
    argo_paths
    [[ -d $NF_ARGO_DIR ]] || return 0
    # Argo failure must not suppress Reality/HY2 links.
    if ! (load_argo) >/dev/null 2>&1; then warn 'Argo state unavailable; Reality/HY2 links are unaffected'; return 0; fi
    local domain uuid path address
    if ! domain=$(argo_current_domain); then
        warn 'Argo tunnel pending/offline; no current Argo link available'
        return 0
    fi
    uuid=$(jq -er '.inbounds[0].settings.clients[0].id' "$NF_ARGO_DIR/xray.json")
    argo_profile_load "$(argo_installed_profile)"
    path=$(argo_profile_path)
    address=www.shopify.com
    if [[ -f $NF_CONFIG_DIR/argo-edge.json ]]; then
        address=$(jq -r '.address' "$NF_CONFIG_DIR/argo-edge.json")
        address=${address:-www.shopify.com}
    fi
    printf 'vless://%s@%s:443?encryption=none&%s&security=tls&sni=%s&host=%s&path=%s#NodeForge-Argo\n' \
        "$uuid" "$address" "$(argo_profile_query)" "$domain" "$domain" "$(uri_encode "$path")"
}

argo_status() {
    argo_paths
    [[ -d $NF_ARGO_DIR ]] || return 0
    local domain
    if ! (load_argo) >/dev/null 2>&1; then printf 'Argo: invalid state\n'
    elif domain=$(argo_current_domain); then
        argo_profile_load "$(argo_installed_profile)"
        printf 'Argo: active (%s:443, %s)\n' "$domain" "$(argo_profile_label)"
    else printf 'Argo: pending/offline (Reality/HY2 independent)\n'; fi
}

remove_argo_files() {
    local file
    for file in "$NF_ARGO_UNIT" "$NF_ARGO_XRAY_UNIT"; do
        [[ -f $file ]] || continue
        systemctl stop "${file##*/}" || return 1
        systemctl disable "${file##*/}" || return 1
    done
    rm -f -- "$NF_ARGO_UNIT" "$NF_ARGO_XRAY_UNIT" || return 1
    while IFS= read -r file; do rm -f -- "$NF_ARGO_DIR/$file" || return 1; done < <(argo_files)
    rmdir -- "$NF_ARGO_DIR" || return 1
    systemctl daemon-reload
}

uninstall_argo() {
    argo_paths
    [[ -e $NF_ARGO_DIR ]] || return 0
    load_argo
    remove_argo_files
}

argo_install_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ ${NF_ARGO_CREATED:-0} == 1 ]]; then
        remove_argo_files || { log ERROR 'Argo cleanup incomplete; existing Reality/HY2 preserved'; status=1; }
    fi
    # Reuse the local runtime publication rollback; the old CLI stays available.
    update_cleanup "$status"
}

# Source-only baseline -> development runtime handoff. No remote release or tag.
argo_prepare_runtime() {
    runtime_paths
    if [[ -d $NF_RUNTIME ]]; then runtime_preinstall; return; fi
    local previous version
    trusted_file "$NF_CLI"
    version=$(bash "$NF_CLI" version)
    version=${version#NodeForge }
    case $version in v0.3.0|v0.4.0-dev|v0.4.1|v0.4.1-dev) ;; *) die 'Unsupported source upgrade baseline' ;; esac
    previous=$NF_APP/releases/$version
    [[ -d $previous && ! -e $NF_RUNTIME_STAGE ]] || die 'Expected installed baseline runtime'
    trusted_file "$previous/lib/runtime.sh"
    # Validate with the baseline's own inventory before publishing the new one.
    (
        NF_SOURCE=$previous
        NF_NODEFORGE_VERSION=$version
        source "$NF_SOURCE/lib/runtime.sh"
        runtime_preinstall
    )
    NF_PENDING=$NF_WORK/runtime-transaction
    mkdir "$NF_PENDING"
    runtime_intent > "$NF_PENDING/cli-created"
    cp -p "$NF_CLI" "$NF_WORK/old-launcher"
    NF_UPDATE_ACTIVE=1
    runtime_stage
    runtime_publish
}

install_argo() (
    cli_load_state
    argo_select_profile
    argo_profile_validate
    init_workspace
    trap argo_install_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local file
    if [[ -e $NF_ARGO_DIR || -L $NF_ARGO_DIR ]]; then
        load_argo
    else
        [[ ! -e $NF_ARGO_UNIT && ! -L $NF_ARGO_UNIT && ! -e $NF_ARGO_XRAY_UNIT && ! -L $NF_ARGO_XRAY_UNIT ]] || die 'Unmanaged Argo units exist'
        fetch_cloudflared
        generate_argo_config
        argo_profile_prepare
    fi
    argo_prepare_runtime
    if [[ ! -d $NF_ARGO_DIR ]]; then
        install -d -m 750 -o root -g nodeforge "$NF_ARGO_DIR"
        NF_ARGO_CREATED=1
        atomic_install "$NF_WORK/cloudflared" "$NF_ARGO_DIR/cloudflared" 755 root root
        # Independent copy: xray-update for Reality cannot replace Argo's core.
        atomic_install "$NF_BIN" "$NF_ARGO_DIR/xray" 755 root root
        atomic_install "$NF_WORK/argo-xray.json" "$NF_ARGO_DIR/xray.json" 640 root nodeforge
        atomic_install "$NF_SOURCE/lib/argo_runtime.py" "$NF_ARGO_DIR/runner.py" 644 root root
        atomic_install "$NF_WORK/cloudflared.yml" "$NF_ARGO_DIR/cloudflared.yml" 644 root root
        if [[ $NF_PROFILE == xhttp ]]; then
            atomic_install "$NF_WORK/credentials.json" "$NF_ARGO_DIR/credentials.json" 640 root nodeforge
        fi
        atomic_install "$NF_SOURCE/templates/nodeforge-argo.service" "$NF_ARGO_UNIT" 644 root root
        atomic_install "$NF_SOURCE/templates/nodeforge-argo-xray.service" "$NF_ARGO_XRAY_UNIT" 644 root root
        printf '{}\n' > "$NF_WORK/argo-files.json"
        for file in cloudflared xray xray.json cloudflared.yml runner.py; do
            jq --arg file "$file" --arg sha "$(sha256_file "$NF_ARGO_DIR/$file")" \
                '. + {($file):$sha}' "$NF_WORK/argo-files.json" > "$NF_WORK/argo-files.new"
            mv "$NF_WORK/argo-files.new" "$NF_WORK/argo-files.json"
        done
        if [[ $NF_PROFILE == xhttp ]]; then
            jq --arg sha "$(sha256_file "$NF_ARGO_DIR/credentials.json")" '. + {"credentials.json":$sha}' \
                "$NF_WORK/argo-files.json" > "$NF_WORK/argo-files.new"
            mv "$NF_WORK/argo-files.new" "$NF_WORK/argo-files.json"
        fi
        jq -n --arg version "$NF_CLOUDFLARED_VERSION" --arg profile "$NF_PROFILE" \
            --arg domain "${NF_ARGO_DOMAIN:-}" --slurpfile files "$NF_WORK/argo-files.json" \
            '{owner:"NodeForge",schema:1,profile:$profile,cloudflared_version:$version,files:$files[0]} +
             (if $profile == "xhttp" then {tunnel_domain:$domain} else {} end)' > "$NF_WORK/argo-state.json"
        atomic_install "$NF_WORK/argo-state.json" "$NF_ARGO_DIR/state.json" 600 root root
        timeout 20 runuser -u nodeforge -- "$NF_ARGO_DIR/xray" run -test -config "$NF_ARGO_DIR/xray.json" >/dev/null 2>&1 || die 'Argo Xray configuration test failed'
    fi
    systemctl daemon-reload
    systemctl enable "$NF_ARGO_XRAY_SERVICE" "$NF_ARGO_SERVICE"
    systemctl start "$NF_ARGO_XRAY_SERVICE" "$NF_ARGO_SERVICE"
    sleep 1
    systemctl is-active --quiet "$NF_ARGO_XRAY_SERVICE" || die 'Argo Xray failed to start'
    if [[ ${NF_UPDATE_ACTIVE:-0} == 1 ]]; then
        runtime_launcher > "$NF_WORK/new-launcher"
        NF_UPDATE_SWITCHED=1
        atomic_install "$NF_WORK/new-launcher" "$NF_CLI" 755 root root
    fi
    NF_UPDATE_ACTIVE=0 NF_ARGO_CREATED=0
    info 'Argo installed and enabled; tunnel connects asynchronously'
    argo_link
)
