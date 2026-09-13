#!/usr/bin/env python3
"""Generate the standalone bootstrap using canonical VERSION, verifier and key."""
import shlex
from pathlib import Path
import release

ROOT = Path(__file__).resolve().parents[1]


def render():
    version, files = release.source_inventory()
    return (ROOT / 'tools/bootstrap.sh.in').read_text().replace(
        '@@PUBLIC_KEY@@', release.TRUST_ANCHOR.read_text().rstrip()).replace(
        '@@VERIFIER@@', (ROOT / 'tools/release.py').read_text().rstrip()).replace(
        '@@VERSION@@', version).replace('@@FILES@@', ' '.join(map(shlex.quote, files)))


if __name__ == '__main__':
    (ROOT / 'bootstrap.sh').write_bytes(render().encode())
