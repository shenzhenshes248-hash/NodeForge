#!/usr/bin/env python3
"""Small token-path HTTP endpoint serving NodeForge's current share links."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys


def edge_address(value):
    if not value:
        return ''
    try:
        address = ipaddress.ip_address(value.strip('[]'))
        return f'[{address}]' if address.version == 6 else str(address)
    except ValueError:
        if len(value) > 253 or not all(re.fullmatch(
                r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', label)
                for label in value.split('.')):
            raise ValueError('Edge address must be an IP or hostname, without port or URL')
        return value


def create_config(address):
    family = socket.AF_INET6 if ':' in address else socket.AF_INET
    bind = '::' if family == socket.AF_INET6 else '0.0.0.0'
    for _ in range(100):
        port = 20000 + secrets.randbelow(30001)
        with socket.socket(family) as probe:
            try:
                probe.bind((bind, port))
            except OSError:
                continue
        return dict(owner='NodeForge', schema=1, address=address, bind=bind,
                    port=port, token=secrets.token_hex(32))
    raise ValueError('No free subscription port')


def read_config(path):
    config = json.loads(Path(path).read_text())
    assert config['owner'] == 'NodeForge' and config['schema'] == 1
    ipaddress.ip_address(config['address'])
    assert config['bind'] in ('0.0.0.0', '::')
    assert type(config['port']) is int and 20000 <= config['port'] <= 50000
    assert re.fullmatch('[a-f0-9]{64}', config['token'])
    return config


def subscription_url(config):
    host = config['address']
    if ':' in host:
        host = f'[{host}]'
    return f"http://{host}:{config['port']}/{config['token']}/sub.txt"


def current_content():
    result = subprocess.run(['/usr/local/bin/nodeforge', 'subscription-content'],
                            check=True, capture_output=True, timeout=20)
    lines = result.stdout.decode().splitlines()
    if len(lines) != 3 or not all(line.startswith(prefix) for line, prefix in zip(
            lines, ('vless://', 'hysteria2://', 'vless://'))):
        raise ValueError('Three current nodes are not ready')
    return ('\n'.join(lines) + '\n').encode()


def handler(config, content=current_content):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != f"/{config['token']}/sub.txt":
                self.send_error(404)
                return
            try:
                body = content()
                status = 200
            except (OSError, ValueError, subprocess.SubprocessError):
                body = b'NodeForge nodes not ready; retry shortly.\n'
                status = 503
            self.send_response(status)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format, *args):
            pass  # Do not put the token URL in the journal.
    return Handler


def main():
    if sys.argv[1] == 'edge':
        print(edge_address(sys.argv[2]))
    elif sys.argv[1] == 'create':
        print(json.dumps(create_config(sys.argv[2])))
    elif sys.argv[1] == 'url':
        print(subscription_url(read_config(sys.argv[2])))
    else:
        config = read_config(sys.argv[1])
        class Server(ThreadingHTTPServer):
            address_family = socket.AF_INET6 if config['bind'] == '::' else socket.AF_INET
        with Server((config['bind'], config['port']), handler(config)) as server:
            server.serve_forever()


if __name__ == '__main__':
    main()
