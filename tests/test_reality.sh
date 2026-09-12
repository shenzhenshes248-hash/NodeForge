#!/usr/bin/env bash
set -Eeuo pipefail
source "${NF_SOURCE:?}/tests/helpers/setup.sh"
parse_reality_target www.example.com:443
assert_eq www.example.com "$NF_TARGET_HOST"
assert_eq 443 "$NF_TARGET_PORT"
parse_reality_target '[2606:4700::1111]:443'
assert_eq 2606:4700::1111 "$NF_TARGET_HOST"
for value in 'example.com' 'https://example.com:443' 'example.com:0' 'example.com:65536' 'example.com:0443' 'foo;id:443'; do
    assert_fails parse_reality_target "$value"
done
assert_fails valid_hostname '*.example.com'
assert_fails valid_hostname 'bad..example.com'
NF_TARGET=www.example.com:443 NF_SNI=www.example.com
timeout() { return 1; }
assert_fails validate_reality_target
NF_UUID=123e4567-e89b-42d3-a456-426614174000 NF_SHORT_ID=0123456789abcdef NF_PORT=20000
NODEFORGE_REALITY_TARGET=target.example.com:443
apply_overrides
assert_eq target.example.com "$NF_SNI"
NODEFORGE_REALITY_TARGET=8.8.8.8:443
assert_fails apply_overrides
printf 'PASS reality target validation\n'
