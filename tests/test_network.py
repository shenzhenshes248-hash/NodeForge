"""Real local socket tests and deterministic failure cases; no external network."""
import importlib.util
import pathlib
import socket
import unittest
from unittest.mock import patch

MODULE = pathlib.Path(__file__).resolve().parents[1] / 'lib' / 'network.py'
SPEC = importlib.util.spec_from_file_location('network', MODULE)
network = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(network)


class NetworkTests(unittest.TestCase):
    def test_public_addresses(self):
        for address in ('8.8.8.8', '2001:4860:4860::8888'):
            network.public_ip(address)

    def test_reject_nonpublic_and_malformed(self):
        for address in ('127.0.0.1', '10.0.0.1', '::1', 'fe80::1%eth0', '224.0.0.1', 'ff02::1', '999.2.3.4', '8.8.8.8;id'):
            with self.subTest(address=address), self.assertRaises(ValueError):
                network.public_ip(address)

    def test_occupied_tcp_port(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(('0.0.0.0', 0))
            listener.listen(1)
            self.assertFalse(network.port_free(listener.getsockname()[1]))

    def test_occupied_udp_port(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
            listener.bind(('0.0.0.0', 0))
            self.assertFalse(network.port_free(listener.getsockname()[1], socket.SOCK_DGRAM))

    def test_free_443_is_preferred(self):
        with patch('sys.argv', ['network.py', 'choose-port']), \
                patch.object(network.secrets, 'randbelow') as random_port, \
                patch.object(network, 'port_free', return_value=True) as free, \
                patch('builtins.print') as output:
            network.main()
            free.assert_called_once_with(443)
            random_port.assert_not_called()
            output.assert_called_once_with(443)

    def test_occupied_443_uses_random_fallback(self):
        for offset, expected in ((0, 20000), (30000, 50000)):
            with patch('sys.argv', ['network.py', 'choose-port']), \
                    patch.object(network.secrets, 'randbelow', return_value=offset), \
                    patch.object(network, 'port_free', side_effect=(False, True)) as free, \
                    patch('builtins.print') as output:
                network.main()
                self.assertEqual([item.args for item in free.call_args_list], [(443,), (expected,)])
                output.assert_called_once_with(expected)

    def test_exhaustion_is_bounded(self):
        with patch('sys.argv', ['network.py', 'choose-port']), \
                patch.object(network, 'port_free', return_value=False) as free:
            with self.assertRaises(ValueError):
                network.main()
            self.assertEqual(free.call_count, 257)
            self.assertEqual(free.call_args_list[0].args, (443,))

    def test_dns_private_address_rejected(self):
        with patch('sys.argv', ['network.py', 'target-addresses', 'example.com', '443']), \
                patch.object(network.socket, 'getaddrinfo', return_value=[(socket.AF_INET, 1, 6, '', ('127.0.0.1', 443))]):
            with self.assertRaises(ValueError):
                network.main()


if __name__ == '__main__':
    unittest.main()
