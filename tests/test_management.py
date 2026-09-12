#!/usr/bin/env python3
"""CLI JSON, identity and socket validation, using only temporary local fixtures."""
import copy
import errno
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('management', ROOT / 'lib/management.py')
management = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(management)


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state_path = Path(self.directory.name) / 'state.json'
        self.config_path = Path(self.directory.name) / 'config.json'
        self.template = ROOT / 'templates/vless-reality.json'
        self.config = json.loads(self.template.read_text())
        inbound = self.config['inbounds'][0]
        inbound['settings']['clients'][0]['id'] = '123e4567-e89b-42d3-a456-426614174000'
        inbound['streamSettings']['realitySettings'].update({
            'privateKey': 'A' * 43, 'shortIds': ['0123456789abcdef'],
            'serverNames': ['www.microsoft.com'], 'target': 'www.microsoft.com:443',
        })
        self.state = dict(owner='NodeForge', schema=1, version='v26.9.9', user_created=False,
                          server_ip='8.8.8.8', public_key='L-V9o0fNYkMVKNqsX7spBzD_9oSvxM_C7ZCZX1jLO3Q',
                          **{key: 'a' * 64 for key in ('config_sha256', 'binary_sha256', 'unit_sha256', 'license_sha256')})

    def validate(self):
        self.state_path.write_text(json.dumps(self.state))
        self.config_path.write_text(json.dumps(self.config))
        management.validate_state(self.state_path, self.config_path, self.template, derive=True)

    def test_valid_identity(self):
        self.validate()

    def test_ipv6_identity(self):
        self.state['server_ip'] = '2606:4700:4700::1111'
        self.config['inbounds'][0]['listen'] = '::'
        self.validate()

    def test_public_key_mismatch(self):
        self.state['public_key'] = 'B' * 43
        with self.assertRaises(ValueError):
            self.validate()

    def test_state_types_and_values(self):
        original = copy.deepcopy(self.state)
        for key, value in [('schema', True), ('schema', 1.0), ('schema', 2), ('schema', '1'),
                           ('version', 'secret\nvalue'), ('user_created', 'true'),
                           ('server_ip', '127.0.0.1'), ('public_key', None), ('config_sha256', '../other')]:
            with self.subTest(key=key, value=value), self.assertRaises((ValueError, TypeError)):
                self.state = dict(original, **{key: value})
                self.validate()

    def test_unknown_and_missing_fields(self):
        self.state['unmanaged_path'] = '/do-not-delete'
        with self.assertRaises(ValueError):
            self.validate()
        del self.state['unmanaged_path']
        del self.state['public_key']
        with self.assertRaises(ValueError):
            self.validate()

    def test_duplicate_and_malformed_json(self):
        for value in ['{"schema":1,"schema":2}', '{"nested":{"key":1,"key":2}}', '{bad']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.state_path.write_text(value)
                management.read_json(self.state_path)

    def test_config_shape_and_values(self):
        original = copy.deepcopy(self.config)
        for key, value in [('port', True), ('port', '23456'), ('port', 70000),
                           ('listen', '127.0.0.1'), ('protocol', 'other')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.config = copy.deepcopy(original)
                self.config['inbounds'][0][key] = value
                self.validate()
        self.config = original
        self.config['inbounds'].append(copy.deepcopy(original['inbounds'][0]))
        with self.assertRaises(ValueError):
            self.validate()
        self.config = copy.deepcopy(original)
        self.config['inbounds'] = self.config['inbounds'][:1]
        self.config['inbounds'][0]['streamSettings']['realitySettings']['show'] = 0
        with self.assertRaises(ValueError):
            self.validate()

    def test_listener_ipv4_and_ipv6_wildcards(self):
        for address, expected in [('0.0.0.0', '0.0.0.0'), ('*', '0.0.0.0'), ('[::]', '::'), ('*', '::')]:
            with self.subTest(address=address):
                management.listener(f'LISTEN 0 128 {address}:23456 *:* users:(("xray",pid=123,fd=3))',
                                    expected, '23456', '123')

    def test_listener_rejects_untrusted_socket(self):
        for line in ['', 'LISTEN 0 128 0.0.0.0:23456 *:*',
                     'LISTEN 0 128 127.0.0.1:23456 *:* users:(("xray",pid=123,fd=3))',
                     'LISTEN 0 128 0.0.0.0:23457 *:* users:(("xray",pid=123,fd=3))',
                     'LISTEN 0 128 0.0.0.0:23456 *:* users:(("other",pid=456,fd=3))',
                     'LISTEN 0 128 0.0.0.0:23456 *:* users:(("xray",pid=123,fd=3),("other",pid=456,fd=4))']:
            with self.subTest(line=line), self.assertRaises(ValueError):
                management.listener(line, '0.0.0.0', '23456', '123')

    def test_listener_ipv4_via_dual_stack(self):
        for address in ('*', '[::]'):
            with self.subTest(address=address):
                management.listener(f'LISTEN 0 128 {address}:23456 *:* users:(("xray",pid=123,fd=3)) v6only:0',
                                    '0.0.0.0', '23456', '123', '6')

    def test_listener_dual_stack_requires_ipv4_support_and_owner(self):
        for address, owner, attributes in [
                ('[::]', '123', ''), ('[::]', '123', 'v6only:1'),
                ('[::]', '123', 'v6only:0 v6only:1'),
                ('[::1]', '123', 'v6only:0'), ('*', '456', 'v6only:0')]:
            with self.subTest(address=address, owner=owner, attributes=attributes), self.assertRaises(ValueError):
                management.listener(f'LISTEN 0 128 {address}:23456 *:* users:(("xray",pid={owner},fd=3)) {attributes}',
                                    '0.0.0.0', '23456', '123', '6')

    def test_directory_publish_renames_sibling(self):
        parent = Path(self.directory.name)
        source, destination = parent / '.pending-v1', parent / 'v1'
        source.mkdir()
        (source / 'payload').write_text('complete')
        with mock.patch.object(management.sys, 'argv', ['management.py', 'rename-directory', str(source), str(destination)]):
            management.main()
        self.assertFalse(source.exists())
        self.assertEqual((destination / 'payload').read_text(), 'complete')

    def test_directory_publish_exdev_never_copies(self):
        parent = Path(self.directory.name)
        source, destination = parent / '.pending-v1', parent / 'v1'
        source.mkdir()
        (source / 'payload').write_text('complete')
        with mock.patch.object(management.sys, 'argv', ['management.py', 'rename-directory', str(source), str(destination)]), \
                mock.patch.object(management.os, 'rename', side_effect=OSError(errno.EXDEV, 'cross-device')):
            with self.assertRaises(OSError):
                management.main()
        self.assertFalse(destination.exists())
        self.assertEqual((source / 'payload').read_text(), 'complete')

    def test_directory_publish_rejects_conflict_and_other_parent(self):
        parent = Path(self.directory.name)
        source, destination = parent / '.pending-v1', parent / 'v1'
        source.mkdir()
        destination.mkdir()
        (destination / 'unmanaged').write_text('preserve')
        for target in (destination, parent / 'other-parent' / 'v1'):
            with mock.patch.object(management.sys, 'argv', ['management.py', 'rename-directory', str(source), str(target)]), \
                    mock.patch.object(management.os, 'rename') as rename:
                with self.assertRaises(ValueError):
                    management.main()
                rename.assert_not_called()
        self.assertEqual((destination / 'unmanaged').read_text(), 'preserve')


if __name__ == '__main__':
    unittest.main()
