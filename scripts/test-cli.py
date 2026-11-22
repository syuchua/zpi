#!/usr/bin/env python3
"""Offline CLI integration: real HTTP, effects, persistence and JSONL stdout."""
import errno
import fcntl
import json
import os
import pty
import select
import shutil
import signal
import socket
import ssl
import struct
import sys
import termios
import time
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent
BINARY = Path(os.environ.get('ZPI_TEST_BINARY', ROOT / 'zig-out/bin/zpi')).resolve()
HAS_SEARCH = bool(shutil.which('rg') and (shutil.which('fd') or shutil.which('fdfind')))


def run_cli(command, **kwargs):
    return subprocess.run(command, **kwargs)


def run_repo_cli(command, **kwargs):
    command = list(command)
    for index, value in enumerate(command):
        if isinstance(value, str) and Path(value).name == 'zpi' and not Path(value).exists():
            command[index] = str(BINARY)
    return subprocess.run(command, **kwargs)


def cli_command(command):
    return [str(BINARY) if value == str(BINARY) else value for value in command]


class Server(ThreadingHTTPServer):
    daemon_threads = True

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/web-fetch-doc':
            body = (b'<html><head><title>Native Fetch Doc</title></head>'
                    b'<body><script>evil()</script><h1>Heading One</h1>'
                    b'<p>Alpha beta target_phrase gamma.</p></body></html>')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == '/web-fetch-redir':
            self.send_response(302)
            self.send_header('Location', '/web-fetch-doc')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.server.failures.append(f'Unexpected provider GET: {self.path}')
        self.send_error(405)

    def do_POST(self):
        try:
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert request['stream'] is True
            if self.path == '/tree-fixture/chat/completions':
                messages = request['messages']
                assert not request.get('tools')
                user = messages[-1]['content']
                if '<departed-branch>' in user:
                    assert len(messages) == 2, messages
                    assert '[User]: departed request' in user and '[Assistant]: departed answer' in user, user
                    assert '[Assistant]: [call read]' in user, user
                    assert 'destination request' not in user and 'shared request' not in user, user
                    assert 'old instructions' not in user and '中文日本語한글' not in user, user
                    self.server.tree_summary_requests += 1
                    if self.server.tree_summary_requests == 1:
                        response = self.text('partial summary')
                        response['choices'][0]['finish_reason'] = 'length'
                    elif self.server.tree_summary_requests == 2:
                        response = self.text('')
                    else:
                        response = self.text('## Goal\nInvestigated the alternative\n\n## Constraints & Preferences\n- none\n\n## Progress\n### Done\n- [x] explored\n\n### In Progress\n- [ ] none\n\n### Blocked\n- none\n\n## Key Decisions\n- **Branch**: explored\n\n## Next Steps\n1. continue')
                elif user in ('tree-live', 'tree-reopen'):
                    system = messages[0]['content']
                    if user == 'tree-live':
                        assert system.startswith('destination instructions\n'), messages
                        assert 'tree-fixture-skill' in system, messages
                    else:
                        assert system == 'destination instructions', messages
                    users = [m['content'] for m in messages if m['role'] == 'user']
                    summary_text = ('The following is a summary of a branch that this conversation came back from:'
                                    '\n\n<summary>\n## Goal\nInvestigated the alternative\n\n'
                                    '## Constraints & Preferences\n- none\n\n## Progress\n### Done\n- [x] explored\n\n'
                                    '### In Progress\n- [ ] none\n\n### Blocked\n- none\n\n'
                                    '## Key Decisions\n- **Branch**: explored\n\n## Next Steps\n1. continue</summary>')
                    expected = ['shared request', 'destination request', summary_text, 'tree-live']
                    if user == 'tree-reopen':
                        expected.append('tree-reopen')
                    assert users == expected, users
                    assert not any(m['role'] == 'tool' for m in messages), messages
                    response = self.text(user + ' complete')
                else:
                    raise AssertionError(f'Unexpected tree fixture prompt: {user!r}')
                data = ('data: ' + json.dumps(response) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/settings-switch/v1/chat/completions':
                tools = {t['function']['name'] for t in request.get('tools', [])}
                assert tools == {'read', 'edit', 'write', 'grep', 'web_fetch', 'get_content'}, tools
                user = [m['content'] for m in request['messages'] if m['role'] == 'user'][-1]
                if user == 'settings-check':
                    assert request.get('reasoning_effort') == 'medium', request
                    reply = 'settings ok'
                elif user == 'thinking-override':
                    assert request.get('reasoning_effort') == 'low', request
                    reply = 'thinking override ok'
                else:
                    raise AssertionError(f'Unexpected settings chat prompt: {user}')
                data = ('data: ' + json.dumps(self.text(reply)) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/settings-switch/v1/responses':
                items = request['input']
                last_user = next(m['content'][0]['text'] for m in reversed(items) if m.get('role') == 'user')
                if last_user == 'switched-turn':
                    assert request.get('reasoning') == {'effort': 'high', 'summary': 'auto'}, request
                    reply = 'switched model ok'
                elif last_user == 'thinking-turn':
                    assert request.get('reasoning') == {'effort': 'minimal', 'summary': 'auto'}, request
                    reply = 'switched thinking ok'
                else:
                    raise AssertionError(f'Unexpected settings responses prompt: {last_user}')
                events = [
                    ('response.created', {'response': {'id': 'resp_sw'}}),
                    ('response.output_item.added', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_sw'}}),
                    ('response.output_text.delta', {'output_index': 0, 'delta': reply}),
                    ('response.output_item.done', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_sw', 'content': [{'type': 'output_text', 'text': reply}]}}),
                    ('response.completed', {'response': {'id': 'resp_sw', 'status': 'completed', 'usage': {'input_tokens': 2, 'output_tokens': 2, 'total_tokens': 4}}}),
                ]
                data = ''.join(f'event: {k}\ndata: {json.dumps(dict(p, type=k))}\n\n' for k, p in events).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/responses-fixture/v1/responses':
                assert self.headers.get_all('Authorization') == ['Bearer fake-responses-key']
                assert self.headers['x-responses-fixture'] == 'enabled'
                assert request['store'] is False
                assert request['max_output_tokens'] == 2048
                items = request['input']
                last_user = next(m['content'][0]['text'] for m in reversed(items) if m.get('role') == 'user')
                outputs = [m for m in items if m.get('type') == 'function_call_output']
                def sse_pack(ev_list):
                    return ''.join(f'event: {kind}\ndata: {json.dumps(dict(payload, type=kind))}\n\n'
                                   for kind, payload in ev_list).encode()
                if last_user == 'responses-retry':
                    self.server.responses_retry_count += 1
                    if self.server.responses_retry_count == 1:
                        self.send_response(429)
                        self.send_header('Retry-After', '1')
                        self.send_header('Content-Length', '0')
                        self.end_headers()
                        return
                    data = sse_pack([
                        ('response.created', {'response': {'id': 'resp_r1'}}),
                        ('response.output_item.added', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_r1'}}),
                        ('response.output_text.delta', {'output_index': 0, 'delta': 'responses retried'}),
                        ('response.output_item.done', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_r1', 'content': [{'type': 'output_text', 'text': 'responses retried'}]}}),
                        ('response.completed', {'response': {'id': 'resp_r1', 'status': 'completed', 'usage': {'input_tokens': 2, 'output_tokens': 2, 'total_tokens': 4}}}),
                    ])
                elif last_user == 'responses-fail-tool':
                    data = sse_pack([
                        ('response.created', {'response': {'id': 'resp_bad'}}),
                        ('response.output_item.added', {'output_index': 0, 'item': {'type': 'function_call', 'id': 'fc_bad', 'call_id': 'call_bad', 'name': 'write', 'arguments': '{"path":"responses-uncommitted.txt","content":"bad"}'}}),
                        ('response.output_item.done', {'output_index': 0, 'item': {'type': 'function_call', 'id': 'fc_bad', 'call_id': 'call_bad', 'name': 'write', 'arguments': '{"path":"responses-uncommitted.txt","content":"bad"}'}}),
                        ('response.failed', {'response': {'id': 'resp_bad', 'status': 'failed', 'error': {'code': 'server_error', 'message': 'boom'}}}),
                    ])
                elif last_user == 'responses-workflow' and not outputs:
                    data = sse_pack([
                        ('response.created', {'response': {'id': 'resp_w1'}}),
                        ('response.output_item.added', {'output_index': 0, 'item': {'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_resp_1', 'name': 'write', 'arguments': '{"path":"responses.txt",'}}),
                        ('response.function_call_arguments.delta', {'output_index': 0, 'delta': '"content":"响应成功\\n"}'}),
                        ('response.output_item.done', {'output_index': 0, 'item': {'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_resp_1', 'name': 'write', 'arguments': '{"path":"responses.txt","content":"响应成功\\n"}'}}),
                        ('response.completed', {'response': {'id': 'resp_w1', 'status': 'completed', 'usage': {'input_tokens': 5, 'output_tokens': 3, 'total_tokens': 8}}}),
                    ])
                elif last_user == 'responses-workflow':
                    assert outputs[-1]['call_id'] == 'call_resp_1', outputs
                    calls = [m for m in items if m.get('type') == 'function_call']
                    assert calls[-1]['id'] == 'fc_1' and calls[-1]['call_id'] == 'call_resp_1', calls
                    data = sse_pack([
                        ('response.created', {'response': {'id': 'resp_w2'}}),
                        ('response.output_item.added', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_w2'}}),
                        ('response.output_text.delta', {'output_index': 0, 'delta': 'responses complete'}),
                        ('response.output_item.done', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_w2', 'content': [{'type': 'output_text', 'text': 'responses complete'}]}}),
                        ('response.completed', {'response': {'id': 'resp_w2', 'status': 'completed', 'usage': {'input_tokens': 8, 'output_tokens': 3, 'total_tokens': 11}}}),
                    ])
                elif last_user == 'responses-resume':
                    assert any(m.get('type') == 'function_call_output' and m.get('call_id') == 'call_resp_1' for m in items), items
                    data = sse_pack([
                        ('response.created', {'response': {'id': 'resp_w3'}}),
                        ('response.output_item.added', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_w3'}}),
                        ('response.output_text.delta', {'output_index': 0, 'delta': 'responses resumed'}),
                        ('response.output_item.done', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_w3', 'content': [{'type': 'output_text', 'text': 'responses resumed'}]}}),
                        ('response.completed', {'response': {'id': 'resp_w3', 'status': 'completed', 'usage': {'input_tokens': 10, 'output_tokens': 3, 'total_tokens': 13}}}),
                    ])
                else:
                    raise AssertionError(f'Unexpected responses prompt: {last_user}')
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/auto-compact/chat/completions':
                messages = request['messages']
                user = [m['content'] for m in messages if m['role'] == 'user'][-1]
                if user.startswith('<conversation>\n'):
                    assert 'auto-compact-1:' in user, user
                    response = self.text('## Goal\nAuto compacted summary')
                elif user.startswith('auto-compact-1:'):
                    response = self.text('auto 1 ok')
                elif user.startswith('auto-compact-2:'):
                    response = self.text('auto 2 ok')
                elif user.startswith('auto-compact-3:'):
                    assert any('<summary>\n## Goal\nAuto compacted summary\n</summary>' in m['content']
                               for m in messages if m['role'] == 'user'), messages
                    response = self.text('auto compact ok')
                else:
                    raise AssertionError(f'Unexpected auto-compact prompt: {user[:80]}')
                data = ('data: ' + json.dumps(response) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/retry-fixture/chat/completions':
                self.server.retry_request_count += 1
                if self.server.retry_request_count == 1:
                    self.send_response(429)
                    self.send_header('Retry-After', '2')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                if self.server.retry_request_count == 2:
                    self.send_response(503)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                data = ('data: ' + json.dumps(self.text('retry recovered')) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/unexpected-redirect':
                raise AssertionError('Provider request followed a redirect')
            if self.path in ('/error-fixture/chat/completions', '/error-fixture/v1/messages',
                             '/redirect-fixture/chat/completions', '/redirect-fixture/v1/messages'):
                credential = self.headers.get('Authorization') or self.headers.get('x-api-key')
                expected = ('Bearer synthetic-provider-key' if self.path.endswith('/chat/completions')
                            else 'synthetic-provider-key')
                assert credential == expected
                self.server.failure_request_count += 1
                body = json.dumps({'error': 'synthetic-provider-error', 'echo': credential}).encode()
                redirect = self.path.startswith('/redirect-fixture/')
                self.send_response(307 if redirect else 401)
                if redirect:
                    self.send_header('Location', '/unexpected-redirect')
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path.startswith('/budget/'):
                assert self.path == self.server.expected_budget_path
                assert request['max_tokens'] == self.server.expected_budget, request
                if self.path.endswith('/messages'):
                    return self.anthropic(request)
                assert [m['content'] for m in request['messages'] if m['role'] == 'system'] == ['1234567']
                data = ('data: ' + json.dumps(self.text('budget complete')) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/compat/chat/completions':
                assert 'stream_options' not in request, request
                messages = request['messages']
                user = [m['content'] for m in messages if m['role'] == 'user'][-1]
                if user == 'compat-store-omitted':
                    assert 'store' not in request, request
                else:
                    assert request['store'] is False, request
                if user == 'workflow':
                    assert request['max_completion_tokens'] == 2000 and 'max_tokens' not in request, request
                    assert {t['function']['name'] for t in request['tools']} == {'read'}, request
                    results = [m for m in messages if m['role'] == 'tool']
                    if results:
                        calls = [m for m in messages if m['role'] == 'assistant' and m.get('tool_calls')]
                        assert len(calls) == 1 and calls[0]['content'] == '', calls
                        assert results[0]['content'] == 'compat input', results
                        assert results[0]['name'] == 'read', results
                        response = self.text('compat complete')
                    else:
                        response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                            'index': 0, 'id': 'compat-read', 'type': 'function',
                            'function': {'name': 'read', 'arguments': '{"path":"compat.txt"}'},
                        }]}, 'finish_reason': 'tool_calls'}]}
                elif user == 'compat-resume':
                    assert request['max_completion_tokens'] == 2000 and 'max_tokens' not in request, request
                    assert request['tools'] == [], request
                    calls = [m for m in messages if m['role'] == 'assistant' and m.get('tool_calls')]
                    assert len(calls) == 1 and calls[0]['content'] == '', calls
                    response = self.text('compat resumed')
                elif user == 'compat-no-finish':
                    assert not request.get('tools'), request
                    response = {'choices': [{'index': 0, 'delta': {'content': 'compat inferred'}}]}
                else:
                    assert user in ('compat-fresh', 'compat-store-omitted'), user
                    assert request['max_completion_tokens'] == 2000 and 'max_tokens' not in request, request
                    assert 'tools' not in request, request
                    response = self.text('compat fresh')
                data = ('data: ' + json.dumps(response) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path.startswith('/route/'):
                assert 'store' not in request, request
                assert request['stream_options'] == {'include_usage': True}, request
                assert self.path == self.server.expected_route_path
                assert request['model'] == self.server.expected_route_model
                assert request['max_tokens'] == self.server.expected_route_tokens
                assert self.headers.get_all('Authorization') == ['Bearer route-key']
                data = ('data: ' + json.dumps(self.text('route complete')) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/comp-fixture/chat/completions':
                messages = request['messages']
                user_msg = [m['content'] for m in messages if m['role'] == 'user'][-1]
                results = [m for m in messages if m['role'] == 'tool']
                if user_msg == 'wrap-and-usage':
                    assert request.get('reasoning_effort') == 'high', request
                    long_md = '- ' + ' '.join(f'word{i}' for i in range(1, 22)) + ' **wrapend**\n'
                    c_text = self.text(long_md)
                    c_usage = {
                        'choices': [],
                        'usage': {'prompt_tokens': 7500, 'completion_tokens': 500, 'total_tokens': 8000},
                    }
                    data = (
                        'data: ' + json.dumps(c_text) + '\n\n' +
                        'data: ' + json.dumps(c_usage) + '\n\ndata: [DONE]\n\n'
                    ).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if user_msg == 'stream-bash':
                    bash_turns = sum(1 for m in messages if m['role'] == 'user' and m['content'] == 'stream-bash')
                    bash_results = sum(1 for r in results if r.get('tool_call_id', '').startswith('comp-bash-'))
                    if bash_results < bash_turns:
                        cmd = "i=1; while [ $i -le 12 ]; do echo B$i; i=$((i+1)); done"
                        c = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                            'index': 0, 'id': f'comp-bash-{bash_turns}', 'type': 'function',
                            'function': {'name': 'bash', 'arguments': json.dumps({'command': cmd, 'timeout': 5})},
                        }]}, 'finish_reason': 'tool_calls'}]}
                        data = ('data: ' + json.dumps(c) + '\n\ndata: [DONE]\n\n').encode()
                    else:
                        data = ('data: ' + json.dumps(self.text('bash stream done')) + '\n\ndata: [DONE]\n\n').encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if not results:
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()
                    c1 = {'choices': [{'index': 0, 'delta': {'reasoning_content': 'checking file'}}]}
                    self.wfile.write(('data: ' + json.dumps(c1) + '\n\n').encode())
                    self.wfile.flush()
                    time.sleep(0.22)
                    c2 = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'comp-edit', 'type': 'function',
                        'function': {'name': 'edit', 'arguments': json.dumps({
                            'path': 'comp.txt', 'oldText': 'old', 'newText': 'new',
                        })},
                    }]}, 'finish_reason': 'tool_calls'}]}
                    self.wfile.write(('data: ' + json.dumps(c2) + '\n\ndata: [DONE]\n\n').encode())
                    self.wfile.flush()
                    return
                body = '## Summary\n- Updated `comp.txt` with **new**\n```zig\nconst ok = true;\n```\n'
                data = ('data: ' + json.dumps(self.text(body)) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/queue-fixture/chat/completions':
                messages = request['messages']
                user = [m['content'] for m in messages if m['role'] == 'user'][-1]
                self.server.queue_requests.append(user)
                if user == 'steer-batch':
                    c = {'choices': [{'index': 0, 'delta': {'tool_calls': [
                        {'index': 0, 'id': 'steer-bash', 'type': 'function',
                         'function': {'name': 'bash', 'arguments': json.dumps({'command': "printf 'steer-step1\\n'; sleep 0.35", 'timeout': 5})}},
                        {'index': 1, 'id': 'steer-write', 'type': 'function',
                         'function': {'name': 'write', 'arguments': json.dumps({'path': 'steer-skipped.txt', 'content': 'must not run'})}},
                    ]}, 'finish_reason': 'tool_calls'}]}
                    data = ('data: ' + json.dumps(c) + '\n\ndata: [DONE]\n\n').encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if user == 'steer redirect':
                    tool_msgs = [m['content'] for m in messages if m['role'] == 'tool']
                    assert any('steer-step1' in t for t in tool_msgs), tool_msgs
                    assert any('Skipped due to queued user message.' in t for t in tool_msgs), tool_msgs
                    data = ('data: ' + json.dumps(self.text('steered ok')) + '\n\ndata: [DONE]\n\n').encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if user == 'queue-slow':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()
                    chunk1 = {'choices': [{'index': 0, 'delta': {'content': 'working...'}}]}
                    self.wfile.write(('data: ' + json.dumps(chunk1) + '\n\n').encode())
                    self.wfile.flush()
                    assert self.server.queue_stream_mid.wait(timeout=10)
                    chunk2 = {'choices': [{'index': 0, 'delta': {'content': ' mid\n'}}]}
                    self.wfile.write(('data: ' + json.dumps(chunk2) + '\n\n').encode())
                    self.wfile.flush()
                    assert self.server.queue_stream_release.wait(timeout=10)
                    chunk3 = {'choices': [{'index': 0, 'delta': {'content': 'done'}, 'finish_reason': 'stop'}]}
                    self.wfile.write(('data: ' + json.dumps(chunk3) + '\n\ndata: [DONE]\n\n').encode())
                    self.wfile.flush()
                    return
                if user == 'queue-cancel-stream':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()
                    partial = {'choices': [{'index': 0, 'delta': {'content': 'cancel-partial-'}}]}
                    self.wfile.write(('data: ' + json.dumps(partial) + '\n\n').encode())
                    self.wfile.flush()
                    self.server.queue_cancel_release.wait(timeout=10)
                    return
                reply = {
                    'queued-edited': 'queued-edited complete',
                    'queued-beta': 'queued-beta complete',
                    'unsubmitted draft': 'draft complete',
                }[user]
                data = ('data: ' + json.dumps(self.text(reply)) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path == '/v1/chat/completions':
                assert request['max_tokens'] == 3000
            else:
                assert request['max_tokens'] > 0
            if self.path == '/v1/messages':
                return self.anthropic(request)
            assert self.path == '/v1/chat/completions'
            assert self.headers.get_all('Authorization') == ['Bearer fake-key']
            assert self.headers['x-provider-header'] == 'model'
            assert self.headers['x-token'] == 'Bearer header-secret'
            assert self.headers['x-model-header'] == 'model-value'
            assert self.headers['x-override-header'] == 'override-value'
            assert self.headers.get_all('x-provider-header') == ['model']
            assert self.headers.get_all('x-token') == ['Bearer header-secret']
            assert self.headers['x-template'] == '$:!:$9:${bad-name}:header-secret'
            messages = request['messages']
            user = [m['content'] for m in messages if m['role'] == 'user'][-1]
            self.server.last_request = request
            if user in ('mcp-workflow', 'mcp-disabled', 'mcp-multiple', 'mcp-excluded', 'mcp-opt-out', 'mcp-rpc-error', 'mcp-server-error') or user.startswith('mcp-response-limit'):
                tool_name = 'mcp__other__echo_text' if user == 'mcp-multiple' else 'mcp__demo__echo_text'
                declared = {t['function']['name']: t['function'] for t in request.get('tools', [])}
                expected_tools = {
                    'mcp-workflow': {tool_name},
                    'mcp-multiple': {'mcp__demo__echo_text', tool_name},
                    'mcp-rpc-error': {tool_name},
                    'mcp-opt-out': {'read'},
                    'mcp-server-error': {tool_name},
                    'mcp-response-limit-accepted': {tool_name},
                    'mcp-response-limit-rejected': {tool_name},
                }.get(user, set())
                assert set(declared) == expected_tools, declared
                if tool_name in declared:
                    assert declared[tool_name]['parameters']['required'] == ['text'], declared
                    assert declared[tool_name]['description'] == 'Echo text', declared
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'mcp-call', 'type': 'function',
                        'function': {'name': tool_name, 'arguments': json.dumps({
                            'text': {'mcp-rpc-error': 'fail after effect',
                                     'mcp-server-error': 'reported tool failure',
                                     'mcp-response-limit-accepted': 'z' * (49 * 1024),
                                     'mcp-response-limit-rejected': 'z' * (50 * 1024 + 1)}.get(user, 'hello MCP'),
                        })},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    expected = {
                        'mcp-workflow': 'demo says: hello MCP',
                        'mcp-multiple': 'other says: hello MCP',
                        'mcp-disabled': f'Unknown tool: {tool_name}',
                        'mcp-excluded': f'Unknown tool: {tool_name}',
                        'mcp-opt-out': f'Unknown tool: {tool_name}',
                        'mcp-server-error': 'fixture reported tool failure',
                        'mcp-response-limit-accepted': 'demo says: ' + 'z' * (49 * 1024),
                        'mcp-response-limit-rejected': 'Tool failed: McpToolOutputTooLarge',
                    }[user]
                    assert results[-1]['content'] == expected, user
                    response = self.text('mcp complete')
            elif self.server.expected_template_prompt is not None:
                assert user == self.server.expected_template_prompt, user
                if user == 'explicit:skill:explicit skill':
                    assert any('project-only' in m['content'] for m in messages if m['role'] == 'system'), messages
                response = self.text('template complete')
            elif user in ('skill-list', 'skill-project') or user.startswith('<skill name="pdf-tools"'):
                systems = [m['content'] for m in messages if m['role'] == 'system']
                if user == 'skill-list':
                    assert 'pdf-tools' in systems[-1] and 'Read PDF files and tables.' in systems[-1], systems
                    assert 'project-only' not in systems[-1]
                elif user.startswith('<skill'):
                    assert 'Read references/formats.md before converting.' in user and '---' not in user, user
                    assert user.endswith('</skill>\n\nextract report.pdf'), user
                    assert any('pdf-tools' in text for text in systems), systems
                else:
                    assert any('project-only' in text for text in systems), systems
                    assert any('pdf-tools' in text for text in systems), systems
                response = self.text('skill complete')
            elif user.startswith(('<skill name="explicit-only"', '/skill:explicit-only ')):
                response = self.text('skill complete')
            elif user in self.server.expected_system_prompts:
                systems = [m['content'] for m in messages if m['role'] == 'system']
                assert systems == [self.server.expected_system_prompts[user]], systems
                response = self.text('system complete')
            elif user in self.server.expected_tool_sets:
                assert {t['function']['name'] for t in request.get('tools', [])} == self.server.expected_tool_sets[user], request.get('tools')
                response = self.text('selection complete')
            elif user == 'cancel-stream':
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                partial = {'choices': [{'index': 0, 'delta': {'content': 'partial-'}}]}
                self.wfile.write(('data: ' + json.dumps(partial) + '\n\n').encode())
                self.wfile.flush()
                self.server.cancel_stream_release.wait(timeout=10)
                return
            elif user == 'after-stream-cancel':
                users = [m['content'] for m in messages if m['role'] == 'user']
                assert users[-3:] == ['cancel-prompt-ok', 'cancel-stream', 'after-stream-cancel'], users
                response = self.text('stream recovered')
            elif user == 'cancel-bash':
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'cancel-bash-1', 'type': 'function',
                        'function': {'name': 'bash', 'arguments': json.dumps({
                            'command': 'touch cancel-started-marker; sleep 5; touch cancel-late-marker',
                            'timeout': 10,
                        })},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    raise AssertionError('unexpected replay after canceled bash')
            elif user == 'after-bash-cancel':
                results = [m for m in messages if m['role'] == 'tool']
                assert len(results) == 1 and 'Interrupted tool call: execution outcome is unknown' in results[0]['content'], results
                response = self.text('bash recovered')
            elif user == 'cancel-prompt-ok':
                response = self.text('prompt recovered')
            elif user.startswith('<conversation>\n'):
                if 'Additional focus: keep api notes' in user:
                    assert 'compact-turn-1' in user and 'compact-turn-2' in user, user
                    response = self.text('## Goal\nCompacted summary')
                else:
                    response = self.text('## Goal\nAuto compacted summary')
            elif user in ('compact-turn-1', 'compact-turn-2'):
                response = self.text(f'{user} ok')
            elif user == 'after-compact':
                assert len(messages) == 3, messages
                assert '<summary>\n## Goal\nCompacted summary\n</summary>' in messages[1]['content'], messages
                response = self.text('after compact ok')
            elif user == 'after-compact-reload':
                assert len(messages) == 5, messages
                assert '<summary>\n## Goal\nCompacted summary\n</summary>' in messages[1]['content'], messages
                response = self.text('after compact reload ok')
            elif user == 'hello zig world':
                response = self.text('editor-left-ok')
            elif user == 're: hello zig world':
                response = self.text('editor-history-ok')
            elif user == 'line1\nline2':
                response = self.text('editor-paste-ok')
            elif user == '@tab-target.txt':
                response = self.text('editor-at-ok')
            elif user == 'edit-preview':
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'preview-edit', 'type': 'function',
                        'function': {'name': 'edit', 'arguments': json.dumps({
                            'path': 'preview.txt', 'oldText': 'beta', 'newText': 'BETA',
                        })},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    response = self.text('preview complete')
            elif user == 'bash-spill':
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'spill-bash', 'type': 'function',
                        'function': {'name': 'bash', 'arguments': json.dumps({
                            'command': 'i=1; while [ $i -le 2005 ]; do echo B$i; i=$((i+1)); done',
                            'timeout': 10,
                        })},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert '[Showing lines 6-2005 of 2005. Full output: ' in results[0]['content'], results[0]
                    response = self.text('bash spill complete')
            elif user == 'filtered-completion':
                assert not any(m['role'] == 'tool' for m in messages), messages
                response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                    'index': 0, 'id': 'filtered-write', 'type': 'function',
                    'function': {'name': 'write', 'arguments': json.dumps({
                        'path': 'filtered.txt', 'content': 'fixture',
                    })},
                }]}, 'finish_reason': 'content_filter'}]}
            elif user == 'disabled-effect':
                assert {t['function']['name'] for t in request.get('tools', [])} == {'read'}
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'disabled-write', 'type': 'function',
                        'function': {'name': 'write', 'arguments': json.dumps({'path': 'forbidden.txt', 'content': 'bad'})},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert results[-1]['content'] == 'Unknown tool: write', results
                    response = self.text('disabled effect prevented')
            elif user == 'Respond briefly in 1-2 sentences: extension-workflow':
                completed = [m for m in messages if m['role'] == 'tool']
                operations = [
                    ('hello', {'name': 'Zig'}),
                    ('throw_fixture', {}),
                    ('write', {'path': 'throw-gate.txt', 'content': 'must not exist'}),
                    ('write', {'path': 'denied.txt', 'content': 'must not exist'}),
                    ('write', {'path': 'mutated.txt', 'content': 'original'}),
                ]
                assert {t['function']['name'] for t in request['tools']} >= {'hello', 'write'}
                if len(completed) < len(operations):
                    name, args = operations[len(completed)]
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': f'ext-{len(completed)}', 'type': 'function',
                        'function': {'name': name, 'arguments': json.dumps(args)},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert completed[0]['content'] == 'Hello, Zig!'
                    assert completed[1]['content'] == 'Tool failed: ExtensionToolFailed'
                    assert completed[2]['content'] == 'Tool failed: ExtensionHostRejected'
                    assert completed[3]['content'] == 'Tool blocked by extension: fixture denied'
                    assert 'Wrote' in completed[4]['content']
                    response = self.text('extension complete')
            elif user == 'web-fetch-ssrf':
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    url = f'http://127.0.0.1:{self.server.server_port}/web-fetch-doc'
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'wf-ssrf', 'type': 'function',
                        'function': {'name': 'web_fetch', 'arguments': json.dumps({'url': url})},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert 'SsrfBlocked' in results[-1]['content'], results
                    response = self.text('ssrf blocked ok')
            elif user == 'web-fetch-loopback':
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    url = f'http://127.0.0.1:{self.server.server_port}/web-fetch-redir'
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'wf-get', 'type': 'function',
                        'function': {'name': 'web_fetch', 'arguments': json.dumps({'url': url})},
                    }]}, 'finish_reason': 'tool_calls'}]}
                elif len(results) == 1:
                    assert 'Native Fetch Doc' in results[0]['content'] and 'evil()' not in results[0]['content'], results[0]
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'wf-search', 'type': 'function',
                        'function': {'name': 'get_content', 'arguments': json.dumps({'responseId': 'wf_1', 'findText': 'TARGET_PHRASE'})},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert 'target_phrase' in results[-1]['content'], results[-1]
                    response = self.text('web fetch loopback ok')
            elif user == 'native-workflow':
                assert any(t['function']['name'] == 'echo_native' for t in request['tools'])
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'native-call', 'type': 'function',
                        'function': {'name': 'echo_native', 'arguments': '{}'},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert results[-1]['content'] == 'native-call', results
                    response = self.text('native complete')
            elif user == 'native-resume':
                assert any(m['role'] == 'tool' and m['content'] == 'native-call' for m in messages)
                response = self.text('native resumed')
            elif user == 'native-no-tools':
                assert not request.get('tools'), request.get('tools')
                response = self.text('native disabled')
            elif user in ('stdin-only-prompt', 'stdin contextpositional-prompt'):
                response = self.text('stdin complete')
            elif user in self.server.expected_file_prompts:
                response = self.text('file input complete')
            elif user in ('recent-first', 'recent-next', 'recent-other'):
                users = [m['content'] for m in messages if m['role'] == 'user']
                assert users == {'recent-first': ['recent-first'],
                                 'recent-next': ['recent-first', 'recent-next'],
                                 'recent-other': ['recent-other']}[user], users
                response = self.text(user + ' complete')
            elif user in ('branch-a', 'branch-b', 'branch-resume'):
                users = [m['content'] for m in messages if m['role'] == 'user']
                expected = {'branch-a': ['branch-a'], 'branch-b': ['branch-b'],
                            'branch-resume': ['branch-a', 'branch-resume']}[user]
                assert users == expected, users
                assert not any(m['role'] == 'tool' for m in messages)
                response = self.text(user + ' complete')
            elif user == 'pi-import-resume':
                assert [m['role'] for m in messages] == [
                    'system', 'user', 'assistant', 'tool', 'assistant', 'user', 'user', 'user', 'user',
                ], messages
                assert [m['content'] for m in messages if m['role'] == 'user'] == [
                    'Edited request', 'Edited custom text', 'Legacy\ncustom text',
                    'The following is a summary of a branch that this conversation came back from:\n\n<summary>\nEarlier path exploration</summary>',
                    'pi-import-resume',
                ], messages
                assert messages[0]['content'] == 'Imported prompt\n\nFirst section\n\nSecond section\n\nProject section', messages
                assert messages[1]['content'] == 'Edited request', messages
                call, = messages[2]['tool_calls']
                assert call['id'] == 'pi-write' and call['function']['name'] == 'write', call
                assert json.loads(call['function']['arguments']) == {
                    'path': 'import-must-not-write.txt', 'content': 'historical', 'exact': 18446744073709551616,
                }, call
                assert messages[3] == {'role': 'tool', 'tool_call_id': 'pi-write', 'content': 'edited write output'}, messages
                assert messages[4]['content'] == 'Edited answer', messages
                assert 'tools' not in request, request
                response = self.text('import resumed')
            elif user == 'pi-compaction-resume':
                assert [(m['role'], m['content']) for m in messages] == [
                    ('system', 'Current checkpoint\n\nProject rules'),
                    ('user', 'The conversation history before this point was compacted into the following summary:'
                             '\n\n<summary>\nLatest summary\n</summary>'),
                    ('user', 'Edited retained request'),
                    ('user', 'Older retained message'),
                    ('assistant', 'Retained answer'),
                    ('user', 'After compaction'),
                    ('user', 'pi-compaction-resume'),
                ], messages
                response = self.text('compacted import resumed')
            elif user == 'branch-interrupted':
                results = [m for m in messages if m['role'] == 'tool']
                assert len(results) == 1 and 'outcome is unknown' in results[0]['content'], results
                assert not any(m['role'] == 'assistant' and m.get('content') == 'workflow complete' for m in messages)
                response = self.text('interrupted branch complete')
            elif user == 'read-zero-limit':
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'read-zero', 'type': 'function',
                        'function': {'name': 'read', 'arguments': json.dumps({'path': 'many-lines.txt', 'limit': 0})},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert len(results) == 1, results
                    assert results[0]['content'] == '\n\n[2002 more lines in file. Use offset=1 to continue.]', results
                    response = self.text('zero limit complete')
            elif user in ('read-truncation', 'read-truncation-resume'):
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': 'read-truncated', 'type': 'function',
                        'function': {'name': 'read', 'arguments': json.dumps({'path': 'many-lines.txt'})},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    expected = 'x\n' * 1999 + 'x\n\n[Showing lines 1-2000 of 2002. Use offset=2001 to continue.]'
                    assert len(results) == 1 and results[0]['content'] == expected, results
                    response = self.text('read truncation complete')
            elif user == 'config-syntax':
                assert self.headers['x-syntax'] == 'https://example.invalid//path ",}"'
                response = self.text('config syntax complete')
            elif user == 'token-limit':
                response = self.text('token-limit complete')
            elif user == 'shell-status':
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    commands = [':', 'printf failed >&2; exit 3', 'kill -TERM $$']
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [
                        {'index': i, 'id': f'status-{i}', 'type': 'function',
                         'function': {'name': 'bash', 'arguments': json.dumps({'command': command, 'timeout': 3})}}
                        for i, command in enumerate(commands)
                    ]}, 'finish_reason': 'tool_calls'}]}
                else:
                    assert [r['content'] for r in results] == [
                        '(no output)', 'failed\n\nCommand exited with code 3',
                        '(no output)\n\nCommand exited with code 143'], results
                    response = self.text('shell status complete')
            elif user == 'resume-check':
                assert any(m['role'] == 'tool' and m['tool_call_id'] == 'call-4' for m in messages)
                assert any(m['role'] == 'assistant' and m.get('content') == 'workflow complete' for m in messages)
                response = self.text('resumed correctly')
            elif user == 'workflow':
                completed = sum(m['role'] == 'tool' for m in messages)
                operations = [
                    ('write', {'path': 'sample.txt', 'content': 'alpha\nbeta\n'}),
                    ('edit', {'path': 'sample.txt', 'oldText': 'beta', 'newText': 'gamma'}),
                    ('read', {'path': 'sample.txt'}),
                    ('bash', {'command': "printf '%s' 'shell-ok'", 'timeout': 3}),
                ]
                if HAS_SEARCH:
                    operations.extend([
                        ('grep', {'pattern': 'gamma', 'path': '.', 'literal': True}),
                        ('find', {'pattern': 'sample.txt', 'path': '.'}),
                        ('ls', {'path': '.'}),
                    ])
                if completed < len(operations):
                    name, args = operations[completed]
                    response = {'choices': [{'index': 0, 'delta': {'tool_calls': [{
                        'index': 0, 'id': f'call-{completed + 1}', 'type': 'function',
                        'function': {'name': name, 'arguments': json.dumps(args)},
                    }]}, 'finish_reason': 'tool_calls'}]}
                else:
                    results = [m for m in messages if m['role'] == 'tool']
                    assert 'gamma' in results[2]['content']
                    assert results[3]['content'] == 'shell-ok'
                    assert not any(m.get('is_error') for m in results)
                    if HAS_SEARCH:
                        assert 'sample.txt:2: gamma' in results[4]['content']
                        assert results[5]['content'] == 'sample.txt'
                        assert 'sample.txt' in results[6]['content']
                    response = self.text('workflow complete')
            else:
                raise AssertionError(f'unexpected fixture prompt: {user!r}; expected files: {self.server.expected_file_prompts!r}')
            data = ('data: ' + json.dumps(response) + '\n\ndata: [DONE]\n\n').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            self.server.failures.append(repr(exc))
            self.send_error(500)

    def anthropic(self, request):
        if self.path.startswith('/budget/'):
            assert self.path == self.server.expected_budget_path
            assert request['max_tokens'] == self.server.expected_budget, request
            assert self.headers['x-api-key'] == 'route-key'
            assert self.headers['anthropic-version'] == '2023-06-01'
            assert request['system'] == '1234567'
            block = {'type': 'text', 'text': 'budget complete'}
            events = [('message_start', {'message': {'usage': {'input_tokens': 1, 'output_tokens': 0}}}),
                      ('content_block_start', {'index': 0, 'content_block': block}),
                      ('content_block_stop', {'index': 0}),
                      ('message_delta', {'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 1}}),
                      ('message_stop', {})]
            data = ''.join(f'event: {kind}\ndata: {json.dumps(dict(payload, type=kind))}\n\n' for kind, payload in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        assert self.headers['x-api-key'] == 'fake-anthropic-key'
        assert self.headers['anthropic-version'] == '2023-06-01'
        assert self.headers['x-fixture'] == 'anthropic-enabled'
        assert not self.headers.get('Authorization')
        assert request['system']
        assert request['max_tokens'] == 2048
        messages = request['messages']
        assert all(m['role'] in ('user', 'assistant') for m in messages)
        blocks = [b for m in messages for b in m['content']]
        results = [b for b in blocks if b['type'] == 'tool_result']
        prompts = [b['text'] for m in messages if m['role'] == 'user'
                   for b in m['content'] if b['type'] == 'text']
        events = [('message_start', {'message': {'usage': {'input_tokens': 3, 'output_tokens': 0}}})]
        if prompts[-1] in self.server.expected_system_prompts:
            assert request['system'] == self.server.expected_system_prompts[prompts[-1]], request['system']
            block = {'type': 'text', 'text': 'system complete'}
            reason = 'end_turn'
        elif prompts[-1] == 'anthropic-resume':
            assert len(results) == 2
            assert any(b.get('text') == 'anthropic complete' for b in blocks)
            block = {'type': 'text', 'text': 'anthropic resumed'}
            reason = 'end_turn'
        elif not results:
            assert {t['name'] for t in request['tools']} >= {'write', 'read'}
            # Two calls in one response establish that their results are merged
            # into a single user message on the next request.
            for index, name, args in [(0, 'write', {'path': 'anthropic.txt', 'content': '你好\n'}),
                                      (1, 'read', {'path': 'anthropic.txt'})]:
                events.extend([
                    ('content_block_start', {'index': index, 'content_block': {
                        'type': 'tool_use', 'id': f'anthropic_{index}', 'name': name, 'input': {}}}),
                    ('content_block_delta', {'index': index, 'delta': {
                        'type': 'input_json_delta', 'partial_json': json.dumps(args)}}),
                    ('content_block_stop', {'index': index}),
                ])
            block = None
            reason = 'tool_use'
        else:
            assert len(results) == 2
            assert messages[-1]['role'] == 'user'
            assert [b['tool_use_id'] for b in messages[-1]['content']] == ['anthropic_0', 'anthropic_1']
            assert all(b['is_error'] is False for b in results)
            assert results[1]['content'] == [{'type': 'text', 'text': '你好\n'}]
            block = {'type': 'text', 'text': 'anthropic complete'}
            reason = 'end_turn'
        if block is not None:
            events.extend([
                ('content_block_start', {'index': 0, 'content_block': block}),
                ('content_block_stop', {'index': 0}),
            ])
        events.extend([
            ('message_delta', {'delta': {'stop_reason': reason}, 'usage': {'output_tokens': 2}}),
            ('message_stop', {}),
        ])
        data = ''.join(f'event: {kind}\ndata: {json.dumps(dict(payload, type=kind))}\n\n'
                       for kind, payload in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    @staticmethod
    def text(text):
        return {'choices': [{'index': 0, 'delta': {'content': text}, 'finish_reason': 'stop'}]}


def terminal_check(common, environment, session, tool_count):
    before_commands = session.read_bytes()
    active_entry = json.loads(before_commands.splitlines()[-1])['id']
    master, slave = pty.openpty()
    before = __import__('termios').tcgetattr(slave)
    process = subprocess.Popen(cli_command(common), stdin=slave, stdout=slave, stderr=slave,
                               env=environment, close_fds=True)
    transcript = bytearray()

    def read_until(marker):
        deadline = time.monotonic() + 10
        while marker not in transcript:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('terminal timed out', bytes(transcript))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', bytes(transcript))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)

    try:
        read_until(b'Ctrl-D exits')
        os.write(master, b'/help\n')
        read_until(b'Use --session PATH')
        os.write(master, b'/hotkeys\n')
        read_until(b'Keyboard shortcuts')
        session_mark = len(transcript)
        os.write(master, b'/session\n')
        read_until(f'Active entry: {active_entry}'.encode())
        assert b'\r\x1b[J' in transcript[session_mark:], bytes(transcript[session_mark:])
        assert f'File: {session}'.encode() in transcript, bytes(transcript)
        messages = [record['message'] for record in map(json.loads, before_commands.splitlines())
                    if record['type'] == 'message' and record['message']['role'] != 'system']
        user_count = sum(message['role'] == 'user' for message in messages)
        assistant_count = sum(message['role'] == 'assistant' for message in messages)
        assert f'Messages: {len(messages)} total ({user_count} user, {assistant_count} assistant)'.encode() in transcript, bytes(transcript)
        assert f'Tools: {tool_count} calls, {tool_count} results'.encode() in transcript, bytes(transcript)
        assert session.read_bytes() == before_commands
        os.write(master, b'resume-check\n')
        read_until(b'resumed correctly')
        os.write(master, b'/exit\n')
        assert process.wait(timeout=5) == 0, bytes(transcript)
        after = termios.tcgetattr(slave)
        pendin = getattr(termios, 'PENDIN', 0)
        assert (after[:3], after[3] & ~pendin, after[4:]) == (before[:3], before[3] & ~pendin, before[4:]), (
            'terminal settings changed', before, after
        )
        assert b'\x1b[?1049h' not in transcript, 'regular UI switched screen'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)


def terminal_cancel_check(common, environment, root, server):
    cancel_session = root / 'cancel-session.jsonl'
    args = common.copy()
    args[-1] = str(cancel_session)
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)

    def become_tty_leader():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        cli_command(args),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=environment,
        close_fds=True,
        preexec_fn=become_tty_leader,
    )
    os.close(slave)
    transcript = bytearray()

    def read_until(marker, start=0):
        deadline = time.monotonic() + 10
        while transcript.find(marker, start) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('terminal cancel timed out', marker, bytes(transcript))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', marker, bytes(transcript))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)
        return transcript.find(marker, start)

    def read_prompt(start=0):
        deadline = time.monotonic() + 10
        while True:
            for marker in (b'>\x1b[0m ', b'> '):
                pos = transcript.find(marker, start)
                if pos != -1:
                    return pos + len(marker)
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('terminal prompt timed out', bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', bytes(transcript[start:]))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)

    try:
        read_until(b'Ctrl-D exits')
        read_prompt()
        # 1. Ctrl-C at the idle prompt discards partial input and re-prompts cleanly.
        mark = len(transcript)
        os.write(master, b'partial\x03')
        prompt_pos = read_prompt(mark)
        os.write(master, b'cancel-prompt-ok\n')
        reply_pos = read_until(b'prompt recovered', prompt_pos)
        read_prompt(reply_pos)

        # 2. Ctrl-C during a stalled provider stream cancels cleanly without committing partial reply.
        mark = len(transcript)
        os.write(master, b'cancel-stream\n')
        read_until(b'partial-', mark)
        os.write(master, b'\x03')
        cancel_pos = read_until(b'zpi: Canceled', mark)
        read_prompt(cancel_pos)
        server.cancel_stream_release.set()
        os.write(master, b'after-stream-cancel\n')
        reply_pos = read_until(b'stream recovered', mark)
        read_prompt(reply_pos)

        # 3. Ctrl-C during bash execution terminates the child group and reconciles the session.
        mark = len(transcript)
        os.write(master, b'cancel-bash\n')
        read_until(b'[tool: bash]', mark)
        started_marker = root / 'cancel-started-marker'
        deadline = time.monotonic() + 5
        while not started_marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert started_marker.exists(), 'bash tool did not start before SIGINT'
        os.write(master, b'\x03')
        cancel_pos = read_until(b'zpi: Canceled', mark)
        read_prompt(cancel_pos)
        os.write(master, b'after-bash-cancel\n')
        reply_pos = read_until(b'bash recovered', mark)
        read_prompt(reply_pos)
        os.write(master, b'/exit\n')
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.05)[0]:
                try:
                    chunk = os.read(master, 16384)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                transcript.extend(chunk)
        assert termios.tcgetattr(master) == before, 'terminal settings changed'
        os.close(master)
        master = -1
        assert process.wait(timeout=5) == 0, bytes(transcript)
        time.sleep(0.2)
        assert not (root / 'cancel-late-marker').exists(), 'bash descendant survived SIGINT'
        saved_records = [json.loads(line) for line in cancel_session.read_text().splitlines()]
        reconciled = [r['message'] for r in saved_records
                      if r.get('message', {}).get('role') == 'tool_result']
        assert len(reconciled) == 1 and reconciled[0]['is_error'] is True, reconciled
        assert 'Interrupted tool call: execution outcome is unknown' in reconciled[0]['content'][0]['text']
    finally:
        server.cancel_stream_release.set()
        if master != -1:
            os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def terminal_editor_check(common, environment, root):
    (root / 'tab-target.txt').write_text('target\n')
    (root / 'preview.txt').write_text('alpha\nbeta\ngamma\n')
    editor_session = root / 'editor-session.jsonl'
    args = common.copy()
    args[-1] = str(editor_session)
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    process = subprocess.Popen(cli_command(args), stdin=slave, stdout=slave, stderr=slave,
                               env=environment, close_fds=True)
    os.close(slave)
    transcript = bytearray()

    def read_until(marker, start=0):
        deadline = time.monotonic() + 10
        while transcript.find(marker, start) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('terminal editor timed out', marker, bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', marker, bytes(transcript))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)
        return transcript.find(marker, start)

    def read_prompt(start=0):
        deadline = time.monotonic() + 10
        while True:
            for marker in (b'>\x1b[0m ', b'> '):
                pos = transcript.find(marker, start)
                if pos != -1:
                    return pos + len(marker)
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('terminal editor prompt timed out', bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', bytes(transcript[start:]))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)

    try:
        read_until(b'Ctrl-D exits')
        p = read_prompt()
        # 1. Tab completes /he -> /help and opens auto-retracting dialog; ambiguous /h shows inline hint and retracts cleanly
        os.write(master, b'/h\t')
        hint_end = read_until(b'/hotkeys', p)
        assert b'/help' in transcript[p:hint_end + 32], bytes(transcript[p:])
        os.write(master, b'e\t\n')
        p = read_prompt(read_until(b'Tab completes /commands and @paths', p))

        # 2. Left-arrow cursor editing
        os.write(master, b'hello world\x1b[D\x1b[D\x1b[D\x1b[D\x1b[Dzig \n')
        p = read_prompt(read_until(b'editor-left-ok', p))

        # 3. Up-arrow history + Ctrl-A Home insertion
        os.write(master, b'\x1b[A\x01re: \n')
        p = read_prompt(read_until(b'editor-history-ok', p))

        # 4. Bracketed paste keeps newline as part of one multi-line prompt
        os.write(master, b'\x1b[200~line1\nline2\x1b[201~\n')
        p = read_prompt(read_until(b'editor-paste-ok', p))

        # 5. @path Tab completion
        os.write(master, b'@tab-tar\t\n')
        p = read_prompt(read_until(b'editor-at-ok', p))

        # 6. Interactive edit tool displays diff preview lines
        mark = len(transcript)
        os.write(master, b'edit-preview\n')
        p = read_prompt(read_until(b'preview complete', mark))
        snippet = transcript[mark:p]
        assert b'-2 beta' in snippet and b'+2 BETA' in snippet, snippet

        # 7. Ctrl-D on empty line exits cleanly with status 0 and restored termios
        os.write(master, b'\x04')
        while True:
            if not select.select([master], [], [], 5)[0]:
                break
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            transcript.extend(chunk)
        assert process.wait(timeout=5) == 0, bytes(transcript)
        after = termios.tcgetattr(master)
        pendin = getattr(termios, 'PENDIN', 0)
        assert (after[:3], after[3] & ~pendin, after[4:]) == (before[:3], before[3] & ~pendin, before[4:]), (
            'terminal settings changed', before, after
        )
    finally:
        if master != -1:
            os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def terminal_compact_check(common, environment, root):
    compact_session = root / 'compact-session.jsonl'
    args = common.copy()
    args[-1] = str(compact_session)
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    process = subprocess.Popen(cli_command(args), stdin=slave, stdout=slave, stderr=slave,
                               env=environment, close_fds=True)
    os.close(slave)
    transcript = bytearray()

    def read_until(marker, start=0):
        deadline = time.monotonic() + 10
        while transcript.find(marker, start) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('terminal compact timed out', marker, bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', marker, bytes(transcript))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)
        return transcript.find(marker, start)

    def read_prompt(start=0):
        deadline = time.monotonic() + 10
        while True:
            for marker in (b'>\x1b[0m ', b'> '):
                pos = transcript.find(marker, start)
                if pos != -1:
                    return pos + len(marker)
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('terminal compact prompt timed out', bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', bytes(transcript[start:]))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)

    try:
        p = read_prompt(read_until(b'Ctrl-D exits'))
        os.write(master, b'compact-turn-1\n')
        p = read_prompt(read_until(b'compact-turn-1 ok', p))
        os.write(master, b'compact-turn-2\n')
        p = read_prompt(read_until(b'compact-turn-2 ok', p))
        os.write(master, b'/compact keep api notes\n')
        p = read_prompt(read_until(b'[compacted:', p))
        os.write(master, b'after-compact\n')
        p = read_prompt(read_until(b'after compact ok', p))
        os.write(master, b'/exit\n')
        while True:
            if not select.select([master], [], [], 5)[0]:
                break
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            transcript.extend(chunk)
        assert process.wait(timeout=5) == 0, bytes(transcript)
        after = termios.tcgetattr(master)
        pendin = getattr(termios, 'PENDIN', 0)
        assert (after[:3], after[3] & ~pendin, after[4:]) == (before[:3], before[3] & ~pendin, before[4:])
    finally:
        if master != -1:
            os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    reloaded = run_repo_cli(args + ['-p', 'after-compact-reload'], input='', text=True,
                            capture_output=True, env=environment, timeout=20)
    assert reloaded.returncode == 0 and reloaded.stdout == 'after compact reload ok\n', reloaded.stderr


def check_https_proxy(root, environment, server):
    import base64

    expected_proxy_auth = 'Basic ' + base64.b64encode(b'proxyuser:proxypass').decode()
    proxy_events = []

    class ConnectProxy(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_CONNECT(self):
            auth = self.headers.get('Proxy-Authorization')
            if auth != expected_proxy_auth:
                proxy_events.append(('rejected', self.path, auth))
                self.send_response(407)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            host, _, port_str = self.path.rpartition(':')
            port = int(port_str)
            upstream = socket.create_connection((host, port), timeout=10)
            proxy_events.append(('tunneled', self.path))
            self.send_response(200, 'Connection Established')
            self.end_headers()
            self.connection.setblocking(False)
            upstream.setblocking(False)
            try:
                sockets = [self.connection, upstream]
                while sockets:
                    readable, _, _ = select.select(sockets, [], [], 10)
                    if not readable:
                        break
                    for sock in readable:
                        other = upstream if sock is self.connection else self.connection
                        try:
                            data = sock.recv(16384)
                        except (BlockingIOError, ssl.SSLWantReadError):
                            continue
                        except OSError:
                            data = b''
                        if not data:
                            return
                        other.sendall(data)
            finally:
                upstream.close()

    proxy_server = ThreadingHTTPServer(('127.0.0.1', 0), ConnectProxy)
    proxy_server.daemon_threads = True
    proxy_thread = threading.Thread(target=proxy_server.serve_forever, daemon=True)
    proxy_thread.start()
    try:
        # 1. NO_PROXY bypasses unreachable http_proxy and connects directly.
        bypass_cfg = root / 'noproxy.json'
        bypass_cfg.write_text(json.dumps({'providers': {'noproxy': {
            'api': 'openai-completions',
            'baseUrl': f'http://127.0.0.1:{server.server_port}/route/v1',
            'apiKey': 'route-key',
            'models': [{'id': 'bypass-model', 'maxTokens': 1024}],
        }}}))
        server.expected_route_path = '/route/v1/chat/completions'
        server.expected_route_model = 'bypass-model'
        server.expected_route_tokens = 1024
        bypass_env = {k: v for k, v in environment.items()
                      if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
        bypass_env['http_proxy'] = 'http://127.0.0.1:1'
        bypass_env['NO_PROXY'] = '127.0.0.1'
        res = run_repo_cli([str(BINARY), '--models-file', str(bypass_cfg), '--provider', 'noproxy',
                            '--no-session', '--no-tools', '-p', 'bypass'],
                           input='', text=True, capture_output=True, env=bypass_env, timeout=20)
        assert res.returncode == 0 and res.stdout == 'route complete\n', (res.stderr, res.stdout)

        # 2. Bad proxy auth on HTTPS CONNECT fails closed with ProxyConnectFailed.
        bad_proxy_cfg = root / 'badproxy.json'
        bad_proxy_cfg.write_text(json.dumps({'providers': {'badproxy': {
            'api': 'openai-completions',
            'baseUrl': 'https://127.0.0.1:4443/v1',
            'apiKey': 'secret-must-not-leak',
            'models': [{'id': 'm'}],
        }}}))
        bad_env = {k: v for k, v in environment.items()
                   if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
        bad_env['https_proxy'] = f'http://wrong:creds@127.0.0.1:{proxy_server.server_port}'
        rejected = run_repo_cli([str(BINARY), '--models-file', str(bad_proxy_cfg), '--provider', 'badproxy',
                                 '--no-session', '--no-tools', '-p', 'hi'],
                                input='', text=True, capture_output=True, env=bad_env, timeout=20)
        assert rejected.returncode != 0 and 'ProxyConnectFailed' in rejected.stderr, rejected.stderr
        assert ('rejected', '127.0.0.1:4443', 'Basic d3Jvbmc6Y3JlZHM=') in proxy_events, proxy_events

        # 3. End-to-end TLS origin over HTTP CONNECT proxy when openssl is available.
        if shutil.which('openssl'):
            cert_file = root / 'tls-cert.pem'
            key_file = root / 'tls-key.pem'
            subprocess.run([
                'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-keyout', str(key_file), '-out', str(cert_file),
                '-days', '1', '-subj', '/CN=127.0.0.1',
                '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
            ], check=True, capture_output=True, timeout=20)

            class TlsOriginHandler(BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def do_POST(self):
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    assert self.headers.get('Authorization') == 'Bearer tls-proxy-secret'
                    assert self.path in ('/v1/chat/completions', '/v1/responses')
                    if self.path == '/v1/responses':
                        events = [
                            ('response.created', {'response': {'id': 'resp_tls'}}),
                            ('response.output_item.added', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_tls'}}),
                            ('response.output_text.delta', {'output_index': 0, 'delta': 'tls proxy ok'}),
                            ('response.output_item.done', {'output_index': 0, 'item': {'type': 'message', 'id': 'msg_tls', 'content': [{'type': 'output_text', 'text': 'tls proxy ok'}]}}),
                            ('response.completed', {'response': {'id': 'resp_tls', 'status': 'completed', 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}),
                        ]
                        data = ''.join(f'event: {k}\ndata: {json.dumps(dict(p, type=k))}\n\n' for k, p in events).encode()
                    else:
                        chunk = {'choices': [{'index': 0, 'delta': {'content': 'tls proxy ok'}, 'finish_reason': 'stop'}]}
                        data = ('data: ' + json.dumps(chunk) + '\n\ndata: [DONE]\n\n').encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

            tls_origin = ThreadingHTTPServer(('127.0.0.1', 0), TlsOriginHandler)
            tls_origin.daemon_threads = True
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(certfile=str(cert_file), keyfile=str(key_file))
            tls_origin.socket = ctx.wrap_socket(tls_origin.socket, server_side=True)
            tls_thread = threading.Thread(target=tls_origin.serve_forever, daemon=True)
            tls_thread.start()
            try:
                tls_port = tls_origin.server_port
                proxy_env = {k: v for k, v in environment.items()
                             if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
                proxy_env['HTTPS_PROXY'] = f'http://proxyuser:proxypass@127.0.0.1:{proxy_server.server_port}'
                proxy_env['SSL_CERT_FILE'] = str(cert_file)
                for api_name in ('openai-completions', 'openai-responses'):
                    tls_cfg = root / f'tls-{api_name}.json'
                    tls_cfg.write_text(json.dumps({'providers': {'tls-proxied': {
                        'api': api_name,
                        'baseUrl': f'https://127.0.0.1:{tls_port}/v1',
                        'apiKey': 'tls-proxy-secret',
                        'models': [{'id': 'tls-model'}],
                    }}}))
                    tunneled = run_repo_cli([str(BINARY), '--models-file', str(tls_cfg), '--provider', 'tls-proxied',
                                             '--no-session', '--no-tools', '-p', 'through proxy'],
                                            input='', text=True, capture_output=True, env=proxy_env, timeout=20)
                    assert tunneled.returncode == 0 and tunneled.stdout == 'tls proxy ok\n', (api_name, tunneled.stderr, tunneled.stdout)
                assert proxy_events.count(('tunneled', f'127.0.0.1:{tls_port}')) == 2, proxy_events
            finally:
                tls_origin.shutdown()
                tls_origin.server_close()
                tls_thread.join(timeout=2)
    finally:
        proxy_server.shutdown()
        proxy_server.server_close()
        proxy_thread.join(timeout=2)


def check_tree_navigation(root, environment, server):
    config = root / 'tree-models.json'
    config.write_text(json.dumps({'providers': {'tree-fixture': {
        'api': 'openai-completions', 'apiKey': 'tree-fixture-key',
        'baseUrl': f'http://127.0.0.1:{server.server_port}/tree-fixture',
        'models': [{'id': 'tree-model'}],
    }}}))
    skills = root / 'tree-fixture-skill'
    skills.mkdir()
    (skills / 'SKILL.md').write_text('---\nname: tree-fixture-skill\ndescription: Test branch context.\n---\nBody.\n')
    session = root / 'interactive-tree.jsonl'
    def message(entry, parent, role, text, **fields):
        return {'type': 'message', 'id': entry, 'parent_id': parent,
                'version': 2 if fields.get('system_prompt_replace') else 1,
                'message': dict(role=role, content=[{'text': text}], **fields)}

    records = [
        {'type': 'session', 'cwd': str(root)},
        message('1', None, 'system', 'base instructions'),
        message('2', '1', 'user', 'shared request'),
        message('3', '2', 'system', 'destination instructions', system_prompt_replace=True),
        message('4', '3', 'user', 'destination request'),
        message('5', '2', 'system', 'old instructions', system_prompt_replace=True),
        message('6', '5', 'user', 'departed request'),
        {'type': 'message', 'id': '7', 'parent_id': '6', 'message': {
            'role': 'assistant', 'content': [{'tool_call': {
                'id': 'historical', 'name': 'read', 'arguments': {'path': 'example.txt'},
            }}],
        }},
        message('8', '7', 'tool_result', '中文日本語한글', tool_call_id='historical', tool_name='read'),
        message('9', '8', 'assistant', 'departed answer'),
    ]
    before = ''.join(json.dumps(record) + '\n' for record in records).encode()
    session.write_bytes(before)
    args = [str(BINARY), '--no-proxy', '--models-file', str(config), '--provider', 'tree-fixture',
            '--session', str(session), '--no-tools', '--skill', str(skills)]
    server.tree_summary_requests = 0
    master, slave = pty.openpty()

    def resize(rows, cols):
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    resize(12, 70)
    term_before = termios.tcgetattr(slave)
    process = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                               env=dict(environment, TERM='xterm'))
    transcript = bytearray()

    def expect(marker, start=0):
        deadline = time.monotonic() + 10
        while (found := transcript.find(marker, start)) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, (marker, bytes(transcript[start:]), server.failures)
            if select.select([master], [], [], remaining)[0]:
                chunk = os.read(master, 16384)
                assert chunk, (marker, bytes(transcript[start:]))
                transcript.extend(chunk)
        return found + len(marker)

    def command(text, marker):
        start = len(transcript)
        os.write(master, text + b'\n')
        return expect(marker, start)

    try:
        prompt_ready = b'\x1b[?2004h'
        picker_ready = b'Up/Down move  Enter switch  s summarize  Esc cancel'
        assert expect(prompt_ready)
        start = len(transcript)
        command(b'/tr\t', picker_ready)
        assert b'Session tree' in transcript[start:]
        assert b'>*         9 assistant' in transcript[start:]
        assert '中文日本語한글'.encode() in transcript[start:]

        # Redraw at a different width and height while no key is pressed.
        start = len(transcript)
        resize(5, 31)
        frame_end = expect(b'Up/Down Enter Esc', start)
        frame = transcript[start:frame_end].decode()
        assert '8 tool_result  中文\r' in frame, frame
        assert '\x1b[7m>*         9 assistant' in frame, frame
        assert '6 user' not in frame, frame
        start = len(transcript)
        os.write(master, b'\x1b[5~')
        frame_end = expect(b'Up/Down Enter Esc', start)
        selected = transcript[start:frame_end].split(b'\x1b[7m>')[-1].lstrip()
        assert selected.startswith(b'6 user '), selected
        start = len(transcript)
        os.write(master, b'\x1b[6~')
        expect(b'>*         9 assistant', start)
        start = len(transcript)
        os.write(master, b'\x1b[A')
        expect(b'>          8 tool_result', start)
        start = len(transcript)
        os.write(master, b'\x1b[200~\n\x1b[B\x1b[201~\x1b/session\r')
        expect(b'Active entry: 9', start)
        assert session.read_bytes() == before and server.tree_summary_requests == 0

        resize(24, 80)
        command(b'/tree', picker_ready)
        start = len(transcript)
        process.send_signal(signal.SIGINT)
        expect(prompt_ready, start)
        assert session.read_bytes() == before

        command(b'/tree --list', b'Use /tree ENTRY-ID or /tree --summary ENTRY-ID.')
        assert b'Session tree (active: 9)' in transcript and b'* 9 <- 8' in transcript
        command(b'/tree --older 4', b'Use /tree ENTRY-ID or /tree --summary ENTRY-ID.')
        command(b'/tree', picker_ready)
        start = len(transcript)
        os.write(master, b'\x1b[A' * 2 + b'\r')
        expect(b'zpi: IncompleteBranchToolBatch', start)
        assert session.read_bytes() == before
        command(b'/tree', picker_ready)
        start = len(transcript)
        os.write(master, b'\x1b[A' * 5 + b'\r')
        expect(b'[branched to 4]', start)
        assert server.tree_summary_requests == 0
        # Fuzzy filter in /tree and prefill a user message into the editor.
        command(b'/tree', picker_ready)
        start = len(transcript)
        os.write(master, b'/destination')
        expect(b'Filter: \x1b[0mdestination', start)
        expect(b'4 user  destination request', start)
        os.write(master, b'\x1b')
        time.sleep(0.05)
        start = len(transcript)
        os.write(master, b'p')
        expect(b'[branched to 3]', start)
        p_end = expect(b'\x1b[21C', start)
        process.send_signal(signal.SIGINT)
        expect(b'\x1b[?2004h', p_end)
        command(b'/tree 9', b'[branched to 9]')
        switched = session.read_bytes()
        command(b'/tree --summary 4', b'zpi: BranchSummaryFailed')
        assert session.read_bytes() == switched
        assert server.tree_summary_requests == 1
        command(b'/tree --summary 4', b'zpi: BranchSummaryFailed')
        assert session.read_bytes() == switched
        assert server.tree_summary_requests == 2
        command(b'/tree', picker_ready)
        start = len(transcript)
        os.write(master, b'\x1b[A' * 5 + b's')
        confirmation = b'Send departed branch to provider? y/n'
        expect(confirmation, start)
        assert session.read_bytes() == switched and server.tree_summary_requests == 2

        # Enter, arrows, and bracketed paste cannot confirm disclosure.
        start = len(transcript)
        os.write(master, b'\r\x1b[A\x1b[200~y\x1b[201~n')
        frame_end = expect(picker_ready, start)
        selected = transcript[:frame_end].split(b'\x1b[7m>')[-1].lstrip()
        assert selected.startswith(b'4 user '), selected
        assert session.read_bytes() == switched and server.tree_summary_requests == 2

        # A resize that hides the confirmation dismisses it; invoke the picker
        # from a fresh prompt afterward to avoid mixing the resize frame with
        # the active prompt editor's incremental redraw.
        start = len(transcript)
        os.write(master, b's')
        expect(confirmation, start)
        resize(5, 31)
        start = len(transcript)
        os.write(master, b'y')
        expect(b'Up/Down Enter Esc', start)
        assert session.read_bytes() == switched and server.tree_summary_requests == 2
        resize(24, 80)
        start = len(transcript)
        os.write(master, b'\x1b/session\r')
        expect(b'Active entry:', start)

        command(b'/tree', picker_ready)
        start = len(transcript)
        os.write(master, b'\x1b[A' * 5 + b's')
        expect(confirmation, start)
        assert session.read_bytes() == switched and server.tree_summary_requests == 2
        start = len(transcript)
        os.write(master, b'y')
        expect(b'[branched to 4 with summary]', start)
        added = session.read_bytes()[len(switched):].splitlines()
        assert len(added) == 1, added
        summary = json.loads(added[0])
        assert (summary['type'], summary['parent_id'], summary['from_id']) == ('branch_summary', '4', '9'), summary
        assert server.tree_summary_requests == 3
        command(b'tree-live', b'tree-live complete')
        os.write(master, b'/exit\n')
        assert process.wait(timeout=5) == 0, bytes(transcript)
        term_after = termios.tcgetattr(slave)
        term_after[3] &= ~getattr(termios, 'PENDIN', 0)
        term_before[3] &= ~getattr(termios, 'PENDIN', 0)
        assert term_after == term_before
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)
    assert server.tree_summary_requests == 3
    reopened_args = args.copy()
    reopened_args[reopened_args.index('--skill'):reopened_args.index('--skill') + 2] = ['--no-skills']
    resumed = run_cli(reopened_args + ['-p', 'tree-reopen'], input='', text=True,
                      capture_output=True, env=environment, timeout=15)
    assert resumed.returncode == 0 and resumed.stdout == 'tree-reopen complete\n', (resumed, server.failures)


def check_queued_followup_editing(root, environment, server):
    agent_dir = root / 'queue-agent'
    agent_dir.mkdir()
    (agent_dir / 'models.json').write_text(json.dumps({'providers': {'queue-fixture': {
        'api': 'openai-completions',
        'baseUrl': f'http://127.0.0.1:{server.server_port}/queue-fixture',
        'apiKey': 'queue-key',
        'models': [{'id': 'queue-model'}],
    }}}))
    session = root / 'queue-session.jsonl'
    env = dict(environment, PI_CODING_AGENT_DIR=str(agent_dir), TERM='xterm')
    args = [str(BINARY), '--no-proxy', '--provider', 'queue-fixture', '--session', str(session)]

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    term_before = termios.tcgetattr(slave)

    def become_tty_leader():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        args, cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
        close_fds=True, preexec_fn=become_tty_leader,
    )
    os.close(slave)
    transcript = bytearray()

    def expect(marker, start=0):
        deadline = time.monotonic() + 10
        while transcript.find(marker, start) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('queued follow-up PTY timed out', marker, bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('PTY exited early', marker, bytes(transcript[start:]))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)
        return transcript.find(marker, start)

    try:
        prompt_ready = b'\x1b[?2004h'
        expect(prompt_ready)

        # 1. Start a streaming turn; no live prompt overlay renders until user types.
        start = len(transcript)
        os.write(master, b'queue-slow\n')
        end = expect(b'working...', start)
        assert b'> ' not in transcript[start:end + len(b'working...')], transcript[start:]

        # 2. Type a live draft while streaming; mid-stream output preserves the draft cleanly.
        prompt_marker = b'\x1b[36m>\x1b[0m '
        start = len(transcript)
        os.write(master, b'first follow')
        expect(prompt_marker + b'first follow', start)
        start = len(transcript)
        server.queue_stream_mid.set()
        expect(b'working... mid', start)
        expect(prompt_marker + b'first follow', start)

        # 3. Queue two follow-up messages with Enter, then restore with Alt+Up and clear with Esc.
        start = len(transcript)
        os.write(master, b'\r')
        expect(b'[queued 1] first follow', start)
        expect(b'Alt+Up edit queued', start)
        assert server.queue_requests == ['queue-slow'], server.queue_requests

        start = len(transcript)
        os.write(master, b'second follow\r')
        expect(b'[queued 2] second follow', start)

        start = len(transcript)
        os.write(master, b'\x1b[1;3A')
        expect(prompt_marker + b'first follow\r\n  \r\n  second follow', start)

        # Bare Esc clears draft; re-queue two items and leave an unsubmitted draft.
        os.write(master, b'\x1b')
        time.sleep(0.05)
        start = len(transcript)
        os.write(master, b'queued-edited\r')
        expect(b'[queued 1] queued-edited', start)
        start = len(transcript)
        os.write(master, b'queued-beta\r')
        expect(b'[queued 2] queued-beta', start)
        start = len(transcript)
        os.write(master, b'unsubmitted draft')
        expect(prompt_marker + b'unsubmitted draft', start)

        # 4. Finish active turn: queued items drain in order and unsubmitted draft remains editable.
        start = len(transcript)
        server.queue_stream_release.set()
        expect(b'done', start)
        expect(b'queued-edited complete', start)
        expect(b'queued-beta complete', start)
        expect(prompt_marker + b'unsubmitted draft', start)
        assert server.queue_requests == ['queue-slow', 'queued-edited', 'queued-beta'], server.queue_requests

        # 5. Submit the preserved draft from the idle prompt.
        start = len(transcript)
        os.write(master, b'\r')
        expect(b'draft complete', start)
        expect(prompt_ready, start)

        # 6. Canceling a busy turn restores queued follow-ups to the idle prompt without sending them.
        start = len(transcript)
        os.write(master, b'queue-cancel-stream\n')
        expect(b'cancel-partial-', start)
        start = len(transcript)
        os.write(master, b'saved-after-cancel\r')
        expect(b'[queued 1] saved-after-cancel', start)
        start = len(transcript)
        os.write(master, b'\x03')
        expect(b'zpi: Canceled', start)
        expect(prompt_marker + b'saved-after-cancel', start)
        server.queue_cancel_release.set()
        assert server.queue_requests == [
            'queue-slow', 'queued-edited', 'queued-beta', 'unsubmitted draft', 'queue-cancel-stream',
        ], server.queue_requests

        # Discard restored draft with Ctrl-C, then verify mid-turn Ctrl+S steering skips remaining tool calls.
        start = len(transcript)
        os.write(master, b'\x03')
        expect(prompt_ready, start)
        start = len(transcript)
        os.write(master, b'steer-batch\n')
        expect(b'steer-step1', start)
        os.write(master, b'steer redirect\x13')
        expect(b'steered ok', start)
        expect(prompt_ready, start)
        assert not (root / 'steer-skipped.txt').exists(), 'second tool call was not skipped by steering'

        os.write(master, b'/exit\n')
        while True:
            if not select.select([master], [], [], 5)[0]:
                break
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            transcript.extend(chunk)
        assert process.wait(timeout=5) == 0, bytes(transcript)
        term_after = termios.tcgetattr(master)
        term_after[3] &= ~getattr(termios, 'PENDIN', 0)
        term_before[3] &= ~getattr(termios, 'PENDIN', 0)
        assert term_after == term_before
    finally:
        server.queue_stream_mid.set()
        server.queue_stream_release.set()
        server.queue_cancel_release.set()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)


def check_tui_components(root, environment, server):
    comp_dir = root / 'comp-work'
    comp_dir.mkdir()
    (comp_dir / '.git').mkdir()
    (comp_dir / '.git' / 'HEAD').write_text('ref: refs/heads/feat/tui-test\n')
    (comp_dir / 'comp.txt').write_text('line1\nold\nline3\n')
    agent_dir = root / 'comp-agent'
    agent_dir.mkdir()
    (agent_dir / 'models.json').write_text(json.dumps({'providers': {'comp-fixture': {
        'api': 'openai-completions',
        'baseUrl': f'http://127.0.0.1:{server.server_port}/comp-fixture',
        'apiKey': 'comp-key',
        'models': [{'id': 'comp-model', 'contextWindow': 10000}],
    }}}))
    (agent_dir / 'settings.json').write_text(json.dumps({
        'defaultProvider': 'comp-fixture',
        'defaultModel': 'comp-model',
        'defaultThinkingLevel': 'medium',
        'quietStartup': True,
    }))
    env = dict(environment, PI_CODING_AGENT_DIR=str(agent_dir), TERM='xterm-256color', COLORTERM='truecolor')
    env.pop('NO_COLOR', None)
    args = [str(BINARY), '--no-proxy', '--no-session', '--cwd', str(comp_dir)]

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    term_before = termios.tcgetattr(slave)

    def become_tty_leader():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        args, cwd=comp_dir, env=env, stdin=slave, stdout=slave, stderr=slave,
        close_fds=True, preexec_fn=become_tty_leader,
    )
    os.close(slave)
    transcript = bytearray()

    def expect(marker, start=0):
        deadline = time.monotonic() + 10
        while transcript.find(marker, start) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('TUI components PTY timed out', marker, bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('PTY exited early', marker, bytes(transcript[start:]))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)
        return transcript.find(marker, start)

    try:
        # 1. Idle double-rule editor + 2-line Footer shows cwd (branch), provider/model, thinking level, and context window.
        expect('─'.encode('utf-8') * 16)
        expect(b'comp-work (feat/tui-test)')
        expect(b'comp-fixture/comp-model (medium)')
        expect(b'/10k (')

        # 2. Submit turn: Loader, ThinkingBlock, ToolCard (+ arg header) + DiffView, MarkdownStyler, and updated Footer render.
        start = len(transcript)
        os.write(master, b'update comp\n')
        expect(b'Thinking...', start)
        expect(b'checking file', start)
        expect(b'\xe2\x95\xad\xe2\x94\x80 ', start)
        expect(b'[tool: edit]', start)
        expect(b'comp.txt', start)
        expect(b'-2 old', start)
        expect(b'+2 new', start)
        expect(b'\xe2\x95\xb0\xe2\x94\x80 ', start)
        expect(b'\xe2\x9c\x93', start)
        expect(b'\x1b[1;38;2;103;212;242m## Summary\x1b[0m', start)
        expect(b'\xe2\x80\xa2 ', start)
        expect(b'const ok = true;', start)
        expect(b'comp-fixture/comp-model (medium)', len(transcript) - 256 if len(transcript) > 256 else 0)
        assert b'\x1b[?1049h' not in transcript, 'alt-screen triggered'
        assert (comp_dir / 'comp.txt').read_text() == 'line1\nnew\nline3\n'

        # 2b. Live bash tool_update streaming + Ctrl+O compact/expanded toggle.
        start = len(transcript)
        os.write(master, b'stream-bash\n')
        expect(b'[tool: bash]', start)
        expect(b'B1', start)
        expect(b'Ctrl+O to expand', start)
        done1 = expect(b'bash stream done', start)
        expect(b'\x1b[?2004h', done1)

        mark_o = len(transcript)
        os.write(master, b'\x0f')
        expect(b'expanded', mark_o)
        start = len(transcript)
        os.write(master, b'stream-bash\n')
        expect(b'B12', start)
        done2 = expect(b'bash stream done', start)
        expect(b'\x1b[?2004h', done2)
        assert b'Ctrl+O to expand' not in transcript[start:], transcript[start:]
        os.write(master, b'\x0f')
        time.sleep(0.08)

        # 2c. Shift+Tab cycles thinking_level (medium -> high), Markdown wraps at 80 cols, and live usage updates Footer warning color.
        shift_mark = len(transcript)
        os.write(master, b'\x1b[Z')
        expect(b'comp-fixture/comp-model (high)', shift_mark)
        wrap_mark = len(transcript)
        os.write(master, b'wrap-and-usage\n')
        wrap_end = expect(b'wrapend', wrap_mark)
        assert b'\nword' in transcript[wrap_mark:wrap_end + 16] or b'\r\nword' in transcript[wrap_mark:wrap_end + 16], transcript[wrap_mark:wrap_end + 16]
        expect(b'\xe2\x86\x917.5k \xe2\x86\x93500', wrap_mark)
        expect(b'\x1b[38;2;229;192;123m8k/10k (80%)\x1b[0m', wrap_mark)

        # Resize PTY to 60 cols and type a key to verify clean rule/footer adaptation.
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 60, 0, 0))
        resize_mark = len(transcript)
        os.write(master, b'x\x7f')
        expect('─'.encode('utf-8') * 59, resize_mark)
        assert ('─'.encode('utf-8') * 60) not in transcript[resize_mark:], transcript[resize_mark:]

        # 2d. Automatic / and @ autocomplete popup below editor + Down/Esc/Tab interaction.
        slash_mark = len(transcript)
        os.write(master, b'/')
        expect(b'/help', slash_mark)
        expect(b'/hotkeys', slash_mark)
        down_mark = len(transcript)
        os.write(master, b'\x1b[B')
        expect(b'\xe2\x96\xb8 ', down_mark)  # ▸ highlight indicator
        os.write(master, b'\x1b')  # Esc dismisses popup while keeping '/'
        time.sleep(0.06)
        os.write(master, b'\x15')  # Ctrl-U clears '/'
        at_mark = len(transcript)
        os.write(master, b'@c')
        expect(b'@comp.txt', at_mark)
        os.write(master, b'\t\x15')  # Tab accepts @comp.txt, Ctrl-U clears line

        os.write(master, b'/exit\n')
        while True:
            if not select.select([master], [], [], 5)[0]:
                break
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            transcript.extend(chunk)
        assert process.wait(timeout=5) == 0, bytes(transcript)
        term_after = termios.tcgetattr(master)
        term_after[3] &= ~getattr(termios, 'PENDIN', 0)
        term_before[3] &= ~getattr(termios, 'PENDIN', 0)
        assert term_after == term_before
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)

    # 3. Verify NO_COLOR suppresses ANSI styling in interactive mode.
    (comp_dir / 'comp.txt').write_text('line1\nold\nline3\n')
    no_color_env = dict(env, NO_COLOR='1')
    master2, slave2 = pty.openpty()
    proc2 = subprocess.Popen(args, cwd=comp_dir, env=no_color_env, stdin=slave2, stdout=slave2, stderr=slave2, close_fds=True)
    os.close(slave2)
    t2 = bytearray()
    try:
        deadline = time.monotonic() + 10
        while b'comp-fixture/comp-model' not in t2 and b'> ' not in t2:
            if select.select([master2], [], [], 0.2)[0]:
                t2.extend(os.read(master2, 16384))
            assert time.monotonic() < deadline, bytes(t2)
        mark = len(t2)
        os.write(master2, b'update comp\n')
        while b'const ok = true;' not in t2[mark:]:
            if select.select([master2], [], [], 0.2)[0]:
                t2.extend(os.read(master2, 16384))
            assert time.monotonic() < deadline, bytes(t2)
        assert b'\x1b[38;' not in t2[mark:] and b'\x1b[32m' not in t2[mark:] and b'\x1b[36m' not in t2, bytes(t2)
        os.write(master2, b'/exit\n')
        assert proc2.wait(timeout=5) == 0
    finally:
        if proc2.poll() is None:
            proc2.kill()
            proc2.wait(timeout=5)
        os.close(master2)

    # 4. Verify TERM=dumb falls back to plain-text lists for /model and /tree.
    dumb_env = dict(env, TERM='dumb')
    master3, slave3 = pty.openpty()
    proc3 = subprocess.Popen(args, cwd=comp_dir, env=dumb_env, stdin=slave3, stdout=slave3, stderr=slave3, close_fds=True)
    os.close(slave3)
    t3 = bytearray()
    try:
        deadline = time.monotonic() + 10
        while b'> ' not in t3:
            if select.select([master3], [], [], 0.2)[0]:
                t3.extend(os.read(master3, 16384))
            assert time.monotonic() < deadline, bytes(t3)
        os.write(master3, b'/model\n')
        while b'Active: comp-fixture/comp-model' not in t3:
            if select.select([master3], [], [], 0.2)[0]:
                t3.extend(os.read(master3, 16384))
            assert time.monotonic() < deadline, bytes(t3)
        os.write(master3, b'/tree\n')
        while b'Session tree (active:' not in t3:
            if select.select([master3], [], [], 0.2)[0]:
                t3.extend(os.read(master3, 16384))
            assert time.monotonic() < deadline, bytes(t3)
        assert b'Type to filter' not in t3 and b'Up/Down move' not in t3, bytes(t3)
        os.write(master3, b'/exit\n')
        assert proc3.wait(timeout=5) == 0
    finally:
        if proc3.poll() is None:
            proc3.kill()
            proc3.wait(timeout=5)
        os.close(master3)


def check_settings_and_model_switch(root, environment, server):
    agent_dir = root / 'settings-agent'
    agent_dir.mkdir()
    sessions_dir = root / 'settings-sessions'
    (agent_dir / 'models.json').write_text(json.dumps({'providers': {
        'settings-chat': {
            'api': 'openai-completions',
            'baseUrl': f'http://127.0.0.1:{server.server_port}/settings-switch/v1',
            'apiKey': 'settings-key',
            'models': [{'id': 'chat-m'}],
        },
        'settings-resp': {
            'api': 'openai-responses',
            'baseUrl': f'http://127.0.0.1:{server.server_port}/settings-switch/v1',
            'apiKey': 'settings-key',
            'models': [{'id': 'gpt-5'}],
        },
    }}))
    (agent_dir / 'settings.json').write_text(json.dumps({
        'defaultProvider': 'settings-chat',
        'defaultModel': 'chat-m',
        'defaultThinkingLevel': 'medium',
        'defaultTools': ['-bash', '+grep'],
        'sessionDir': str(sessions_dir),
        'quietStartup': True,
        'compaction': {'enabled': True, 'reserveTokens': 12000, 'keepRecentTokens': 8000},
        'retry': {'enabled': True, 'maxRetries': 2, 'baseDelayMs': 100, 'maxAgentDelayMs': 5000},
    }))
    env = dict(environment, PI_CODING_AGENT_DIR=str(agent_dir))
    res = run_repo_cli([str(BINARY), '--no-proxy', '-p', 'settings-check'],
                       input='', text=True, capture_output=True, env=env, timeout=20)
    assert res.returncode == 0 and res.stdout == 'settings ok\n', (res.stderr, res.stdout)
    assert len(list(sessions_dir.glob('*.jsonl'))) == 1

    overridden = run_repo_cli([str(BINARY), '--no-proxy', '--no-session', '--thinking', 'low', '-p', 'thinking-override'],
                              input='', text=True, capture_output=True, env=env, timeout=20)
    assert overridden.returncode == 0 and overridden.stdout == 'thinking override ok\n', overridden.stderr

    # Exercise quietStartup, /model listing, /model switching to openai-responses:high, and /thinking minimal in a PTY.
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    transcript = bytearray()
    process = subprocess.Popen(
        [str(BINARY), '--no-proxy', '--no-session'],
        cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
    )
    os.close(slave)

    def read_until(marker, start=0):
        deadline = time.monotonic() + 10
        while transcript.find(marker, start) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('settings PTY timed out', marker, bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', marker, bytes(transcript))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)
        return transcript.find(marker, start)

    def read_prompt(start=0):
        deadline = time.monotonic() + 10
        while True:
            for marker in (b'>\x1b[0m ', b'> '):
                pos = transcript.find(marker, start)
                if pos != -1:
                    return pos + len(marker)
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('settings PTY prompt timed out', bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(('terminal exited early', bytes(transcript[start:]))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)

    try:
        p = read_prompt()
        assert b'Ctrl-D exits' not in transcript, bytes(transcript)
        os.write(master, b'/model --list\n')
        p = read_prompt(read_until(b'settings-resp/gpt-5', p))
        # Interactive /model fuzzy SelectList: filter, Esc cancel, then filter + Enter switch.
        mark = p
        os.write(master, b'/model\n')
        read_until(b'Type to filter', mark)
        os.write(master, b'gpt5')
        filter_pos = read_until(b'settings-resp/gpt-5', mark)
        os.write(master, b'\x1b')
        time.sleep(0.08)
        os.write(master, b'\x1b')
        cancel_pos = read_until(b'\x1b[?2004h', filter_pos) + len(b'\x1b[?2004h')
        assert b'\r\x1b[J' in transcript[filter_pos:cancel_pos], bytes(transcript[filter_pos:cancel_pos])
        p = read_prompt(cancel_pos)
        mark = p
        os.write(master, b'/model\n')
        read_until(b'Type to filter', mark)
        os.write(master, b'gpt5\r')
        switched_pos = read_until(b'[model: settings-resp/gpt-5 (openai_responses), thinking: medium]', mark)
        assert b'\r\x1b[J' in transcript[mark:switched_pos], bytes(transcript[mark:switched_pos])
        p = read_prompt(switched_pos)
        os.write(master, b'/model settings-resp/gpt-5:high\n')
        p = read_prompt(read_until(b'[model: settings-resp/gpt-5 (openai_responses), thinking: high]', p))
        os.write(master, b'switched-turn\n')
        p = read_prompt(read_until(b'switched model ok', p))
        os.write(master, b'/thinking minimal\n')
        p = read_prompt(read_until(b'[thinking: minimal]', p))
        os.write(master, b'thinking-turn\n')
        p = read_prompt(read_until(b'switched thinking ok', p))
        os.write(master, b'/exit\n')
        while True:
            if not select.select([master], [], [], 5)[0]:
                break
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            transcript.extend(chunk)
        assert process.wait(timeout=5) == 0, bytes(transcript)
        after = termios.tcgetattr(master)
        pendin = getattr(termios, 'PENDIN', 0)
        assert (after[:3], after[3] & ~pendin, after[4:]) == (before[:3], before[3] & ~pendin, before[4:])
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def check_resume_picker(root, environment):
    resume_work = root / 'resume-work'
    resume_work.mkdir()
    sessions_dir = root / 'resume-sessions'
    sessions_dir.mkdir()
    alpha = sessions_dir / 'alpha-session.jsonl'
    beta = sessions_dir / 'beta-session.jsonl'
    empty_sys = sessions_dir / 'empty-session.jsonl'

    def write_session(path, user_text, assistant_text):
        records = [
            {'type': 'session', 'version': 1, 'format': 'zpi', 'cwd': str(resume_work)},
            {'type': 'message', 'id': '1', 'parent_id': None, 'version': 1,
             'message': {'role': 'system', 'content': [{'text': 'sys'}]}},
            {'type': 'message', 'id': '2', 'parent_id': '1', 'version': 1,
             'message': {'role': 'user', 'content': [{'text': user_text}]}},
            {'type': 'message', 'id': '3', 'parent_id': '2', 'version': 1,
             'message': {'role': 'assistant', 'content': [{'text': assistant_text}]}},
        ]
        path.write_text(''.join(json.dumps(r) + '\n' for r in records))

    write_session(alpha, 'first task alpha', 'alpha answer')
    write_session(beta, 'second task beta', 'beta answer')
    empty_sys.write_text(''.join(json.dumps(r) + '\n' for r in [
        {'type': 'session', 'version': 1, 'format': 'zpi', 'cwd': str(resume_work)},
        {'type': 'message', 'id': '1', 'parent_id': None, 'version': 1,
         'message': {'role': 'system', 'content': [{'text': 'sys only'}]}},
    ]))
    os.utime(alpha, (1000, 1000))
    os.utime(beta, (2000, 2000))
    os.utime(empty_sys, (3000, 3000))

    env = dict(environment, TERM='xterm-256color', PI_CODING_AGENT_SESSION_DIR=str(sessions_dir))
    env.pop('NO_COLOR', None)
    args = [str(BINARY), '--no-proxy', '--cwd', str(resume_work), '--session', str(alpha)]

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    before = termios.tcgetattr(slave)
    process = subprocess.Popen(args, cwd=resume_work, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    transcript = bytearray()

    def expect(marker, start=0):
        deadline = time.monotonic() + 10
        while transcript.find(marker, start) == -1:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('resume PTY timed out', marker, bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            chunk = os.read(master, 16384)
            assert chunk, bytes(transcript)
            transcript.extend(chunk)
        return transcript.find(marker, start)

    try:
        expect(b'\x1b[?2004h')
        s = len(transcript)
        os.write(master, b'/resume --list\n')
        expect(b'beta-session.jsonl', s)
        expect(b'second task beta', s)
        expect(b'alpha-session.jsonl', s)
        assert b'empty-session.jsonl' not in transcript[s:], bytes(transcript[s:])

        # Interactive fuzzy SelectList /resume picker: filter to beta and select.
        s2 = len(transcript)
        os.write(master, b'/resume\n')
        expect(b'Type to filter', s2)
        os.write(master, b'beta')
        filt_pos = expect(b'beta-session.jsonl', s2)
        os.write(master, b'\r')
        resumed_pos = expect(b'[resumed: beta-session.jsonl]', filt_pos)
        assert b'\r\x1b[J' in transcript[filt_pos:resumed_pos], bytes(transcript[filt_pos:resumed_pos])

        # /session reflects switched session file and counts.
        s3 = len(transcript)
        os.write(master, b'/session\n')
        expect(str(beta).encode(), s3)
        expect(b'Messages: 2 total (1 user, 1 assistant)', s3)

        os.write(master, b'/exit\n')
        while True:
            if not select.select([master], [], [], 5)[0]:
                break
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            transcript.extend(chunk)
        assert process.wait(timeout=5) == 0, bytes(transcript)
        after = termios.tcgetattr(master)
        pendin = getattr(termios, 'PENDIN', 0)
        assert (after[:3], after[3] & ~pendin, after[4:]) == (before[:3], before[3] & ~pendin, before[4:])
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    # TERM=dumb falls back to plain-text /resume listing without SelectList chrome.
    dumb_env = dict(env, TERM='dumb')
    m2, s2_fd = pty.openpty()
    p2 = subprocess.Popen(args, cwd=resume_work, env=dumb_env, stdin=s2_fd, stdout=s2_fd, stderr=s2_fd, close_fds=True)
    os.close(s2_fd)
    t2 = bytearray()
    try:
        dl = time.monotonic() + 10
        while b'> ' not in t2:
            if select.select([m2], [], [], 0.2)[0]:
                t2.extend(os.read(m2, 16384))
            assert time.monotonic() < dl, bytes(t2)
        os.write(m2, b'/resume\n')
        while b'beta-session.jsonl' not in t2:
            if select.select([m2], [], [], 0.2)[0]:
                t2.extend(os.read(m2, 16384))
            assert time.monotonic() < dl, bytes(t2)
        assert b'Type to filter' not in t2, bytes(t2)
        os.write(m2, b'/h\x15')
        time.sleep(0.05)
        assert b'Show keyboard shortcuts' not in t2 and '─'.encode('utf-8') * 8 not in t2, bytes(t2)
        os.write(m2, b'/exit\n')
        while True:
            if not select.select([m2], [], [], 5)[0]:
                break
            try:
                chunk = os.read(m2, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            t2.extend(chunk)
        assert p2.wait(timeout=5) == 0, bytes(t2)
    finally:
        os.close(m2)
        if p2.poll() is None:
            p2.kill()
            p2.wait(timeout=5)

    # Exiting interactive mode without sending a prompt creates no .jsonl file.
    lazy_dir = root / 'lazy-sessions'
    lazy_dir.mkdir()
    lazy_env = dict(env, PI_CODING_AGENT_SESSION_DIR=str(lazy_dir))
    lazy_args = [str(BINARY), '--no-proxy', '--cwd', str(resume_work)]
    m3, s3_fd = pty.openpty()
    p3 = subprocess.Popen(lazy_args, cwd=resume_work, env=lazy_env, stdin=s3_fd, stdout=s3_fd, stderr=s3_fd, close_fds=True)
    os.close(s3_fd)
    t3 = bytearray()
    try:
        dl = time.monotonic() + 10
        while b'\x1b[?2004h' not in t3:
            if select.select([m3], [], [], 0.2)[0]:
                t3.extend(os.read(m3, 16384))
            assert time.monotonic() < dl, bytes(t3)
        os.write(m3, b'/exit\n')
        while True:
            if not select.select([m3], [], [], 5)[0]:
                break
            try:
                chunk = os.read(m3, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            t3.extend(chunk)
        assert p3.wait(timeout=5) == 0, bytes(t3)
    finally:
        os.close(m3)
        if p3.poll() is None:
            p3.kill()
            p3.wait(timeout=5)
    assert list(lazy_dir.glob('*.jsonl')) == [], list(lazy_dir.glob('*.jsonl'))


def check_pi_import(root, resume_args, environment, server):
    project = root / 'pi-import-project'
    project.mkdir()
    source = root / 'pi-source.jsonl'
    target = root / 'pi-converted.jsonl'
    stamp = '2025-01-01T00:00:00.000Z'
    millis = 1735689600000

    def entry(kind, entry_id, parent, **fields):
        return {'type': kind, 'id': entry_id, 'parentId': parent, 'timestamp': stamp, **fields}

    def message(entry_id, parent, role, content, **fields):
        return entry('message', entry_id, parent, message={
            'role': role, 'content': content, 'timestamp': millis, **fields,
        })

    def text(value):
        return {'type': 'text', 'text': value}

    assistant_metadata = {
        'api': 'openai-completions', 'provider': 'openai', 'model': 'original-model',
        'usage': {'input': 3, 'output': 2, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 5,
                  'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0, 'total': 0}},
    }
    records = [
        {'type': 'session', 'version': 3, 'id': 'original', 'timestamp': stamp, 'cwd': str(project)},
        message('sys', None, 'system', 'Imported prompt',
                sections={'project': 'Project section', '2': 'Second section', '1': 'First section', 'empty': None},
                toolsAdded=[{'name': 'pi_fixture_only', 'description': 'Ignored declaration', 'parameters': {}}]),
        message('user', 'sys', 'user', [text('Imported'), text('request')]),
        message('call', 'user', 'assistant', [{'type': 'toolCall', 'id': 'pi-write', 'name': 'write', 'arguments': {
            'path': 'import-must-not-write.txt', 'content': 'historical', 'exact': 18446744073709551616,
        }}], stopReason='toolUse', thinkingLevel='off', **assistant_metadata),
        entry('branch_summary', 'empty-summary', 'call', fromId='user', summary=''),
        message('result', 'empty-summary', 'toolResult', [text('previous write failed')],
                toolCallId='pi-write', toolName='write', isError=True, details={'fixture': True}),
        message('reply', 'result', 'assistant', [text('Imported reply')], stopReason='stop', thinkingLevel='off', **assistant_metadata),
        message('other', 'user', 'user', 'Abandoned branch'),
        entry('context_edit', 'inactive-edit', 'other', targetId='user', replacement={'content': 'Inactive edit'}),
        message('discard', 'reply', 'user', 'Omitted from context'),
        entry('label', 'last', 'discard', targetId='user', label='Main branch'),
        entry('context_edit', 'first-edit', 'last', targetId='user', replacement={'content': [text('Superseded edit')]}),
        entry('context_edit', 'edit-user', 'first-edit', targetId='user', replacement={'content': [text('Edited request')]}),
        entry('context_edit', 'edit-result', 'edit-user', targetId='result', replacement={'content': [text('edited write output')]}),
        entry('context_edit', 'edit-answer', 'edit-result', targetId='reply', replacement={'content': [text('Edited answer')]}),
        entry('context_edit', 'omit-user', 'edit-answer', targetId='discard', replacement=None),
        entry('custom_message', 'custom', 'omit-user', customType='fixture',
              content=[text('Original custom text')], display=False, details={'internal': 'extension state'}),
        entry('context_edit', 'omit-custom-temporarily', 'custom', targetId='custom', replacement=None),
        entry('context_edit', 'superseded-custom-edit', 'omit-custom-temporarily', targetId='custom',
              replacement={'content': [{'type': 'image', 'mimeType': 'image/png', 'data': 'AA=='}]}),
        entry('context_edit', 'restore-custom', 'superseded-custom-edit', targetId='custom',
              replacement={'content': 'Edited custom text'}),
        entry('custom_message', 'custom-omit', 'restore-custom', customType='fixture',
              content='Omitted custom text', display=True),
        entry('context_edit', 'omit-custom', 'custom-omit', targetId='custom-omit', replacement=None),
        message('legacy-custom', 'omit-custom', 'custom', [text('Legacy'), text('custom text')],
                customType='fixture', display=True),
        entry('custom', 'state-only', 'legacy-custom', customType='fixture', data={'not': 'prompt text'}),
        entry('branch_summary', 'branch-summary', 'state-only', fromId='inactive-edit',
              summary='Earlier path exploration', details={'summary_metadata': True}),
    ]

    def encode(entries):
        return ('\n'.join(map(json.dumps, entries)) + '\n').encode()

    original = encode(records)
    source.write_bytes(original)
    import_environment = {'PATH': os.environ['PATH'], 'ZPI_MODELS_FILE': str(root / 'missing-models.json')}

    def run_import(src, dst, *extra):
        return run_cli([str(BINARY), '--import-pi-session', src, '--session', dst, *extra],
                              cwd=root, input='ignored stdin', text=True, capture_output=True,
                              env=import_environment, timeout=10)

    imported = run_import(source.name, target.name)
    assert (imported.returncode, imported.stdout, imported.stderr) == (0, '', ''), imported
    assert source.read_bytes() == original
    saved = target.read_bytes()
    converted = list(map(json.loads, saved.splitlines()))
    assert converted[0] == {'type': 'session', 'version': 1, 'format': 'zpi', 'cwd': str(project)}, converted[0]
    assert [r['message']['role'] for r in converted[1:]] == [
        'system', 'user', 'assistant', 'tool_result', 'assistant', 'user', 'user', 'user',
    ]
    assert converted[4]['message']['is_error'] is True and converted[4]['message']['details'] == {'fixture': True}
    assert converted[2]['message']['content'] == [{'text': 'Edited request'}]
    assert converted[4]['message']['content'] == [{'text': 'edited write output'}]
    assert converted[5]['message']['content'] == [{'text': 'Edited answer'}]
    assert converted[6]['message']['content'] == [{'text': 'Edited custom text'}]
    assert 'details' not in converted[6]['message']
    assert converted[7]['message']['content'] == [{'text': 'Legacy\ncustom text'}]
    assert converted[8]['message']['content'] == [{
        'text': 'The following is a summary of a branch that this conversation came back from:\n\n'
                '<summary>\nEarlier path exploration</summary>'
    }]
    assert len(converted) == 9, converted
    assert target.stat().st_mode & 0o077 == 0

    def compare_with_pi(pi_source, zpi_target):
        parity_sdk = environment.get('ZPI_PI_SESSION_SDK') or environment.get('ZPI_PI_SDK')
        if parity_sdk:
            parity_environment = dict(import_environment, ZPI_PI_SESSION_SDK=parity_sdk)
            parity = subprocess.run(
                ['node', str(ROOT / 'scripts/test-pi-session-parity.mjs'), str(pi_source), str(zpi_target)],
                text=True, capture_output=True, env=parity_environment, timeout=15,
            )
            assert parity.returncode == 0, parity.stderr
            print(parity.stdout.strip())

    compare_with_pi(source, target)
    refused = run_import(source.name, target.name)
    assert refused.returncode != 0 and 'PathAlreadyExists' in refused.stderr, refused
    assert target.read_bytes() == saved
    refused = run_import(source.name, source.name)
    assert refused.returncode != 0 and 'PathAlreadyExists' in refused.stderr, refused
    assert source.read_bytes() == original

    absent = root / 'pi-import-rejected.jsonl'
    refused = run_import(source.name, absent.name, '--no-tools')
    assert refused.returncode != 0 and 'InvalidPiSessionImportArguments' in refused.stderr, refused
    assert not absent.exists()
    link = root / 'pi-import-link.jsonl'
    link.symlink_to(source.name)
    refused = run_import(link.name, absent.name)
    assert refused.returncode != 0 and 'PiSessionNotRegularFile' in refused.stderr, refused
    refused = run_import(source.name, link.name)
    assert refused.returncode != 0 and 'PathAlreadyExists' in refused.stderr, refused
    assert link.is_symlink() and source.read_bytes() == original

    bad_source = root / 'pi-import-invalid.jsonl'
    tip = records[-1]['id']
    for tail, expected in [
        (entry('context_edit', 'wrong-branch', tip, targetId='other', replacement=None), 'UnsupportedPiContextEdit'),
        (entry('context_edit', 'orphan', tip, targetId='missing', replacement=None), 'UnsupportedPiContextEdit'),
        (entry('context_edit', 'bad-shape', tip, targetId='user', replacement='Invalid replacement'), 'InvalidPiContextEdit'),
        (entry('context_edit', 'drop-result', tip, targetId='result', replacement=None), 'UnsupportedPiToolHistory'),
        (entry('context_edit', 'replace-call', tip, targetId='call', replacement={'content': 'No call'}), 'UnsupportedPiContextEdit'),
        (message('image', tip, 'user', [{'type': 'image', 'mimeType': 'image/png', 'data': 'AA=='}]),
         'UnsupportedPiSessionContent'),
        (entry('custom_message', 'custom-image', tip, customType='fixture', display=False,
               content=[{'type': 'image', 'mimeType': 'image/png', 'data': 'AA=='}]), 'UnsupportedPiSessionContent'),
        (entry('custom_message', 'interleaved-custom', 'call', customType='fixture', display=True,
               content='Tool still pending'), 'UnsupportedPiToolHistory'),
        (entry('branch_summary', 'interleaved-summary', 'call', fromId='user', summary='Cannot split calls'),
         'UnsupportedPiToolHistory'),
        (entry('branch_summary', 'invalid-summary', tip, fromId='inactive-edit', summary=[]),
         'InvalidPiSessionRecord'),
        (entry('context_edit', 'edit-summary', tip, targetId='branch-summary', replacement=None),
         'UnsupportedPiContextEdit'),
        (message('late', tip, 'system', 'Change instructions'), 'UnsupportedPiSystemUpdate'),
    ]:
        bad_source.write_bytes(encode(records + [tail]))
        refused = run_import(bad_source.name, absent.name)
        assert refused.returncode != 0 and expected in refused.stderr, refused
        assert not absent.exists()
    bad_source.write_bytes(encode(records[:4]))
    refused = run_import(bad_source.name, absent.name)
    assert refused.returncode != 0 and 'UnsupportedPiToolHistory' in refused.stderr, refused
    assert not absent.exists()

    resumed = run_cli(resume_args + ['--no-tools', '--session', str(target), '-p', 'pi-import-resume'],
                             cwd=root, input='', text=True, capture_output=True, env=environment, timeout=20)
    assert resumed.returncode == 0 and resumed.stdout == 'import resumed\n', (resumed, server.failures)
    assert target.read_bytes().startswith(saved)
    assert not (project / 'import-must-not-write.txt').exists()
    assert not (root / 'import-must-not-write.txt').exists()
    assert source.read_bytes() == original

    compacted_source = root / 'pi-compacted.jsonl'
    compacted_target = root / 'zpi-compacted.jsonl'
    compacted_records = [
        *records[:2],
        entry('context_edit', 'obsolete-edit', 'sys', targetId='missing', replacement=None),
        message('old-image', 'obsolete-edit', 'user', [{'type': 'image', 'mimeType': 'image/png', 'data': 'AA=='}]),
        message('old-system', 'old-image', 'system', 'Old instructions'),
        message('kept', 'old-system', 'user', 'Before edit'),
        entry('compaction', 'older-cut', 'kept', firstKeptEntryId='kept', summary='Obsolete summary', tokensBefore=100),
        message('older-retained', 'older-cut', 'user', 'Older retained message'),
        message('superseded-system', 'older-retained', 'system', 'Superseded system text'),
        message('kept-answer', 'superseded-system', 'assistant', [text('Retained answer')],
                stopReason='stop', **assistant_metadata),
        entry('context_edit', 'kept-edit', 'kept-answer', targetId='kept', replacement={'content': 'Edited retained request'}),
        entry('compaction', 'latest-cut', 'kept-edit', firstKeptEntryId='kept', summary='Latest summary', tokensBefore=200,
              systemMessage={'role': 'system', 'content': 'Current checkpoint', 'sections': {'project': 'Project rules'},
                             'timestamp': millis}),
        message('new-user', 'latest-cut', 'user', 'After compaction'),
        entry('context_edit', 'edit-dropped', 'new-user', targetId='old-image', replacement=None),
    ]
    snapshot = encode(compacted_records)
    compacted_source.write_bytes(snapshot)
    imported = run_import(compacted_source.name, compacted_target.name)
    assert (imported.returncode, imported.stdout, imported.stderr) == (0, '', ''), imported
    compare_with_pi(compacted_source, compacted_target)
    compacted_saved = compacted_target.read_bytes()
    resumed = run_cli(resume_args + ['--no-tools', '--session', str(compacted_target), '-p', 'pi-compaction-resume'],
                             cwd=root, input='', text=True, capture_output=True, env=environment, timeout=20)
    assert (resumed.returncode, resumed.stdout) == (0, 'compacted import resumed\n'), (resumed, server.failures)
    assert compacted_target.read_bytes().startswith(compacted_saved)
    assert compacted_source.read_bytes() == snapshot

    bad_cut = entry('compaction', 'bad-cut', 'reply', firstKeptEntryId='missing',
                    summary='Invalid range', tokensBefore=100)
    bad_source.write_bytes(encode(records + [bad_cut, message('after-bad-cut', 'bad-cut', 'user', 'After bad cut')]))
    refused = run_import(bad_source.name, absent.name)
    assert refused.returncode != 0 and 'InvalidPiCompactionRange' in refused.stderr, refused
    assert not absent.exists()

    cut_batch = entry('compaction', 'cut-batch', 'call', firstKeptEntryId='call',
                      summary='Cuts away a required result', tokensBefore=100)
    bad_source.write_bytes(encode(records + [cut_batch]))
    refused = run_import(bad_source.name, absent.name)
    assert refused.returncode != 0 and 'UnsupportedPiToolHistory' in refused.stderr, refused
    assert not absent.exists()

    retain_none = entry('compaction', 'retain-none', 'reply', firstKeptEntryId='retain-none',
                        summary='No retained entries', tokensBefore=100,
                        systemMessage={'role': 'system', 'content': 'Compact checkpoint', 'timestamp': millis})
    bad_source.write_bytes(encode(records + [retain_none]))
    imported = run_import(bad_source.name, absent.name)
    assert (imported.returncode, imported.stdout, imported.stderr) == (0, '', ''), imported
    retained_messages = [r['message'] for r in map(json.loads, absent.read_text().splitlines()[1:])]
    assert [message['role'] for message in retained_messages] == ['system', 'user'], retained_messages
    assert retained_messages[0]['content'] == [{'text': 'Compact checkpoint'}], retained_messages
    assert retained_messages[1]['content'][0]['text'].endswith('<summary>\nNo retained entries\n</summary>')
    compare_with_pi(bad_source, absent)


def main():
    server = Server(('127.0.0.1', 0), Handler)
    server.failures = []
    server.expected_file_prompts = set()
    server.expected_tool_sets = {}
    server.expected_system_prompts = {}
    server.expected_template_prompt = None
    server.expected_budget = 0
    server.expected_budget_path = ''
    server.failure_request_count = 0
    server.retry_request_count = 0
    server.responses_retry_count = 0
    server.cancel_stream_release = threading.Event()
    server.queue_requests = []
    server.queue_stream_mid = threading.Event()
    server.queue_stream_release = threading.Event()
    server.queue_cancel_release = threading.Event()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='zpi-cli-') as directory:
            root = Path(directory).resolve()
            session = root / 'conversation.jsonl'
            config = root / 'models.json'
            config.write_text(json.dumps({'providers': {'fixture': {
                'api': 'openai-completions',
                'baseUrl': f'http://127.0.0.1:{server.server_port}/v1',
                'apiKey': 'fake-${ZPI_TEST_KEY_PART}',
                'headers': {'X-Provider-Header': 'provider', 'X-Token': 'Bearer ${ZPI_TEST_HEADER_TOKEN}',
                            'X-Template': '$$:$!:$9:${bad-name}:$ZPI_TEST_HEADER_TOKEN'},
                'models': [{'id': 'fixture-model', 'maxTokens': 7000, 'headers': {
                    'X-Provider-Header': 'model', 'X-Model-Header': 'model-value'}}],
                'modelOverrides': {'fixture-model': {'maxTokens': 3000, 'headers': {
                    'X-Override-Header': 'override-value',
                    'X-Provider-Header': 'override-provider'}}},
            }}}))
            common = [str(BINARY), '--no-proxy', '--models-file', str(config),
                      '--provider', 'fixture', '--cwd', directory, '--session', str(session)]
            environment = {k: v for k, v in os.environ.items()
                           if k not in ('OPENAI_API_KEY', 'OPENAI_BASE_URL', 'OPENAI_MODEL', 'ZPI_MODELS_FILE',
                                        'PI_CODING_AGENT_SESSION_DIR', 'PI_CODING_AGENT_DIR')}
            environment['HOME'] = str(root)
            environment['ZPI_TEST_HEADER_TOKEN'] = 'header-secret'
            environment['ZPI_TEST_KEY_PART'] = 'key'
            environment['ZPI_EMPTY_HEADER'] = ''
            check_pi_import(root, common[:-4], environment, server)
            credential_session = root / 'invalid-credential.jsonl'
            credential_args = common[:-1] + [str(credential_session), '--no-tools', '-p', 'Reject credential']
            for invalid_key in ('synthetic-invalid-key\r\nInjected: value', 'x' * (16 * 1024 + 1)):
                rejected = run_repo_cli(credential_args + ['--api-key', invalid_key], input=b'',
                                          capture_output=True, env=environment, timeout=10)
                assert rejected.returncode == 1
                assert rejected.stderr == b'zpi: InvalidCredential\n' and rejected.stdout == b''
                assert not credential_session.exists()
            failure_config = root / 'provider-errors.json'
            for api, route in [(api, route) for api in ('openai-completions', 'anthropic-messages')
                               for route in ('error-fixture', 'redirect-fixture')]:
                before_failure_count = server.failure_request_count
                failure_config.write_text(json.dumps({'providers': {'error-fixture': {
                    'api': api,
                    'baseUrl': f'http://127.0.0.1:{server.server_port}/{route}',
                    'apiKey': 'synthetic-provider-key',
                    'models': [{'id': 'fixture-model'}],
                }}}))
                failure_session = root / f'{api}-{route}.jsonl'
                failed_request = run_repo_cli([
                    str(BINARY), '--no-proxy', '--models-file', str(failure_config),
                    '--provider', 'error-fixture', '--session', str(failure_session),
                    '--no-tools', '--mode', 'json', 'Provider failure fixture',
                ], input='', text=True, capture_output=True, env=environment, timeout=10)
                assert failed_request.returncode == 1, failed_request
                assert failed_request.stderr == 'zpi: HttpRequestFailed\n', failed_request
                events = [json.loads(line) for line in failed_request.stdout.splitlines()]
                assert events[-1] == {'type': 'error', 'error_code': 'HttpRequestFailed'}, events
                saved_history = failure_session.read_text()
                for marker in ('synthetic-provider-key', 'synthetic-provider-error'):
                    assert marker not in failed_request.stdout
                    assert marker not in saved_history
                assert server.failure_request_count == before_failure_count + 1
                if route == 'redirect-fixture':
                    assert all('Unexpected provider GET:' not in error for error in server.failures), server.failures
            retry_config = root / 'retry.json'
            retry_config.write_text(json.dumps({'providers': {'retry-fixture': {
                'api': 'openai-completions',
                'baseUrl': f'http://127.0.0.1:{server.server_port}/retry-fixture',
                'apiKey': 'retry-key',
                'models': [{'id': 'fixture-model'}],
            }}}))
            retry_session = root / 'retry-session.jsonl'
            retried = run_repo_cli([
                str(BINARY), '--no-proxy', '--models-file', str(retry_config),
                '--provider', 'retry-fixture', '--session', str(retry_session),
                '--no-tools', '--mode', 'json', 'Trigger retry',
            ], input='', text=True, capture_output=True, env=environment, timeout=20)
            assert retried.returncode == 0, (retried.stderr, retried.stdout)
            retry_events = [json.loads(line) for line in retried.stdout.splitlines()]
            assert [e.get('attempt') for e in retry_events if e.get('type') == 'auto_retry_start'] == [1, 2], retry_events
            assert [e.get('delay_ms') for e in retry_events if e.get('type') == 'auto_retry_start'] == [2000, 2000], retry_events
            assert any(e.get('type') == 'auto_retry_end' and e.get('success') is True and e.get('attempt') == 2
                       for e in retry_events), retry_events
            assert any(e.get('type') == 'message_end' and
                       e.get('message', {}).get('content') == [{'text': 'retry recovered'}]
                       for e in retry_events), retry_events
            assert server.retry_request_count == 3
            route_config = root / 'routes.json'
            route_providers = {
                name: {'baseUrl': f'http://127.0.0.1:{server.server_port}/route/{index}',
                       'apiKey': 'route-key', 'models': [{'id': model, 'maxTokens': tokens}]}
                for index, (name, model, tokens) in enumerate([
                    ('fixture', 'org/model', 2000),
                    ('fixture/nested', 'literal/id', 2500),
                    ('openai', 'unregistered/literal', 3500),
                ])
            }
            route_providers['fixture/nested']['models'].append({'id': 'fixture/nested/literal/id', 'maxTokens': 2250})
            route_providers['fixture/nested']['modelOverrides'] = {
                'literal/id': {'maxTokens': 2750},
                'fixture/nested/literal/id': {'maxTokens': 2250},
            }
            route_config.write_text(json.dumps({'providers': route_providers}))
            skill_agent = root / 'skill-agent'
            (skill_agent / 'skills' / 'pdf-tools').mkdir(parents=True)
            (skill_agent / 'skills' / 'pdf-tools' / 'SKILL.md').write_text('---\nname: pdf-tools\ndescription: Read PDF files and tables.\n---\nRead references/formats.md before converting.\n')
            user_prompts = skill_agent / 'prompts'
            user_prompts.mkdir()
            (user_prompts / 'review.md').write_text('---\ndescription: User-level template metadata\n---\n$1:${2:-fallback}:$@')
            explicit_prompts = root / 'explicit-prompts'
            explicit_prompts.mkdir()
            (explicit_prompts / 'only.md').write_text('---\ndescription: Explicit template\n---\nExplicit-only template index')
            project_prompts = root / 'project' / '.zpi' / 'prompts'
            project_prompts.mkdir(parents=True)
            (project_prompts / 'project-review.md').write_text('Project-level template index')
            (project_prompts / 'review.md').write_text('Must not shadow the user template.')
            (user_prompts / 'help.md').write_text('Help template body')
            project_skills = root / 'project' / '.agents' / 'skills' / 'project-only'
            project_skills.mkdir(parents=True)
            (project_skills / 'SKILL.md').write_text('---\nname: project-only\ndescription: Project-specific instructions.\n---\nProject-specific instructions.\n')
            skill_args = [str(BINARY), '--no-proxy', '--models-file', str(config), '--provider', 'fixture', '--no-session']
            skill_env = dict(environment, PI_CODING_AGENT_DIR='skill-agent')
            automatic_skill = run_repo_cli(skill_args + ['-p', 'skill-list'], input='', cwd=root, text=True,
                                             capture_output=True, env=skill_env, timeout=20)
            assert automatic_skill.returncode == 0 and automatic_skill.stdout == 'skill complete\n', (automatic_skill.stderr, server.failures)
            assert not any(m.get('role') == 'system' and 'project-only' in m.get('content', '') for m in server.last_request.get('messages', []))
            expanded_skill = run_repo_cli(skill_args + ['-p', '/skill:pdf-tools extract report.pdf'], input='', cwd=root, text=True,
                                            capture_output=True, env=skill_env, timeout=20)
            assert expanded_skill.returncode == 0 and expanded_skill.stdout == 'skill complete\n', (expanded_skill.stderr, server.failures)
            trust_args = skill_args + ['--trust-project-skills']
            trusted_project = run_repo_cli(trust_args + ['--cwd', str(root / 'project'), '-p', 'skill-project'], input='', cwd=root, text=True,
                                             capture_output=True, env=skill_env, timeout=20)
            assert trusted_project.returncode == 0 and trusted_project.stdout == 'skill complete\n', (trusted_project.stderr, server.failures)
            assert any(m.get('role') == 'system' and 'project-only' in m.get('content', '') for m in server.last_request.get('messages', []))
            project_flags = ['--cwd', str(root / 'project')]
            skill_session = root / 'skill.jsonl'
            explicit_skill = root / 'project' / 'manual-skills' / 'explicit-only' / 'SKILL.md'
            explicit_skill.parent.mkdir(parents=True)
            explicit_skill.write_text('---\nname: explicit-only\ndescription: Explicit checklist index.\n---\nChecklist body.\n')
            skill_session_args = skill_args[:-1] + project_flags + ['--session', str(skill_session)]
            manual_skill = ['--skill', 'manual-skills']
            base_prompt = 'Skill session instructions.'
            expected_users = []
            for state, flags, text in [
                ('enabled', manual_skill + ['--system-prompt', base_prompt], '/skill:explicit-only initial'),
                ('disabled', manual_skill + ['--trust-project-skills', '--no-skills'], '/skill:explicit-only disabled'),
                ('removed', manual_skill, '/skill:explicit-only removed'),
            ]:
                if state == 'removed':
                    explicit_skill.unlink()
                run = run_repo_cli(skill_session_args + flags + ['-p', text], input='', cwd=root, text=True,
                                     capture_output=True, env=skill_env, timeout=20)
                assert run.returncode == 0 and run.stdout == 'skill complete\n', (state, run.stderr, server.failures)
                messages = server.last_request['messages']
                users = [m['content'] for m in messages if m['role'] == 'user']
                systems = [m['content'] for m in messages if m['role'] == 'system']
                assert len(systems) == 1 and systems[0].startswith(base_prompt), systems
                assert 'project-only' not in systems[0], systems
                if state == 'enabled':
                    assert '<name>explicit-only</name>' in systems[0], systems
                    assert 'Explicit checklist index.' in systems[0], systems
                    assert '<name>pdf-tools</name>' in systems[0], systems
                    assert users[-1].startswith('<skill name="explicit-only"'), users
                    assert users[-1].endswith('\n\nChecklist body.\n</skill>\n\ninitial'), users
                    expected_users.append(users[-1])
                else:
                    assert 'explicit-only' not in systems[0] and 'Explicit checklist index.' not in systems[0], systems
                    if state == 'disabled':
                        assert systems == [base_prompt], systems
                    else:
                        assert '<name>pdf-tools</name>' in systems[0], systems
                    expected_users.append(text)
                assert users == expected_users, (state, users)
                assert [m['content'] for m in messages if m['role'] == 'assistant'] == ['skill complete'] * (len(users) - 1)
            skill_records = skill_session.read_text()
            assert '<available_skills>' not in skill_records and 'Explicit checklist index.' not in skill_records
            skill_messages = [json.loads(line).get('message', {}) for line in skill_records.splitlines()]
            assert [m['content'] for m in skill_messages if m.get('role') == 'user'] == [
                [{'text': text}] for text in expected_users
            ]
            template_session = root / 'template.jsonl'
            for flags, text, expected in [
                ([], '/review "literal safe"', 'literal safe:fallback:literal safe'),
                (['--no-prompt-templates'], '/review ignored', '/review ignored'),
                (project_flags, '/project-review ignored', '/project-review ignored'),
                (project_flags + ['--trust-project-prompts'], '/project-review ignored', 'Project-level template index'),
                (project_flags + ['--trust-project-prompts'], '/review precedence', 'precedence:fallback:precedence'),
                (project_flags + ['--skill', '.agents/skills/project-only/SKILL.md'], '/review explicit skill', 'explicit:skill:explicit skill'),
                (['-np', '--prompt-template', str(explicit_prompts)], '/only', 'Explicit-only template index'),
                (['-np', '--prompt-template=explicit-prompts/only.md'], '/only', 'Explicit-only template index'),
                ([], '/not-found ignored', '/not-found ignored'),
                ([], '/help', 'Help template body'),
            ]:
                server.expected_template_prompt = expected
                run = run_repo_cli(skill_args + flags + ['-p', text], input='', cwd=root, text=True,
                                     capture_output=True, env=skill_env, timeout=20)
                assert run.returncode == 0 and run.stdout == 'template complete\n', (run.stderr, server.failures)
            server.expected_template_prompt = 'persisted:fallback:persisted'
            template_session_args = skill_args[:-1] + ['--session', str(template_session), '-p']
            run = run_repo_cli(template_session_args + ['/review persisted'], input='', cwd=root, text=True,
                                 capture_output=True, env=skill_env, timeout=20)
            assert run.returncode == 0 and run.stdout == 'template complete\n', (run.stderr, server.failures)
            (user_prompts / 'review.md').unlink()
            server.expected_template_prompt = '/review removed'
            run = run_repo_cli(template_session_args + ['/review removed'],  input='', cwd=root, text=True,
                                 capture_output=True, env=skill_env, timeout=20)
            assert run.returncode == 0 and run.stdout == 'template complete\n', (run.stderr, server.failures)
            template_messages = [json.loads(line).get('message', {}) for line in template_session.read_text().splitlines()]
            assert [m['content'] for m in template_messages if m.get('role') == 'user'] == [
                [{'text': 'persisted:fallback:persisted'}], [{'text': '/review removed'}],
            ]
            server.expected_template_prompt = None
            mcp_server = root / 'mcp-fixture.py'
            mcp_server.write_text('''import json, sys
from pathlib import Path
label = sys.argv[1]
assert sys.argv[2:] == ["--", "@literal"]
initialized = False
for line in sys.stdin:
    message = json.loads(line)
    assert message["jsonrpc"] == "2.0"
    method = message["method"]
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "serverInfo": {"name": "fixture", "version": "1"}, "capabilities": {"tools": {}}}
    elif method == "notifications/initialized":
        assert "id" not in message
        initialized = True
        continue
    elif method == "tools/list":
        assert initialized
        result = {"tools": [{"name": "echo-text", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
    elif method == "tools/call":
        assert initialized and message["params"]["name"] == "echo-text"
        text = message["params"]["arguments"]["text"]
        with Path("mcp-calls.txt").open("a") as calls:
            calls.write(label + ": " + text + chr(10))
        if text == "fail after effect":
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "error": {
                "code": -32603, "message": "fixture internal failure",
            }}), flush=True)
            continue
        result = ({"content": [{"type": "text", "text": "fixture reported tool failure"}], "isError": True}
                  if text == "reported tool failure" else
                  {"content": [{"type": "text", "text": label + " says: " + text}]})
    else:
        raise AssertionError(method)
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
''')
            def mcp_child(name):
                return ['--mcp-stdio', name, '--', sys.executable, str(mcp_server), name, '--', '@literal']

            mcp_common = common[:-1] + [str(root / 'mcp.jsonl')]
            server_fail_session = root / 'mcp-server-error.jsonl'
            for flags, prompt in [(['--tools', 'mcp__demo__*'], 'mcp-workflow'),
                                  (['--no-tools'], 'mcp-disabled'),
                                  (['--tools', 'mcp__*'], 'mcp-multiple'),
                                  (['--tools', 'mcp__demo__*', '--exclude-tools', '*'], 'mcp-excluded'),
                                  (['--tools', 'read'], 'mcp-opt-out'),
                                  (['--tools', 'mcp__demo__*'], 'mcp-server-error'),
                                  (['--tools', 'mcp__demo__*'], 'mcp-response-limit-accepted'),
                                  (['--tools', 'mcp__demo__*'], 'mcp-response-limit-rejected')]:
                server_calls_before = (root / 'mcp-calls.txt').read_text().splitlines() if (root / 'mcp-calls.txt').exists() else []
                args = {
                    'mcp-workflow': mcp_common,
                    'mcp-server-error': common[:-1] + [str(server_fail_session)],
                }.get(prompt, skill_args)
                children = mcp_child('demo')
                if prompt == 'mcp-multiple':
                    children += mcp_child('other')
                result = run_repo_cli(args + flags + ['-p', prompt] + children, input='', cwd=root,
                                        text=True, capture_output=True, env=environment, timeout=20)
                assert result.returncode == 0 and result.stdout == 'mcp complete\n', (result.stderr, server.failures)
                expected_new_call = prompt in ('mcp-workflow', 'mcp-multiple', 'mcp-server-error', 'mcp-response-limit-accepted', 'mcp-response-limit-rejected')
                new_calls = (root / 'mcp-calls.txt').read_text().splitlines() if (root / 'mcp-calls.txt').exists() else []
                assert len(new_calls) == len(server_calls_before) + int(expected_new_call), new_calls
                if expected_new_call:
                    expected_input = {
                        'mcp-workflow': 'hello MCP',
                        'mcp-multiple': 'hello MCP',
                        'mcp-server-error': 'reported tool failure',
                        'mcp-response-limit-accepted': 'z' * (49 * 1024),
                        'mcp-response-limit-rejected': 'z' * (50 * 1024 + 1),
                    }[prompt]
                    assert new_calls[-1] == ('other' if prompt == 'mcp-multiple' else 'demo') + ': ' + expected_input
            server_fail_records = [json.loads(line) for line in server_fail_session.read_text().splitlines()]
            server_fail_results = [r['message'] for r in server_fail_records if r.get('message', {}).get('role') == 'tool_result']
            assert len(server_fail_results) == 1 and server_fail_results[0]['is_error'], server_fail_results
            assert server_fail_results[0]['content'] == [{'text': 'fixture reported tool failure'}], server_fail_results
            mcp_records = [json.loads(line) for line in (root / 'mcp.jsonl').read_text().splitlines()]
            mcp_results = [r['message'] for r in mcp_records if r.get('message', {}).get('role') == 'tool_result']
            assert len(mcp_results) == 1 and mcp_results[0]['tool_call_id'] == 'mcp-call', mcp_results
            assert 'demo says: hello MCP' in json.dumps(mcp_results[0]), mcp_results
            failed_session = root / 'mcp-failure.jsonl'
            result = run_repo_cli(common[:-1] + [str(failed_session), '--tools', 'mcp__demo__*',
                                    '--mode=json', 'mcp-rpc-error'] + mcp_child('demo'), input='', cwd=root,
                                    text=True, capture_output=True, env=environment, timeout=20)
            assert result.returncode != 0 and 'Canceled' in result.stderr, (result.stderr, server.failures)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            assert any(e['type'] == 'error' and e['error_code'] == 'Canceled' for e in events), events
            records = [json.loads(line) for line in failed_session.read_text().splitlines()]
            unknown = [r['message'] for r in records if r.get('message', {}).get('role') == 'tool_result']
            assert len(unknown) == 1 and unknown[0]['is_error'], unknown
            assert 'outcome is unknown' in json.dumps(unknown[0]), unknown
            mcp_call_lines = (root / 'mcp-calls.txt').read_text().splitlines()
            assert mcp_call_lines == [
                'demo: hello MCP', 'other: hello MCP', 'demo: reported tool failure',
                'demo: ' + 'z' * (49 * 1024), 'demo: ' + 'z' * (50 * 1024 + 1), 'demo: fail after effect',
            ]
            agent_config_dir = root / 'pi-agent'
            (agent_config_dir / 'providers').mkdir(parents=True)
            (agent_config_dir / 'models.json').write_text(json.dumps({'providers': route_providers}))
            agent_config = dict(environment, PI_CODING_AGENT_DIR='~/pi-agent')
            agent_route_args = [str(BINARY), '--no-proxy', '--provider', 'fixture', '--model', 'org/model', '--no-session', '-p', 'route']
            server.expected_route_path = '/route/0/chat/completions'
            server.expected_route_model = 'org/model'
            server.expected_route_tokens = 2000
            agent_route = run_repo_cli(agent_route_args, input='', cwd=root, text=True,
                                         capture_output=True, env=agent_config, timeout=20)
            assert agent_route.returncode == 0 and agent_route.stdout == 'route complete\n', (agent_route.stderr, server.failures)
            zpi_config = root / 'zpi-models.json'
            zpi_providers = json.loads(json.dumps(route_providers))
            zpi_providers['fixture']['baseUrl'] = f'http://127.0.0.1:{server.server_port}/route/1'
            zpi_config.write_text(json.dumps({'providers': zpi_providers}))
            zpi_config_env = dict(agent_config, ZPI_MODELS_FILE=str(zpi_config))
            server.expected_route_path = '/route/1/chat/completions'
            zpi_route = run_repo_cli(agent_route_args, input='', cwd=root, text=True,
                                       capture_output=True, env=zpi_config_env, timeout=20)
            assert zpi_route.returncode == 0 and zpi_route.stdout == 'route complete\n', (zpi_route.stderr, server.failures)
            explicit_route_args = [str(BINARY), '--no-proxy', '--models-file', str(route_config),
                                   '--provider', 'fixture', '--model', 'org/model', '--no-session', '-p', 'route']
            server.expected_route_path = '/route/0/chat/completions'
            server.expected_route_model = 'org/model'
            server.expected_route_tokens = 2000
            explicit_route = run_repo_cli(explicit_route_args, input='', cwd=root, text=True,
                                            capture_output=True, env=zpi_config_env, timeout=20)
            assert explicit_route.returncode == 0 and explicit_route.stdout == 'route complete\n', (explicit_route.stderr, server.failures)
            route_base = [str(BINARY), '--no-proxy', '--models-file', str(route_config), '--no-session']
            for flags, model, tokens, index in [
                (['--model', 'fixture/org/model'], 'org/model', 2000, 0),
                (['--model', 'FIXTURE/nested/literal/id'], 'literal/id', 2750, 1),
                (['--model', 'fixture/nested/literal/id'], 'literal/id', 2750, 1),
                (['--provider', 'fixture/nested', '--model', 'fixture/nested/literal/id'], 'fixture/nested/literal/id', 2250, 1),
                (['--provider', 'fixture', '--model', 'fixture/org/model'], 'fixture/org/model', 16384, 0),
                (['--model', 'unregistered/literal'], 'unregistered/literal', 3500, 2),
                (['--model', 'openai/unregistered/literal'], 'unregistered/literal', 3500, 2),
                (['--provider', 'fixture'], 'org/model', 2000, 0),
            ]:
                server.expected_route_path = f'/route/{index}/chat/completions'
                server.expected_route_model = model
                server.expected_route_tokens = tokens
                routed = run_cli(route_base + flags + ['-p', 'route'], input='', text=True,
                                        capture_output=True, env=environment, timeout=20)
                assert routed.returncode == 0 and routed.stdout == 'route complete\n', (routed.stderr, server.failures)
            # Removing the stripped ID exercises the full literal fallback.
            route_providers['fixture/nested']['models'] = [
                {'id': 'fixture/nested/literal/id', 'maxTokens': 2250}]
            route_config.write_text(json.dumps({'providers': route_providers}))
            server.expected_route_path = '/route/1/chat/completions'
            server.expected_route_model = 'fixture/nested/literal/id'
            server.expected_route_tokens = 2250
            routed = run_cli(route_base + ['--model', 'fixture/nested/literal/id', '-p', 'route'],
                                    input='', text=True, capture_output=True, env=environment, timeout=20)
            assert routed.returncode == 0 and routed.stdout == 'route complete\n', (routed.stderr, server.failures)
            route_providers['fixture']['models'].append({'id': 'fixture/nested/literal/id'})
            route_providers['openai']['models'].append({'id': 'fixture/org/model'})
            route_config.write_text(json.dumps({'providers': route_providers}))
            for model, expected in [('fixture/org/model', 'AmbiguousModelReference'),
                                    ('fixture/nested/literal/id', 'AmbiguousModelReference'),
                                    ('fixture/', 'InvalidModel'), ('anthropic/', 'InvalidModel')]:
                route_session = root / 'rejected-route.jsonl'
                rejected = run_repo_cli([str(BINARY), '--models-file', str(route_config),
                    '--model', model, '--session', str(route_session),
                    '--native-plugin', str(root / 'missing-plugin.so'), '-p', 'route'],
                    input='', text=True, capture_output=True, env=environment, timeout=10)
                assert rejected.returncode != 0 and expected in rejected.stderr, rejected.stderr
                assert rejected.stdout == '' and not route_session.exists()
            syntax_config = root / 'syntax-models.json'
            syntax_providers = json.loads(config.read_text())
            # Comment-like bytes and escaped quotes inside values stay literal.
            syntax_providers['providers']['fixture']['headers']['X-Syntax'] = 'https://example.invalid//path ",}"'
            syntax_text = json.dumps(syntax_providers, indent=2)
            syntax_text = syntax_text.replace('\n        }\n', '\n        }, // model tail\n')
            syntax_text = syntax_text[:-1] + ', // root tail\n}'
            syntax_config.write_text('\ufeff// models.json with pi syntax\n' + syntax_text + '\n// EOF comment')
            syntax_run = run_repo_cli([str(BINARY), '--no-proxy', '--models-file', str(syntax_config),
                '--provider', 'fixture', '--no-session', '-p', 'config-syntax'], input='', text=True,
                capture_output=True, env=environment, timeout=20)
            assert syntax_run.returncode == 0 and syntax_run.stdout == 'config syntax complete\n', (syntax_run.stderr, server.failures)
            for invalid_bytes in (b'{/* unsupported block */"providers":{}}',
                                  b'{"providers":{},,}', b'{"providers":"unterminated // text}', b'\xff'):
                syntax_config.write_bytes(invalid_bytes)
                syntax_session = root / 'syntax-rejected.jsonl'
                rejected = run_repo_cli([str(BINARY), '--models-file', str(syntax_config),
                    '--session', str(syntax_session), '--native-plugin', str(root / 'missing-plugin.so'),
                    '-p', 'invalid config syntax'], input='', text=True, capture_output=True,
                    env=environment, timeout=10)
                assert rejected.returncode != 0 and any(name in rejected.stderr for name in
                    ('SyntaxError', 'UnexpectedEndOfInput', 'InvalidModelsUtf8')), rejected.stderr
                assert rejected.stdout == '' and not syntax_session.exists()
            token_config = root / 'token-config.json'
            token_session = root / 'token-session.jsonl'
            token_config.write_bytes(config.read_bytes())
            token_run = run_repo_cli([str(BINARY), '--no-proxy', '--models-file', str(token_config),
                '--provider', 'fixture', '--cwd', directory, '--session', str(token_session),
                '-p', 'token-limit'], input='', text=True, capture_output=True, env=environment, timeout=20)
            assert token_run.returncode == 0 and token_run.stdout == 'token-limit complete\n', (token_run.stderr, server.failures)
            assert token_session.exists()
            compat_config = root / 'compat-models.json'
            compat_session = root / 'compat.jsonl'
            (root / 'compat.txt').write_text('compat input')
            compat_provider = {
                'api': 'openai-completions', 'apiKey': 'route-key',
                'baseUrl': f'http://127.0.0.1:{server.server_port}/compat',
                'compat': {'maxTokensField': 'max_tokens', 'requiresNonNullAssistantContent': False,
                           'requiresToolsWithToolHistory': True, 'requiresToolResultName': True,
                           'requiresAssistantAfterToolResult': True, 'supportsUsageInStreaming': True,
                           'supportsStore': True},
                'models': [{'id': 'compat-model', 'maxTokens': 2000,
                            'compat': {'requiresNonNullAssistantContent': True, 'supportsStore': False}}],
                'modelOverrides': {'compat-model': {'compat': {'maxTokensField': 'max_completion_tokens', 'supportsUsageInStreaming': False,
                                                               'supportsFinishReason': False, 'supportsStore': True}}},
            }
            compat_config.write_text(json.dumps({'providers': {'compat': compat_provider}}))
            compat_args = [str(BINARY), '--no-proxy', '--models-file', str(compat_config),
                           '--provider', 'compat', '--cwd', directory]
            for flags, prompt, expected in [
                (['--no-session', '--no-tools'], 'compat-fresh', 'compat fresh'),
                (['--session', str(compat_session), '--tools', 'read'], 'workflow', 'compat complete'),
                (['--session', str(compat_session), '--no-tools'], 'compat-resume', 'compat resumed'),
            ]:
                run = run_cli(compat_args + flags + ['-p', prompt], input='', text=True,
                                     capture_output=True, env=environment, timeout=20)
                assert run.returncode == 0 and run.stdout == expected + '\n', (run.stderr, server.failures)
            no_finish_args = compat_args + ['--no-session', '--no-tools', '-p', 'compat-no-finish']
            inferred_run = run_repo_cli(no_finish_args, input='', text=True, capture_output=True, env=environment, timeout=20)
            assert inferred_run.returncode == 0 and inferred_run.stdout == 'compat inferred\n', (inferred_run.stderr, server.failures)
            compat_override = compat_provider['modelOverrides']['compat-model']['compat']
            del compat_override['supportsFinishReason']
            compat_config.write_text(json.dumps({'providers': {'compat': compat_provider}}))
            strict_run = run_repo_cli(no_finish_args, input='', text=True, capture_output=True, env=environment, timeout=20)
            assert strict_run.returncode != 0 and 'MissingFinishReason' in strict_run.stderr, (strict_run.stderr, server.failures)
            compat_override['supportsFinishReason'] = False
            store_layers = (compat_provider['compat'], compat_provider['models'][0]['compat'], compat_override)
            for values, prompt in [
                ((True, None, None), 'compat-fresh'),
                ((True, False, None), 'compat-store-omitted'),
                ((True, True, False), 'compat-store-omitted'),
                ((None, None, None), 'compat-store-omitted'),
            ]:
                for layer, value in zip(store_layers, values):
                    if value is None:
                        layer.pop('supportsStore', None)
                    else:
                        layer['supportsStore'] = value
                compat_config.write_text(json.dumps({'providers': {'compat': compat_provider}}))
                store_run = run_repo_cli(compat_args + ['--no-session', '--no-tools', '-p', prompt], input='', text=True, capture_output=True, env=environment, timeout=20)
                assert store_run.returncode == 0 and store_run.stdout == 'compat fresh\n', (values, store_run.stderr, server.failures)
            compat_override['supportsStore'] = True
            rejected_compat_session = root / 'bad-compat.jsonl'
            for compat, field in [
                (compat_provider['compat'], 'requiresNonNullAssistantContent'),
                (compat_override, 'supportsUsageInStreaming'),
                (compat_override, 'supportsFinishReason'),
                (compat_override, 'supportsStore'),
            ]:
                original = compat[field]
                compat[field] = 'false'
                compat_config.write_text(json.dumps({'providers': {'compat': compat_provider}}))
                compat[field] = original
                rejected_compat = run_repo_cli(compat_args + ['--session', str(rejected_compat_session), '-p', 'compat-fresh'], input='', text=True, capture_output=True, env=environment, timeout=20)
                assert rejected_compat.returncode != 0 and 'InvalidOpenAiCompat' in rejected_compat.stderr, rejected_compat.stderr
                assert not rejected_compat_session.exists()
            # The projected system and user each contain seven ASCII bytes:
            # two tokens apiece, leaving 5000 - 4096 - 4 = 900 output tokens.
            budget_config = root / 'budget-models.json'
            for api in ('openai-completions', 'anthropic-messages'):
                budget_config.write_text(json.dumps({'providers': {'budget': {
                    'api': api, 'apiKey': 'route-key',
                    'baseUrl': f'http://127.0.0.1:{server.server_port}/budget/{api}',
                    'models': [{'id': 'budget-model', 'maxTokens': 2000, 'contextWindow': 6000}],
                    'modelOverrides': {'budget-model': {'contextWindow': 5000}},
                }}}))
                budget_session = root / f'{api}-budget.jsonl'
                budget_args = [str(BINARY), '--no-proxy', '--models-file', str(budget_config),
                    '--provider', 'budget', '--no-tools', '--session', str(budget_session)]
                for flags, expected in [(['--system-prompt', '1234567'], 900), ([], 893)]:
                    server.expected_budget = expected
                    server.expected_budget_path = f'/budget/{api}/v1/messages' if api == 'anthropic-messages' else f'/budget/{api}/chat/completions'
                    budget_run = run_repo_cli(budget_args + flags + ['-p', '1234567'], input='', text=True, capture_output=True, env=environment, timeout=20)
                    assert budget_run.returncode == 0 and budget_run.stdout == 'budget complete\n', (budget_run.stderr, server.failures)
            # Invalid model or override windows fail before loading a plugin or
            # creating a session, even when an override could mask the model.
            for location in ('models', 'modelOverrides'):
                for value in (0, -1, 1.5, 4294967296, '5000', None, True):
                    provider_config = {'baseUrl': 'http://127.0.0.1:1/v1',
                                       'models': [{'id': 'm', 'contextWindow': 6000}],
                                       'modelOverrides': {'m': {'contextWindow': 5000}}}
                    if location == 'models':
                        provider_config['models'][0]['contextWindow'] = value
                    else:
                        provider_config['modelOverrides']['m']['contextWindow'] = value
                    budget_config.write_text(json.dumps({'providers': {'budget': provider_config}}))
                    rejected_path = root / 'budget-rejected.jsonl'
                    rejected = run_repo_cli([str(BINARY), '--models-file', str(budget_config),
                        '--provider', 'budget', '--session', str(rejected_path),
                        '--native-plugin', str(root / 'missing-plugin.so'), '-p', 'bad window'],
                        input='', text=True, capture_output=True, env=environment, timeout=10)
                    assert rejected.returncode != 0 and 'InvalidContextWindow' in rejected.stderr, rejected.stderr
                    assert rejected.stdout == '' and not rejected_path.exists()
            invalid_token_session = root / 'invalid-token-session.jsonl'
            for location in ('models', 'modelOverrides'):
                for value in (0, -1, 1.5, 4294967296, '7000', None, True):
                    provider_config = {'baseUrl': 'http://127.0.0.1:1/v1',
                                       'models': [{'id': 'fixture-model'}]}
                    if location == 'models':
                        provider_config['models'][0]['maxTokens'] = value
                    else:
                        provider_config['modelOverrides'] = {'fixture-model': {'maxTokens': value}}
                    token_config.write_text(json.dumps({'providers': {'fixture': provider_config}}))
                    rejected = run_repo_cli([str(BINARY), '--models-file', str(token_config),
                        '--provider', 'fixture', '--session', str(invalid_token_session),
                        '--native-plugin', str(root / 'missing-plugin.so'), '-p', 'invalid token limit'],
                        input='', text=True, capture_output=True, env=environment, timeout=10)
                    assert rejected.returncode != 0 and 'InvalidTokenLimit' in rejected.stderr, rejected.stderr
                    assert rejected.stdout == '' and not invalid_token_session.exists()
            # Invalid header configuration must fail before sessions or native
            # plugin initialization; diagnostics must not echo secret values.
            invalid_config = root / 'invalid-headers.json'
            invalid_session = root / 'invalid-headers-session.jsonl'
            rejection_cases = [
                ({'bad name': 'private-header-marker'}, b'InvalidHeaderName'),
                ({'X-Token': 'private-header-marker\r\nInjected: yes'}, b'InvalidHeaderValue'),
                ({'User-Agent': 'private-header-marker'}, b'ReservedRequestHeader'),
                ({'X-Token': '$ZPI_MISSING_HEADER'}, b'MissingCredentialEnvironment'),
                ({'X-Token': '${ZPI_EMPTY_HEADER}'}, b'MissingCredentialEnvironment'),
                ({'X-Token': '!touch header-command-marker'}, b'CommandCredentialUnsupported'),
                ({'X-Token': 'private-header-marker', 'x-token': 'duplicate'}, b'DuplicateHeader'),
                ({'X-Token': 'x' * 16384}, b'HeadersTooLarge'),
                ({'X-Token': '${ZPI_LARGE_HEADER}'}, b'HeadersTooLarge'),
            ]
            environment.pop('ZPI_MISSING_HEADER', None)
            environment['ZPI_LARGE_HEADER'] = 'x' * 16385
            for headers, expected in rejection_cases:
                invalid_config.write_text(json.dumps({'providers': {'fixture': {
                    'baseUrl': 'http://127.0.0.1:1/v1', 'headers': headers,
                }}}))
                rejected = run_repo_cli([str(BINARY), '--models-file', str(invalid_config),
                    '--provider', 'fixture', '--session', str(invalid_session),
                    '--native-plugin', str(root / 'missing-plugin.so'), '-p', 'reject headers'],
                    input=b'', capture_output=True, env=environment, cwd=root, timeout=10)
                assert rejected.returncode != 0 and expected in rejected.stderr, rejected.stderr
                assert b'private-header-marker' not in rejected.stderr and rejected.stdout == b''
                assert not invalid_session.exists() and not (root / 'header-command-marker').exists()
            # --continue creates a session when none match, resumes the latest
            # matching cwd, and leaves corrupt or locked selected history alone.
            recent_args = common[:-2]  # remove explicit --session PATH
            recent_home = root / 'recent-home'
            recent_env = dict(environment, HOME=str(recent_home))
            for flags, prompt in [(['--continue'], 'recent-first'), (['-c'], 'recent-next')]:
                result = run_cli(recent_args + flags + ['-p', prompt], input='', text=True,
                                        capture_output=True, env=recent_env, timeout=20)
                assert result.returncode == 0 and result.stdout == prompt + ' complete\n', (result.stderr, server.failures)
            recent_dir = recent_home / '.zpi/agent/sessions'
            recent_files = list(recent_dir.glob('*.jsonl'))
            assert len(recent_files) == 1
            recent_file = recent_files[0]
            other_project = root / 'other-project'
            other_project.mkdir()
            result = run_cli(recent_args + ['--cwd', str(other_project), '-c', '-p', 'recent-other'],
                                    input='', text=True, capture_output=True, env=recent_env, timeout=20)
            assert result.returncode == 0 and result.stdout == 'recent-other complete\n', (result.stderr, server.failures)
            assert len(list(recent_dir.glob('*.jsonl'))) == 2
            older = recent_dir / 'older.jsonl'
            older.write_bytes(recent_file.read_bytes())
            os.utime(older, (1000000000, 1000000000))
            # Discovery is read-only, and the newest matching candidate is
            # opened normally. Corrupt or externally locked history must fail
            # rather than silently selecting an older conversation.
            broken = recent_dir / 'broken.jsonl'
            broken.write_text('{"type":"session","version":1,"format":"zpi","cwd":"' + directory + '"}\nnot-json\n')
            now = recent_file.stat().st_mtime + 10
            os.utime(broken, (now, now))
            broken_bytes = broken.read_bytes()
            result = run_cli(recent_args + ['-c', '-p', 'ignored'], input='', text=True,
                                    capture_output=True, env=recent_env, timeout=20)
            assert result.returncode != 0 and 'CorruptSessionEntry' in result.stderr, result.stderr
            assert broken.read_bytes() == broken_bytes
            pid_file = root / 'lock-holder.pid'
            holder = subprocess.Popen(
                [sys.executable, '-c',
                 'import fcntl, os, sys, time; f=open(sys.argv[1], "rb"); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); '
                 'open(sys.argv[2], "w").write(str(os.getpid())); print("LOCKED", flush=True); time.sleep(30)',
                 str(broken), str(pid_file)],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                assert holder.stdout.readline() == 'LOCKED\n', holder.stderr.read()
                assert pid_file.exists()
                before_locked = broken.read_bytes()
                result = run_cli(recent_args + ['-c', '-p', 'ignored'], input='', text=True,
                                        capture_output=True, env=recent_env, timeout=20)
                assert result.returncode != 0 and ('WouldBlock' in result.stderr or 'AccessDenied' in result.stderr), result.stderr
                assert broken.read_bytes() == before_locked
            finally:
                holder.kill()
                holder.wait(timeout=5)
                if holder.stdout:
                    holder.stdout.close()
                if holder.stderr:
                    holder.stderr.close()
            session_pipe = root / 'session-pipe.jsonl'
            os.mkfifo(session_pipe)
            result = run_cli(recent_args + ['--session', str(session_pipe), '-p', 'ignored'],
                                    input='', text=True, capture_output=True, env=recent_env, timeout=5)
            assert result.returncode == 1 and result.stderr == 'zpi: SessionNotRegularFile\n', result
            assert result.stdout == '' and session_pipe.is_fifo()
            # Explicit session directories work without HOME and resolve from
            # launch cwd, independently of the tool working directory.
            custom_env = dict(environment)
            custom_env.pop('HOME', None)
            for flags, prompt in [(['--session-dir', 'custom-sessions'], 'recent-first'),
                                  (['--session-dir=custom-sessions', '-c'], 'recent-next')]:
                result = run_cli(recent_args + flags + ['-p', prompt], input='', cwd=root,
                                        text=True, capture_output=True, env=custom_env, timeout=20)
                assert result.returncode == 0 and result.stdout == prompt + ' complete\n', (result.stderr, server.failures)
            assert len(list((root / 'custom-sessions').glob('*.jsonl'))) == 1
            env_session_dir = root / 'env-session-dir'
            env_session = dict(environment, PI_CODING_AGENT_SESSION_DIR=str(env_session_dir))
            env_session_run = run_cli(recent_args + ['-p', 'recent-first'], input='', cwd=root,
                                             text=True, capture_output=True, env=env_session, timeout=20)
            assert env_session_run.returncode == 0 and env_session_run.stdout == 'recent-first complete\n', (env_session_run.stderr, server.failures)
            env_continue = run_cli(recent_args + ['-c', '-p', 'recent-next'], input='', cwd=root,
                                          text=True, capture_output=True, env=env_session, timeout=20)
            assert env_continue.returncode == 0 and env_continue.stdout == 'recent-next complete\n', (env_continue.stderr, server.failures)
            assert len(list(env_session_dir.glob('*.jsonl'))) == 1
            env_override_dir = root / 'env-cli-override'
            cli_override_env = dict(env_session, PI_CODING_AGENT_SESSION_DIR=str(root / 'ignored-session-dir'))
            cli_override_run = run_cli(recent_args + ['--session-dir', str(env_override_dir), '-p', 'recent-first'],
                                              input='', cwd=root, text=True, capture_output=True, env=cli_override_env, timeout=20)
            assert cli_override_run.returncode == 0 and cli_override_run.stdout == 'recent-first complete\n', (cli_override_run.stderr, server.failures)
            assert len(list(env_override_dir.glob('*.jsonl'))) == 1 and not (root / 'ignored-session-dir').exists()
            tilde_session_dir = root / 'tilde-session-dir'
            tilde_env = dict(environment, PI_CODING_AGENT_SESSION_DIR='~/tilde-session-dir')
            tilde_run = run_cli(recent_args + ['-p', 'recent-first'], input='', cwd=root,
                                       text=True, capture_output=True, env=tilde_env, timeout=20)
            assert tilde_run.returncode == 0 and tilde_run.stdout == 'recent-first complete\n', (tilde_run.stderr, server.failures)
            assert len(list(tilde_session_dir.glob('*.jsonl'))) == 1
            explicit_session = root / 'explicit-session.jsonl'
            unused_directory = root / 'unused-sessions'
            result = run_cli(recent_args + ['--session-dir', str(unused_directory), '--session', str(explicit_session), '-p', 'recent-first'],
                                    input='', text=True, capture_output=True, env=custom_env, timeout=20)
            assert result.returncode == 0 and result.stdout == 'recent-first complete\n', (result.stderr, server.failures)
            assert explicit_session.exists() and not unused_directory.exists()
            for flags in (['--session-dir='], ['-c', '--no-session']):
                result = run_cli(recent_args + flags + ['-p', 'ignored'], input='',
                                        text=True, capture_output=True, env=environment, timeout=20)
                assert result.returncode != 0
            system_file = root / 'instructions.md'
            system_file.write_bytes(b'\xef\xbb\xbf' + 'custom 规则'.encode())
            system_session = root / 'system.jsonl'
            system_args = common.copy()
            system_args[-1] = str(system_session)
            for name, flags, expected in [
                ('system-first', ['--system-prompt', str(system_file), '--append-system-prompt', 'one', '--append-system-prompt=two'], 'custom 规则\n\none\n\ntwo'),
                ('system-reload', [], 'custom 规则\n\none\n\ntwo'),
                ('system-append', ['--append-system-prompt', 'three'], 'custom 规则\n\none\n\ntwo\n\nthree'),
                ('system-replace', ['--system-prompt=reset'], 'reset'),
            ]:
                server.expected_system_prompts[name] = expected
                result = run_cli(system_args + flags + ['-p', name], input='', text=True,
                                        capture_output=True, env=environment, timeout=20)
                assert result.returncode == 0 and result.stdout == 'system complete\n', (result.stderr, server.failures)
            system_records = [json.loads(line) for line in system_session.read_text().splitlines()]
            checkpoints = [r for r in system_records if r.get('message', {}).get('system_prompt_replace')]
            assert len(checkpoints) == 3
            # The persisted history is lossless, while provider projection uses
            # only the newest checkpoint and leaves user/assistant history intact.
            prompt_checkpoint = checkpoints[0]['id']
            (root / 'instructions.md').write_text('alternate system')
            server.expected_system_prompts['system-branch-replaced'] = 'alternate system'
            result = run_cli(system_args + ['--branch', prompt_checkpoint, '--system-prompt', str(root / 'instructions.md'), '-p', 'system-branch-replaced'],
                                    input='', text=True, capture_output=True, env=environment, timeout=20)
            assert result.returncode == 0 and result.stdout == 'system complete\n', (result.stderr, server.failures)
            system_records = [json.loads(line) for line in system_session.read_text().splitlines()]
            assert len([r for r in system_records if r.get('message', {}).get('system_prompt_replace')]) == 4
            assert sum(r.get('message', {}).get('role') == 'user' for r in system_records) == 5
            server.expected_system_prompts['system-branch'] = 'custom 规则\n\none\n\ntwo'
            result = run_cli(system_args + ['--branch', checkpoints[0]['id'], '-p', 'system-branch'],
                                    input='', text=True, capture_output=True, env=environment, timeout=20)
            assert result.returncode == 0 and result.stdout == 'system complete\n', (result.stderr, server.failures)
            before_overflow = system_session.read_bytes()
            large_addition = root / 'large-system.txt'
            large_addition.write_bytes(b'x' * (1024 * 1024))
            overflow = run_cli(system_args + ['--branch', checkpoints[0]['id'], '--append-system-prompt', str(large_addition), '-p', 'ignored'],
                                      input='', text=True, capture_output=True, env=environment, timeout=20)
            assert overflow.returncode != 0 and 'SystemPromptTooLarge' in overflow.stderr, overflow.stderr
            assert system_session.read_bytes() == before_overflow, 'prompt validation changed the active branch'
            invalid_system = root / 'invalid-system.txt'
            invalid_system.write_bytes(b'invalid\xff')
            oversized_system = root / 'oversized-system.txt'
            oversized_system.write_bytes(b'x' * (1024 * 1024 + 1))
            for value, expected in [(str(invalid_system), 'InvalidSystemPrompt'),
                                    (str(oversized_system), 'SystemPromptTooLarge'),
                                    (str(root), 'SystemPromptNotRegularFile')]:
                rejected_path = root / 'system-rejected.jsonl'
                rejected_args = common.copy()
                rejected_args[-1] = str(rejected_path)
                result = run_cli(rejected_args + ['--system-prompt', value, '-p', 'ignored'],
                                        input='', text=True, capture_output=True, env=environment, timeout=20)
                assert result.returncode != 0 and expected in result.stderr, result.stderr
                assert not rejected_path.exists()
            builtins = {'read', 'write', 'edit', 'bash', 'grep', 'find', 'ls', 'web_fetch', 'get_content'}
            for index, (flags, expected) in enumerate([
                (['--tools', 'read,ls'], {'read', 'ls'}),
                (['-t', 'r*,*sh', '-xt', '*sh'], {'read'}),
                (['--tools=+write,-write,-bash,-web_fetch,-get_content'], {'read', 'edit'}),
                ([], {'read', 'write', 'edit', 'bash', 'web_fetch', 'get_content'}),
                (['-nt', '-t', '+read,+ls', '--exclude-tools=ls'], {'read'}),
                (['-nbt'], set()), (['--tools', ''], set()),
                (['--tools', 'unknown'], set()),
            ]):
                prompt_name = f'selection-{index}'
                server.expected_tool_sets[prompt_name] = expected
                selected_run = run_repo_cli(common + flags + ['-p', prompt_name], input='', text=True,
                                              capture_output=True, env=environment, timeout=20)
                assert selected_run.returncode == 0 and selected_run.stdout == 'selection complete\n', selected_run.stderr
            wf_ssrf = run_repo_cli(common[:-2] + ['--no-session', '-p', 'web-fetch-ssrf'], input='', text=True,
                                   capture_output=True, env=environment, timeout=20)
            assert wf_ssrf.returncode == 0 and wf_ssrf.stdout == 'ssrf blocked ok\n', (wf_ssrf.stderr, server.failures)
            wf_loop = run_repo_cli(common[:-2] + ['--no-session', '--allow-loopback-web-fetch', '-p', 'web-fetch-loopback'], input='', text=True,
                                   capture_output=True, env=environment, timeout=20)
            assert wf_loop.returncode == 0 and wf_loop.stdout == 'web fetch loopback ok\n', (wf_loop.stderr, server.failures)
            disabled_session = root / 'disabled.jsonl'
            disabled_args = common.copy()
            disabled_args[-1] = str(disabled_session)
            disabled = run_repo_cli(disabled_args + ['--tools', 'read', '-p', 'disabled-effect'],
                                      input='', text=True, capture_output=True, env=environment, timeout=20)
            assert disabled.returncode == 0 and disabled.stdout == 'disabled effect prevented\n', disabled.stderr
            assert not (root / 'forbidden.txt').exists()
            for flags, expected in [(['--tools', 'read,+write'], 'MixedToolSelection'),
                                    (['--tools', '+r*'], 'InvalidToolModifier')]:
                invalid = run_cli(common + flags + ['-p', 'ignored'], input='', text=True,
                                         capture_output=True, env=environment, timeout=20)
                assert invalid.returncode != 0 and expected in invalid.stderr
            # Pi-compatible stdin composition supports prompt-only pipes and
            # piped context prepended to a positional prompt.
            stdin_prompt = run_cli(common + ['-p'], input='stdin-only-prompt', text=True,
                                          capture_output=True, env=environment, timeout=20)
            assert stdin_prompt.returncode == 0 and stdin_prompt.stdout == 'stdin complete\n', (stdin_prompt.stdout, stdin_prompt.stderr)
            combined_prompt = run_cli(common + ['-p', 'positional-prompt'], input='stdin context',
                                             text=True, capture_output=True, env=environment, timeout=20)
            assert combined_prompt.returncode == 0 and combined_prompt.stdout == 'stdin complete\n', (combined_prompt.stdout, combined_prompt.stderr)
            file_one = root / 'first file.txt'
            file_two = root / 'second.txt'
            file_one.write_bytes(b'\xef\xbb\xbf' + 'first file 你好\n'.encode())
            file_two.write_text('second file')
            (root / 'empty.txt').write_text('')
            tools_dir = root / 'tools'
            tools_dir.mkdir()
            # Relative @paths use the launch directory even with --cwd set;
            # files retain their order across positional arguments and --.
            file_session = root / 'files.jsonl'
            file_args = common.copy()
            file_args[-1] = str(file_session)
            file_args.extend(['--cwd', str(tools_dir)])
            wrapped = (f'<file name="{root}/first file.txt">\nfirst file 你好\n\n</file>\n'
                       f'<file name="{root}/second.txt">\nsecond file\n</file>\n')
            server.expected_file_prompts.update((wrapped, 'prefix' + wrapped + 'last positional'))
            for args, pipe in [(['-p', '@first file.txt', '@empty.txt', '@second.txt'], ''),
                               (['--mode', 'text', '@first file.txt', 'last', '--', '@second.txt', 'positional'], 'prefix'),
                               (['-p', '@~/first file.txt', '@~/second.txt'], '')]:
                file_prompt = run_cli(file_args + args, input=pipe, cwd=root, text=True,
                                             capture_output=True, env=environment, timeout=20)
                assert file_prompt.returncode == 0 and file_prompt.stdout == 'file input complete\n', (file_prompt.stdout, file_prompt.stderr, server.failures)
            file_records = [json.loads(line) for line in file_session.read_text().splitlines()]
            assert [r['message']['content'] for r in file_records if r.get('message', {}).get('role') == 'user'] == [
                [{'text': wrapped}], [{'text': 'prefix' + wrapped + 'last positional'}], [{'text': wrapped}]]
            for flags in ([], ['--mode', 'text'], ['--mode', 'text', '-p'], ['-p', '--mode', 'text']):
                redirected = run_cli(common + flags, input=' \tstdin-only-prompt\r\n',
                                            text=True, capture_output=True, env=environment, timeout=20)
                assert redirected.returncode == 0 and redirected.stdout == 'stdin complete\n', (flags, redirected.stdout, redirected.stderr)
            json_stdin = run_cli(common + ['--mode', 'json'], input='stdin-only-prompt',
                                        text=True, capture_output=True, env=environment, timeout=20)
            assert json_stdin.returncode == 0, json_stdin.stderr
            assert json.loads(json_stdin.stdout.splitlines()[-1])['type'] == 'agent_settled'
            # Input rejection happens before creating a session or loading a library.
            rejected_session = root / 'rejected.jsonl'
            reject_args = common.copy()
            reject_args[-1] = str(rejected_session)
            reject_args.extend(['--native-plugin', str(root / 'missing.so')])
            (root / 'binary.dat').write_bytes(b'bad\x00text')
            (root / 'too-large.txt').write_bytes(b'x' * (1024 * 1024 + 1))
            for names, expected in [(['absent.txt'], b'FileNotFound'), (['binary.dat'], b'UnsupportedInputFile'),
                                    (['tools'], b'InputNotRegularFile'), (['too-large.txt'], b'InputFileTooLarge'),
                                    (['empty.txt'], b'EmptyPrompt')]:
                rejected = run_repo_cli(reject_args + ['-p'] + [f'@{root / name}' for name in names],
                                          input=b'', capture_output=True, env=environment, timeout=20)
                assert rejected.returncode != 0 and expected in rejected.stderr, rejected.stderr
                assert not rejected_session.exists() and rejected.stdout == b''
            for payload, expected in [(b'', b'EmptyPrompt'), (b' \t\r\n', b'EmptyPrompt'),
                                      (b'\xff', b'InvalidStdinUtf8'),
                                      (b'x' * (1024 * 1024 + 1), b'StdinTooLarge')]:
                rejected = run_repo_cli(reject_args + ['-p'], input=payload, capture_output=True,
                                          env=environment, timeout=20)
                assert rejected.returncode != 0 and expected in rejected.stderr, rejected.stderr
                assert not rejected_session.exists()
                assert rejected.stdout == b''
            help_run = run_cli(common + ['--help'], input=b'\xff', capture_output=True,
                                      env=environment, timeout=5)
            assert help_run.returncode == 0 and b'Usage:' in help_run.stdout
            first = run_repo_cli(common + ['--tools', '*', '-p', 'workflow'], input='', text=True, capture_output=True,
                                   env=environment, timeout=20)
            assert first.returncode == 0, first.stderr
            assert first.stdout == 'workflow complete\n', repr(first.stdout)
            assert (root / 'sample.txt').read_text() == 'alpha\ngamma\n'
            records = [json.loads(line) for line in session.read_text().splitlines()]
            read_result = next(r['message'] for r in records if r['type'] == 'message'
                               and r['message']['role'] == 'tool_result' and r['message'].get('tool_name') == 'read')
            assert read_result['content'] == [{'text': 'alpha\ngamma\n'}], read_result
            assert read_result.get('details') is None, read_result
            tool_results = [r['message'] for r in records if r['type'] == 'message'
                            and r['message']['role'] == 'tool_result']
            expected_results = 7 if HAS_SEARCH else 4
            assert len(tool_results) == expected_results
            second = run_repo_cli(common + ['--mode', 'json', 'resume-check'], text=True,
                                    capture_output=True, env=environment, timeout=20)
            assert second.returncode == 0, second.stderr
            events = [json.loads(line) for line in second.stdout.splitlines()]
            assert events[0]['type'] == 'session'
            assert events[-1]['type'] == 'agent_settled'
            assert any(e.get('type') == 'message_end' and
                       e.get('message', {}).get('content') == [{'text': 'resumed correctly'}]
                       for e in events)
            terminal_check(common, environment, session, expected_results)
            terminal_cancel_check(common, environment, root, server)
            terminal_editor_check(common, environment, root)
            terminal_compact_check(common, environment, root)
            auto_compact_config = root / 'auto-compact.json'
            auto_compact_config.write_text(json.dumps({'providers': {'fixture': {
                'api': 'openai-completions',
                'baseUrl': f'http://127.0.0.1:{server.server_port}/auto-compact',
                'apiKey': 'fake-key',
                'models': [{'id': 'compact-model', 'contextWindow': 22000, 'maxTokens': 1024}],
            }}}))
            auto_compact_session = root / 'auto-compact.jsonl'
            auto_args = [str(BINARY), '--no-proxy', '--models-file', str(auto_compact_config),
                         '--provider', 'fixture', '--model', 'compact-model',
                         '--cwd', directory, '--session', str(auto_compact_session)]
            first_auto = run_repo_cli(auto_args + ['-p', 'auto-compact-1:' + ('x' * 10000)],
                                      input='', text=True, capture_output=True, env=environment, timeout=20)
            assert first_auto.returncode == 0 and first_auto.stdout == 'auto 1 ok\n', first_auto.stderr
            second_auto = run_repo_cli(auto_args + ['-p', 'auto-compact-2:' + ('y' * 10000)],
                                       input='', text=True, capture_output=True, env=environment, timeout=20)
            assert second_auto.returncode == 0 and second_auto.stdout == 'auto 2 ok\n', second_auto.stderr
            third_auto = run_repo_cli(auto_args + ['--mode', 'json', 'auto-compact-3:' + ('z' * 20000)],
                                      input='', text=True, capture_output=True, env=environment, timeout=20)
            assert third_auto.returncode == 0, (third_auto.stderr, third_auto.stdout)
            auto_events = [json.loads(line) for line in third_auto.stdout.splitlines()]
            assert any(e.get('type') == 'compaction' and e.get('automatic') is True for e in auto_events), auto_events
            assert any(e.get('type') == 'message_end' and
                       e.get('message', {}).get('content') == [{'text': 'auto compact ok'}]
                       for e in auto_events), auto_events
            spill_session = root / 'bash-spill.jsonl'
            spill_env = dict(environment, TMPDIR=str(root))
            spill_run = run_repo_cli(common[:-1] + [str(spill_session), '--mode', 'json', 'bash-spill'],
                                     input='', text=True, capture_output=True, env=spill_env, timeout=20)
            assert spill_run.returncode == 0, spill_run.stderr
            spill_events = [json.loads(line) for line in spill_run.stdout.splitlines()]
            spill_end = [e for e in spill_events if e.get('type') == 'tool_execution_end'][0]['result']
            assert spill_end['details']['truncation']['truncated'] is True, spill_end
            spill_path = Path(spill_end['details']['fullOutputPath'])
            assert spill_path.parent == root and spill_path.exists(), spill_path
            assert (spill_path.stat().st_mode & 0o777) == 0o600, oct(spill_path.stat().st_mode)
            spill_lines = spill_path.read_text().splitlines()
            assert len(spill_lines) == 2005 and spill_lines[0] == 'B1' and spill_lines[-1] == 'B2005'
            spill_path.unlink()
            # Also verify edit details.diff & firstChangedLine survived in original session JSONL.
            edit_results = [r['message'] for r in records if r['type'] == 'message'
                            and r['message']['role'] == 'tool_result'
                            and r['message'].get('details') and 'diff' in r['message']['details']]
            assert len(edit_results) == 1 and edit_results[0]['details']['firstChangedLine'] == 2, edit_results
            filtered_session = root / 'filtered.jsonl'
            filtered = run_repo_cli(common[:-1] + [str(filtered_session), '--mode', 'json', 'filtered-completion'],
                                      input='', text=True, capture_output=True, env=environment, timeout=20)
            assert filtered.returncode != 0 and 'ProviderFailed' in filtered.stderr, (filtered.stderr, server.failures)
            filtered_events = [json.loads(line) for line in filtered.stdout.splitlines()]
            assert filtered_events[-1] == {'type': 'error', 'error_code': 'ProviderFailed'}, filtered_events
            assert not any(event['type'] == 'tool_execution_start' for event in filtered_events), filtered_events
            assert not (root / 'filtered.txt').exists()
            filtered_roles = [record['message']['role'] for record in map(json.loads, filtered_session.read_text().splitlines())
                              if record['type'] == 'message']
            assert filtered_roles == ['system', 'user'], filtered_roles
            status_session = root / 'shell-status.jsonl'
            status_args = common.copy()
            status_args[-1] = str(status_session)
            result = run_repo_cli(status_args + ['-p', 'shell-status'], input='', text=True,
                                    capture_output=True, env=environment, timeout=20)
            assert result.returncode == 0 and result.stdout == 'shell status complete\n', (result.stderr, server.failures)
            status_records = [json.loads(line) for line in status_session.read_text().splitlines()]
            status_results = [r['message'] for r in status_records if r.get('message', {}).get('role') == 'tool_result']
            assert [r['is_error'] for r in status_results] == [False, True, True], status_results
            # Structured truncation metadata survives durable save/reload, and
            # provider context contains the same bounded read output on resume.
            (root / 'many-lines.txt').write_text('x\n' * 2001)
            zero_args = common.copy()
            zero_args[-1] = str(root / 'read-zero.jsonl')
            result = run_repo_cli(zero_args + ['-p', 'read-zero-limit'], input='', text=True,
                                    capture_output=True, env=environment, timeout=20)
            assert result.returncode == 0 and result.stdout == 'zero limit complete\n', (result.stderr, server.failures)
            read_session = root / 'read-truncation.jsonl'
            read_args = common.copy()
            read_args[-1] = str(read_session)
            for prompt in ('read-truncation', 'read-truncation-resume'):
                result = run_repo_cli(read_args + ['--mode', 'json', prompt], input='', text=True,
                                        capture_output=True, env=environment, timeout=20)
                assert result.returncode == 0, (result.stderr, server.failures)
                read_events = [json.loads(line) for line in result.stdout.splitlines()]
                assert read_events[-1]['type'] == 'agent_settled'
                read_records = [json.loads(line) for line in read_session.read_text().splitlines()]
                saved = [r['message'] for r in read_records if r.get('message', {}).get('role') == 'tool_result']
                assert len(saved) == 1, saved
                truncation = saved[0]['details']['truncation']
                assert truncation == {
                    'content': 'x\n' * 1999 + 'x', 'truncated': True, 'truncatedBy': 'lines',
                    'totalLines': 2001, 'totalBytes': 4002, 'outputLines': 2000, 'outputBytes': 3999,
                    'lastLinePartial': False, 'firstLineExceedsLimit': False, 'maxLines': 2000, 'maxBytes': 51200,
                }, truncation
                if prompt == 'read-truncation':
                    tool_end = next(e for e in read_events if e['type'] == 'tool_execution_end')
                    assert tool_end['result']['details'] == saved[0]['details']
                    message_end = next(e for e in read_events if e['type'] == 'message_end'
                                       and e['message']['role'] == 'tool_result')
                    assert message_end['message'] == saved[0]
            # Branch switching changes the active path without deleting history.
            tree_session = root / 'tree.jsonl'
            tree_args = common.copy()
            tree_args[-1] = str(tree_session)
            result = run_cli(tree_args + ['-p', 'branch-a'], input='', text=True,
                                    capture_output=True, env=environment, timeout=20)
            assert result.returncode == 0 and result.stdout == 'branch-a complete\n', result.stderr
            tree_before = tree_session.read_bytes()
            tree = [json.loads(line) for line in tree_before.splitlines()]
            system_id = next(r['id'] for r in tree if r.get('message', {}).get('role') == 'system')
            a_tip = tree[-1]['id']
            for flags, prompt, expected in [(['--branch', system_id], 'branch-b', 'branch-b complete\n'),
                                             (['--branch=' + a_tip], 'branch-resume', 'branch-resume complete\n')]:
                result = run_cli(tree_args + flags + ['-p', prompt], input='', text=True,
                                        capture_output=True, env=environment, timeout=20)
                assert result.returncode == 0 and result.stdout == expected, (result.stderr, server.failures)
            assert tree_session.read_bytes().startswith(tree_before)
            tree = [json.loads(line) for line in tree_session.read_text().splitlines()]
            assert len([r for r in tree if r['type'] == 'leaf']) == 2
            assert any(r.get('message', {}).get('content') == [{'text': 'branch-b complete'}] for r in tree)
            before_bad_branch = tree_session.read_bytes()
            result = run_cli(tree_args + ['--branch', 'missing', '-p', 'ignored'], input='',
                                    text=True, capture_output=True, env=environment, timeout=20)
            assert result.returncode != 0 and 'UnknownSessionEntry' in result.stderr
            assert tree_session.read_bytes() == before_bad_branch
            result = run_cli(tree_args + ['--branch', system_id, '--native-plugin', str(root / 'missing.so'), '-p', 'ignored'],
                                    input='', text=True, capture_output=True, env=environment, timeout=20)
            assert result.returncode != 0
            assert tree_session.read_bytes() == before_bad_branch, 'plugin startup failure changed the active branch'
            absent_args = tree_args.copy()
            absent_args[-1] = str(root / 'absent-session.jsonl')
            result = run_cli(absent_args + ['--branch', system_id, '-p', 'ignored'], input='',
                                    text=True, capture_output=True, env=environment, timeout=20)
            assert result.returncode != 0 and 'FileNotFound' in result.stderr
            assert not (root / 'absent-session.jsonl').exists()
            # A tip ending at a tool call is reconciled, never executed again.
            interrupted_id = next(r['id'] for r in records if any('tool_call' in p for p in r.get('message', {}).get('content', [])))
            original_sample = (root / 'sample.txt').read_bytes()
            result = run_cli(common + ['--branch', interrupted_id, '-p', 'branch-interrupted'],
                                    input='', text=True, capture_output=True, env=environment, timeout=20)
            assert result.returncode == 0 and result.stdout == 'interrupted branch complete\n', (result.stderr, server.failures)
            assert (root / 'sample.txt').read_bytes() == original_sample
            if environment.get('ZPI_PI_SDK'):
                probe = subprocess.run(['node', str(ROOT / 'scripts/probe-ts-installed.mjs'),
                                        environment['ZPI_PI_SDK']], text=True, capture_output=True,
                                       env=environment, timeout=15)
                assert probe.returncode == 0, probe.stderr
                probe_info = json.loads(probe.stdout)
                assert probe_info['version'] in ('1.5.2', '1.6.0') and probe_info['piAiVersion'] == probe_info['version']
                ext_session = root / 'extension.jsonl'
                ext_args = common.copy()
                ext_args[-1] = str(ext_session)
                ext_args.extend(['--pi-sdk', environment['ZPI_PI_SDK'],
                                 '-e', str(ROOT / '.reference/pi/packages/coding-agent/examples/extensions/hello.ts'),
                                 '-e', str(ROOT / '.reference/pi/packages/coding-agent/examples/extensions/input-transform.ts'),
                                 '-e', str(ROOT / 'scripts/fixtures/ts-extension.ts')])
                extension = run_repo_cli(ext_args + ['-p', '?quick extension-workflow'], text=True,
                                           capture_output=True, env=environment, timeout=20)
                assert extension.returncode == 0, (extension.stderr, server.failures)
                assert extension.stdout == 'extension complete\n', repr(extension.stdout)
                assert not (root / 'denied.txt').exists()
                assert not (root / 'throw-gate.txt').exists()
                assert (root / 'mutated.txt').read_text() == 'changed by extension'
                ext_records = [json.loads(line) for line in ext_session.read_text().splitlines()]
                hello_results = [r['message'] for r in ext_records if r.get('message', {}).get('tool_name') == 'hello']
                assert hello_results[0]['details'] == {'greeted': 'Zig', 'transformed': True}
                assert 'extension handler failed' in extension.stderr
                for index, (flags, expected) in enumerate([
                    (['--no-builtin-tools'], {'hello', 'throw_fixture', 'wait_fixture'}),
                    (['--no-tools', '--tools', '+hello'], {'hello'}),
                    (['--tools', '*', '--exclude-tools', 'hello,throw_*,wait_*'], builtins),
                ]):
                    prompt_name = f'extension-selection-{index}'
                    server.expected_tool_sets[prompt_name] = expected
                    selection_run = run_repo_cli(ext_args + flags + ['-p', prompt_name], input='',
                                                   text=True, capture_output=True, env=environment, timeout=20)
                    assert selection_run.returncode == 0 and selection_run.stdout == 'selection complete\n', (selection_run.stderr, server.failures)
            native_plugins = os.environ.get('ZPI_TEST_NATIVE_PLUGINS', '').split(os.pathsep)
            for plugin_index, plugin in enumerate(filter(None, native_plugins)):
                native_session = root / f'native-{plugin_index}.jsonl'
                native_args = common.copy()
                native_args[-1] = str(native_session)
                native_args.extend(['--native-plugin', plugin])
                for index, (flags, expected) in enumerate([
                    (['--no-builtin-tools'], {'echo_native'}),
                    (['--no-tools', '--tools', '+echo_native'], {'echo_native'}),
                    (['--tools', '*', '--exclude-tools', 'echo_*'], builtins),
                ]):
                    prompt_name = f'native-selection-{plugin_index}-{index}'
                    server.expected_tool_sets[prompt_name] = expected
                    selection_run = run_cli(native_args + flags + ['-p', prompt_name], input='',
                                                   text=True, capture_output=True, env=environment, timeout=20)
                    assert selection_run.returncode == 0 and selection_run.stdout == 'selection complete\n', (selection_run.stderr, server.failures)
                native_run = run_repo_cli(native_args + ['--mode', 'json', 'native-workflow'],
                                            text=True, capture_output=True, env=environment, timeout=20)
                assert native_run.returncode == 0, (native_run.stderr, server.failures)
                native_events = [json.loads(line) for line in native_run.stdout.splitlines()]
                assert native_events[-1]['type'] == 'agent_settled'
                assert any(e['type'] == 'tool_execution_update' and e['id'] == 'native-call' for e in native_events)
                native_records = [json.loads(line) for line in native_session.read_text().splitlines()]
                native_results = [r['message'] for r in native_records if r.get('message', {}).get('role') == 'tool_result']
                assert native_results[-1]['details'] == 'native-call'
                resumed = run_repo_cli(native_args + ['-p', 'native-resume'], text=True,
                                         capture_output=True, env=environment, timeout=20)
                assert resumed.returncode == 0 and resumed.stdout == 'native resumed\n', resumed.stderr
                disabled = run_repo_cli(native_args + ['--no-tools', '-p', 'native-no-tools'], text=True,
                                          capture_output=True, env=environment, timeout=20)
                assert disabled.returncode == 0 and disabled.stdout == 'native disabled\n', disabled.stderr
            # Select Anthropic through a model-level API override on a custom
            # provider. Use a separate persistent session, then reopen it.
            config.write_text(json.dumps({'providers': {'anthropic-fixture': {
                'api': 'openai-completions',
                'baseUrl': f'http://127.0.0.1:{server.server_port}/v1',
                'apiKey': 'fake-anthropic-key',
                'headers': {'X-Fixture': 'anthropic-enabled'},
                'models': [{'id': 'fixture-model', 'api': 'anthropic-messages', 'maxTokens': 2048}],
            }}}))
            anthropic_args = [str(BINARY), '--no-proxy', '--models-file', str(config),
                              '--provider', 'anthropic-fixture', '--cwd', directory,
                              '--session', str(root / 'anthropic.jsonl')]
            system_file.write_bytes(b'\xef\xbb\xbf' + 'custom 规则'.encode())
            system_anthropic_args = anthropic_args.copy()
            system_anthropic_args[-1] = str(root / 'anthropic-system.jsonl')
            for name, flags, expected in [
                ('anthropic-system-first', ['--system-prompt', str(system_file)], 'custom 规则'),
                ('anthropic-system-update', ['--append-system-prompt', 'additional'], 'custom 规则\n\nadditional'),
                ('anthropic-system-reload', [], 'custom 规则\n\nadditional'),
            ]:
                server.expected_system_prompts[name] = expected
                response = run_repo_cli(system_anthropic_args + flags + ['-p', name], input='',
                                          text=True, capture_output=True, env=environment, timeout=20)
                assert response.returncode == 0 and response.stdout == 'system complete\n', (response.stderr, server.failures)
            for prompt, expected in [('anthropic-workflow', 'anthropic complete\n'),
                                     ('anthropic-resume', 'anthropic resumed\n')]:
                response = run_repo_cli(anthropic_args + ['-p', prompt], text=True,
                                          capture_output=True, env=environment, timeout=20)
                assert response.returncode == 0, (response.stderr, server.failures)
                assert response.stdout == expected, repr(response.stdout)
            assert (root / 'anthropic.txt').read_text() == '你好\n'
            # Exercise openai-responses API selection, streaming function_call -> function_call_output,
            # retry backoff, resume, and fail-closed partial tool call rejection.
            config.write_text(json.dumps({'providers': {'responses-fixture': {
                'api': 'openai-responses',
                'baseUrl': f'http://127.0.0.1:{server.server_port}/responses-fixture/v1',
                'apiKey': 'fake-responses-key',
                'headers': {'X-Responses-Fixture': 'enabled'},
                'models': [{'id': 'gpt-5-fixture', 'maxTokens': 2048}],
            }}}))
            responses_args = [str(BINARY), '--no-proxy', '--models-file', str(config),
                              '--provider', 'responses-fixture', '--cwd', directory,
                              '--session', str(root / 'responses.jsonl')]
            for prompt, expected in [('responses-retry', 'responses retried\n'),
                                     ('responses-workflow', 'responses complete\n'),
                                     ('responses-resume', 'responses resumed\n')]:
                response = run_repo_cli(responses_args + ['-p', prompt], text=True,
                                          capture_output=True, env=environment, timeout=20)
                assert response.returncode == 0, (response.stderr, server.failures)
                assert response.stdout == expected, repr(response.stdout)
            assert (root / 'responses.txt').read_text() == '响应成功\n'
            failed_responses = run_repo_cli(responses_args + ['--no-session', '-p', 'responses-fail-tool'],
                                            text=True, capture_output=True, env=environment, timeout=20)
            assert failed_responses.returncode != 0
            assert not (root / 'responses-uncommitted.txt').exists()
            check_https_proxy(root, environment, server)
            check_settings_and_model_switch(root, environment, server)
            check_resume_picker(root, environment)
            check_tree_navigation(root, environment, server)
            check_queued_followup_editing(root, environment, server)
            check_tui_components(root, environment, server)
            assert not server.failures, server.failures
            tools = 'write/edit/read/bash/grep/find/ls' if HAS_SEARCH else 'write/edit/read/bash (search dependencies absent)'
            extensions = ', real pi TS input/tool/gate/details integration' if environment.get('ZPI_PI_SDK') else ' (TS integration skipped: ZPI_PI_SDK unset)'
            native_coverage = f', {sum(bool(p) for p in native_plugins)} native library CLI workflows' if any(native_plugins) else ' (native CLI skipped: ZPI_TEST_NATIVE_PLUGINS unset)'
            print(f'CLI integration passed: {tools}, OpenAI + Anthropic tool loops, session reload and pi v3 import, stdin and @file text inputs, print stdout, JSONL, PTY help/prompt/exit and terminal restoration, Skills, prompt templates and MCP stdio{extensions}{native_coverage}')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

if __name__ == '__main__':
    main()
