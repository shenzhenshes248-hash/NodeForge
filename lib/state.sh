#!/usr/bin/env bash
set -Eeuo pipefail

# Preserve the M1 acceptance predicate and schema-1 on-disk representation.
# Schema 2 is deliberately not enabled, read, written, or migrated in Phase 1.
validate_legacy_state_record() {
    jq -e '.owner == "NodeForge" and .schema == 1 and (.user_created | type == "boolean")' "$1" >/dev/null
}

# Read-only compatibility boundary for future callers, not a migration hook.
# Never return credentials or rewrite a state file while probing compatibility.
state_schema_supported() {
    require_regular "$1"
    jq -e 'type == "object" and (.schema | type == "number") and .schema == 1' "$1" >/dev/null 2>&1
}
