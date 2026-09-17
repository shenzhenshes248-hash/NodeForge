#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"
printf 'old\n' > "$NF_WORK/destination"
printf 'new\n' > "$NF_WORK/source"
atomic_install "$NF_WORK/source" "$NF_WORK/destination" 600 root root
assert_eq new "$(cat "$NF_WORK/destination")"
# Invoked indirectly by the production atomic_install function.
# shellcheck disable=SC2317,SC2329
mv() { return 1; }
assert_fails atomic_install "$NF_WORK/source" "$NF_WORK/destination" 600 root root
assert_eq new "$(cat "$NF_WORK/destination")"
assert_eq 0 "$(find "$NF_WORK" -name '*.new.*' | wc -l | tr -d ' ')"
unset -f mv
install_nodeforge > "$NF_WORK/output"
before=$(sha256_file "$NF_CONFIG")
before_state=$(sha256_file "$NF_STATE")
# Fail a commit after the binary/license were replaced but before config rename.
mv() {
    if [[ $* == *xray.json.new.* ]]; then return 1; fi
    command mv "$@"
}
set +e
( set -e; trap cleanup EXIT; NODEFORGE_PORT=24567; install_nodeforge )
status=$?
set -e
[[ $status != 0 ]]
assert_eq "$before" "$(sha256_file "$NF_CONFIG")"
assert_eq "$before_state" "$(sha256_file "$NF_STATE")"
[[ -f $NF_TEST_ROOT/active && ! -d $NF_PENDING ]]
printf 'PASS atomic replacement and mid-commit rollback\n'
