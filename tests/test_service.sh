#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
unit=$NF_SOURCE/templates/nodeforge-xray.service
for line in 'User=nodeforge' 'Group=nodeforge' 'Restart=on-failure' 'RestartSec=5s' 'WantedBy=multi-user.target' \
  'ExecStart=/usr/local/nodeforge/bin/xray run -config /etc/nodeforge/xray.json' 'NoNewPrivileges=true' 'ProtectSystem=strict' \
  'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' 'AmbientCapabilities=CAP_NET_BIND_SERVICE'; do
    grep -Fxq "$line" "$unit"
done
assert_fails grep -Eq '/root|User=root' "$unit"
hy_unit=$NF_SOURCE/templates/nodeforge-hysteria.service
for line in 'User=root' 'Group=root' 'Restart=on-failure' 'WantedBy=multi-user.target' \
  'ExecStart=/usr/local/nodeforge/bin/hysteria server -c /etc/nodeforge/hysteria.yaml' \
  'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE'; do
    grep -Fxq "$line" "$hy_unit"
done
printf 'PASS systemd template (no host systemd calls)\n'
