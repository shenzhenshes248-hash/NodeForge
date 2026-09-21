#!/usr/bin/env python3
"""Provision a locally managed Named Tunnel after one Cloudflare login."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def save_json(path, value):
    temporary = path.with_suffix('.tmp')
    with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as stream:
        json.dump(value, stream)
        stream.write('\n')
    temporary.replace(path)


def provision(auth, directory, machine_id, domain, api):
    zone = api('GET', '/zones/' + auth['zoneID'])
    suffix = hashlib.sha256(machine_id.encode()).hexdigest()[:12]
    domain = domain or 'nodeforge-' + suffix + '.' + zone['name']
    if not domain.endswith('.' + zone['name']):
        raise ValueError('Argo hostname must be a subdomain of the authorized Cloudflare zone')
    name = 'nodeforge-xhttp-' + suffix
    endpoint = '/accounts/' + auth['accountID'] + '/cfd_tunnel'
    tunnels = api('GET', endpoint + '?' + urlencode({'name': name, 'is_deleted': 'false'}))
    tunnels = [t for t in tunnels if t['name'] == name and not t.get('deleted_at')]
    records = api('GET', '/zones/' + auth['zoneID'] + '/dns_records?' + urlencode({'name': domain}))
    if len(tunnels) > 1:
        raise ValueError('Multiple matching Named Tunnels; cannot select credentials')
    if records and (not tunnels or len(records) != 1 or records[0]['type'] != 'CNAME'
                    or records[0]['content'].rstrip('.') != tunnels[0]['id'] + '.cfargotunnel.com'):
        raise ValueError('Argo hostname already has an unrelated DNS record')
    if tunnels:
        tunnel_id = tunnels[0]['id']
        credentials = json.loads((directory / (tunnel_id + '.json')).read_text())
        if credentials['TunnelID'] != tunnel_id or credentials['AccountTag'] != auth['accountID'] or not credentials['TunnelSecret']:
            raise ValueError('Saved Named Tunnel credentials do not match')
    else:
        secret = base64.b64encode(secrets.token_bytes(32)).decode()
        tunnel = api('POST', endpoint, {'name': name, 'config_src': 'local', 'tunnel_secret': secret})
        tunnel_id = tunnel['id']
        credentials = {'AccountTag': auth['accountID'], 'TunnelID': tunnel_id, 'TunnelSecret': secret}
        save_json(directory / (tunnel_id + '.json'), credentials)
    dns_endpoint = '/zones/' + auth['zoneID'] + '/dns_records'
    record = {'type': 'CNAME', 'name': domain, 'content': tunnel_id + '.cfargotunnel.com', 'proxied': True, 'ttl': 1}
    if not records:
        api('POST', dns_endpoint, record)
    elif not records[0]['proxied']:
        api('PATCH', dns_endpoint + '/' + records[0]['id'], {'proxied': True})
    return domain, credentials


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cloudflared', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--domain', default='')
    args = parser.parse_args()
    directory = Path.home() / '.cloudflared'
    directory.mkdir(mode=0o700, exist_ok=True)
    cert = directory / 'cert.pem'
    if not cert.exists():
        print('Cloudflare authorization: open the following login URL, select your domain, and authorize.', flush=True)
        subprocess.run([args.cloudflared, 'tunnel', 'login'], check=True)
    encoded = ''.join(line for line in cert.read_text().splitlines() if not line.startswith('-----'))
    auth = json.loads(base64.b64decode(encoded))

    def api(method, path, body=None):
        request = Request('https://api.cloudflare.com/client/v4' + path,
                          data=None if body is None else json.dumps(body).encode(), method=method,
                          headers={'Authorization': 'Bearer ' + auth['apiToken'], 'Content-Type': 'application/json'})
        try:
            with urlopen(request, timeout=30) as response:
                result = json.load(response)
        except HTTPError as error:
            raise ValueError('Cloudflare API ' + method + ' failed: HTTP ' + str(error.code)) from None
        if not result.get('success'):
            raise ValueError('Cloudflare API ' + method + ' failed')
        return result['result']

    domain, credentials = provision(auth, directory, Path('/etc/machine-id').read_text().strip(), args.domain, api)
    save_json(args.output / 'credentials.json', credentials)
    save_json(args.output / 'named-tunnel.json', {'domain': domain})
    print('Named Tunnel ready: ' + domain)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('Named Tunnel setup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
