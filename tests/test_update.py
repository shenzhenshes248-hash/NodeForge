#!/usr/bin/env python3
"""Release selection and authenticated update preparation, with local transport fixtures."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('update', ROOT / 'lib/update.py')
update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / 'work'
        self.work.mkdir()

    def test_version_order_and_channels(self):
        entries = [dict(tag_name=tag, draft=False, prerelease=tag.endswith('-dev'))
                   for tag in ['v0.2.0-dev', 'v0.2.0', 'v0.10.0-dev', 'bad', '../outside']]
        entries.append(dict(tag_name='v99.0.0', draft=True, prerelease=False))
        def download(url, destination):
            destination.write_text(json.dumps(entries))
        with mock.patch.object(update, 'download', side_effect=download):
            self.assertEqual('v0.10.0-dev', update.latest('v0.2.0-dev', self.work))
            self.assertEqual('v0.2.0', update.latest('v0.1.0', self.work))
            self.assertEqual('v0.2.0', update.latest('v0.2.0', self.work))

    def test_pagination_and_no_downgrade(self):
        def download(url, destination):
            entries = [dict(tag_name='v0.1.0', draft=False, prerelease=False)] * 100 if 'page=1' == url.split('&')[-1] else [dict(tag_name='v1.0.0', draft=False, prerelease=False)]
            destination.write_text(json.dumps(entries))
        with mock.patch.object(update, 'download', side_effect=download):
            self.assertEqual('v1.0.0', update.latest('v0.2.0-dev', self.work))
            self.assertEqual('v2.0.0', update.latest('v2.0.0', self.work))

    def test_authenticated_prepare_and_tamper(self):
        private, public = self.root / 'test.key', self.root / 'test.pub'
        update.release.openssl('genpkey', '-algorithm', 'Ed25519', '-out', private)
        update.release.openssl('pkey', '-in', private, '-pubout', '-out', public)
        artifact, manifest = update.release.build(self.root / 'assets')
        signature = manifest.with_suffix('.sig')
        update.release.sign(manifest, private, signature)
        current = 'v0.1.0-dev'
        target = (ROOT / 'VERSION').read_text().strip()
        def download(url, destination):
            if url.startswith(update.API):
                destination.write_text(json.dumps([dict(tag_name=target, draft=False, prerelease=True)]))
            else:
                self.assertTrue(url.startswith(f'{update.REPOSITORY}/releases/download/{target}/'))
                shutil.copyfile(artifact.parent / url.rsplit('/', 1)[1], destination)
        with mock.patch.object(update, 'download', side_effect=download):
            self.assertEqual(target, update.prepare(current, self.work, public))
            self.assertTrue((self.work / 'extracted' / f'nodeforge-{target}' / 'VERSION').is_file())
            for original in (artifact, manifest, signature):
                content = original.read_bytes()
                original.write_bytes(content + b'tamper')
                with tempfile.TemporaryDirectory(dir=self.root) as work:
                    with self.assertRaises((ValueError, update.subprocess.SubprocessError)):
                        update.prepare(current, Path(work), public)
                    self.assertFalse((Path(work) / 'extracted').exists())
                original.write_bytes(content)


if __name__ == '__main__':
    unittest.main()
