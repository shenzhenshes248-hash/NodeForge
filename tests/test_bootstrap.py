#!/usr/bin/env python3
"""Execute bootstrap locally with fixture downloads; never invoke the real installer."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import build_bootstrap
release = build_bootstrap.release


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.private, cls.public = cls.root / 'test.key', cls.root / 'test.pub'
        release.openssl('genpkey', '-algorithm', 'Ed25519', '-out', cls.private)
        release.openssl('pkey', '-in', cls.private, '-pubout', '-out', cls.public)
        cls.original, _ = release.build(cls.root / 'original')
        cls.version = (ROOT / 'VERSION').read_text().strip()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(dir=self.root))
        self.assets = self.case / 'assets'
        self.assets.mkdir()
        self.work = self.case / 'work'
        self.work.mkdir()
        self.marker = self.case / 'installer-ran'
        self.bundle()

    def bundle(self, extra=None, missing=False):
        artifact = self.assets / self.original.name
        with tarfile.open(self.original) as original, tarfile.open(artifact, 'w:gz') as target:
            for member in original.getmembers():
                if missing and member.name.endswith('/lib/service.sh'):
                    continue
                data = original.extractfile(member).read()
                if member.name.endswith('/install.sh'):
                    data = b'#!/bin/bash\nprintf invoked > "$BOOT_MARKER"\nexit "${BOOT_INSTALL_RC:-0}"\n'
                member = copy.copy(member)
                member.size = len(data)
                target.addfile(member, io.BytesIO(data))
            if extra:
                target.addfile(extra, io.BytesIO(b''))
        manifest = self.assets / 'manifest.json'
        manifest.write_text(json.dumps(dict(schema=1, version=self.version, artifact=artifact.name,
                                            sha256=hashlib.sha256(artifact.read_bytes()).hexdigest())))
        signature = self.assets / 'manifest.sig'
        if signature.exists():
            signature.unlink()
        release.sign(manifest, self.private, signature)

    def run_bootstrap(self, fail_download='', installer_rc='0'):
        script = (ROOT / 'bootstrap.sh').read_text()
        # Only the isolated test copy gets a fixture anchor and platform/download mocks.
        script = script.replace(release.TRUST_ANCHOR.read_text().strip(), self.public.read_text().strip())
        script = script.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin', '# Use the fixture process PATH')
        script = script.replace('[[ ! -s /etc/ssl/certs/ca-certificates.crt ]]', 'false')
        mocks = r'''
id() { printf '0\n'; }
uname() { printf 'x86_64\n'; }
grep() { if [[ ${*: -1} == /etc/os-release ]]; then return 0; fi; command grep "$@"; }
apt-get() { return 99; }
mktemp() { command mktemp -d "$BOOT_TMP/work-XXXXXXXX"; }
curl() {
    local out='' url='' name
    while (( $# )); do
        case $1 in --output) out=$2; shift 2 ;; *) url=$1; shift ;; esac
    done
    [[ $url == "https://github.com/shenzhenshes248-hash/NodeForge/releases/download/$BOOT_VERSION/"* ]] || return 98
    name=${url##*/}
    printf '%s\n' "$name" >> "$BOOT_TMP/downloads"
    [[ $name != "$BOOT_FAIL_DOWNLOAD" ]] || return 22
    command cp "$BOOT_ASSETS/$name" "$out"
}
'''
        env = dict(os.environ, BOOT_TMP=self.work.as_posix(),
                   BOOT_ASSETS=self.assets.as_posix(), BOOT_MARKER=self.marker.as_posix(),
                   BOOT_FAIL_DOWNLOAD=fail_download, BOOT_INSTALL_RC=installer_rc, BOOT_VERSION=self.version)
        result = subprocess.run(['bash', '-s'], input=mocks + script, env=env, text=True,
                                capture_output=True, timeout=60)
        self.assertFalse(list(self.work.glob('work-*')), 'bootstrap temporary directory leaked')
        return result

    def test_generated_entry_matches_sources(self):
        self.assertEqual(build_bootstrap.render(), (ROOT / 'bootstrap.sh').read_text())

    def test_success_and_installer_failure_cleanup(self):
        result = self.run_bootstrap()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(self.marker.exists())
        self.marker.unlink()
        self.assertEqual(7, self.run_bootstrap(installer_rc='7').returncode)
        self.assertTrue(self.marker.exists())

    def test_each_download_failure_stops_install(self):
        for name in ('manifest.json', 'manifest.sig', self.original.name):
            with self.subTest(name=name):
                self.assertNotEqual(0, self.run_bootstrap(fail_download=name).returncode)
                self.assertFalse(self.marker.exists())

    def test_tampering_stops_install(self):
        for name in ('manifest.json', 'manifest.sig', self.original.name):
            with self.subTest(name=name):
                path = self.assets / name
                original = path.read_bytes()
                changed = bytearray(original)
                changed[len(changed) // 2] ^= 1
                path.write_bytes(changed)
                self.assertNotEqual(0, self.run_bootstrap().returncode)
                self.assertFalse(self.marker.exists())
                path.write_bytes(original)

    def test_signed_unsafe_or_incomplete_bundle_stops_install(self):
        traversal = tarfile.TarInfo(f'nodeforge-{self.version}/../escape')
        symlink = tarfile.TarInfo(f'nodeforge-{self.version}/link')
        symlink.type, symlink.linkname = tarfile.SYMTYPE, '/outside'
        for extra, missing in ((traversal, False), (symlink, False), (None, True)):
            with self.subTest(extra=extra, missing=missing):
                self.bundle(extra=extra, missing=missing)
                self.assertNotEqual(0, self.run_bootstrap().returncode)
                self.assertFalse(self.marker.exists())


if __name__ == '__main__':
    unittest.main()
