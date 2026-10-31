"""Verify live screen capture through the installed app's authenticated HTTPS API."""
import json
import unittest
from server_smoke import CONFIG, request


class CaptureSmoke(unittest.TestCase):
    def test_authorized_desktop_has_fresh_jpeg_frames(self):
        code, headers, _ = request('POST', '/api/login', {'token': CONFIG['token']})
        self.assertEqual(code, 200)
        cookie = {'Cookie': headers['Set-Cookie'].split(';')[0]}
        code, _, body = request('GET', '/api/status', headers=cookie)
        self.assertEqual(code, 200)
        state = json.loads(body)
        self.assertTrue(state['screenPermission'], state['error'] or 'Screen recording is not authorized')
        self.assertGreater(state['frames'], 0, state['error'] or 'No desktop frames captured')
        self.assertGreaterEqual(state['frameAge'], 0)
        self.assertLess(state['frameAge'], 5, 'Desktop frames are stale')
        code, headers, frame = request('GET', '/api/frame', headers=cookie)
        self.assertEqual(code, 200)
        self.assertEqual(headers['Content-Type'], 'image/jpeg')
        self.assertTrue(frame.startswith(b'\xff\xd8'), 'Response is not a JPEG image')

    def test_accessibility_permission_is_active(self):
        code, headers, _ = request('POST', '/api/login', {'token': CONFIG['token']})
        self.assertEqual(code, 200)
        cookie = {'Cookie': headers['Set-Cookie'].split(';')[0]}
        code, _, body = request('GET', '/api/status', headers=cookie)
        self.assertEqual(code, 200)
        self.assertTrue(json.loads(body)['inputPermission'], 'Accessibility is not authorized')


if __name__ == '__main__':
    unittest.main(verbosity=2)
