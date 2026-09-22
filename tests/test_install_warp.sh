#!/usr/bin/env bash
# Exercise the real installer argument handling and final dispatch in isolation.
# shellcheck disable=SC2329
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
# Load only main's definition; never execute the host installer entry point.
# shellcheck disable=SC1090
source <(sed -n '/^main() {/,/^main "\$@"$/p' "$NF_SOURCE/install.sh" | sed '$d')
preflight() { NF_OS=debian NF_OS_VERSION=12 NF_ARCH=64; }
acquire_lock() { :; }
argo_select_profile() { NF_PROFILE=${NF_REQUESTED_PROFILE:-ws}; }
argo_profile_validate() { :; }
init_workspace() { :; }
cleanup() { :; }
apt-get() { printf 'apt %s\n' "$*" >> "$NF_TEST_ROOT/calls"; }
install_nodeforge() { printf 'nodes\n' >> "$NF_TEST_ROOT/calls"; }
install_argo() { printf 'argo %s\n' "$NF_PROFILE" >> "$NF_TEST_ROOT/calls"; }
install_subscription() { printf 'subscription\n' >> "$NF_TEST_ROOT/calls"; }
warp_switch() {
    assert_eq enabled "$1"
    assert_eq subscription "$(tail -n 1 "$NF_TEST_ROOT/calls")"
    printf 'warp enabled\n' >> "$NF_TEST_ROOT/calls"
}
# Any unexpected WARP side effect outside the explicit final dispatch fails.
warp_install() { return 99; }
warp_cli() { return 99; }
for profile in ws xhttp; do
    : > "$NF_TEST_ROOT/calls"
    (main --profile "$profile")
    assert_not_contains 'warp' "$NF_TEST_ROOT/calls"
    grep -q "^argo $profile$" "$NF_TEST_ROOT/calls"
    : > "$NF_TEST_ROOT/calls"
    (main --profile "$profile" --warp)
    assert_eq 'warp enabled' "$(tail -n 1 "$NF_TEST_ROOT/calls")"
done
: > "$NF_TEST_ROOT/calls"
(main)
assert_not_contains 'warp' "$NF_TEST_ROOT/calls"
: > "$NF_TEST_ROOT/calls"
(main --dry-run --warp)
[[ ! -s $NF_TEST_ROOT/calls ]]
printf 'PASS: default installer skips WARP; explicit --warp dispatches after installation for ws/xhttp\n'
