#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"
install_nodeforge > "$NF_WORK/output"
printf 'user data\n' > "$NF_CONFIG_DIR/keep-me"
printf 'unrelated\n' > "$NF_TEST_ROOT/unrelated"
uninstall_nodeforge
[[ ! -f $NF_CONFIG && ! -f $NF_BIN && ! -f $NF_UNIT && ! -f $NF_STATE ]]
[[ -f $NF_CONFIG_DIR/keep-me && -f $NF_TEST_ROOT/unrelated ]]
[[ ! -f $NF_TEST_ROOT/active && ! -f $NF_TEST_ROOT/enabled ]]
printf 'PASS uninstall preserves unknown files\n'
