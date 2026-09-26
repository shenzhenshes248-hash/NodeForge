#!/usr/bin/env bash
# Fixture adapters are invoked by the CLI functions under test.
# shellcheck disable=SC2329
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
eval "$(declare -f test_xray_config | sed '1s/test_xray_config/fixture_test_xray_config/')"
test_xray_config() {
    [[ $2 == *.json ]] || die 'Xray requires a recognizable config format'
    fixture_test_xray_config "$@"
}
install_nodeforge > "$NF_WORK/install.stdout"

# Production installs own Reality config as nodeforge:nodeforge, unlike the
# unprivileged filesystem fixture. Exercise the actual ownership predicate.
(
    source "$NF_SOURCE/lib/runtime.sh"
    trusted_directory() { [[ -d $1 && ! -L $1 ]]; }
    stat() {
        case $2 in
            %u) if [[ $3 == "$NF_CONFIG" ]]; then printf '999\n'; else printf '0\n'; fi ;;
            %a) printf '600\n' ;;
            *) command stat "$@" ;;
        esac
    }
    maintenance_paths
    maintenance_check_paths
)

# Journal mapping is isolated from host systemd/journald.
(
    systemctl() { printf 'loaded\n'; }
    journalctl() { printf '%s\n' "$*"; }
    for pair in reality:nodeforge-xray.service hy2:nodeforge-hysteria.service argo:nodeforge-argo.service warp:warp-svc.service; do
        assert_eq "--no-pager -n 100 -u ${pair#*:}" "$(cli_main logs "${pair%%:*}")"
    done
    [[ $(cli_main logs reality -f) == *' -f' ]]
    [[ $(cli_main logs) == *'-u nodeforge-xray.service -u nodeforge-hysteria.service -u nodeforge-argo.service -u warp-svc.service' ]]
    systemctl() { printf 'not-found\n'; }
    assert_fails cli_main logs argo
    grep -q 'service unavailable: nodeforge-argo.service' "$NF_WORK/expected-failure.log"
)

# Real TLS material exercises certificate/key staging validation.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=fixture \
    -keyout "$NF_HYSTERIA_KEY" -out "$NF_HYSTERIA_CERT" >/dev/null 2>&1
if command -v cygpath >/dev/null; then
    # Native Windows Python receives translated paths from Git Bash.
    config_path=$(cygpath -m "$NF_CONFIG_DIR")
    sed -i "s|$NF_CONFIG_DIR|$config_path|g" "$NF_HYSTERIA_CONFIG"
fi
write_hysteria_state
cli_main backup > "$NF_WORK/backup.stdout"
backup=$(sed 's/^NodeForge backup: //' "$NF_WORK/backup.stdout")
[[ -f $backup ]]
original=$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY")
# A valid, different active identity must be replaced with the saved identity.
jq '.inbounds[0].settings.clients[0].id="11111111-1111-4111-8111-111111111111"' "$NF_CONFIG" > "$NF_WORK/changed"
cp "$NF_WORK/changed" "$NF_CONFIG"
write_state
( unset NF_WORK; cli_main restore "$backup" )
assert_eq "$original" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_HYSTERIA_CERT" "$NF_HYSTERIA_KEY")"
[[ ! -e $NF_DATA_DIR/maintenance-restore ]]

# Publication failure restores the pre-restore files, including changed identity.
jq '.inbounds[0].settings.clients[0].id="22222222-2222-4222-8222-222222222222"' "$NF_CONFIG" > "$NF_WORK/changed"
cp "$NF_WORK/changed" "$NF_CONFIG"
write_state
before=$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")
eval "$(declare -f atomic_install | sed '1s/atomic_install/fixture_atomic_install/')"
atomic_install() {
    if [[ $2 == "$NF_HYSTERIA_CONFIG" && ! -f $NF_TEST_ROOT/failure-injected ]]; then
        touch "$NF_TEST_ROOT/failure-injected"
        return 1
    fi
    fixture_atomic_install "$@"
}
assert_fails cli_main restore "$backup"
assert_eq "$before" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
[[ ! -e $NF_DATA_DIR/maintenance-restore ]]
printf 'broken archive' > "$NF_WORK/broken.tar.gz"
assert_fails cli_main restore "$NF_WORK/broken.tar.gz"
assert_eq "$before" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE")"
touch "$NF_TEST_ROOT/nonroot"
assert_fails cli_main restore "$backup"
rm "$NF_TEST_ROOT/nonroot"
cli_main help > "$NF_WORK/help"
for command in logs backup restore; do grep -q "  $command" "$NF_WORK/help"; done

# Optional owned state: both profiles and both WARP modes. Host effects only
# are mocked; archive validation, ownership hashes and restore remain real.
argo_paths
mkdir "$NF_ARGO_DIR"
cp "$NF_SOURCE/templates/nodeforge-argo.service" "$NF_ARGO_UNIT"
cp "$NF_SOURCE/templates/nodeforge-argo-xray.service" "$NF_ARGO_XRAY_UNIT"
cp "$NF_SOURCE/lib/argo_runtime.py" "$NF_ARGO_DIR/runner.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NF_ARGO_DIR/xray"
cp "$NF_ARGO_DIR/xray" "$NF_ARGO_DIR/cloudflared"
chmod 755 "$NF_ARGO_DIR/xray" "$NF_ARGO_DIR/cloudflared"
warp-cli() { :; }
warp_cli() { printf '%s\n' "$*" >> "$NF_TEST_ROOT/warp.calls"; }
diagnostic_warp_connection() { printf 'Connected\n'; }
for profile in ws xhttp; do
    mode=disabled
    [[ $profile != xhttp ]] || mode=enabled
    python3 - "$NF_SOURCE" "$NF_ARGO_DIR" "$profile" "$mode" "$NF_CONFIG" "$NF_DATA_DIR/warp.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
source, argo = map(Path, sys.argv[1:3])
sys.path.insert(0, str(source / 'lib'))
from management import warp_xray
profile, mode = sys.argv[3:5]
config = json.loads((source / 'templates' / f'vless-{profile}.json').read_text())
config['inbounds'][0]['settings']['clients'][0]['id'] = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa'
warp_xray(config, mode == 'enabled')
(argo / 'xray.json').write_text(json.dumps(config))
reality = Path(sys.argv[5])
reality.write_text(json.dumps(warp_xray(json.loads(reality.read_text()), mode == 'enabled')))
Path(sys.argv[6]).write_text(json.dumps(dict(owner='NodeForge', schema=1, mode=mode)))
tunnel = {}
state = dict(owner='NodeForge', schema=1, profile=profile, cloudflared_version='2026.9.0')
files = ['xray.json', 'cloudflared.yml', 'cloudflared', 'xray', 'runner.py']
if profile == 'xhttp':
    creds = dict(TunnelID='11111111-1111-4111-8111-111111111111', AccountTag='fixture', TunnelSecret='Zml4dHVyZQ==')
    (argo / 'credentials.json').write_text(json.dumps(creds))
    files.append('credentials.json')
    state['tunnel_domain'] = 'nodeforge.example.com'
    tunnel = {'tunnel': creds['TunnelID'], 'credentials-file': (argo / 'credentials.json').as_posix(),
              'ingress': [{'hostname': state['tunnel_domain'], 'service': 'http://127.0.0.1:20001'}, {'service': 'http_status:404'}]}
(argo / 'cloudflared.yml').write_text(json.dumps(tunnel))
state['files'] = {f: hashlib.sha256((argo / f).read_bytes()).hexdigest() for f in files}
(argo / 'state.json').write_text(json.dumps(state))
PY
    write_state
    cli_main backup > "$NF_WORK/backup.stdout"
    backup=$(sed 's/^NodeForge backup: //' "$NF_WORK/backup.stdout")
    before=$(sha256sum "$NF_ARGO_DIR/"*.json "$NF_ARGO_DIR/cloudflared.yml" "$NF_DATA_DIR/warp.json")
    jq '.inbounds[0].settings.clients[0].id="bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"' "$NF_ARGO_DIR/xray.json" > "$NF_WORK/changed"
    cp "$NF_WORK/changed" "$NF_ARGO_DIR/xray.json"
    jq '.mode = (if .mode == "enabled" then "disabled" else "enabled" end)' "$NF_DATA_DIR/warp.json" > "$NF_WORK/changed"
    cp "$NF_WORK/changed" "$NF_DATA_DIR/warp.json"
    cli_main restore "$backup"
    assert_eq "$before" "$(sha256sum "$NF_ARGO_DIR/"*.json "$NF_ARGO_DIR/cloudflared.yml" "$NF_DATA_DIR/warp.json")"
    assert_eq "$profile" "$(argo_installed_profile)"
    warp_load
    assert_eq "$mode" "$NF_WARP_MODE"
done
grep -qx disconnect "$NF_TEST_ROOT/warp.calls"
grep -qx connect "$NF_TEST_ROOT/warp.calls"
if grep -q 'registration new' "$NF_TEST_ROOT/warp.calls"; then exit 1; fi
printf 'PASS logs mappings, backup, staged restore identity, failure recovery, corrupt archive, root and help\n'
printf 'PASS ws/xhttp profile, Named Tunnel credentials and enabled/disabled WARP preservation\n'
