"""Loopback-only UI fixture; never captures or controls the Mac."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path

WEB = Path(__file__).resolve().parents[1] / 'Web'
STATE = {'screenPermission': True, 'inputPermission': True, 'selectedDisplay': 1,
         'virtualDisplay': 0, 'monitorsOff': False, 'frames': 24, 'frameBytes': 32000,
         'frameAge': 0.1, 'busy': False, 'error': '',
         'displays': [{'id': 1, 'width': 1440, 'height': 900, 'virtual': False}]}
EVENTS = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, mime='application/json', cookie=False):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        if cookie:
            self.send_header('Set-Cookie', 'test_session=1; Path=/; SameSite=Strict')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/api/status':
            if 'test_session=1' not in self.headers.get('Cookie', ''):
                self.send(401, b'{"error":"Login required"}')
            else:
                self.send(200, json.dumps(STATE).encode())
        elif path == '/api/stream':
            svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="900"><rect width="1440" height="900" fill="#343b40"/><rect x="140" y="90" width="1160" height="720" rx="8" fill="#f4f2ee"/><text x="190" y="160" font-family="sans-serif" font-size="30">Prueba de interfaz · escritorio simulado</text><path d="M190 190H1250" stroke="#ccc"/><text x="190" y="240" font-family="sans-serif" font-size="22">Texto de ejemplo para comprobar la escala en iPhone y iPad.</text></svg>'
            self.send(200, svg.encode(), 'image/svg+xml')
        elif path == '/test/events':
            self.send(200, json.dumps(EVENTS).encode())
        else:
            name = 'index.html' if path == '/' else path.lstrip('/')
            if name not in {'index.html', 'app.js', 'style.css', 'manifest.webmanifest'}:
                self.send(404, b'{}')
                return
            mime = 'text/html' if name.endswith('html') else 'text/javascript' if name.endswith('js') else 'text/css' if name.endswith('css') else 'application/json'
            self.send(200, (WEB / name).read_bytes(), mime)

    def do_POST(self):
        value = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path == '/api/login':
            self.send(200 if value.get('token') == 'test-only' else 401, b'{}', cookie=True)
            return
        EVENTS.append({'path': self.path, 'body': value})
        if self.path == '/api/virtual':
            STATE['virtualDisplay'] = 77
            STATE['selectedDisplay'] = 77
            STATE['displays'].append({'id': 77, 'width': 1440, 'height': 900, 'virtual': True})
        if self.path == '/api/display':
            STATE['selectedDisplay'] = value['id']
        if self.path == '/api/monitors':
            STATE['monitorsOff'] = value['off']
        self.send(200, json.dumps(STATE).encode())

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8790), Handler).serve_forever()
