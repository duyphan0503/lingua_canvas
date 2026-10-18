#!/usr/bin/env python3
"""Loopback development static server with a bounded, same-origin API proxy."""
import argparse
import http.client
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

MAX_BODY = 1024 * 1024
MAX_RESPONSE = 16 * MAX_BODY
HOP_HEADERS = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
               'te', 'trailer', 'transfer-encoding', 'upgrade'}

class WebHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        # API paths, headers and credentials are deliberately not logged.
        pass

    def do_GET(self):
        self._handle()

    def do_HEAD(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_OPTIONS(self):
        self._handle()

    def _handle(self):
        self.connection.settimeout(5)
        path = urlsplit(self.path).path
        if path == '/api/v1' or path.startswith('/api/v1/'):
            self._proxy()
        elif path.startswith('/api/'):
            self.send_error(404)
        elif self.command in ('GET', 'HEAD'):
            self._static(path)
        else:
            self.send_error(405)

    def _static(self, path):
        decoded = unquote(path)
        if '..' in Path(decoded).parts or '\\' in decoded or '\x00' in decoded:
            self.send_error(403)
            return
        root = self.server.directory
        target = (root / decoded.lstrip('/')).resolve()
        if not target.is_relative_to(root):
            self.send_error(403)
            return
        if target.is_dir():
            target = target / 'index.html'
        if not target.is_file() and not Path(decoded).suffix:
            target = root / 'index.html'
        if not target.is_file():
            self.send_error(404)
            return
        try:
            with target.open('rb') as stream:
                self.send_response(200)
                mime = 'application/wasm' if target.suffix == '.wasm' else mimetypes.guess_type(target)[0]
                self.send_header('Content-Type', mime or 'application/octet-stream')
                self.send_header('Content-Length', str(target.stat().st_size))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                if self.command != 'HEAD':
                    while chunk := stream.read(65536):
                        self.wfile.write(chunk)
        except (OSError, TimeoutError):
            self.close_connection = True

    def _proxy(self):
        lengths = self.headers.get_all('Content-Length', [])
        if self.headers.get('Transfer-Encoding') or len(lengths) > 1:
            self.send_error(400)
            return
        try:
            size = int(lengths[0]) if lengths else 0
            if size < 0:
                raise ValueError()
        except ValueError:
            self.send_error(400)
            return
        if size > MAX_BODY:
            self.send_error(413)
            return
        conn = None
        try:
            body = self.rfile.read(size) if size else None
            if size and len(body) != size:
                self.send_error(400)
                return
            origin = self.server.api_origin
            conn_type = http.client.HTTPSConnection if origin.scheme == 'https' else http.client.HTTPConnection
            conn = conn_type(origin.hostname, origin.port, timeout=15)
            blocked = HOP_HEADERS | {'host', 'content-length'} | {
                x.strip().lower() for x in self.headers.get('Connection', '').split(',')
            }
            headers = {k: v for k, v in self.headers.items() if k.lower() not in blocked}
            conn.request(self.command, self.path, body=body, headers=headers)
            response = conn.getresponse()
            payload = response.read(MAX_RESPONSE + 1)
            if len(payload) > MAX_RESPONSE:
                self.send_error(502)
                return
            self.send_response(response.status)
            blocked_response = HOP_HEADERS | {'content-length', 'server', 'date'} | {
                x.strip().lower() for x in (response.getheader('Connection') or '').split(',')
            }
            for key, value in response.getheaders():
                if key.lower() not in blocked_response:
                    self.send_header(key, value)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(payload)
        except (OSError, http.client.HTTPException):
            self.send_error(502, 'API unavailable')
        finally:
            if conn is not None:
                conn.close()
            self.close_connection = True


def create_server(directory, host, port, api_origin):
    origin = urlsplit(api_origin)
    if origin.scheme not in ('http', 'https') or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment or origin.path not in ('', '/'):
        raise ValueError('api-origin must be an HTTP(S) origin without credentials or a path')
    root = Path(directory).resolve(strict=True)
    if not root.is_dir():
        raise ValueError('directory must be a directory')
    server = ThreadingHTTPServer((host, port), WebHandler)
    server.directory = root
    server.api_origin = origin
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', default='app/build/web')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=28190)
    parser.add_argument('--api-origin', default='http://127.0.0.1:28191')
    args = parser.parse_args()
    with create_server(args.directory, args.host, args.port, args.api_origin) as server:
        print(f'Lingua Canvas: http://{args.host}:{server.server_port}', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass

if __name__ == '__main__':
    main()
