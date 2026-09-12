#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"
install_nodeforge > "$NF_WORK/installed"
runtime_remove
load_existing
state_before=$(sha256_file "$NF_STATE")
config_before=$(sha256_file "$NF_CONFIG")
install() {
    if [[ -f $NF_TEST_ROOT/fail-copy && ${*: -1} == "$NF_RUNTIME_STAGE/lib/service.sh" ]]; then return 1; fi
    fixture_install "$@"
}
runtime_publish() {
    [[ ! -f $NF_TEST_ROOT/fail-publish ]] || return 1
    python3 "$NF_SOURCE/lib/management.py" rename-directory "$NF_RUNTIME_STAGE" "$NF_RUNTIME"
}
rm() {
    local argument
    for argument in "$@"; do
        if [[ -f $NF_TEST_ROOT/fail-runtime-unlink && $argument == "$NF_RUNTIME/lib/common.sh" ]]; then return 1; fi
        if [[ -f $NF_TEST_ROOT/fail-launcher-unlink && $argument == "$NF_CLI" ]]; then return 1; fi
        if [[ -f $NF_TEST_ROOT/fail-evidence-unlink && $argument == "$NF_PENDING/xray.json" ]]; then return 1; fi
    done
    command rm "$@"
}
rmdir() {
    local argument
    for argument in "$@"; do
        if [[ -f $NF_TEST_ROOT/fail-runtime-rmdir && $argument == "$NF_RUNTIME/lib" ]]; then return 1; fi
        if [[ -f $NF_TEST_ROOT/fail-pending-rmdir && $argument == "$NF_PENDING" ]]; then return 1; fi
    done
    command rmdir "$@"
}
# Invoked by the production snapshot restore function.
# shellcheck disable=SC2329
mv() {
    if [[ -f $NF_TEST_ROOT/fail-snapshot && $* == *xray.json.restore.* ]]; then return 1; fi
    command mv "$@"
}
run_install() { init_workspace; trap cleanup EXIT; install_nodeforge; }
assert_original() {
    assert_eq "$state_before" "$(sha256_file "$NF_STATE")"
    assert_eq "$config_before" "$(sha256_file "$NF_CONFIG")"
    [[ -f $NF_TEST_ROOT/active && -f $NF_TEST_ROOT/enabled ]]
}
for failure in fail-copy fail-publish; do
    touch "$NF_TEST_ROOT/$failure"
    capture_command "$NF_TEST_ROOT/failed-install" run_install
    [[ $NF_CAPTURE_STATUS != 0 && ! -e $NF_RUNTIME && ! -e $NF_RUNTIME_STAGE && ! -d $NF_PENDING ]]
    assert_original
    rm "$NF_TEST_ROOT/$failure"
done
# Partial final tree requires a valid transaction intent; ordinary uninstall
# must still reject its incomplete inventory.
begin_transaction
runtime_intent > "$NF_PENDING/cli-created"
mkdir -p "$NF_RUNTIME/lib"
printf 'partial\n' > "$NF_RUNTIME/lib/common.sh"
capture_command "$NF_TEST_ROOT/normal-remove" runtime_preuninstall
[[ $NF_CAPTURE_STATUS != 0 && -f $NF_RUNTIME/lib/common.sh ]]
outside=$NF_TEST_ROOT/outside
printf 'preserve me\n' > "$outside"
outside_hash=$(sha256_file "$outside")
cp "$NF_PENDING/cli-created" "$NF_WORK/good-intent"
printf 'final=../../outside\n' >> "$NF_PENDING/cli-created"
capture_command "$NF_TEST_ROOT/bad-intent" rollback
[[ $NF_CAPTURE_STATUS != 0 && -d $NF_PENDING && -f $NF_RUNTIME/lib/common.sh ]]
assert_eq "$outside_hash" "$(sha256_file "$outside")"
cp "$NF_WORK/good-intent" "$NF_PENDING/cli-created"
capture_command "$NF_TEST_ROOT/partial-cleanup" rollback
assert_eq 0 "$NF_CAPTURE_STATUS"
NF_TRANSACTION=0
[[ ! -e $NF_RUNTIME && ! -d $NF_PENDING ]]
assert_original
# Exercise rollback from an OR-list, the context which exposed B2.
conditional_rollback() { rollback || return 1; }
for failure in fail-runtime-unlink fail-runtime-rmdir fail-launcher-unlink fail-snapshot fail-start fail-evidence-unlink fail-pending-rmdir; do
    begin_transaction
    install_cli_runtime
    original_hash=$(sha256_file "$NF_PENDING/original.json")
    touch "$NF_TEST_ROOT/$failure"
    capture_command "$NF_TEST_ROOT/failed-recovery" conditional_rollback
    [[ $NF_CAPTURE_STATUS != 0 && -d $NF_PENDING ]]
    grep -q 'Recovery incomplete' "$NF_TEST_ROOT/failed-recovery.stderr"
    case $failure in
        fail-evidence-unlink|fail-pending-rmdir) [[ -f $NF_PENDING/rollback-complete ]] ;;
        *) assert_eq "$original_hash" "$(sha256_file "$NF_PENDING/original.json")" ;;
    esac
    assert_eq "$outside_hash" "$(sha256_file "$outside")"
    rm -f "$NF_TEST_ROOT/$failure"
    capture_command "$NF_TEST_ROOT/retried-recovery" conditional_rollback
    assert_eq 0 "$NF_CAPTURE_STATUS"
    NF_TRANSACTION=0
    [[ ! -e $NF_CLI && ! -e $NF_RUNTIME && ! -e $NF_RUNTIME_STAGE && ! -d $NF_PENDING ]]
    assert_original
done
begin_transaction
runtime_intent > "$NF_PENDING/cli-created"
mkdir -p "$NF_APP/releases"
ln -s "$outside" "$NF_RUNTIME_STAGE"
capture_command "$NF_TEST_ROOT/unsafe-stage" conditional_rollback
[[ $NF_CAPTURE_STATUS != 0 && -d $NF_PENDING ]]
assert_eq "$outside_hash" "$(sha256_file "$outside")"
if [[ ! -L $NF_RUNTIME_STAGE ]]; then
    printf 'LIMITATION: native symlink unavailable; non-directory stage rejected, Linux symlink validation remains\n'
fi
rm "$NF_RUNTIME_STAGE"
capture_command "$NF_TEST_ROOT/safe-stage-retry" conditional_rollback
assert_eq 0 "$NF_CAPTURE_STATUS"
NF_TRANSACTION=0
printf 'PASS sibling-stage copy/rename failures, partial-owned cleanup, unlink/rmdir failures, retained evidence and retry\n'
