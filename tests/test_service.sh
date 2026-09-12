#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
unit=$NF_SOURCE/templates/nodeforge-xray.service
for line in 'User=nodeforge' 'Group=nodeforge' 'Restart=on-failure' 'RestartSec=5s' 'WantedBy=multi-user.target' \
  'ExecStart=/usr/local/nodeforge/bin/xray run -config /etc/nodeforge/xray.json' 'NoNewPrivileges=true' 'ProtectSystem=strict'; do
    grep -Fxq "$line" "$unit"
done
assert_fails grep -Eq '/root|User=root' "$unit"
printf 'PASS systemd template (no host systemd calls)\n'
