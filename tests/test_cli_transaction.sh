#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"
# Fail publishing the PATH entry after the runtime has been published.
# Invoked indirectly by atomic_install.
# shellcheck disable=SC2329
mv() {
    if [[ $* == *nodeforge.new.* ]]; then return 1; fi
    command mv "$@"
}
set +e
( set -e; trap cleanup EXIT; install_nodeforge ) > "$NF_WORK/failed-install" 2>&1
result=$?
set -e
[[ $result != 0 && ! -e $NF_CLI && ! -e $NF_BIN && ! -e $NF_STATE && ! -d $NF_PENDING ]]
runtime_paths
[[ ! -e $NF_APP ]]
unset -f mv
init_workspace
install_nodeforge > "$NF_WORK/output"
# Model accepted M1 without CLI: remove only the Phase 2 installation products.
runtime_remove
state_before=$(sha256_file "$NF_STATE")
config_before=$(sha256_file "$NF_CONFIG")
load_existing
begin_transaction
runtime_paths
install_cli_runtime
NF_TRANSACTION=0
# The next local installer recovers the interrupted CLI publication, then installs.
install_nodeforge > "$NF_WORK/recovered"
runtime_validate
assert_eq "$state_before" "$(sha256_file "$NF_STATE")"
assert_eq "$config_before" "$(sha256_file "$NF_CONFIG")"
[[ -f $NF_CLI && ! -d $NF_PENDING ]]
printf 'PASS CLI publication rollback and pending recovery preserve M1 state bytes\n'
