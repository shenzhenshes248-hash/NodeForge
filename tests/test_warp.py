#!/usr/bin/env python3
"""Targeted outbound policy tests; no network or credentials."""
import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
from management import warp_xray, warp_hysteria  # noqa: E402


class WarpTests(unittest.TestCase):
    def test_all_xray_profiles_roundtrip_and_idempotency(self):
        for name in ('vless-reality.json', 'vless-ws.json', 'vless-xhttp.json'):
            with self.subTest(name=name):
                original = json.loads((ROOT / 'templates' / name).read_text())
                enabled = warp_xray(copy.deepcopy(original), True)
                self.assertEqual(enabled['inbounds'], original['inbounds'])
                self.assertEqual([x['protocol'] for x in enabled['outbounds']], ['socks', 'blackhole'])
                self.assertEqual(enabled['routing']['rules'][0]['network'], 'udp')
                self.assertEqual(warp_xray(copy.deepcopy(enabled), True), enabled)
                restored = warp_xray(enabled, False)
                self.assertEqual(restored, original)
                self.assertEqual(warp_xray(restored, False), original)

    def test_hysteria_only_proxy_and_no_udp(self):
        original = 'listen: :443,20000-50000\nauth:\n  type: password\n  password: existing\n'
        enabled = warp_hysteria(original, True)
        self.assertIn('disableUDP: true\n', enabled)
        self.assertIn('type: socks5\n', enabled)
        self.assertNotIn('type: direct', enabled)
        self.assertEqual(warp_hysteria(enabled, True), enabled)
        self.assertEqual(warp_hysteria(enabled, False), original)

    def test_refuse_unmanaged_bypass_policy(self):
        config = json.loads((ROOT / 'templates/vless-reality.json').read_text())
        config['routing'] = {'rules': []}
        with self.assertRaises(ValueError):
            warp_xray(config, True)
        with self.assertRaises(ValueError):
            warp_hysteria('acl:\n  inline: []\n', True)


if __name__ == '__main__':
    unittest.main()
