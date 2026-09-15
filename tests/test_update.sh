#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
install_nodeforge > "$NF_WORK/install.stdout"
candidate=$NF_TEST_ROOT/candidate
mkdir -p "$candidate/lib" "$candidate/tools" "$candidate/trust" "$candidate/templates"
while IFS= read -r file; do cp "$NF_SOURCE/$file" "$candidate/$file"; done < <(runtime_files)
printf 'v99.0.0-dev\n' > "$candidate/VERSION"
old_runtime=$NF_RUNTIME
before_cli=$(sha256_file "$NF_CLI")
before_xray=$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_BIN" "$NF_UNIT")
# Release transport/signature validation is exercised with real Ed25519 in Python.
# This suite isolates the existing runtime publication and rollback machinery.
python3() {
    if [[ $1 == */lib/update.py ]]; then
        [[ ! -f $NF_TEST_ROOT/fail-download ]] || return 1
        if [[ -f $NF_TEST_ROOT/no-update ]]; then printf '%s\n' "$2"; return; fi
        mkdir "$3/extracted"
        cp -r "$candidate" "$3/extracted/nodeforge-v99.0.0-dev"
        printf 'v99.0.0-dev\n'
    else command python3 "$@"; fi
}
update_check_runtime() {
    local NF_SOURCE=$1 NF_PENDING=$NF_DATA_DIR/pending count
    count=$(cat "$NF_TEST_ROOT/check-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$NF_TEST_ROOT/check-count"
    [[ ! -f $NF_TEST_ROOT/fail-health-$count ]] || return 1
    [[ $(bash "$1/nodeforge.sh" version) == 'NodeForge v99.0.0-dev' ]] || return 1
    cli_status >/dev/null
}
runtime_publish() {
    [[ ! -f $NF_TEST_ROOT/fail-publish ]] || return 1
    command python3 "$NF_SOURCE/lib/management.py" rename-directory "$NF_RUNTIME_STAGE" "$NF_RUNTIME"
}
install() {
    if [[ -f $NF_TEST_ROOT/fail-copy && ${*: -1} == */.pending-v99.0.0-dev/lib/service.sh ]]; then return 1; fi
    fixture_install "$@"
}
mv() {
    if [[ -f $NF_TEST_ROOT/fail-switch && $* == *nodeforge.new.* ]]; then return 1; fi
    command mv "$@"
}
touch "$NF_TEST_ROOT/no-update"
cli_main update > "$NF_WORK/no-update.stdout"
grep -q 'no update needed' "$NF_WORK/no-update.stdout"
rm "$NF_TEST_ROOT/no-update"
for failure in fail-download fail-copy fail-publish fail-health-1 fail-switch fail-health-2; do
    touch "$NF_TEST_ROOT/$failure"
    printf '0\n' > "$NF_TEST_ROOT/check-count"
    assert_fails cli_main update
    assert_eq "$before_cli" "$(sha256_file "$NF_CLI")"
    assert_eq "NodeForge $NF_NODEFORGE_VERSION" "$(bash "$NF_CLI" version)"
    [[ -d $old_runtime && ! -e $NF_APP/releases/v99.0.0-dev && ! -e $NF_APP/releases/.pending-v99.0.0-dev ]]
    assert_eq "$before_xray" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_BIN" "$NF_UNIT")"
    cli_main status >/dev/null
    rm "$NF_TEST_ROOT/$failure"
done
printf '0\n' > "$NF_TEST_ROOT/check-count"
cli_main update > "$NF_WORK/update.stdout"
assert_eq 'NodeForge v99.0.0-dev' "$(bash "$NF_CLI" version)"
[[ ! -d $old_runtime && -d $NF_APP/releases/v99.0.0-dev ]]
assert_eq "$before_xray" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_BIN" "$NF_UNIT")"
grep -q 'version and status healthy' "$NF_WORK/update.stdout"
grep -q '^exclusive$' "$NF_TEST_ROOT/locks.calls"
printf 'PASS update no-op, staging/publication/health rollback, version and unchanged Xray identity\n'
