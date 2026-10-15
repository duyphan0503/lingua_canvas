import http.client
import importlib.util
import pathlib
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SPEC = importlib.util.spec_from_file_location('serve_web', pathlib.Path(__file__).resolve().parents[2] / 'tools/serve_web.py')
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)

class Upstream(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith('/slow'):
            time.sleep(5.1)
        self.server.seen_token = self.headers.get('X-Sync-Token')
        self.server.seen_auth = self.headers.get('Authorization')
        if self.path.endswith('/redirect'):
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:1/secret')
        elif self.path.endswith('/missing'):
            self.send_response(404)
        else:
            self.send_response(202)
        self.send_header('X-Cache', 'HIT')
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"api":true}')
    def do_HEAD(self):
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args):
        pass

class WebTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = pathlib.Path(cls.tmp.name)
        (cls.root / 'index.html').write_text('INDEX')
        (cls.root / 'main.dart.js').write_text('JS')
        (cls.root / 'engine.wasm').write_bytes(b'wasm')
        (cls.root / 'escape').symlink_to('/etc/passwd')
        cls.upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        cls.server = web.create_server(cls.root, '127.0.0.1', 0, f'http://127.0.0.1:{cls.upstream.server_port}')
        for server in (cls.upstream, cls.server):
            threading.Thread(target=server.serve_forever, daemon=True).start()
    @classmethod
    def tearDownClass(cls):
        for server in (cls.server, cls.upstream):
            server.shutdown()
            server.server_close()
        cls.tmp.cleanup()
    def request(self, path, method='GET', body=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=8)
        conn.request(method, path, body, headers or {})
        res = conn.getresponse()
        result = res.status, dict(res.getheaders()), res.read()
        conn.close()
        return result
    def test_static_and_spa(self):
        for path in ('/', '/study'):
            s, h, b = self.request(path)
            self.assertEqual((s, b), (200, b'INDEX'))
            self.assertEqual(h['Cache-Control'], 'no-cache')
        self.assertEqual(self.request('/missing.js')[0], 404)
        self.assertEqual(self.request('/main.dart.js')[1]['Cache-Control'], 'no-cache')
    def test_wasm(self):
        self.assertEqual(self.request('/engine.wasm')[1]['Content-Type'], 'application/wasm')
    def test_proxy(self):
        s, h, b = self.request('/api/v1/health', headers={'X-Sync-Token':'test-only', 'Authorization':'Bearer test-only'})
        self.assertEqual((s,b), (202,b'{"api":true}'))
        self.assertEqual(h['X-Cache'], 'HIT')
        self.assertEqual(self.upstream.seen_token, 'test-only')
        self.assertEqual(self.upstream.seen_auth, 'Bearer test-only')
        self.assertEqual(self.request('/api/v1/health', 'HEAD')[0], 204)
    def test_unknown_api_and_redirect(self):
        self.assertEqual(self.request('/api/v1/missing')[0], 404)
        self.assertEqual(self.request('/api/v1/redirect')[0], 302)
        self.assertEqual(self.request('/api/unknown')[0], 404)
    def test_traversal_and_symlink(self):
        for path in ('/../etc/passwd', '/%2e%2e/etc/passwd', '/escape'):
            self.assertIn(self.request(path)[0], (403,404))
    def test_bounded_upstream_allows_debug_pin_hash(self):
        self.assertEqual(self.request('/api/v1/slow')[0], 202)

    def test_body_bounds(self):
        self.assertEqual(self.request('/api/v1/sync', 'POST', headers={'Content-Length':str(1048577)})[0], 413)
        self.assertEqual(self.request('/api/v1/sync', 'POST', headers={'Content-Length':'-1'})[0], 400)
        self.assertEqual(self.request('/api/v1/sync', 'POST', headers={'Transfer-Encoding':'chunked'})[0], 400)

if __name__ == '__main__':
    unittest.main()
