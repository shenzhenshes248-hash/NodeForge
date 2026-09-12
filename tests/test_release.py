#!/usr/bin/env python3
"""Local release round trips and rejection tests; keys live outside the repo."""
import hashlib
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release', ROOT / 'tools/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.private = cls.base / 'test.key'
        cls.public = cls.base / 'test.pub'
        release.openssl('genpkey', '-algorithm', 'Ed25519', '-out', cls.private)
        cls.private.chmod(0o600)
        release.openssl('pkey', '-in', cls.private, '-pubout', '-out', cls.public)
        cls.artifact, cls.manifest = release.build(cls.base / 'bundle')
        cls.signature = cls.manifest.with_suffix('.sig')
        release.sign(cls.manifest, cls.private, cls.signature)

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(dir=self.base))

    def verify(self, artifact=None, manifest=None, signature=None, public=None):
        return release._verify_with_key(artifact or self.artifact, manifest or self.manifest,
                              signature or self.signature, public or self.public)

    def raw_signed_manifest(self, raw):
        manifest, signature = self.case / 'manifest.json', self.case / 'manifest.sig'
        manifest.write_bytes(raw)
        signature.write_bytes(release.openssl('pkeyutl', '-sign', '-rawin', '-inkey', self.private, '-in', manifest))
        return manifest, signature

    def test_round_trip_and_complete_bundle(self):
        version = (ROOT / 'VERSION').read_text().strip()
        self.assertEqual(version, self.verify())
        with tarfile.open(self.artifact) as archive:
            names = archive.getnames()
            prefix = f'nodeforge-{version}/'
            for name in ['VERSION', 'install.sh', 'uninstall.sh', 'nodeforge.sh', 'tools/release.py',
                         'templates/nodeforge-xray.service', 'templates/vless-reality.json',
                         'trust/release-ed25519.pub']:
                self.assertIn(prefix + name, names)
            for path in (ROOT / 'lib').iterdir():
                if path.suffix in ('.py', '.sh'):
                    self.assertIn(prefix + 'lib/' + path.name, names)
            self.assertFalse(any('/.tools/' in n or '/tests/' in n or n.endswith(('.key', '.sig')) for n in names))
            self.assertNotIn(self.private.read_bytes(), b''.join(archive.extractfile(m).read() for m in archive.getmembers()))
            archive.extractall(self.case)
        result = subprocess.run(['bash', (self.case / prefix / 'nodeforge.sh').as_posix(), 'version'],
                                capture_output=True, text=True, check=True)
        self.assertEqual(f'NodeForge {version}', result.stdout.strip())

    def test_artifact_manifest_signature_tampering(self):
        for kind, original in [('artifact', self.artifact), ('manifest', self.manifest), ('signature', self.signature)]:
            with self.subTest(kind=kind):
                modified = self.case / original.name
                content = bytearray(original.read_bytes())
                content[len(content) // 2] ^= 1
                modified.write_bytes(content)
                with self.assertRaises((ValueError, subprocess.SubprocessError)):
                    self.verify(**{kind: modified})

    def test_wrong_public_key(self):
        private, public = self.case / 'other.key', self.case / 'other.pub'
        release.openssl('genpkey', '-algorithm', 'Ed25519', '-out', private)
        release.openssl('pkey', '-in', private, '-pubout', '-out', public)
        with self.assertRaises(subprocess.SubprocessError):
            self.verify(public=public)

    def test_strict_signed_manifest(self):
        good = json.loads(self.manifest.read_bytes())
        values = [dict(good, schema=True), dict(good, schema=2), dict(good, version=2),
                  dict(good, artifact='../outside.tar.gz'), dict(good, sha256=123),
                  dict(good, extra='unsupported')]
        raws = [json.dumps(value).encode() for value in values]
        raws += [self.manifest.read_bytes().replace(b'"schema": 1', b'"schema": 1, "schema": 1'), b'{bad']
        for raw in raws:
            with self.subTest(raw=raw):
                manifest, signature = self.raw_signed_manifest(raw)
                with self.assertRaises(ValueError):
                    self.verify(manifest=manifest, signature=signature)

    def test_signature_checked_before_json(self):
        manifest = self.case / 'manifest.json'
        manifest.write_bytes(b'{invalid unsigned JSON')
        with mock.patch.object(release, 'manifest_data', side_effect=AssertionError('parsed before authentication')):
            with self.assertRaises(subprocess.SubprocessError):
                self.verify(manifest=manifest)

    def test_signed_bundle_version_mismatch(self):
        artifact = self.case / self.artifact.name
        version = json.loads(self.manifest.read_bytes())['version']
        with tarfile.open(artifact, 'w:gz') as archive:
            member = tarfile.TarInfo(f'nodeforge-{version}/VERSION')
            value = b'v9.9.9\n'
            member.size = len(value)
            archive.addfile(member, io.BytesIO(value))
        data = json.loads(self.manifest.read_bytes())
        data['sha256'] = hashlib.sha256(artifact.read_bytes()).hexdigest()
        manifest, signature = self.raw_signed_manifest(json.dumps(data).encode())
        with self.assertRaises(ValueError):
            self.verify(artifact=artifact, manifest=manifest, signature=signature)

    def test_private_key_location_rejected(self):
        with mock.patch.object(release, 'ROOT', self.base):
            with self.assertRaises(ValueError):
                release.sign(self.manifest, self.private, self.case / 'never.sig')
        manifest = self.base / 'manifest.json'
        shutil.copyfile(self.manifest, manifest)
        with self.assertRaises(ValueError):
            release.sign(manifest, self.private, self.case / 'never.sig')
        self.assertFalse((self.case / 'never.sig').exists())

    def test_cli_fail_closed(self):
        signature = self.case / 'bad.sig'
        signature.write_bytes(b'bad signature')
        result = subprocess.run([sys.executable, str(ROOT / 'tools/release.py'), 'verify',
                                 '--artifact', str(self.artifact), '--manifest', str(self.manifest),
                                 '--signature', str(signature)],
                                capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('', result.stdout)
        self.assertNotIn(self.private.read_text(), result.stderr)

    def test_production_path_fixed_anchor(self):
        # Substitute only the installed trust anchor in this isolated test process.
        # The production entry point and argument parsing remain unchanged.
        args = ['release.py', 'verify', '--artifact', str(self.artifact),
                '--manifest', str(self.manifest), '--signature', str(self.signature)]
        with mock.patch.object(release, 'TRUST_ANCHOR', self.public), \
                mock.patch.object(sys, 'argv', args), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, release.main())

        other_private, other_public = self.case / 'other.key', self.case / 'other.pub'
        other_signature = self.case / 'other.sig'
        release.openssl('genpkey', '-algorithm', 'Ed25519', '-out', other_private)
        release.openssl('pkey', '-in', other_private, '-pubout', '-out', other_public)
        release.sign(self.manifest, other_private, other_signature)
        # Its matching public key works only through the explicit internal test helper.
        self.assertEqual((ROOT / 'VERSION').read_text().strip(),
                         self.verify(signature=other_signature, public=other_public))
        args[-1] = str(other_signature)
        with mock.patch.object(release, 'TRUST_ANCHOR', self.public), \
                mock.patch.object(sys, 'argv', args), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(1, release.main())
        with mock.patch.object(sys, 'argv', args + ['--public-key', str(other_public)]), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as rejected:
            release.main()
        self.assertEqual(2, rejected.exception.code)


if __name__ == '__main__':
    unittest.main()
