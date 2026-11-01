import http.client
import json
import os
import socket
import ssl
import subprocess
import unittest
from pathlib import Path

ROOT = Path(os.environ.get('MACWEB_SUPPORT_DIRECTORY', str(Path.home() / 'Library/Application Support/MacWebRemote')))
CONFIG = json.loads((ROOT / 'config.json').read_text())
PORT = CONFIG['port']
ADDRESS = CONFIG.get('bindAddress') or '127.0.0.1'
HOST = CONFIG.get('accessHost') or subprocess.check_output(['scutil', '--get', 'LocalHostName'], text=True).strip().lower() + '.local'
AUTHORITY = HOST if PORT == 443 else f'{HOST}:{PORT}'
ORIGIN = f'https://{AUTHORITY}'
CERTIFICATE = (ROOT / CONFIG['certificateFile']).parent / 'issuer.crt' if CONFIG.get('certificateFile') else ROOT / 'server.crt'
CONTEXT = ssl.create_default_context(cafile=str(CERTIFICATE))


def request(method, path, payload=None, headers=None):
    connection = http.client.HTTPSConnection(HOST, PORT, context=CONTEXT, timeout=8)
    # Resolve the configured DNS name to the selected interface only for this test.
    # TLS still verifies the DNS name and the explicitly selected certificate authority.
    connection._create_connection = lambda address, timeout=None, source_address=None: socket.create_connection((ADDRESS, PORT), timeout, source_address)
    body = json.dumps(payload).encode() if payload is not None else None
    actual_headers = {'Content-Type': 'application/json', 'Origin': ORIGIN} if body else {}
    actual_headers.update(headers or {})
    connection.request(method, path, body, actual_headers)
    response = connection.getresponse()
    result = response.status, dict(response.getheaders()), response.read()
    connection.close()
    return result


class ServerSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        status, headers, _ = request('POST', '/api/login', {'token': CONFIG['token']})
        assert status == 200
        cls.cookie = headers['Set-Cookie'].split(';')[0]

    def test_static_and_protected_routes(self):
        for path in ['/', '/app.js', '/transport.js', '/passkeys.js', '/style.css', '/manifest.webmanifest', '/icon.png']:
            self.assertEqual(request('GET', path)[0], 200)
        for path in ['/api/status', '/api/frame', '/api/stream', '/api/passkeys/list']:
            self.assertEqual(request('GET', path)[0], 401)

    def test_authentication_and_origin(self):
        self.assertEqual(request('POST', '/api/login', {'token': 'wrong'})[0], 401)
        self.assertEqual(request('POST', '/api/login', {'token': CONFIG['token']}, {'Origin': 'https://external.invalid'})[0], 403)
        self.assertEqual(request('GET', '/', headers={'Host': 'external.invalid'})[0], 403)
        status, headers, _ = request('POST', '/api/login', {'token': CONFIG['token']})
        self.assertEqual(status, 200)
        for attribute in ['Secure', 'HttpOnly', 'SameSite=Strict']:
            self.assertIn(attribute, headers['Set-Cookie'])

    def test_state_and_json_boundary(self):
        status, _, body = request('GET', '/api/status', headers={'Cookie': self.cookie})
        self.assertEqual(status, 200)
        self.assertIn('screenPermission', json.loads(body))
        self.assertEqual(request('POST', '/api/input', {}, {'Cookie': self.cookie, 'Content-Type': 'text/plain'})[0], 400)

    def test_passkey_config_and_authorization(self):
        status, _, body = request('GET', '/api/auth/config')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['origin'], ORIGIN)
        self.assertTrue(json.loads(body)['availableHere'])
        self.assertEqual(request('POST', '/api/passkeys/register/options', {'name': 'Unauthorized'})[0], 401)
        self.assertEqual(request('POST', '/api/passkeys/login/options', {}, {'Origin': 'https://external.invalid'})[0], 403)
        code, _, body = request('POST', '/api/passkeys/register/options', {'name': 'Protocol test'}, {'Cookie': self.cookie})
        self.assertEqual(code, 200)
        options = json.loads(body)
        self.assertEqual(options['publicKey']['rp']['id'], HOST)
        self.assertEqual(options['publicKey']['authenticatorSelection']['userVerification'], 'required')
        payload = {'requestID': options['requestID'], 'credential': {}}
        self.assertEqual(request('POST', '/api/passkeys/register/finish', payload, {'Cookie': self.cookie})[0], 400)
        self.assertEqual(request('POST', '/api/passkeys/register/finish', payload, {'Cookie': self.cookie})[0], 400)

    def test_cross_origin_cannot_control(self):
        self.assertEqual(request('POST', '/api/monitors', {'off': True}, {'Cookie': self.cookie, 'Origin': 'https://external.invalid'})[0], 403)


if __name__ == '__main__':
    unittest.main(verbosity=2)
