#!/usr/bin/env python3
"""Strict local CLI validation. Never print input values or raw tool errors."""
import base64
import gzip
import hashlib
import io
import tarfile
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


def warp_xray(config, enabled):
    """Only the two NodeForge outbound policies are accepted; preserve inbounds."""
    direct = [{'tag': 'direct', 'protocol': 'freedom'}]
    proxy = [
        {'tag': 'warp', 'protocol': 'socks',
         'settings': {'servers': [{'address': '127.0.0.1', 'port': 40000}]}},
        {'tag': 'warp-block', 'protocol': 'blackhole'},
    ]
    routing = {'rules': [{'type': 'field', 'network': 'udp', 'outboundTag': 'warp-block'}]}
    if config.get('outbounds') == direct and 'routing' not in config:
        pass
    elif config.get('outbounds') == proxy and config.get('routing') == routing:
        pass
    else:
        raise ValueError('unsupported outbound policy')
    config['outbounds'] = proxy if enabled else direct
    if enabled:
        config['routing'] = routing
    else:
        config.pop('routing', None)
    return config


WARP_HYSTERIA = ('# NodeForge WARP outbound\n'
                 'disableUDP: true\n'
                 'outbounds:\n'
                 '  - name: warp\n'
                 '    type: socks5\n'
                 '    socks5:\n'
                 '      addr: 127.0.0.1:40000\n')


def warp_hysteria(text, enabled):
    # Both switch directions keep HY2 direct. The old suffix is recognized
    # only to restore configurations installed by v0.6.0, never emitted again.
    if text.endswith(WARP_HYSTERIA):
        text = text[:-len(WARP_HYSTERIA)]
    # The managed base has only listen, tls and auth. Never silently keep an ACL
    # or a second outbound that could bypass the selected egress.
    if re.search(r'^(?:outbounds|acl|disableUDP):', text, re.MULTILINE):
        raise ValueError('unsupported Hysteria outbound policy')
    return text


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
    if config.get('outbounds', [{}])[0].get('tag') == 'warp':
        warp_xray(template, True)
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


BACKUP_REQUIRED = {'reality-config', 'reality-state', 'hy2-config', 'hy2-state', 'hy2-cert', 'hy2-key'}
BACKUP_ARGO = {'argo-config', 'argo-state', 'argo-tunnel'}
BACKUP_ALLOWED = BACKUP_REQUIRED | BACKUP_ARGO | {'argo-credentials', 'warp-state', 'subscription', 'argo-edge'}
BACKUP_LIMIT = 4 * 1024 * 1024


def backup_digest(data):
    return hashlib.sha256(data).hexdigest()


def backup_validate_inventory(files):
    if not BACKUP_REQUIRED <= files.keys() or not files.keys() <= BACKUP_ALLOWED:
        raise ValueError('file inventory')
    if files.keys() & BACKUP_ARGO and not BACKUP_ARGO <= files.keys():
        raise ValueError('incomplete Argo')
    if 'argo-state' in files:
        state = json.loads(files['argo-state'], object_pairs_hook=unique_object)
        profile = json.loads(files['argo-config'])['inbounds'][0]['streamSettings']['network']
        if profile not in ('ws', 'xhttp') or state.get('profile', 'ws') != profile:
            raise ValueError('profile')
        if (profile == 'xhttp') != ('argo-credentials' in files):
            raise ValueError('Named Tunnel credentials')
    elif 'argo-credentials' in files:
        raise ValueError('orphan credentials')


def backup_create(output, version, pairs):
    files = {}
    for name, path in zip(pairs[::2], pairs[1::2]):
        p = Path(path)
        if p.is_symlink():
            raise ValueError('symlink')
        if p.exists():
            if not p.is_file() or p.stat().st_size > BACKUP_LIMIT:
                raise ValueError('invalid file')
            files[name] = p.read_bytes()
    backup_validate_inventory(files)
    manifest = {'format': 'NodeForge-backup', 'schema': 1, 'version': version,
                'files': {name: backup_digest(data) for name, data in files.items()}}
    payload = {'manifest.json': json.dumps(manifest, sort_keys=True).encode(), **files}
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as raw, tarfile.open(fileobj=raw, mode='w:gz') as archive:
            for name, data in payload.items():
                entry = tarfile.TarInfo(name)
                entry.size, entry.mode = len(data), 0o600
                archive.addfile(entry, io.BytesIO(data))
    except BaseException:
        Path(output).unlink(missing_ok=True)
        raise


def backup_extract(source, destination):
    files = {}
    # Read through the gzip trailer so truncated/corrupt streams cannot pass
    # merely because tar reached its end marker first.
    with gzip.open(source, 'rb') as compressed:
        raw = compressed.read(BACKUP_LIMIT * (len(BACKUP_ALLOWED) + 1) + 10241)
    if len(raw) > BACKUP_LIMIT * (len(BACKUP_ALLOWED) + 1) + 10240:
        raise ValueError('archive too large')
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as archive:
        for entry in archive:
            if (entry.name not in BACKUP_ALLOWED | {'manifest.json'} or entry.name in files
                    or not entry.isfile() or entry.size > BACKUP_LIMIT or entry.size < 0):
                raise ValueError('invalid archive member')
            files[entry.name] = archive.extractfile(entry).read()
    manifest = json.loads(files.pop('manifest.json'), object_pairs_hook=unique_object)
    if (set(manifest) != {'format', 'schema', 'version', 'files'}
            or manifest['format'] != 'NodeForge-backup' or type(manifest['schema']) is not int
            or manifest['schema'] != 1
            or not re.fullmatch(r'v\d+\.\d+\.\d+(?:-dev)?', manifest['version'])
            or manifest['files'] != {name: backup_digest(data) for name, data in files.items()}):
        raise ValueError('invalid manifest or checksum')
    backup_validate_inventory(files)
    root = Path(destination)
    root.mkdir(mode=0o700)
    for name, data in files.items():
        with os.fdopen(os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as out:
            out.write(data)


def backup_validate_stage(stage, config_dir, argo_dir, source):
    from subscription import read_config, edge_address
    stage, config_dir, argo_dir, source = map(Path, (stage, config_dir, argo_dir, source))
    hy = read_json(stage / 'hy2-state')
    expected = (f"listen: :{hy['listen']}\ntls:\n  cert: {config_dir.as_posix()}/hysteria.crt\n"
                f"  key: {config_dir.as_posix()}/hysteria.key\nauth:\n  type: password\n"
                f"  password: {hy['password']}\n")
    if warp_hysteria((stage / 'hy2-config').read_text(), False) != expected:
        raise ValueError('Hysteria identity/config mismatch')
    def openssl(*args):
        return subprocess.run(['openssl', *map(str, args)], check=True, capture_output=True,
                              timeout=10).stdout
    cert_public = openssl('x509', '-in', stage / 'hy2-cert', '-pubkey', '-noout')
    key_public = openssl('pkey', '-in', stage / 'hy2-key', '-pubout')
    if cert_public != key_public:
        raise ValueError('certificate/key mismatch')
    enabled = False
    if (stage / 'warp-state').exists():
        warp = read_json(stage / 'warp-state')
        if warp.get('owner') != 'NodeForge' or warp.get('schema') != 1 or warp.get('mode') not in ('enabled', 'disabled'):
            raise ValueError('WARP state')
        enabled = warp['mode'] == 'enabled'
    reality = read_json(stage / 'reality-config')
    if (reality['outbounds'][0].get('tag') == 'warp') != enabled:
        raise ValueError('Reality/WARP state mismatch')
    if (stage / 'argo-state').exists():
        config = read_json(stage / 'argo-config')
        inbound = config['inbounds'][0]
        profile = inbound['streamSettings']['network']
        template = read_json(source / 'templates' / f'vless-{profile}.json')
        uuid = inbound['settings']['clients'][0]['id']
        if not re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', uuid):
            raise ValueError('Argo UUID')
        if type(inbound['port']) is not int or not 1024 <= inbound['port'] <= 65535:
            raise ValueError('Argo port')
        template['inbounds'][0]['port'] = inbound['port']
        template['inbounds'][0]['settings']['clients'][0]['id'] = uuid
        warp_xray(template, enabled)
        if template != config:
            raise ValueError('Argo configuration')
        tunnel = read_json(stage / 'argo-tunnel')
        if profile == 'ws':
            if tunnel != {}:
                raise ValueError('Quick Tunnel configuration')
        else:
            credentials = read_json(stage / 'argo-credentials')
            domain = read_json(stage / 'argo-state')['tunnel_domain']
            if (not hostname(domain) or not re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', credentials['TunnelID'])
                    or not all(isinstance(credentials[k], str) and credentials[k] for k in ('AccountTag', 'TunnelSecret'))):
                raise ValueError('Named Tunnel identity')
            expected_tunnel = {'tunnel': credentials['TunnelID'], 'credentials-file': (argo_dir / 'credentials.json').as_posix(),
                               'ingress': [{'hostname': domain, 'service': f"http://127.0.0.1:{inbound['port']}"},
                                           {'service': 'http_status:404'}]}
            if tunnel != expected_tunnel:
                raise ValueError('Named Tunnel configuration')
    if (stage / 'subscription').exists():
        read_config(stage / 'subscription')
    if (stage / 'argo-edge').exists():
        edge_address(read_json(stage / 'argo-edge')['address'])


def main():
    if sys.argv[1] in ('warp-xray', 'warp-hysteria'):
        operation, mode, path = sys.argv[1:4]
        if mode not in ('enabled', 'disabled'):
            raise ValueError('mode')
        if operation == 'warp-xray':
            print(json.dumps(warp_xray(read_json(path), mode == 'enabled'), indent=2))
        else:
            sys.stdout.buffer.write(warp_hysteria(Path(path).read_text(), mode == 'enabled').encode())
    elif sys.argv[1] == 'rename-directory':
        source, destination = map(Path, sys.argv[2:4])
        # Sibling staging only. os.rename raises EXDEV; it never copies a tree.
        if (source.parent != destination.parent or source.is_symlink()
                or not source.is_dir() or destination.exists() or destination.is_symlink()
                or source.stat().st_dev != destination.parent.stat().st_dev):
            raise ValueError('unsafe directory rename')
        os.rename(source, destination)
    elif sys.argv[1] in ('state', 'link'):
        validate_state(*sys.argv[2:5], derive=True)
    elif sys.argv[1] == 'backup-create':
        backup_create(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif sys.argv[1] == 'backup-extract':
        backup_extract(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'backup-validate':
        backup_validate_stage(*sys.argv[2:])
    elif sys.argv[1] == 'listener':
        listener(sys.stdin.read(), *sys.argv[2:])
    else:
        raise ValueError('operation')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, TypeError, KeyError, IndexError, AttributeError, OSError,
            AssertionError, EOFError, tarfile.TarError, subprocess.SubprocessError):
        print('NodeForge: local validation failed (details suppressed)', file=sys.stderr)
        sys.exit(1)
