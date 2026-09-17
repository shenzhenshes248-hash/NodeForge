#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
# Refuse unrelated PATH entries before installing any service/configuration.
mkdir -p "$(dirname "$NF_CLI")"
printf 'unrelated command\n' > "$NF_CLI"
assert_fails install_nodeforge
[[ ! -e $NF_STATE && ! -e $NF_CONFIG ]]
assert_eq 'unrelated command' "$(cat "$NF_CLI")"
rm "$NF_CLI"
install_nodeforge > "$NF_WORK/output"
runtime_validate
before=$(sha256_file "$NF_CLI")
inventory=$(sha256_file "$NF_RUNTIME/.inventory")
assert_eq "$NF_CLI" "$(PATH="$(dirname "$NF_CLI"):$PATH" command -v nodeforge)"
# Execute the actual installed entry in a separate Bash process.
assert_eq "NodeForge $NF_NODEFORGE_VERSION" "$(bash "$NF_CLI" version)"
bash "$NF_CLI" --help > "$NF_WORK/installed-help"
grep -q 'Usage: nodeforge' "$NF_WORK/installed-help"
install_nodeforge > "$NF_WORK/again"
assert_eq "$before" "$(sha256_file "$NF_CLI")"
assert_eq "$inventory" "$(sha256_file "$NF_RUNTIME/.inventory")"
assert_eq 1 "$(find "$NF_APP/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
printf '\n' >> "$NF_RUNTIME/lib/cli.sh"
assert_fails install_nodeforge
assert_fails uninstall_nodeforge
[[ -f $NF_STATE && -f $NF_TEST_ROOT/active ]]
cp "$NF_SOURCE/lib/cli.sh" "$NF_RUNTIME/lib/cli.sh"
cp "$NF_CLI" "$NF_WORK/good-entry"
printf '\n# external modification\n' >> "$NF_CLI"
assert_fails uninstall_nodeforge
[[ -f $NF_STATE && -f $NF_TEST_ROOT/active ]]
cp "$NF_WORK/good-entry" "$NF_CLI"
printf 'unrelated\n' > "$NF_RUNTIME/lib/keep-me"
printf 'unrelated\n' > "$NF_CONFIG_DIR/keep-me"
runtime_validate
# Execute the actual installed launcher and nodeforge.sh for self-uninstall.
# Instrument only this disposable runtime to inject host mocks after module load.
NF_ORIGINAL_SOURCE=$NF_SOURCE NF_FIXTURE_PATH=$PATH NF_ENTRY_FIXTURE=$NF_WORK/entry-fixture.sh
export NF_ORIGINAL_SOURCE NF_FIXTURE_PATH NF_ENTRY_FIXTURE
cat > "$NF_ENTRY_FIXTURE" <<'FIXTURE'
saved_runtime=$NF_SOURCE
NF_SOURCE=$NF_ORIGINAL_SOURCE
source "$NF_SOURCE/tests/helpers/cli_mocks.sh"
NF_SOURCE=$saved_runtime
export PATH=$NF_FIXTURE_PATH
NF_BIN_DIR=$NF_TEST_ROOT/usr/local/nodeforge
NF_CONFIG_DIR=$NF_TEST_ROOT/etc/nodeforge
NF_DATA_DIR=$NF_TEST_ROOT/var/lib/nodeforge
NF_BIN=$NF_BIN_DIR/bin/xray NF_LICENSE=$NF_BIN_DIR/LICENSE.xray
NF_CONFIG=$NF_CONFIG_DIR/xray.json NF_STATE=$NF_DATA_DIR/state.json
NF_PENDING=$NF_DATA_DIR/pending
NF_UNIT=$NF_TEST_ROOT/etc/systemd/system/nodeforge-xray.service
NF_HYSTERIA_UNIT=$NF_TEST_ROOT/etc/systemd/system/nodeforge-hysteria.service
NF_HYSTERIA_BIN=$NF_BIN_DIR/bin/hysteria
NF_HYSTERIA_CONFIG=$NF_CONFIG_DIR/hysteria.yaml
NF_HYSTERIA_CERT=$NF_CONFIG_DIR/hysteria.crt
NF_HYSTERIA_KEY=$NF_CONFIG_DIR/hysteria.key
NF_HYSTERIA_STATE=$NF_DATA_DIR/hysteria.json
NF_CLI=$NF_TEST_ROOT/usr/local/bin/nodeforge
FIXTURE
# shellcheck disable=SC2016
sed '/^load_modules$/a source "$NF_ENTRY_FIXTURE"' "$NF_SOURCE/nodeforge.sh" > "$NF_RUNTIME/nodeforge.sh"
runtime_inventory "$NF_RUNTIME" > "$NF_RUNTIME/.inventory"
bash "$NF_CLI" uninstall > "$NF_WORK/self-uninstall"
[[ ! -f $NF_CLI && ! -f $NF_CONFIG && ! -f $NF_BIN && ! -f $NF_STATE && ! -f $NF_UNIT ]]
[[ -f $NF_RUNTIME/lib/keep-me && -f $NF_CONFIG_DIR/keep-me ]]
assert_fails env PATH="$(dirname "$NF_CLI")" /bin/bash -c 'command -v nodeforge'
uninstall_nodeforge
cli_main uninstall
printf 'PASS installed CLI entry, idempotency, integrity, self-removal and unknown files\n'
