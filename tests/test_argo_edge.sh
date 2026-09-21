#!/usr/bin/env bash
set -Eeuo pipefail
export MSYS2_ARG_CONV_EXCL=/nodeforge-argo
source "${NF_SOURCE:?}/lib/common.sh"
load_modules
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
NF_CONFIG_DIR=$test_root
NF_BIN_DIR=$test_root
NF_UNIT=$test_root/unit
mkdir "$test_root/argo"
cp "$NF_SOURCE/templates/vless-xhttp.json" "$test_root/argo/xray.json"
cli_load_state() { :; }
load_argo() { :; }
argo_current_domain() { printf 'current.trycloudflare.com\n'; }
node_link() { printf 'vless://reality-fixture\n'; }
hysteria_link() { printf 'hysteria2://hy2-fixture\n'; }

check_address() {
    argo_link > "$test_root/link"
    subscription_content > "$test_root/sub.txt"
    python3 - "$test_root" "$1" <<'PY'
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlsplit
root, expected = Path(sys.argv[1]), sys.argv[2]
link = (root / 'link').read_text().strip()
lines = (root / 'sub.txt').read_text().splitlines()
assert lines == ['vless://reality-fixture', 'hysteria2://hy2-fixture', link]
url = urlsplit(link)
query = parse_qs(url.query)
assert url.scheme == 'vless' and url.hostname == expected and url.port == 443
assert query['host'] == query['sni'] == ['current.trycloudflare.com']
assert query['type'] == ['xhttp'] and query['security'] == ['tls']
assert query['mode'] == ['packet-up'] and query['path'] == ['/nodeforge-argo']
PY
}
check_address www.shopify.com
cli_argo_edge edge.example.com
check_address edge.example.com
cli_argo_edge 203.0.113.10
check_address 203.0.113.10
cli_argo_edge ''
check_address www.shopify.com
printf 'PASS Argo default, custom domain/IP, clear, Host/SNI and subscription parity\n'
