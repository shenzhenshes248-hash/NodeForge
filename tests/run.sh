#!/usr/bin/env bash
set -Eeuo pipefail
NF_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export NF_SOURCE
cd "$NF_SOURCE"
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 1; }
command -v shellcheck >/dev/null || { printf 'ShellCheck is required; checks are not silently skipped\n' >&2; exit 1; }
mapfile -t scripts < <(find lib tests -name '*.sh' -type f -print; printf '%s\n' install.sh uninstall.sh nodeforge.sh tests/fixtures/xray/xray)
shellcheck -x "${scripts[@]}"
for script in "${scripts[@]}"; do bash -n "$script"; done
count=0
for suite in tests/test_*.sh; do
    bash "$suite"
    count=$((count + 1))
done
"${PYTHON:-python3}" tests/test_network.py
"${PYTHON:-python3}" tests/test_management.py
"${PYTHON:-python3}" tests/test_release.py
printf 'PASS: ShellCheck, bash syntax, %s isolated suites\n' "$count"
