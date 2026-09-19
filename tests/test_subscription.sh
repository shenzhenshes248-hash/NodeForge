#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
install_nodeforge > "$NF_WORK/core-install"
load_argo() { :; }
eval "$(declare -f systemctl | sed '1s/systemctl/core_systemctl/')"
systemctl() {
    if [[ $* != *nodeforge-subscription* ]]; then core_systemctl "$@"; return; fi
    case $1 in
        enable) touch "$NF_TEST_ROOT/sub-enabled" ;;
        start)
            [[ ! -f $NF_TEST_ROOT/fail-sub ]] || return 1
            touch "$NF_TEST_ROOT/sub-active" ;;
        stop) rm -f "$NF_TEST_ROOT/sub-active" ;;
        disable) rm -f "$NF_TEST_ROOT/sub-enabled" ;;
        is-active) [[ -f $NF_TEST_ROOT/sub-active ]] ;;
        *) return 1 ;;
    esac
}
before=$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_CLI")
subscription_paths
touch "$NF_TEST_ROOT/fail-sub"
assert_fails install_subscription
[[ ! -e $NF_SUB_DIR && ! -e $NF_SUB_CONFIG && ! -e $NF_SUB_UNIT ]]
rm "$NF_TEST_ROOT/fail-sub"
install_subscription > "$NF_WORK/sub-install"
load_subscription
[[ -f $NF_TEST_ROOT/sub-enabled && -f $NF_TEST_ROOT/sub-active ]]
url=$(subscription_url)
[[ $url == http://8.8.8.8:*/sub.txt ]]
assert_eq "Subscription URL: $url" "$(cat "$NF_WORK/sub-install")"
config=$(sha256_file "$NF_SUB_CONFIG")
install_subscription > "$NF_WORK/sub-again"
assert_eq "$url" "$(subscription_url)"
assert_eq "$config" "$(sha256_file "$NF_SUB_CONFIG")"
assert_eq "$before" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_CLI")"
uninstall_subscription
[[ ! -e $NF_SUB_CONFIG && ! -e $NF_SUB_DIR && ! -e $NF_SUB_UNIT ]]
assert_eq "$before" "$(sha256sum "$NF_CONFIG" "$NF_STATE" "$NF_HYSTERIA_CONFIG" "$NF_HYSTERIA_STATE" "$NF_CLI")"
printf 'PASS subscription install, rollback, stable URL, idempotency and isolated uninstall\n'
