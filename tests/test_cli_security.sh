#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
install_nodeforge > "$NF_WORK/install-output"
NF_ERROR_SENTINEL=PRIVATE-ERROR-SENTINEL
secrets=("$NF_UUID" "$NF_PRIVATE_KEY" "$NF_PUBLIC_KEY" "$NF_SHORT_ID" vless:// "$NF_ERROR_SENTINEL" BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB)
assert_private_capture() {
    local secret
    for secret in "${secrets[@]}"; do
        assert_not_contains "$secret" "$NF_WORK/capture.stdout" "$NF_WORK/capture.stderr" "$NF_TEST_ROOT/systemctl.calls"
    done
}
private_failure() {
    capture_command "$NF_WORK/capture" cli_main "$1"
    [[ $NF_CAPTURE_STATUS != 0 ]]
    assert_private_capture
    assert_not_contains 'Status: healthy' "$NF_WORK/capture.stdout" "$NF_WORK/capture.stderr"
}
# Mutation/self-test: the assertion must detect injected output in EACH channel,
# return failure and leave the captured evidence byte-for-byte intact.
for channel in stdout stderr; do
    printf '%s\n' "$NF_ERROR_SENTINEL" > "$NF_WORK/sentinel.$channel"
    before=$(sha256_file "$NF_WORK/sentinel.$channel")
    capture_command "$NF_WORK/assertion" assert_not_contains "$NF_ERROR_SENTINEL" "$NF_WORK/sentinel.$channel"
    [[ $NF_CAPTURE_STATUS != 0 ]]
    assert_eq "$before" "$(sha256_file "$NF_WORK/sentinel.$channel")"
done
for command in status info; do
    capture_command "$NF_WORK/capture" cli_main "$command"
    assert_eq 0 "$NF_CAPTURE_STATUS"
    assert_private_capture
done
cp "$NF_STATE" "$NF_WORK/good-state"
cp "$NF_CONFIG" "$NF_WORK/good-config"
printf '{broken %s' "$NF_ERROR_SENTINEL" > "$NF_STATE"
private_failure status
private_failure info
private_failure uninstall
cp "$NF_WORK/good-state" "$NF_STATE"
jq --arg sentinel "$NF_ERROR_SENTINEL" '.log.loglevel=$sentinel' "$NF_WORK/good-config" > "$NF_CONFIG"
private_failure status
cp "$NF_WORK/good-config" "$NF_CONFIG"
jq '.public_key="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"' "$NF_WORK/good-state" > "$NF_STATE"
private_failure status
cp "$NF_WORK/good-state" "$NF_STATE"
touch "$NF_TEST_ROOT/missing-listener"
private_failure status
rm "$NF_TEST_ROOT/missing-listener"
runuser() {
    if [[ -f $NF_TEST_ROOT/raw-config-error ]]; then
        printf '%s\n' "${secrets[*]}"
        printf '%s\n' "${secrets[*]}" >&2
        return 23
    fi
    shift 3
    "$@"
}
touch "$NF_TEST_ROOT/raw-config-error"
private_failure restart
rm "$NF_TEST_ROOT/raw-config-error"
for failure in fail-restart fail-post-active missing-listener; do
    touch "$NF_TEST_ROOT/$failure"
    private_failure restart
    rm "$NF_TEST_ROOT/$failure"
    touch "$NF_TEST_ROOT/active"
done
# Inject service/path-like data through the real CLI validation and dispatch.
# The sentinel is outside every managed root, inside the disposable test root.
outside=$NF_TEST_ROOT/outside-sentinel
printf 'must survive unchanged\n' > "$outside"
outside_hash=$(sha256_file "$outside")
calls_hash=$(sha256_file "$NF_TEST_ROOT/systemctl.calls")
for attack in 'attacker.service' '/tmp/attacker-path' '../../outside-sentinel' "$outside" 'symlink-target'; do
    jq --arg attack "$attack" '.service=$attack | .config_path=$attack | .unmanaged_path=$attack' "$NF_WORK/good-state" > "$NF_STATE"
    for command in restart uninstall; do private_failure "$command"; done
    assert_eq "$outside_hash" "$(sha256_file "$outside")"
    assert_eq "$calls_hash" "$(sha256_file "$NF_TEST_ROOT/systemctl.calls")"
done
cp "$NF_WORK/good-state" "$NF_STATE"
jq --arg path "$outside" '.unmanaged_path=$path' "$NF_WORK/good-config" > "$NF_CONFIG"
for command in restart uninstall; do private_failure "$command"; done
assert_eq "$outside_hash" "$(sha256_file "$outside")"
assert_eq "$calls_hash" "$(sha256_file "$NF_TEST_ROOT/systemctl.calls")"
assert_not_contains attacker.service "$NF_TEST_ROOT/systemctl.calls"
cp "$NF_WORK/good-config" "$NF_CONFIG"
# Linux also exercises an actual config symlink. Git Bash ln may copy instead;
# report that limitation explicitly rather than calling it a symlink test.
mv "$NF_CONFIG" "$NF_WORK/config-saved"
ln -s "$outside" "$NF_CONFIG"
if [[ -L $NF_CONFIG ]]; then
    for command in restart uninstall; do private_failure "$command"; done
    assert_eq "$outside_hash" "$(sha256_file "$outside")"
    assert_eq "$calls_hash" "$(sha256_file "$NF_TEST_ROOT/systemctl.calls")"
else
    printf 'LIMITATION: native symlink unavailable; path-field rejection tested, Linux symlink validation remains\n'
fi
rm "$NF_CONFIG"
mv "$NF_WORK/config-saved" "$NF_CONFIG"
printf 'PASS independent secret captures/assertion mutation, raw-error suppression, malicious state/path/service\n'
