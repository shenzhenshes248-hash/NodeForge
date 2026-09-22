#!/usr/bin/env bash
set -Eeuo pipefail

warp_load() {
    NF_WARP_STATE=$NF_DATA_DIR/warp.json
    NF_WARP_MODE=disabled
    if [[ -e $NF_WARP_STATE || -L $NF_WARP_STATE ]]; then
        trusted_file "$NF_WARP_STATE"
        jq -e '.owner == "NodeForge" and .schema == 1 and
            (.mode == "enabled" or .mode == "disabled")' "$NF_WARP_STATE" >/dev/null || die 'Invalid WARP state'
        NF_WARP_MODE=$(jq -r '.mode' "$NF_WARP_STATE")
    fi
}

warp_generate_xray() {
    warp_load
    [[ $NF_WARP_MODE == enabled ]] || return 0
    python3 "$NF_SOURCE/lib/management.py" warp-xray enabled "$1" > "$1.warp"
    mv -f -- "$1.warp" "$1"
}

warp_cli() { timeout 30 warp-cli --accept-tos "$@"; }

warp_install() {
    if ! dpkg-query -W -f='${Status}' cloudflare-warp 2>/dev/null | grep -qx 'install ok installed'; then
        detect_platform /etc/os-release "$(uname -m)"
        local codename
        codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')
        [[ $codename =~ ^[a-z]+$ ]] || die 'Cannot determine distribution codename'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gpg
        curl --noproxy '*' -fsSL https://pkg.cloudflareclient.com/pubkey.gpg |
            gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        chmod 644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" > /etc/apt/sources.list.d/cloudflare-client.list
        chmod 644 /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cloudflare-warp
    fi
    systemctl enable --now warp-svc.service >/dev/null
}

warp_connect() {
    local registration attempt settings
    warp_install
    if ! registration=$(warp_cli registration show 2>&1); then
        if grep -qi 'Missing registration' <<< "$registration"; then
            warp_cli registration new >/dev/null
        else
            die 'Cannot read WARP registration; existing registration was not replaced'
        fi
    fi
    # Syntax verified against the official current Linux CLI; fail on an
    # incompatible CLI rather than falling back to a full-device tunnel.
    warp_cli mode --help | grep 'proxy' >/dev/null || die 'WARP proxy mode unavailable'
    warp_cli proxy port --help >/dev/null
    warp_cli tunnel protocol set --help | grep MASQUE >/dev/null || die 'WARP MASQUE unavailable'
    warp_cli mode proxy >/dev/null
    warp_cli proxy port 40000 >/dev/null
    warp_cli tunnel protocol set MASQUE >/dev/null
    settings=$(warp_cli settings)
    grep -q 'Mode: WarpProxy on port 40000' <<< "$settings" || die 'WARP did not select Local Proxy'
    grep -q 'WARP tunnel protocol: MASQUE' <<< "$settings" || die 'WARP did not select MASQUE'
    warp_cli connect >/dev/null
    for attempt in {1..15}; do
        if warp_cli status | grep 'Status update: Connected' >/dev/null; then
            if curl --noproxy '' --proxy socks5h://127.0.0.1:40000 -fsS --connect-timeout 3 --max-time 8 \
                https://www.cloudflare.com/cdn-cgi/trace | grep -x 'warp=on' >/dev/null; then return 0; fi
        fi
        sleep 1
    done
    die 'WARP Local Proxy is not ready; node egress was not changed'
}

warp_status() {
    warp_load
    local connection='Disconnected' original exit_ip='unavailable'
    if command -v warp-cli >/dev/null && warp_cli status 2>/dev/null | grep 'Status update: Connected' >/dev/null; then
        connection=Connected
        exit_ip=$(curl --noproxy '' --proxy socks5h://127.0.0.1:40000 -4 -fsS --connect-timeout 3 --max-time 8 https://api.ipify.org 2>/dev/null) || exit_ip=unavailable
    fi
    original=$(curl --noproxy '*' -4 -fsS --connect-timeout 3 --max-time 8 https://api.ipify.org 2>/dev/null) || original=unavailable
    printf 'WARP: %s\nConnection: %s\nLocal Proxy: socks5h://127.0.0.1:40000\nVPS IP: %s\nWARP IP: %s\n' \
        "$NF_WARP_MODE" "$connection" "$original" "$exit_ip"
    if [[ $NF_WARP_MODE == enabled ]]; then
        printf 'Reality: WARP\nArgo: WARP\n'
    else
        printf 'Reality: direct\nArgo: direct\n'
    fi
    if grep -q '^# NodeForge WARP outbound$' "$NF_HYSTERIA_CONFIG" 2>/dev/null; then
        printf 'HY2: legacy WARP; run nodeforge warp enable/disable to restore direct\n'
    else
        printf 'HY2: direct (VPS, TCP/UDP)\n'
    fi
}

warp_cleanup() {
    local status=$? i
    trap - EXIT INT TERM
    if [[ ${NF_WARP_CHANGING:-0} == 1 ]]; then
        warn 'WARP switch failed; restoring the previous node egress'
        systemctl stop "${warp_services[@]}" || true
        for i in "${!warp_files[@]}"; do
            restore_snapshot_file "$NF_WORK/warp-backup/$i" "${warp_files[$i]}" || status=1
        done
        systemctl start "${warp_services[@]}" || status=1
    fi
    if [[ $status != 0 && ${NF_WARP_PREVIOUS:-disabled} == disabled ]] && command -v warp-cli >/dev/null; then
        warp_cli disconnect >/dev/null 2>&1 || true
    fi
    cleanup "$status"
}

warp_switch() (
    local desired=$1 i hy_changed=0
    cli_load_state
    warp_load
    local NF_WARP_PREVIOUS=$NF_WARP_MODE NF_WARP_CHANGING=0
    argo_paths
    local -a warp_files=("$NF_CONFIG" "$NF_STATE")
    local -a warp_services=("$NF_SERVICE")
    if [[ -d $NF_ARGO_DIR ]]; then
        load_argo
        warp_files+=("$NF_ARGO_DIR/xray.json" "$NF_ARGO_DIR/state.json")
        warp_services+=("$NF_ARGO_XRAY_SERVICE")
    fi
    init_workspace
    trap warp_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Restore the v0.6.0 HY2 proxy policy once, including repeated enable.
    # Normal WARP toggles neither rewrite nor restart an already-direct HY2.
    if grep -q '^# NodeForge WARP outbound$' "$NF_HYSTERIA_CONFIG"; then
        python3 "$NF_SOURCE/lib/management.py" warp-hysteria disabled "$NF_HYSTERIA_CONFIG" > "$NF_WORK/warp-hysteria.yaml"
        hy_changed=1
        warp_files+=("$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")
        warp_services+=("$NF_HYSTERIA_SERVICE")
    fi
    if [[ $desired == enabled ]]; then warp_connect; fi
    if [[ $desired != "$NF_WARP_MODE" || $hy_changed == 1 ]]; then
        mkdir "$NF_WORK/warp-backup"
        for i in "${!warp_files[@]}"; do cp -p -- "${warp_files[$i]}" "$NF_WORK/warp-backup/$i"; done
        python3 "$NF_SOURCE/lib/management.py" warp-xray "$desired" "$NF_CONFIG" > "$NF_WORK/warp-xray.json"
        test_xray_config "$NF_BIN" "$NF_WORK/warp-xray.json"
        if [[ -d $NF_ARGO_DIR ]]; then
            python3 "$NF_SOURCE/lib/management.py" warp-xray "$desired" "$NF_ARGO_DIR/xray.json" > "$NF_WORK/warp-argo.json"
            test_xray_config "$NF_ARGO_DIR/xray" "$NF_WORK/warp-argo.json"
        fi
        NF_WARP_CHANGING=1
        systemctl stop "${warp_services[@]}"
        atomic_install "$NF_WORK/warp-xray.json" "$NF_CONFIG" 600 nodeforge nodeforge
        write_state
        if [[ $hy_changed == 1 ]]; then
            atomic_install "$NF_WORK/warp-hysteria.yaml" "$NF_HYSTERIA_CONFIG" 600 root root
            write_hysteria_state
        fi
        if [[ -d $NF_ARGO_DIR ]]; then
            atomic_install "$NF_WORK/warp-argo.json" "$NF_ARGO_DIR/xray.json" 640 root nodeforge
            jq --arg hash "$(sha256_file "$NF_ARGO_DIR/xray.json")" '.files["xray.json"]=$hash' \
                "$NF_ARGO_DIR/state.json" > "$NF_WORK/warp-argo-state.json"
            atomic_install "$NF_WORK/warp-argo-state.json" "$NF_ARGO_DIR/state.json" 600 root root
        fi
        systemctl start "${warp_services[@]}"
        wait_managed_service || die 'Reality failed after WARP switch'
        managed_hysteria_healthy || die 'HY2 failed after WARP switch'
        if [[ -d $NF_ARGO_DIR ]]; then systemctl is-active --quiet "$NF_ARGO_XRAY_SERVICE" || die 'Argo Xray failed after WARP switch'; fi
        jq -n --arg mode "$desired" '{owner:"NodeForge",schema:1,mode:$mode}' > "$NF_WORK/warp-state.json"
        atomic_install "$NF_WORK/warp-state.json" "$NF_WARP_STATE" 600 root root
        NF_WARP_CHANGING=0
    fi
    if [[ $desired == disabled ]] && command -v warp-cli >/dev/null; then warp_cli disconnect >/dev/null; fi
    printf 'WARP: %s\n' "$desired"
)

cli_warp() {
    case $1 in
        enable) warp_switch enabled ;;
        disable) warp_switch disabled ;;
        status) warp_status ;;
    esac
}
