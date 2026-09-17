#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
install_nodeforge > "$NF_WORK/install.stdout"
NF_ARCH=64
old_binary=$(sha256_file "$NF_BIN")
old_state=$(sha256_file "$NF_STATE")
old_license=$(sha256_file "$NF_LICENSE")
unchanged=$(sha256sum "$NF_CONFIG" "$NF_UNIT" "$NF_CLI" "$NF_RUNTIME/.inventory" "$NF_RUNTIME/VERSION")
link=$(cli_main link)
runtime_before=$(runtime_inventory "$NF_RUNTIME")
download_https() {
    [[ $1 == "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100&page=1" ]] || return 1
    [[ ! -f $NF_TEST_ROOT/fail-query ]] || return 1
    local tag=v99.0.0
    [[ ! -f $NF_TEST_ROOT/no-update ]] || tag=v26.9.9
    printf '[{"tag_name":"v26.3.27","draft":false,"prerelease":false},{"tag_name":"%s","draft":false,"prerelease":true},{"tag_name":"v999.1.1","draft":true,"prerelease":true}]\n' "$tag" > "$2"
}
fetch_xray() {
    [[ ! -f $NF_TEST_ROOT/fail-download ]] || return 1
    if [[ -f $NF_TEST_ROOT/fail-checksum ]]; then
        printf 'bad archive\n' > "$NF_WORK/xray.zip"
        printf 'SHA2-256= %064d\n' 0 > "$NF_WORK/xray.zip.dgst"
        verify_checksum "$NF_WORK/xray.zip" "$NF_WORK/xray.zip.dgst"
    fi
    sed 's/26\.9\.9/99.0.0/g' "$NF_SOURCE/tests/fixtures/xray/xray" > "$NF_WORK/xray"
    chmod 755 "$NF_WORK/xray"
    printf 'New mock upstream license\n' > "$NF_WORK/LICENSE.xray"
    NF_CANDIDATE_BIN=$NF_WORK/xray NF_CANDIDATE_LICENSE=$NF_WORK/LICENSE.xray
}
timeout() {
    shift
    if [[ ${1:-} == systemctl && ${2:-} == restart && -f $NF_TEST_ROOT/fail-new-restart ]]; then
        return 1
    fi
    if [[ ${1:-} == runuser && -f $NF_TEST_ROOT/fail-final-config ]]; then return 1; fi
    "$@"
}
wait_managed_service() {
    if [[ -f $NF_TEST_ROOT/fail-new-health && $(sha256_file "$NF_BIN") != "$old_binary" ]]; then return 1; fi
    managed_service_healthy
}
# CalVer numeric order (9 versus 10), including pre-releases and ignoring drafts.
(
    # Invoked indirectly by latest_xray_release.
    # shellcheck disable=SC2317,SC2329
    download_https() {
        printf '[{"tag_name":"v26.9.9","draft":false,"prerelease":true},{"tag_name":"v26.10.1","draft":false,"prerelease":true},{"tag_name":"v99.1.1","draft":true}]' > "$2"
    }
    assert_eq v26.10.1 "$(latest_xray_release)"
)
touch "$NF_TEST_ROOT/no-update"
cli_main xray-update > "$NF_WORK/no-update.stdout"
grep -q 'no update needed' "$NF_WORK/no-update.stdout"
rm "$NF_TEST_ROOT/no-update"
for failure in fail-query fail-download fail-checksum fail-config fail-final-config fail-new-restart fail-new-health; do
    touch "$NF_TEST_ROOT/$failure"
    assert_fails cli_main xray-update
    assert_eq "$old_binary" "$(sha256_file "$NF_BIN")"
    assert_eq "$old_state" "$(sha256_file "$NF_STATE")"
    assert_eq "$old_license" "$(sha256_file "$NF_LICENSE")"
    [[ ! -e $NF_PENDING ]]
    rm "$NF_TEST_ROOT/$failure"
    cli_main status >/dev/null
    assert_eq "$link" "$(cli_main link)"
done
cli_main xray-update > "$NF_WORK/update.stdout"
assert_eq v99.0.0 "$(jq -r .version "$NF_STATE")"
[[ $(sha256_file "$NF_BIN") != "$old_binary" ]]
assert_eq "$unchanged" "$(sha256sum "$NF_CONFIG" "$NF_UNIT" "$NF_CLI" "$NF_RUNTIME/.inventory" "$NF_RUNTIME/VERSION")"
assert_eq "$runtime_before" "$(runtime_inventory "$NF_RUNTIME")"
assert_eq "$link" "$(cli_main link)"
cli_main status >/dev/null
cli_main xray-update > "$NF_WORK/second.stdout"
grep -q 'no update needed' "$NF_WORK/second.stdout"
grep -q '^exclusive$' "$NF_TEST_ROOT/locks.calls"
printf 'PASS Xray independent update, no-op, validation/restart rollback, runtime/config/link unchanged\n'
