#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"

# Fresh install startup failure must leave no managed service/config/account.
touch "$NF_TEST_ROOT/fail-start"
set +e
( set -e; trap cleanup EXIT; install_nodeforge ) > "$NF_WORK/failure-output" 2>&1
status=$?
set -e
[[ $status != 0 ]]
[[ ! -e $NF_CONFIG && ! -e $NF_BIN && ! -e $NF_STATE && ! -e $NF_UNIT && ! -d $NF_PENDING ]]
[[ ! -e $NF_TEST_ROOT/user ]]
init_workspace
install_nodeforge > "$NF_WORK/output"
before=$(sha256_file "$NF_CONFIG")
touch "$NF_TEST_ROOT/fail-target"
NODEFORGE_PORT=24567
assert_fails install_nodeforge
assert_eq "$before" "$(sha256_file "$NF_CONFIG")"
[[ ! -d $NF_PENDING ]]
rm "$NF_TEST_ROOT/fail-target"
# Refuse changed configuration instead of silently regenerating credentials.
printf '\n' >> "$NF_CONFIG"
changed=$(sha256_file "$NF_CONFIG")
assert_fails install_nodeforge
assert_eq "$changed" "$(sha256_file "$NF_CONFIG")"
printf 'PASS fresh failure rollback, target failure and unmanaged edits\n'
