import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('argo_provision', Path(__file__).resolve().parents[1] / 'lib/argo_provision.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProvisionTests(unittest.TestCase):
    def test_create_then_retry_reuses_credentials_and_dns(self):
        tunnels, records, writes = [], [], []

        def api(method, path, body=None):
            if method == 'GET':
                if '/dns_records?' in path:
                    return records
                if '/cfd_tunnel?' in path:
                    return tunnels
                return {'name': 'example.com'}
            writes.append((method, path))
            if '/cfd_tunnel' in path:
                tunnels.append({'id': '11111111-1111-4111-8111-111111111111', 'name': body['name']})
                return tunnels[0]
            records.append(dict(body, id='dns-id'))
            return records[0]

        with tempfile.TemporaryDirectory() as root:
            args = ({'zoneID': 'zone', 'accountID': 'account'}, Path(root), 'machine-id', '', api)
            first = module.provision(*args)
            second = module.provision(*args)
            self.assertEqual(first, second)
            self.assertEqual(len(writes), 2)
            self.assertTrue(first[0].endswith('.example.com'))
            self.assertTrue(records[0]['proxied'])
            self.assertEqual(first[1]['AccountTag'], 'account')

    def test_existing_unrelated_dns_is_not_overwritten(self):
        def api(method, path, body=None):
            self.assertEqual(method, 'GET')
            if '/dns_records?' in path:
                return [{'type': 'A', 'content': '192.0.2.1'}]
            if '/cfd_tunnel?' in path:
                return []
            return {'name': 'example.com'}

        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, 'unrelated DNS'):
                module.provision({'zoneID': 'zone', 'accountID': 'account'}, Path(root), 'machine', 'nodeforge.example.com', api)


if __name__ == '__main__':
    unittest.main()
