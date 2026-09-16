#!/usr/bin/env python3
"""Small standard-library network validators; no shell commands or persisted secrets."""
import ipaddress
import errno
import secrets
import socket
import sys


def public_ip(value):
    ip = ipaddress.ip_address(value)
    if not ip.is_global or ip.is_multicast or ip.is_reserved or '%' in value:
        raise ValueError('a globally routable IP literal is required')
    return ip


def port_free(port):
    sockets = []
    try:
        families = [(socket.AF_INET, '0.0.0.0')]
        if socket.has_ipv6:
            families.append((socket.AF_INET6, '::'))
        for family, address in families:
            try:
                sock = socket.socket(family, socket.SOCK_STREAM)
                sockets.append(sock)
                if family == socket.AF_INET6:
                    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.bind((address, port))
            except OSError as error:
                if family == socket.AF_INET6 and error.errno in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL):
                    continue  # IPv4-only VPS with IPv6 disabled in the kernel.
                raise
        return True
    except OSError:
        return False
    finally:
        for sock in sockets:
            sock.close()


def main():
    operation = sys.argv[1]
    if operation == 'ip':
        public_ip(sys.argv[2])
    elif operation == 'port':
        if not port_free(int(sys.argv[2])):
            raise ValueError('TCP port unavailable')
    elif operation == 'choose-port':
        if port_free(443):
            print(443)
            return
        for _ in range(256):
            port = 20000 + secrets.randbelow(30001)
            if port_free(port):
                print(port)
                return
        raise ValueError('no free TCP port found after 256 attempts')
    elif operation == 'target-addresses':
        # Forbid local/private targets, including public names resolving privately.
        addresses = socket.getaddrinfo(sys.argv[2], int(sys.argv[3]), type=socket.SOCK_STREAM)
        if not addresses:
            raise ValueError('target has no addresses')
        for address in addresses:
            public_ip(address[4][0])
    else:
        raise ValueError('unknown operation')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, IndexError) as error:
        print(f'Network validation failed: {error}', file=sys.stderr)
        sys.exit(1)
