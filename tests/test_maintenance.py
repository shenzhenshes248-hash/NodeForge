#!/usr/bin/env python3
"""Archive round trip and rejection tests, without host services."""
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import management as backup


class BackupTest(unittest.TestCase):
    def test_roundtrip_and_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pairs = []
            values = {name: b'identity-fixture' for name in backup.BACKUP_REQUIRED}
            values.update({'argo-config': json.dumps({'inbounds': [{'streamSettings': {'network': 'xhttp'}}]}).encode(),
                           'argo-state': b'{"profile":"xhttp"}', 'argo-tunnel': b'{}',
                           'argo-credentials': b'{"TunnelID":"stable-fixture"}',
                           'warp-state': b'{"mode":"disabled"}'})
            for name, data in values.items():
                (root / name).write_bytes(data)
                pairs.extend([name, str(root / name)])
            archive = root / 'backup.tar.gz'
            backup.backup_create(archive, 'v0.8.0-dev', pairs)
            backup.backup_extract(archive, root / 'restored')
            self.assertEqual(values, {p.name: p.read_bytes() for p in (root / 'restored').iterdir()})
            archive.write_bytes(archive.read_bytes()[:-5])
            with self.assertRaises((EOFError, OSError, ValueError)):
                backup.backup_extract(archive, root / 'bad')
            self.assertFalse((root / 'bad').exists())

    def test_unknown_links_and_missing_required(self):
        for name, kind in [('../outside', tarfile.REGTYPE), ('hy2-key', tarfile.SYMTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with tarfile.open(root / 'bad.tar.gz', 'w:gz') as archive:
                    item = tarfile.TarInfo(name)
                    item.type = kind
                    archive.addfile(item, io.BytesIO())
                with self.assertRaises(ValueError):
                    backup.backup_extract(root / 'bad.tar.gz', root / 'out')
        with self.assertRaises(ValueError):
            backup.backup_validate_inventory({})


if __name__ == '__main__':
    unittest.main()
