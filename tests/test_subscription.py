import importlib.util
import json
from pathlib import Path
import subprocess
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import build_opener, ProxyHandler

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('subscription', ROOT / 'lib/subscription.py')
sub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sub)


class SubscriptionTests(unittest.TestCase):
    def test_live_http_content_changes_at_same_url(self):
        current = [b'vless://reality\nhysteria2://hy2\nvless://old-domain\n']
        def content():
            if current[0] is None:
                raise ValueError('Argo reconnecting')
            return current[0]
        server = sub.ThreadingHTTPServer(('127.0.0.1', 0), sub.handler({'token': 'test-token'}, content))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        url = f'http://127.0.0.1:{server.server_port}/test-token/sub.txt'
        client = build_opener(ProxyHandler({}))
        try:
            with client.open(url) as response:
                self.assertEqual(response.read(), current[0])
                self.assertEqual(response.headers['Cache-Control'], 'no-store')
            current[0] = b'vless://reality\nhysteria2://hy2\nvless://new-domain\n'
            self.assertEqual(client.open(url).read(), current[0])
            with self.assertRaises(HTTPError) as wrong:
                client.open(url.replace('test-token', 'wrong-token'))
            self.assertEqual(wrong.exception.code, 404)
            current[0] = None
            with self.assertRaises(HTTPError) as pending:
                client.open(url)
            self.assertEqual(pending.exception.code, 503)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_content_requires_three_nodes_and_excludes_url(self):
        good = b'vless://reality\nhysteria2://hy2\nvless://argo\n'
        with patch.object(sub.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, good)):
            self.assertEqual(sub.current_content(), good)
        for body in (b'vless://reality\nhysteria2://hy2\n', good + b'Subscription URL: http://host/sub.txt\n'):
            with patch.object(sub.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, body)):
                with self.assertRaises(ValueError):
                    sub.current_content()

    def test_edge_address(self):
        for value, expected in (('', ''), ('edge.example.com', 'edge.example.com'),
                                ('1.2.3.4', '1.2.3.4'), ('2001:db8::1', '[2001:db8::1]')):
            self.assertEqual(sub.edge_address(value), expected)
        for value in ('https://edge.example.com', 'edge.example.com:443', 'edge.example.com/path'):
            with self.assertRaises(ValueError):
                sub.edge_address(value)

    def test_stable_persisted_url(self):
        config = sub.create_config('8.8.8.8')
        self.assertTrue(20000 <= config['port'] <= 50000)
        self.assertEqual(len(config['token']), 64)
        self.assertEqual(sub.subscription_url(config), sub.subscription_url(json.loads(json.dumps(config))))
        self.assertNotIn('trycloudflare', sub.subscription_url(config))


if __name__ == '__main__':
    unittest.main()
