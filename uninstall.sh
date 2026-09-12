#!/usr/bin/env bash
set -Eeuo pipefail
set +x
set +a
unset NF_PRIVATE_KEY NF_PUBLIC_KEY
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
NF_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$NF_SOURCE/lib/common.sh"
load_modules
main() {
    (( $# == 0 )) || die 'Usage: bash uninstall.sh'
    preflight
    command -v jq >/dev/null || die 'jq is required to read the ownership record safely'
    acquire_lock
    init_workspace
    trap cleanup EXIT
    uninstall_nodeforge
}
main "$@"
