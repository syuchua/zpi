#!/usr/bin/env python3
"""Offline HTTP checks with independently calculated output budgets."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
BINARY = Path(os.environ.get('ZPI_TEST_BINARY', ROOT / 'zig-out/bin/zpi')).resolve()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert body['stream'] is True
            assert body['model'] == 'budget-model'
            if self.server.api == 'anthropic-messages':
                assert body['system'] == '1234567'
                wire_messages = body['messages']
                user = next(block['text'] for block in wire_messages[-1]['content'] if block['type'] == 'text')
                events = [
                    ('message_start', {'message': {'usage': {'input_tokens': 1, 'output_tokens': 0}}}),
                    ('content_block_start', {'index': 0, 'content_block': {'type': 'text', 'text': 'budget complete'}}),
                    ('content_block_stop', {'index': 0}),
                    ('message_delta', {'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 1}}),
                    ('message_stop', {}),
                ]
                data = ''.join(f'event: {kind}\ndata: {json.dumps(dict(payload, type=kind))}\n\n'
                               for kind, payload in events).encode()
            else:
                wire_messages = body['messages']
                user = wire_messages[-1]['content']
                assert wire_messages[0] == {'role': 'system', 'content': '1234567'}
                reply = {'choices': [{'index': 0, 'delta': {'content': 'budget complete'}, 'finish_reason': 'stop'}]}
                data = ('data: ' + json.dumps(reply) + '\n\ndata: [DONE]\n\n').encode()
            assert user in (self.server.prompt, 'second turn'), user
            estimate = 0
            for message in wire_messages:
                content = message['content']
                text = content if isinstance(content, str) else ''.join(
                    block.get('text', '') for block in content if block.get('type') == 'text')
                units = len(text.encode('utf-16-le')) // 2
                estimate += (units * 2 + 6) // 7
            if self.server.api == 'anthropic-messages':
                estimate += 2
            margin = max(4096, (estimate * 15 + 99) // 100)
            room = self.server.window - estimate - margin
            if room < 32768:
                room = min(32768, self.server.window - estimate - 4096)
            expected = min(self.server.max_tokens, max(1, room))
            assert body['max_tokens'] == expected, {
                'actual': body['max_tokens'], 'expected': expected,
                'estimate': estimate, 'window': self.server.window,
                'model_max_tokens': self.server.max_tokens, 'user': user,
            }
            if user == 'second turn':
                assert any('budget complete' in str(message.get('content', '')) for message in wire_messages[:-1])
            else:
                assert body['max_tokens'] == self.server.expected, (body['max_tokens'], self.server.expected)
            self.server.observed.append((self.server.api, user, body['max_tokens']))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            self.server.failures.append(repr(exc))
            self.send_error(500)

def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.failures = []
    server.observed = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    # Every request has a seven-byte system prompt (two estimated tokens).
    # Large prompt: 28,572 tokens; total 28,574; ratio margin 4,287.
    cases = [
        (5000, 2000, '1234567', 900),
        (128000, 120000, 'x' * 350000, 23902),
        (8000, 2000, '1234567', 2000),
        (8000, 4000, 'x' * 5407, 2357),
        (5000, 2000, '12345678', 899),
        (100000, 100000, 'x' * 100000, 67139),
        (65500, 100000, 'x' * 100000, 32768),
        (60000, 100000, 'x' * 100000, 27330),
        (100000, 500, '1234567', 500),
        (4096, 2000, '1234567', 1),
        (5000, 2000, '你好🙂', 900),
        (5000, 2000, '🙂' * 14, 894),
        (5000, 2000, 'e\u0301' * 7, 898),
        (5000, 2000, '👩‍💻' * 7, 892),
    ]
    try:
        with tempfile.TemporaryDirectory(prefix='zpi-budget-') as directory:
            root = Path(directory)
            config = root / 'models.json'
            for api in ('openai-completions', 'anthropic-messages'):
                for index, (window, ceiling, prompt, expected) in enumerate(cases):
                    server.api, server.prompt, server.expected = api, prompt, expected
                    server.window, server.max_tokens = window, ceiling
                    definition = {'id': 'budget-model', 'maxTokens': ceiling}
                    if index != 1:
                        definition['contextWindow'] = window
                    model_overrides = {}
                    provider_config = {
                        'api': api, 'baseUrl': f'http://127.0.0.1:{server.server_port}/v1',
                        'models': [definition],
                    }
                    if model_overrides:
                        provider_config['modelOverrides'] = model_overrides
                    config.write_text(json.dumps({'providers': {'budget': provider_config}}))
                    # stdin avoids platform-specific per-argument byte limits.
                    session = root / f'{api}-{index}.jsonl'
                    common = [str(BINARY), '--no-proxy', '--models-file', str(config),
                              '--provider', 'budget', '--no-tools', '--session', str(session),
                              '--system-prompt', '1234567']
                    result = subprocess.run(common + ['-p'], input=prompt, text=True,
                                            capture_output=True, env=dict(os.environ, HOME=str(root)), timeout=20)
                    assert result.returncode == 0 and result.stdout == 'budget complete\n', (result.stderr, server.failures)
                    server.prompt = 'second turn'
                    result = subprocess.run(common + ['-p'], input='second turn', text=True, capture_output=True,
                                            env=dict(os.environ, HOME=str(root)), timeout=20)
                    assert result.returncode == 0 and result.stdout == 'budget complete\n', (result.stderr, server.failures)
            assert not server.failures, server.failures
            assert len(server.observed) == len(cases) * 4, len(server.observed)
            print(f'Context budget integration passed: {len(server.observed)} recalculated request budgets across both APIs and initial/resumed turns; fixed/ratio margins, fallback cap, model ceilings, floor and UTF-8')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

if __name__ == '__main__':
    main()
