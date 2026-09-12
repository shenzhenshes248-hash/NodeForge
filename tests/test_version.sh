#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
assert_eq "$(cat "$NF_SOURCE/VERSION")" "$NF_NODEFORGE_VERSION"
assert_eq v26.9.9 "$NF_DEFAULT_XRAY_VERSION"
NF_XRAY_VERSION=v99.1.2
load_nodeforge_version
assert_eq v99.1.2 "$NF_XRAY_VERSION"
original_source=$NF_SOURCE
mkdir "$NF_WORK/source"
NF_SOURCE=$NF_WORK/source
assert_fails load_nodeforge_version
printf 'v1.2.3\nv9.9.9\n' > "$NF_SOURCE/VERSION"
assert_fails load_nodeforge_version
printf 'not-a-version\n' > "$NF_SOURCE/VERSION"
assert_fails load_nodeforge_version
printf 'v1.2.3\n' > "$NF_SOURCE/VERSION"
load_nodeforge_version
assert_eq v1.2.3 "$NF_NODEFORGE_VERSION"
NF_SOURCE=$original_source
load_nodeforge_version
printf 'PASS separate NodeForge/Xray versions and VERSION validation\n'
