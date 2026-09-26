#!/usr/bin/env bash
# rollback_as_new deliberately leaves the outer fixture's version unchanged.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
install_nodeforge > "$NF_WORK/install.stdout"
# This suite isolates program publication. Optional profile/Tunnel state below
# is an opaque fixture; only the core fixture's service health is meaningful.
cli_status() { cli_load_state; managed_service_healthy; managed_hysteria_healthy; }
argo_paths
mkdir "$NF_ARGO_DIR"
printf '{"profile":"xhttp"}\n' > "$NF_ARGO_DIR/state.json"
printf '{"uuid":"fixture-identity"}\n' > "$NF_ARGO_DIR/xray.json"
printf '{"TunnelID":"fixture-tunnel","TunnelSecret":"fixture-secret"}\n' > "$NF_ARGO_DIR/credentials.json"
printf '{"owner":"NodeForge","schema":1,"mode":"enabled"}\n' > "$NF_DATA_DIR/warp.json"
owned_state_digest() {
    sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_BIN" "$NF_UNIT" \
        "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_HYSTERIA_KEY" "$NF_HYSTERIA_CERT" \
        "$NF_ARGO_DIR/state.json" "$NF_ARGO_DIR/xray.json" "$NF_ARGO_DIR/credentials.json" "$NF_DATA_DIR/warp.json"
}
assert_fails cli_main rollback
grep -q 'No rollback version available' "$NF_WORK/expected-failure.log"
candidate=$NF_TEST_ROOT/candidate
mkdir -p "$candidate/lib" "$candidate/tools" "$candidate/trust" "$candidate/templates"
while IFS= read -r file; do cp "$NF_SOURCE/$file" "$candidate/$file"; done < <(runtime_files)
printf 'v99.0.0-dev\n' > "$candidate/VERSION"
old_runtime=$NF_RUNTIME
before_cli=$(sha256_file "$NF_CLI")
before_xray=$(owned_state_digest)
# An older retained predecessor must survive failed updates, then be retired
# when A -> B succeeds, leaving exactly A as the selectable previous version.
older_runtime=$NF_APP/releases/v0.7.0
cp -r "$old_runtime" "$older_runtime"
printf 'v0.7.0\n' > "$older_runtime/VERSION"
runtime_inventory "$older_runtime" > "$older_runtime/.inventory"
printf 'v0.7.0\n' > "$NF_APP/previous"
chmod 600 "$NF_APP/previous"
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
    [[ $(bash "$1/nodeforge.sh" version) == "NodeForge $(cat "$1/VERSION")" ]] || return 1
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
    if [[ -f $NF_TEST_ROOT/fail-previous && $* == *previous.new.* ]]; then return 1; fi
    command mv "$@"
}
touch "$NF_TEST_ROOT/no-update"
cli_main update > "$NF_WORK/no-update.stdout"
grep -q 'no update needed' "$NF_WORK/no-update.stdout"
rm "$NF_TEST_ROOT/no-update"
for failure in fail-download fail-copy fail-publish fail-health-1 fail-switch fail-health-2 fail-previous; do
    touch "$NF_TEST_ROOT/$failure"
    printf '0\n' > "$NF_TEST_ROOT/check-count"
    assert_fails cli_main update
    assert_eq "$before_cli" "$(sha256_file "$NF_CLI")"
    assert_eq "NodeForge $NF_NODEFORGE_VERSION" "$(bash "$NF_CLI" version)"
    [[ -d $old_runtime && ! -e $NF_APP/releases/v99.0.0-dev && ! -e $NF_APP/releases/.pending-v99.0.0-dev ]]
    assert_eq "$before_xray" "$(owned_state_digest)"
    assert_eq v0.7.0 "$(cat "$NF_APP/previous")"
    [[ -d $older_runtime ]]
    cli_main status >/dev/null
    rm "$NF_TEST_ROOT/$failure"
done
printf '0\n' > "$NF_TEST_ROOT/check-count"
cli_main update > "$NF_WORK/update.stdout"
assert_eq 'NodeForge v99.0.0-dev' "$(bash "$NF_CLI" version)"
[[ -d $old_runtime && -d $NF_APP/releases/v99.0.0-dev && ! -e $older_runtime ]]
assert_eq "$NF_NODEFORGE_VERSION" "$(cat "$NF_APP/previous")"
assert_eq "$before_xray" "$(owned_state_digest)"
grep -q 'version and status healthy' "$NF_WORK/update.stdout"
grep -q '^exclusive$' "$NF_TEST_ROOT/locks.calls"
printf 'PASS update no-op, staging/publication/health rollback, version and unchanged Xray identity\n'

rollback_as_new() (
    NF_SOURCE=$NF_APP/releases/v99.0.0-dev
    NF_NODEFORGE_VERSION=v99.0.0-dev
    cli_main rollback
)
assert_current_usable() {
    assert_eq 'NodeForge v99.0.0-dev' "$(bash "$NF_CLI" version)"
    assert_eq "$NF_NODEFORGE_VERSION" "$(cat "$NF_APP/previous")"
    assert_eq "$before_xray" "$(owned_state_digest)"
    cli_status >/dev/null
}
touch "$NF_TEST_ROOT/nonroot"
assert_fails rollback_as_new
rm "$NF_TEST_ROOT/nonroot"
assert_current_usable

mv "$old_runtime/nodeforge.sh" "$NF_WORK/saved-nodeforge"
assert_fails rollback_as_new
assert_current_usable
cp "$NF_WORK/saved-nodeforge" "$old_runtime/nodeforge.sh"
printf '# corrupt previous runtime\n' >> "$old_runtime/nodeforge.sh"
assert_fails rollback_as_new
assert_current_usable
cp "$NF_WORK/saved-nodeforge" "$old_runtime/nodeforge.sh"

for failure in fail-health-1 fail-switch fail-health-2; do
    touch "$NF_TEST_ROOT/$failure"
    printf '0\n' > "$NF_TEST_ROOT/check-count"
    assert_fails rollback_as_new
    assert_current_usable
    [[ -d $old_runtime ]]
    rm "$NF_TEST_ROOT/$failure"
done
printf '0\n' > "$NF_TEST_ROOT/check-count"
rollback_as_new > "$NF_WORK/rollback.stdout"
grep -q "v99.0.0-dev -> $NF_NODEFORGE_VERSION" "$NF_WORK/rollback.stdout"
assert_eq "NodeForge $NF_NODEFORGE_VERSION" "$(bash "$NF_CLI" version)"
[[ ! -e $NF_APP/previous && ! -e $NF_APP/releases/v99.0.0-dev && -d $old_runtime ]]
assert_eq "$before_xray" "$(owned_state_digest)"
assert_fails cli_main rollback
grep -q 'No rollback version available' "$NF_WORK/expected-failure.log"
cli_main help > "$NF_WORK/help.stdout"
grep -qx '  rollback' "$NF_WORK/help.stdout"
printf 'PASS single previous retention, manual rollback, unchanged profile/identity/WARP, missing/corrupt rejection, switch failure recovery, root and help\n'
