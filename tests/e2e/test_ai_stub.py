"""Exercise the actual Compose AI handler without Docker or network sockets."""
import io
import json
from pathlib import Path
import unittest


def handler_class():
    # The Compose literal is Python source; extract it without a YAML dependency.
    text = (Path(__file__).resolve().parents[2] / 'docker-compose.yml').read_text()
    source = text.split('      - |\n', 1)[1].split('    healthcheck:', 1)[0]
    source = '\n'.join(line[8:] for line in source.splitlines())
    source = source.split('\nserver = HTTPServer', 1)[0]
    namespace = {}
    exec(compile(source, 'compose-ai-stub', 'exec'), namespace)
    return namespace['AIHandler']


class AIStubTests(unittest.TestCase):
    def request(self, path):
        handler = object.__new__(handler_class())
        handler.path = path
        handler.headers = {'Content-Length': '2'}
        handler.rfile = io.BytesIO(b'{}')
        handler.wfile = io.BytesIO()
        statuses = []
        handler.send_response = statuses.append
        handler.send_header = lambda *args: None
        handler.end_headers = lambda: None
        handler.do_POST()
        return statuses[0], handler.wfile.getvalue()

    def test_both_provider_envelopes_contain_structured_learning_content(self):
        for path in ['/api/generate', '/v1/chat/completions']:
            with self.subTest(path=path):
                status, body = self.request(path)
                self.assertEqual(status, 200)
                envelope = json.loads(body)
                content = (envelope['response'] if path == '/api/generate'
                           else envelope['choices'][0]['message']['content'])
                payload = json.loads(content)
                for field in ['topic', 'profession', 'difficulty_level']:
                    self.assertTrue(payload[field])
                self.assertTrue(payload['reply'])
                self.assertTrue(payload['lines'][0]['text'])
                self.assertTrue(payload['vocabulary'][0]['word'])
                self.assertTrue(payload['writing_challenge'])
                self.assertIn('suggested_writing_targets', payload)

    def test_unknown_path_returns_404(self):
        self.assertEqual(self.request('/not-an-ai-endpoint')[0], 404)
