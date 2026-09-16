#!/usr/bin/env python3
"""Strict local CLI validation. Never print input values or raw tool errors."""
import base64
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key')
        result[key] = value
    return result


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=unique_object)


def matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def hostname(value):
    return (isinstance(value, str) and len(value) <= 253 and '.' in value
            and not re.fullmatch(r'[0-9.]+', value)
            and all(matches(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', part)
                    for part in value.split('.')))


def validate_state(state_path, config_path, template_path, derive=False):
    state, config, template = map(read_json, (state_path, config_path, template_path))
    hashes = {'config_sha256', 'binary_sha256', 'unit_sha256', 'license_sha256'}
    if set(state) != hashes | {'owner', 'schema', 'version', 'public_key', 'server_ip', 'user_created'}:
        raise ValueError('state fields')
    if (state['owner'] != 'NodeForge' or type(state['schema']) is not int or state['schema'] != 1
            or type(state['user_created']) is not bool
            or not matches(r'v[0-9]+\.[0-9]+\.[0-9]+', state['version'])
            or not all(matches(r'[a-f0-9]{64}', state[key]) for key in hashes)
            or not matches(r'[A-Za-z0-9_-]{43}', state['public_key'])):
        raise ValueError('state values')
    ip = ipaddress.ip_address(state['server_ip'])
    if not ip.is_global or ip.is_multicast or ip.is_reserved or '%' in state['server_ip']:
        raise ValueError('address')
    inbound = config['inbounds'][0]
    reality = inbound['streamSettings']['realitySettings']
    client = inbound['settings']['clients'][0]
    if (type(inbound['port']) is not int
            or not (inbound['port'] == 443 or 1024 <= inbound['port'] <= 65535)
            or inbound['listen'] != ('::' if ip.version == 6 else '0.0.0.0')
            or not matches(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', client['id'])
            or not matches(r'[A-Za-z0-9_-]{43}', reality['privateKey'])
            or len(reality['shortIds']) != 1 or not matches(r'[a-f0-9]{16}', reality['shortIds'][0])
            or len(reality['serverNames']) != 1 or not hostname(reality['serverNames'][0])):
        raise ValueError('identity')
    target = reality['target']
    host, port = target.rsplit(':', 1)
    if not matches(r'[1-9][0-9]{0,4}', port) or int(port) > 65535:
        raise ValueError('target port')
    if host.startswith('[') and host.endswith(']'):
        ipaddress.IPv6Address(host[1:-1])
    elif not hostname(host):
        raise ValueError('target hostname')
    expected = template['inbounds'][0]
    expected['port'], expected['listen'] = inbound['port'], inbound['listen']
    expected['settings']['clients'][0]['id'] = client['id']
    for key in ('privateKey', 'serverNames', 'shortIds', 'target'):
        expected['streamSettings']['realitySettings'][key] = reality[key]
    # JSON comparison also distinguishes false/0 and 0/0.0, unlike Python equality.
    if json.dumps(config, sort_keys=True) != json.dumps(template, sort_keys=True):
        raise ValueError('unsupported configuration')
    if derive:
        private = base64.urlsafe_b64decode(reality['privateKey'] + '=')
        # RFC 8410 PKCS#8 X25519 key, passed through stdin, never argv or a file.
        result = subprocess.run(['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                                input=bytes.fromhex('302e020100300506032b656e04220420') + private,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=True)
        if len(result.stdout) != 44 or result.stdout[:12] != bytes.fromhex('302a300506032b656e032100'):
            raise ValueError('public key encoding')
        public = base64.urlsafe_b64encode(result.stdout[12:]).decode().rstrip('=')
        if public != state['public_key']:
            raise ValueError('public key mismatch')


def listener(lines, listen, port, pid, family=None):
    expected = ipaddress.ip_address(listen)
    family = expected.version if family is None else int(family)
    dual_stack = expected == ipaddress.ip_address('0.0.0.0') and family == 6
    if family != expected.version and not dual_stack:
        raise ValueError('listener family')
    found = False
    for line in lines.splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[0] != 'LISTEN':
            raise ValueError('listener format')
        address, actual_port = fields[3].rsplit(':', 1)
        if actual_port != port:
            raise ValueError('listener port')
        address = address.strip('[]')
        # A cross-family wildcard is valid only with per-socket IPv4 support.
        target = ipaddress.ip_address('::') if dual_stack else expected
        if address != '*' and ipaddress.ip_address(address) != target:
            raise ValueError('listener address')
        if dual_stack and [field for field in fields[5:] if field.startswith('v6only:')] != ['v6only:0']:
            raise ValueError('listener is not dual-stack')
        pids = re.findall(r'\bpid=([0-9]+),', ' '.join(fields[5:]))
        if not pids or any(value != pid for value in pids):
            raise ValueError('listener owner')
        found = True
    if not found:
        raise ValueError('listener missing')


def main():
    if sys.argv[1] == 'rename-directory':
        source, destination = map(Path, sys.argv[2:4])
        # Sibling staging only. os.rename raises EXDEV; it never copies a tree.
        if (source.parent != destination.parent or source.is_symlink()
                or not source.is_dir() or destination.exists() or destination.is_symlink()
                or source.stat().st_dev != destination.parent.stat().st_dev):
            raise ValueError('unsafe directory rename')
        os.rename(source, destination)
    elif sys.argv[1] in ('state', 'link'):
        validate_state(*sys.argv[2:5], derive=True)
    elif sys.argv[1] == 'listener':
        listener(sys.stdin.read(), *sys.argv[2:])
    else:
        raise ValueError('operation')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, TypeError, KeyError, IndexError, AttributeError, OSError, subprocess.SubprocessError):
        print('NodeForge: local validation failed (details suppressed)', file=sys.stderr)
        sys.exit(1)
