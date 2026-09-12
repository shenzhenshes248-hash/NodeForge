#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/mocks.sh"
# Verify ownership/mode rejection with portable stat fixtures, without chmod'ing
# or changing ownership of any host path.
source "$NF_SOURCE/lib/runtime.sh"
printf 'fixture\n' > "$NF_WORK/trust-file"
stat() {
    case $2 in
        %u) printf '%s\n' "$fixture_uid" ;;
        %a) printf '%s\n' "$fixture_mode" ;;
        *) return 1 ;;
    esac
}
fixture_uid=1000 fixture_mode=600
assert_fails trusted_file "$NF_WORK/trust-file"
assert_fails trusted_directory "$NF_WORK"
fixture_uid=0 fixture_mode=666
assert_fails trusted_file "$NF_WORK/trust-file"
fixture_mode=777
assert_fails trusted_directory "$NF_WORK"
fixture_mode=600
trusted_file "$NF_WORK/trust-file"
fixture_mode=700
trusted_directory "$NF_WORK"
unset -f stat
source "$NF_SOURCE/tests/helpers/mocks.sh"
# Use the production lock implementation with only its fixed path relocated.
sed "s|/run/lock/nodeforge.lock|$NF_TEST_ROOT/nodeforge.lock|g" "$NF_SOURCE/lib/system.sh" > "$NF_WORK/system-fixture.sh"
# shellcheck disable=SC1091
source "$NF_WORK/system-fixture.sh"
flock() {
    printf '%s\n' "$*" >> "$NF_TEST_ROOT/flock.calls"
    [[ ! -f $NF_TEST_ROOT/busy ]]
}
acquire_lock shared
grep -q '^-s -n [0-9]' "$NF_TEST_ROOT/flock.calls"
printf 'stable inode content\n' > "$NF_TEST_ROOT/nodeforge.lock"
acquire_lock
grep -q '^-x -n [0-9]' "$NF_TEST_ROOT/flock.calls"
assert_eq 'stable inode content' "$(cat "$NF_TEST_ROOT/nodeforge.lock")"
touch "$NF_TEST_ROOT/busy"
assert_fails acquire_lock shared
assert_fails acquire_lock
rm "$NF_TEST_ROOT/busy"
# A non-regular planted lock must fail before open/flock.
rm "$NF_TEST_ROOT/nodeforge.lock"
mkdir "$NF_TEST_ROOT/nodeforge.lock"
assert_fails acquire_lock
rmdir "$NF_TEST_ROOT/nodeforge.lock"
# Inspect entry-point main functions with privileged work replaced by assertions.
sed -n '/^main() {/,/^}/p' "$NF_SOURCE/install.sh" > "$NF_WORK/main-fixture.sh"
# shellcheck disable=SC1091
source "$NF_WORK/main-fixture.sh"
preflight() { :; }
install_dependencies() { [[ -n ${NF_LOCK_FD:-} && -f $NF_TEST_ROOT/nodeforge.lock ]]; }
install_nodeforge() { [[ -n ${NF_LOCK_FD:-} ]]; }
unset NF_LOCK_FD
( main )
printf 'PASS stable shared/exclusive lock, busy failure and install lock boundary (fixture flock)\n'
