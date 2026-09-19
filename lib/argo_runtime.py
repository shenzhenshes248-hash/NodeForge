#!/usr/bin/env python3
"""Run one Quick Tunnel and publish only this invocation's current hostname."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

DOMAIN = re.compile(r'https://([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.trycloudflare\.com)(?=[\s/"|]|$)')


def tunnel_domain(line):
    match = DOMAIN.search(line)
    return match.group(1) if match else None


def publish(path, domain, invocation):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(dict(domain=domain, invocation_id=invocation)) + '\n')
    temporary.replace(path)


def run(binary, config, empty_config, state):
    state = Path(state)
    state.unlink(missing_ok=True)
    inbound = json.loads(Path(config).read_text())['inbounds'][0]
    if inbound['listen'] != '127.0.0.1' or not 1024 <= inbound['port'] <= 65535:
        raise ValueError('Argo requires an unprivileged loopback port')
    invocation = os.environ['INVOCATION_ID']
    child = None
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True
        state.unlink(missing_ok=True)
        if child is not None and child.poll() is None:
            child.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        child = subprocess.Popen(
            [binary, 'tunnel', '--config', empty_config, '--no-autoupdate',
             '--url', f"http://127.0.0.1:{inbound['port']}", '--loglevel', 'info'],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            encoding='utf-8', errors='replace', bufsize=1)
        if stopping:
            child.terminate()
        domain = None
        for line in child.stdout:
            print(line, end='', flush=True)
            current = tunnel_domain(line)
            if current and not stopping:
                domain = current
                # Clear the previous URL while a newly announced tunnel connects.
                state.unlink(missing_ok=True)
            if domain and 'Registered tunnel connection' in line and not stopping:
                publish(state, domain, invocation)
        return child.wait()
    finally:
        state.unlink(missing_ok=True)
        if child is not None:
            child.stdout.close()
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == '__main__':
    sys.exit(run(*sys.argv[1:]))
