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
# All modules and this final invocation are parsed before uninstall removes them.
cli_main "$@"
