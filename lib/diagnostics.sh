#!/usr/bin/env bash
set -Eeuo pipefail

# Local observations only. Keep failures isolated so doctor can finish its report.
diagnostic_egress() {
    python3 - "$NF_SOURCE/lib" "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from management import WARP_HYSTERIA, warp_hysteria, warp_xray
try:
    text = Path(sys.argv[3]).read_text()
    if sys.argv[2] == 'hy2':
        warp_hysteria(text, False)
        print('WARP' if text.endswith(WARP_HYSTERIA) else 'direct')
    else:
        config = json.loads(text)
        mode = config.get('outbounds', [{}])[0].get('tag') == 'warp'
        warp_xray(config, mode)
        print('WARP' if mode else 'direct')
except (OSError, ValueError, KeyError, IndexError, TypeError):
    print('unknown')
PY
}

diagnostic_named_tunnel() {
    python3 - "$NF_ARGO_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path
try:
    root = Path(sys.argv[1])
    credentials = json.loads((root / 'credentials.json').read_text())
    config = json.loads((root / 'cloudflared.yml').read_text())
    state = json.loads((root / 'state.json').read_text())
    assert re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', credentials['TunnelID'])
    assert all(isinstance(credentials[k], str) and credentials[k] for k in ('AccountTag', 'TunnelSecret'))
    assert config['tunnel'] == credentials['TunnelID']
    assert Path(config['credentials-file']) == root / 'credentials.json'
    assert config['ingress'][0]['hostname'] == state['tunnel_domain'] and state['tunnel_domain']
except (OSError, ValueError, KeyError, IndexError, TypeError, AssertionError):
    sys.exit(1)
PY
}

diagnostic_issue() {
    local severity=$1 label=$2 reason=$3 command=$4
    if [[ $severity == FAILED ]]; then result=Failed
    elif [[ $result == Healthy ]]; then result=Warning; fi
    if [[ $detail == doctor ]]; then
        printf '%s: %s\nReason: %s\nSuggested: %s\n' "$label" "$severity" "$reason" "$command"
    fi
}

cli_diagnostics() (
    local detail=$1 result=Healthy profile=unknown reality=failed hy2=failed argo=failed
    local domain='' warp=unknown connection=Disconnected subscription=missing re he ae
    argo_paths
    subscription_paths
    # Existing loaders exit on corrupt state; isolate their validation first.
    if (cli_load_state) >/dev/null 2>&1; then
        cli_load_state >/dev/null 2>&1
        if managed_service_healthy >/dev/null 2>&1; then reality=running; fi
        if managed_hysteria_healthy >/dev/null 2>&1; then hy2=running; fi
    fi
    [[ -d $NF_ARGO_DIR ]] || argo="not installed"
    profile=$(argo_installed_profile 2>/dev/null) || profile=unknown
    local argo_valid=no named_valid=no
    if (load_argo) >/dev/null 2>&1; then
        argo_valid=yes
        if [[ $profile == ws ]] || diagnostic_named_tunnel; then named_valid=yes; fi
        if timeout 3 systemctl is-active --quiet "$NF_ARGO_SERVICE" >/dev/null 2>&1 &&
            timeout 3 systemctl is-active --quiet "$NF_ARGO_XRAY_SERVICE" >/dev/null 2>&1; then argo=running; fi
        domain=$(argo_current_domain 2>/dev/null) || domain=''
    fi
    warp=$( (warp_load; printf '%s' "$NF_WARP_MODE") 2>/dev/null) || warp=unknown
    if command -v warp-cli >/dev/null && warp_cli status 2>/dev/null | grep -q '^Status update: Connected$'; then connection=Connected; fi
    [[ ! -f $NF_SUB_DIR/sub.txt ]] || subscription=OK
    re=$(diagnostic_egress xray "$NF_CONFIG")
    ae=$(diagnostic_egress xray "$NF_ARGO_DIR/xray.json")
    he=$(diagnostic_egress hy2 "$NF_HYSTERIA_CONFIG")
    printf 'NodeForge %s\nProfile: %s\n\n' "$NF_NODEFORGE_VERSION" "$profile"
    if [[ $detail == status ]]; then
        printf 'Reality: %s\nHY2: %s\nArgo %s: %s\n\n' "$reality" "$hy2" "${profile^^}" "$argo"
    else
        [[ $reality != running ]] || printf 'Reality: OK (service + TCP listener)\n'
        [[ $hy2 != running ]] || printf 'HY2: OK (service + UDP listener)\n'
        [[ $argo != running ]] || printf 'Argo %s: OK (Xray + cloudflared services)\n' "${profile^^}"
    fi
    [[ $reality == running ]] || diagnostic_issue FAILED Reality 'state, service or TCP listener unavailable' 'nodeforge restart'
    [[ $hy2 == running ]] || diagnostic_issue FAILED HY2 'state, service or UDP listener unavailable' 'nodeforge restart'
    if [[ -d $NF_ARGO_DIR ]]; then
    [[ $profile != unknown ]] || diagnostic_issue FAILED Profile 'transport unavailable' 'nodeforge info'
    [[ $argo_valid == yes ]] || diagnostic_issue FAILED Argo 'state/config unavailable' 'nodeforge info'
    [[ $argo == running ]] || diagnostic_issue FAILED Argo 'service unavailable' 'nodeforge restart'
    if [[ $profile == xhttp ]]; then
        if [[ $named_valid == yes ]]; then
            [[ $detail != doctor ]] || printf 'Named Tunnel / credentials: OK\n'
        else diagnostic_issue FAILED Argo 'Named Tunnel or credentials unavailable' 'nodeforge info'; fi
    fi
    if [[ -n $domain ]]; then
        [[ $detail != doctor ]] || printf 'Tunnel hostname: %s\n' "$domain"
    else diagnostic_issue FAILED Argo 'tunnel hostname unavailable' 'nodeforge restart'; fi
    else diagnostic_issue WARNING Argo 'not installed' 'nodeforge info'; fi
    printf 'Reality egress: %s\nArgo egress: %s\nHY2 egress: %s\n\nWARP: %s\n' "$re" "$ae" "$he" "$warp"
    [[ $detail != doctor ]] || printf 'Connection: %s\n' "$connection"
    if [[ $warp == unknown || $re == unknown || $ae == unknown || $he == unknown ]]; then
        diagnostic_issue WARNING Egress 'state or outbound policy unavailable' 'nodeforge info'
    elif [[ $warp == enabled && ( $re != WARP || $ae != WARP ) || $warp == disabled && ( $re != direct || $ae != direct ) || $he != direct ]]; then
        diagnostic_issue WARNING Egress 'outbound policy differs from WARP state' 'nodeforge warp status'
    fi
    if [[ $warp == enabled && $connection != Connected || ( $re == WARP || $ae == WARP || $he == WARP ) && $connection != Connected ]]; then
        diagnostic_issue FAILED WARP 'Local Proxy is not Connected' 'nodeforge warp status'
    fi
    printf 'Subscription: %s\n' "$subscription"
    [[ $subscription == OK ]] || diagnostic_issue WARNING Subscription 'subscription/sub.txt missing' 'nodeforge link'
    if [[ $detail == doctor ]]; then
        local xv hv cv
        xv=$(timeout 3 "$NF_BIN" version 2>/dev/null | awk 'NR == 1 && $1 == "Xray" {print $2}') || xv=''
        hv=$(timeout 3 "$NF_HYSTERIA_BIN" version 2>/dev/null | awk '$1 == "Version:" {print $2}') || hv=''
        cv=$(timeout 3 "$NF_ARGO_DIR/cloudflared" --version 2>/dev/null | awk '$1 == "cloudflared" && $2 == "version" {print $3}') || cv=''
        printf 'Xray version: %s\nHY2 version: %s\ncloudflared version: %s\n' "${xv:-unavailable}" "${hv:-unavailable}" "${cv:-unavailable}"
        [[ -n $xv && -n $hv && -n $cv ]] || diagnostic_issue WARNING Versions 'binary version unavailable' 'nodeforge info'
    fi
    printf '\n%s\n' "$result"
    [[ $result != Failed ]]
)
