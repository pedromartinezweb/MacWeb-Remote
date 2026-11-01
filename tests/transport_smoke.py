"""Real HTTPS connection reuse and ordered-input boundary checks."""
import http.client
import json
import socket
import unittest
from server_smoke import ADDRESS, HOST, PORT, CONTEXT, ORIGIN, CONFIG, request


def connection():
    client = http.client.HTTPSConnection(HOST, PORT, context=CONTEXT, timeout=8)
    client._create_connection = lambda address, timeout=None, source_address=None: socket.create_connection((ADDRESS, PORT), timeout, source_address)
    return client


class TransportSmoke(unittest.TestCase):
    def test_multiple_responses_reuse_one_tls_socket(self):
        client = connection()
        try:
            client.request('GET', '/api/auth/config')
            response = client.getresponse()
            response.read()
            self.assertFalse(response.will_close)
            original = client.sock
            for _ in range(3):
                client.request('GET', '/api/auth/config')
                response = client.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
                self.assertIs(client.sock, original)
            client.request('GET', '/api/auth/config', headers={'Connection':'close'})
            response = client.getresponse()
            response.read()
            self.assertTrue(response.will_close)
        finally:
            client.close()

    def test_input_batch_rejects_invalid_envelopes_without_target_actions(self):
        status, headers, _ = request('POST', '/api/login', {'token':CONFIG['token']})
        self.assertEqual(status, 200)
        cookie = {'Cookie':headers['Set-Cookie'].split(';')[0]}
        for events in [[], [None], [{'type':'release'}] * 65]:
            self.assertEqual(request('POST', '/api/input', {'events':events}, cookie)[0], 400)
        # Releasing no keys does not type or click anything on the desktop.
        status, _, body = request('POST', '/api/input', {'events':[{'type':'release'}]}, cookie)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['applied'], 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
