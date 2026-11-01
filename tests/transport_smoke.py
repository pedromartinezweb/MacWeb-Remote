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

    def test_host_validation_runs_for_every_persistent_request(self):
        client = connection()
        try:
            for host, expected in [(f'{HOST}:{PORT}',200), ('external.invalid',403), (f'{HOST}:{PORT}',200)]:
                client.request('GET', '/api/auth/config', headers={'Host':host})
                response = client.getresponse()
                self.assertEqual(response.status, expected)
                response.read()
        finally:
            client.close()

    def test_pipelined_requests_preserve_response_boundaries(self):
        client = connection()
        client.connect()
        stream = client.sock.makefile('rb')
        try:
            first = f'GET /api/auth/config HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n\r\n'
            last = f'GET /api/auth/config HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nConnection: close\r\n\r\n'
            client.sock.sendall((first + last).encode())
            for _ in range(2):
                self.assertIn(b'200 OK', stream.readline())
                headers = {}
                while True:
                    line = stream.readline()
                    if line == b'\r\n': break
                    self.assertTrue(line, 'Missing response boundary')
                    key, value = line.decode().split(':',1)
                    headers[key.lower()] = value.strip()
                payload = stream.read(int(headers['content-length']))
                self.assertIn('availableHere',json.loads(payload))
        finally:
            stream.close()
            client.close()

    def test_conditional_frame_response_does_not_resend_unchanged_image(self):
        status, headers, _ = request('POST', '/api/login', {'token':CONFIG['token']})
        self.assertEqual(status,200)
        cookie = {'Cookie':headers['Set-Cookie'].split(';')[0]}
        code, headers, body = request('GET','/api/frame',headers=cookie)
        self.assertEqual(code,200)
        serial = headers['X-Frame-Serial']
        self.assertTrue(body.startswith(b'\xff\xd8'))
        code, headers, body = request('GET',f'/api/frame?after={serial}',headers=cookie)
        self.assertIn(code,[200,204])
        if code == 204:
            self.assertEqual(body,b'')
            self.assertNotIn('Content-Length',headers)
        else:
            self.assertNotEqual(headers['X-Frame-Serial'],serial)
            self.assertTrue(body.startswith(b'\xff\xd8'))

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
