"""Cold-start offline browser check for the versioned Flutter app shell."""
import json
import os
import re
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[2]
WEB_ROOT = ROOT / 'app' / 'build' / 'web'


class QuietHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if urlsplit(self.path).path != '/__offline_probe':
            return super().do_GET()
        body = b'''<!doctype html><pre id="result">waiting</pre><script>
          (async () => {
            void fetch('/api/v1/health').catch(() => {});
            const names = await caches.keys();
            const cache = await caches.open('lingua-shell-v1');
            const keys = await cache.keys();
            document.querySelector('#result').textContent = JSON.stringify({names,
              keys: keys.map((key) => new URL(key.url).pathname)});
          })().catch((error) => {
            document.querySelector('#result').textContent = `error:${error}`;
          });
        </script>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class OfflineShellBrowserTest(unittest.TestCase):
    def test_cached_flutter_shell_starts_after_server_is_stopped(self):
        executable = os.environ.get('CHROME_EXECUTABLE')
        if not executable:
            self.skipTest('Set CHROME_EXECUTABLE to run the offline browser check')
        self.assertTrue((WEB_ROOT / 'sw.js').is_file(), 'build web assets first')
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]

        handler = partial(QuietHandler, directory=str(WEB_ROOT))
        server = ThreadingHTTPServer(('127.0.0.1', port), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f'http://127.0.0.1:{port}/'
        with tempfile.TemporaryDirectory(prefix='lingua-offline-chrome-') as profile:
            common = [
                executable, '--headless=new', '--no-sandbox', '--disable-gpu',
                '--disable-dev-shm-usage', '--disable-background-networking',
                '--no-first-run', f'--user-data-dir={profile}', '--dump-dom',
                '--virtual-time-budget=12000', url,
            ]
            try:
                online = subprocess.run(common, capture_output=True, text=True,
                                        timeout=45, check=False)
                self.assertEqual(online.returncode, 0, online.stderr[-2000:])
                self.assertIn('flt-glass-pane', online.stdout)
                # Let registration finish, then make a controlled online launch
                # so the browser has fetched and cached renderer/runtime assets.
                time.sleep(1)
                warm = subprocess.run(common, capture_output=True, text=True,
                                      timeout=45, check=False)
                self.assertEqual(warm.returncode, 0, warm.stderr[-2000:])
                self.assertIn('flt-glass-pane', warm.stdout)
                probe = subprocess.run(
                    [*common[:-1], url + '__offline_probe'], capture_output=True,
                    text=True, timeout=45, check=False,
                )
                self.assertEqual(probe.returncode, 0, probe.stderr[-2000:])
                result = re.search(r'<pre id="result">(.*?)</pre>', probe.stdout, re.S)
                self.assertIsNotNone(result, probe.stdout[-2000:])
                cached = json.loads(result.group(1))
                paths = cached['keys']
                self.assertIn('/main.dart.js', paths)
                self.assertIn('/canvaskit/canvaskit.wasm', paths)
                self.assertIn('/assets/assets/kanjivg/strokes.json', paths)
                self.assertFalse(any('/api/' in path for path in paths))
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)

            offline = subprocess.run(common, capture_output=True, text=True,
                                     timeout=45, check=False)
            self.assertEqual(offline.returncode, 0, offline.stderr[-2000:])
            self.assertIn('flt-glass-pane', offline.stdout)


if __name__ == '__main__':
    unittest.main()
