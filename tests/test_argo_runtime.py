#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('argo_runtime', ROOT / 'lib/argo_runtime.py')
argo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(argo)


class ArgoRuntimeTests(unittest.TestCase):
    def test_official_log_domain(self):
        self.assertEqual(argo.tunnel_domain('| https://one-two.trycloudflare.com |'),
                         'one-two.trycloudflare.com')
        self.assertIsNone(argo.tunnel_domain('https://one.trycloudflare.com.evil.test'))
        self.assertIsNone(argo.tunnel_domain('https://example.com'))

    def test_restart_replaces_domain_and_exit_removes_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'xray.json'
            data = json.loads((ROOT / 'templates/vless-ws.json').read_text())
            config.write_text(json.dumps(data))
            state = root / 'current.json'
            state.write_text('{"domain":"stale.trycloudflare.com"}')

            def logs():
                self.assertFalse(state.exists())
                yield '| https://first.trycloudflare.com |\n'
                self.assertFalse(state.exists())
                yield 'INF Registered tunnel connection connIndex=0\n'
                self.assertEqual(json.loads(state.read_text()), dict(
                    domain='first.trycloudflare.com', invocation_id='a' * 32))
                yield '| https://second.trycloudflare.com |\n'
                self.assertFalse(state.exists())
                yield 'INF Registered tunnel connection connIndex=0\n'
                self.assertEqual(json.loads(state.read_text())['domain'],
                                 'second.trycloudflare.com')

            class Process:
                stdout = logs()

                def wait(self):
                    return 7

                def poll(self):
                    return 7

            with patch.dict(os.environ, INVOCATION_ID='a' * 32), \
                    patch.object(argo.subprocess, 'Popen', return_value=Process()) as launch, \
                    patch.object(argo.signal, 'signal'), patch('sys.stdout', new=io.StringIO()):
                self.assertEqual(argo.run('cloudflared', config, 'empty.yml', state), 7)
            self.assertFalse(state.exists())
            self.assertEqual(launch.call_args.args[0], [
                'cloudflared', 'tunnel', '--config', 'empty.yml', '--no-autoupdate',
                '--url', 'http://127.0.0.1:20001', '--loglevel', 'info'])

    def test_stop_clears_domain_and_forwards_signal(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'current.json'
            handlers = {}
            calls = []

            def logs():
                yield 'https://first.trycloudflare.com\n'
                yield 'Registered tunnel connection\n'
                self.assertTrue(state.exists())
                handlers[argo.signal.SIGTERM](None, None)
                self.assertFalse(state.exists())
                yield 'Registered tunnel connection\n'
                self.assertFalse(state.exists())

            class Process:
                stdout = logs()

                def poll(self):
                    return None if not calls else 0

                def terminate(self):
                    calls.append('terminated')

                def wait(self):
                    return 0

            with patch.dict(os.environ, INVOCATION_ID='b' * 32), \
                    patch.object(argo.subprocess, 'Popen', return_value=Process()), \
                    patch.object(argo.signal, 'signal', side_effect=handlers.__setitem__), \
                    patch('sys.stdout', new=io.StringIO()):
                argo.run('cloudflared', ROOT / 'templates/vless-ws.json', 'empty.yml', state)
            self.assertEqual(calls, ['terminated'])
            self.assertFalse(state.exists())


if __name__ == '__main__':
    unittest.main()
