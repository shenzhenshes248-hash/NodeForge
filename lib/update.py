#!/usr/bin/env python3
"""Fixed-origin release discovery/download; use the installed release verifier."""
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import release

REPOSITORY = 'https://github.com/shenzhenshes248-hash/NodeForge'
API = 'https://api.github.com/repos/shenzhenshes248-hash/NodeForge/releases'


def version_key(value):
    if not isinstance(value, str) or not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-dev)?', value):
        raise ValueError('Unsupported release version')
    return tuple(map(int, value.removeprefix('v').removesuffix('-dev').split('.'))) + (not value.endswith('-dev'),)


def download(url, destination):
    subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
                    '--proto-redir', '=https', '--connect-timeout', '15', '--max-time', '300',
                    '--output', str(destination), url], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=310)


def latest(current, work):
    candidates = []
    for page in range(1, 101):
        destination = work / 'releases.json'
        download(f'{API}?per_page=100&page={page}', destination)
        entries = json.loads(destination.read_bytes())
        if not isinstance(entries, list):
            raise ValueError('Invalid release response')
        for entry in entries:
            if entry.get('draft') is not False:
                continue
            tag = entry.get('tag_name')
            try:
                key = version_key(tag)
            except ValueError:
                continue
            # Development builds may follow development releases; stable builds do not.
            if not current.endswith('-dev') and (tag.endswith('-dev') or entry.get('prerelease') is not False):
                continue
            if key > version_key(current):
                candidates.append((key, tag))
        if len(entries) < 100:
            return max(candidates)[1] if candidates else current
    raise ValueError('Release pagination limit exceeded')


def prepare(current, work, anchor):
    version_key(current)
    target = latest(current, work)
    if target == current:
        return current
    names = ('manifest.json', 'manifest.sig', f'nodeforge-{target}.tar.gz')
    for name in names:
        download(f'{REPOSITORY}/releases/download/{target}/{name}', work / name)
    release.TRUST_ANCHOR = anchor  # Supplied only by the root CLI's canonical local path.
    actual = release.extract(work / names[2], work / names[0], work / names[1], work / 'extracted')
    if actual != target:
        raise ValueError('Release version mismatch')
    return target


if __name__ == '__main__':
    try:
        print(prepare(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])))
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError, release.tarfile.TarError):
        print('NodeForge update: release check or verification failed', file=sys.stderr)
        sys.exit(1)
