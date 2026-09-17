#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"
install_nodeforge > "$NF_WORK/first-output"
first=$(sha256_file "$NF_CONFIG")
first_state=$(sha256_file "$NF_STATE")
install_nodeforge > "$NF_WORK/second-output"
assert_eq "$first" "$(sha256_file "$NF_CONFIG")"
assert_eq "$first_state" "$(sha256_file "$NF_STATE")"
assert_eq 1 "$(grep -c '^restart nodeforge-xray.service$' "$NF_TEST_ROOT/systemctl.calls")"
assert_eq 2 "$(find "$NF_DATA_DIR/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
assert_fails grep -q AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "$NF_WORK/second-output"
touch "$NF_TEST_ROOT/fail-config"
assert_fails install_nodeforge
assert_eq "$first" "$(sha256_file "$NF_CONFIG")"
rm "$NF_TEST_ROOT/fail-config"
# A subprocess exits normally on error and runs the production rollback trap.
touch "$NF_TEST_ROOT/fail-start"
set +e
( set -e; trap cleanup EXIT; NODEFORGE_PORT=24567; install_nodeforge )
status=$?
set -e
[[ $status != 0 ]]
assert_eq "$first" "$(sha256_file "$NF_CONFIG")"
assert_eq "$first_state" "$(sha256_file "$NF_STATE")"
[[ -f $NF_TEST_ROOT/active && -f $NF_TEST_ROOT/enabled && ! -d $NF_PENDING ]]
# Recover an interrupted committed configuration from its durable snapshot.
init_workspace
begin_transaction
printf 'broken\n' > "$NF_CONFIG"
NF_TRANSACTION=0
install_nodeforge > "$NF_WORK/recovered-output"
assert_eq "$first" "$(sha256_file "$NF_CONFIG")"
NODEFORGE_PORT=29999
assert_fails install_nodeforge
assert_eq "$first" "$(sha256_file "$NF_CONFIG")"
printf 'PASS idempotent install, failures, and recovery\n'
