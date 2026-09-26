#!/usr/bin/env bash
set -Eeuo pipefail
NF_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$NF_SOURCE/lib/common.sh"
load_modules
source "$NF_SOURCE/tests/helpers/assertions.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
NF_BIN_DIR=$root
NF_CONFIG=$root/reality.json
NF_HYSTERIA_CONFIG=$root/hysteria.yaml
NF_BIN=$root/xray
NF_HYSTERIA_BIN=$root/hysteria
NF_UNIT=$root/unit
mkdir -p "$root/argo" "$root/subscription"

cat > "$NF_BIN" <<'BIN'
#!/usr/bin/env bash
printf 'Xray 26.9.9\n'
BIN
cat > "$NF_HYSTERIA_BIN" <<'BIN'
#!/usr/bin/env bash
printf 'Version: v2.6.5\n'
BIN
cat > "$root/argo/cloudflared" <<'BIN'
#!/usr/bin/env bash
printf 'cloudflared version 2026.9.0\n'
BIN
chmod +x "$NF_BIN" "$NF_HYSTERIA_BIN" "$root/argo/cloudflared"
cli_require_root() { :; }
acquire_lock() { [[ $1 == shared ]]; }
cli_load_state() { :; }
managed_service_healthy() { [[ ! -e $root/fail-service ]]; }
managed_hysteria_healthy() { :; }
load_argo() { :; }
argo_installed_profile() { printf '%s\n' "$fixture_profile"; }
argo_current_domain() { [[ ! -e $root/fail-hostname ]] && printf '%s\n' "$fixture_domain"; }
timeout() { shift; "$@"; }
systemctl() { [[ $1 == is-active ]]; }
warp_load() { NF_WARP_MODE=$mode; }
warp_cli() {
    printf 'Status update: %s\r\n' "$connected"
    # A second write after the status line reproduces the original pipe race.
    sleep 0.02
    printf 'Network: healthy\n'
}
diagnostic_subscription() { [[ ! -e $root/fail-subscription ]]; }
warp-cli() { :; }
printf 'listen: :443\n' > "$NF_HYSTERIA_CONFIG"
fixture_profile=ws fixture_domain=fixture.trycloudflare.com mode=disabled connected=Disconnected
printf '{"outbounds":[{"tag":"direct","protocol":"freedom"}]}\n' > "$NF_CONFIG"
cp "$NF_CONFIG" "$root/argo/xray.json"
cli_main help > "$root/help"
grep -q 'Usage: nodeforge' "$root/help"
grep -q '^  doctor$' "$root/help"
cli_main --help > "$root/help2"
cmp "$root/help" "$root/help2"
cli_main status > "$root/status"
grep -q '^Profile: ws$' "$root/status"
grep -q '^Reality: running$' "$root/status"
grep -q '^WARP: disabled$' "$root/status"
grep -q '^Connection: Disconnected$' "$root/status"
grep -q '^Subscription: OK$' "$root/status"
cli_main doctor > "$root/doctor"
grep -q '^Healthy$' "$root/doctor"
grep -q '^Tunnel hostname: fixture.trycloudflare.com$' "$root/doctor"
fixture_profile=xhttp fixture_domain=fixture.example.com
python3 - "$root/argo" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1]); tid='12345678-1234-1234-1234-123456789abc'
(root/'credentials.json').write_text(json.dumps(dict(TunnelID=tid, AccountTag='fixture', TunnelSecret='fixture')))
(root/'state.json').write_text(json.dumps(dict(tunnel_domain='fixture.example.com')))
(root/'cloudflared.yml').write_text(json.dumps({'tunnel':tid,'credentials-file':str(root/'credentials.json'),'ingress':[{'hostname':'fixture.example.com'}]}))
PY
cli_main doctor > "$root/doctor"
grep -q '^Named Tunnel / credentials: OK$' "$root/doctor"
grep -q '^Healthy$' "$root/doctor"
cli_main status > "$root/status"
grep -q '^Argo XHTTP: running$' "$root/status"
cat "$root/status"
cat "$root/doctor"
grep -q '^Connection: Disconnected$' "$root/doctor"
mode=enabled connected=Connected
python3 - "$NF_SOURCE/lib" "$NF_CONFIG" "$root/argo/xray.json" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from management import warp_xray
for file in sys.argv[2:]:
    p=Path(file); p.write_text(json.dumps(warp_xray(json.loads(p.read_text()),True)))
PY
cli_main doctor > "$root/doctor"
grep -q '^WARP: enabled$' "$root/doctor"
grep -q '^Connection: Connected$' "$root/doctor"
grep -q '^Reality egress: WARP$' "$root/doctor"
grep -q '^Argo egress: WARP$' "$root/doctor"
grep -q '^HY2 egress: direct$' "$root/doctor"
grep -q '^Healthy$' "$root/doctor"
cli_main status > "$root/status"
grep -q '^WARP: enabled$' "$root/status"
grep -q '^Connection: Connected$' "$root/status"
connected=Disconnected
if cli_main doctor > "$root/failure"; then exit 1; fi
grep -q '^WARP: FAILED$' "$root/failure"
connected=Connected
touch "$root/fail-service"
if cli_main doctor > "$root/failure"; then exit 1; fi
grep -q '^Reality: FAILED$' "$root/failure"
grep -q '^Failed$' "$root/failure"
if cli_main status > "$root/failure"; then exit 1; fi
rm "$root/fail-service"
touch "$root/fail-hostname"
if cli_main doctor > "$root/failure"; then exit 1; fi
grep -q '^Reason: tunnel hostname unavailable$' "$root/failure"
rm "$root/fail-hostname"
touch "$root/fail-subscription"
cli_main doctor > "$root/warning"
grep -q '^Warning$' "$root/warning"
printf 'PASS M7: ws/xhttp, WARP OFF/ON/disconnected, service failure, hostname failure, subscription warning, status/help\n'
