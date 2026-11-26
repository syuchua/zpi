#!/usr/bin/env python3
"""Compare native history loading, streamed output and a file read over local RPC."""
import argparse
import hashlib
import json
import math
import os
import platform
import select
import shutil
import statistics
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

MODEL = 'fixture-model'
STAMP = '2026-01-01T00:00:00.000Z'
SESSION_ID = '019b76da-a800-7000-8000-000000000001'
READ_BODY = '0123456789abcdef' * 256 + '\n'
STREAM_CHUNKS = tuple(f'{i:04d}' + 'x' * 1020 for i in range(64))
STREAM_BODY = ''.join(STREAM_CHUNKS)
READ_REPLY = 'Read complete.'
HISTORY_REPLY = 'History verified.'
TIMEOUT = 15


def text(content):
    if isinstance(content, str):
        return content
    return ''.join(part.get('text', '') for part in content or [])


def history_messages(count):
    return [f'Message {i:06d} ' + 'x' * 128 for i in range(1, count + 1)]


def write_history(path, tool, cwd, messages):
    if tool == 'zpi':
        header = dict(type='session', version=1, cwd=str(cwd))
    elif tool == 'pi':
        header = dict(type='session', version=3, id=SESSION_ID, timestamp=STAMP, cwd=str(cwd))
    else:
        header = dict(kind='header', version=4, id=SESSION_ID, createdAt=1, cwd=str(cwd))
    with path.open('w', encoding='utf-8') as output:
        print(json.dumps(header), file=output)
        for i, body in enumerate(messages, 1):
            prev = f'{i - 1:016x}' if i > 1 else None
            entry = dict(type='message', id=f'{i:016x}')
            if tool == 'zpi':
                entry.update(parent_id=prev, message=dict(role='user', content=[dict(text=body)]))
            elif tool == 'pi':
                entry.update(parentId=prev, timestamp=STAMP, message=dict(role='user', content=body, timestamp=1))
            else:
                entry.update(kind='entry', lane='main', seq=i, parentId=prev, timestamp=1,
                             message=dict(kind='user', role='user', content=body, timestamp=1))
            print(json.dumps(entry), file=output)


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        request_started = time.perf_counter_ns()
        try:
            assert self.path == '/v1/chat/completions'
            size = int(self.headers['Content-Length'])
            assert 0 < size <= 16 * 1024 * 1024
            body = self.rfile.read(size)
            body_received = time.perf_counter_ns()
            payload = json.loads(body)
            assert payload['model'] == MODEL and payload['stream'] is True
            messages = payload['messages']
            users = [text(m['content']) for m in messages if m['role'] == 'user']
            tools = [t['function']['name'] for t in payload.get('tools', [])]
            kind = users[-1]
            self.server.requests.append({'request_started_ns': request_started, 'body_received_ns': body_received})
            if kind == 'bench-history':
                assert not tools and users[:-1] == self.server.history, 'history differs from fixture'
                self.respond((HISTORY_REPLY,))
            elif kind == 'bench-stream':
                assert not tools and len(users) == 1
                self.respond(STREAM_CHUNKS)
            elif kind == 'bench-read':
                assert tools == ['read'] and len(users) == 1
                results = [m for m in messages if m['role'] == 'tool']
                if not results:
                    self.respond((), call=True)
                else:
                    assert len(results) == 1 and results[0]['tool_call_id'] == 'call_fixture'
                    assert text(results[0]['content']) in (READ_BODY, READ_BODY.rstrip('\n'))
                    self.respond((READ_REPLY,))
            else:
                raise ValueError('unexpected benchmark prompt')
        except Exception as err:
            self.server.failure = repr(err)
            self.close_connection = True

    def respond(self, chunks, call=False):
        def event(delta, reason):
            chunk = dict(id='chatcmpl-fixture', object='chat.completion.chunk', created=1, model=MODEL,
                         choices=[dict(index=0, delta=delta, finish_reason=reason)])
            return ('data: ' + json.dumps(chunk) + '\n\n').encode()

        if call:
            call_delta = dict(index=0, id='call_fixture', type='function',
                              function=dict(name='read', arguments='{"path":"fixture.txt"}'))
            frames = [event(dict(role='assistant', tool_calls=[call_delta]), 'tool_calls')]
        else:
            frames = [event(dict(role='assistant', content=chunk), None) for chunk in chunks]
            frames.append(event({}, 'stop'))
        frames.append(b'data: [DONE]\n\n')
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(sum(map(len, frames))))
        # Record before any response bytes can be seen by the client.
        self.server.requests[-1]['response_start_ns'] = time.perf_counter_ns()
        self.end_headers()
        for frame in frames:
            self.wfile.write(frame)


class Client:
    def __init__(self, process, server):
        self.process = process
        self.server = server
        self.pending = bytearray()

    def send(self, kind, request_id, **data):
        self.process.stdin.write((json.dumps(dict(type=kind, id=request_id, **data)) + '\n').encode())
        self.process.stdin.flush()

    def read(self, deadline):
        while (offset := self.pending.find(b'\n')) < 0:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise TimeoutError('RPC response deadline')
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError('RPC closed stdout before completion')
            self.pending.extend(chunk)
            if len(self.pending) > 16 * 1024 * 1024:
                raise RuntimeError('RPC record exceeded benchmark limit')
        record = json.loads(self.pending[:offset])
        del self.pending[:offset + 1]
        if record.get('type') == 'error' or (record.get('type') == 'response' and not record['success']):
            raise RuntimeError(f'RPC failure: {record}')
        return time.perf_counter_ns(), record

    def ready(self):
        self.send('get_state', 'ready')
        deadline = time.monotonic() + TIMEOUT
        while True:
            observed, record = self.read(deadline)
            if record.get('type') == 'response' and record.get('id') == 'ready':
                return observed, record['data']

    def turn(self, workload):
        started = time.perf_counter_ns()
        self.send('prompt', 'prompt', message='bench-' + workload)
        deadline = time.monotonic() + TIMEOUT
        observed_deltas = []
        zpi_phases = {}
        first_text = last_text = tool_start = tool_end = None
        while True:
            observed, record = self.read(deadline)
            kind = record['type']
            if kind == 'zpi_performance':
                phase = record['phase']
                zpi_phases[phase] = zpi_phases.get(phase, 0) + record['elapsed_ns']
            delta = record.get('event', {}).get('text_delta') if kind == 'provider_event' else None
            if kind == 'message_update':
                event = record.get('assistantMessageEvent', {})
                if event.get('type') == 'text_delta':
                    delta = event['delta']
            if delta:
                observed_deltas.append(delta)
                if first_text is None:
                    first_text = observed
                last_text = observed
            if kind == 'tool_execution_start':
                assert tool_start is None and record.get('toolCallId', record.get('id')) == 'call_fixture'
                tool_start = observed
            if kind == 'tool_execution_end':
                assert tool_end is None and tool_start is not None
                assert record.get('toolCallId', record.get('id')) == 'call_fixture'
                result = record['result']
                assert not record.get('isError') and not result.get('is_error')
                assert text(result.get('text', result.get('content'))) in (READ_BODY, READ_BODY.rstrip('\n'))
                tool_end = observed
            if kind in ('agent_settled', 'agent_end'):
                assert not record.get('aborted') and not record.get('willRetry')
                break
        expected = {'stream': STREAM_BODY, 'read': READ_REPLY, 'history': HISTORY_REPLY}[workload]
        assert ''.join(observed_deltas) == expected, f'{workload} output differs from fixture'
        ms = 1_000_000
        metrics = {'first_text_ms': (first_text - started) / ms,
                   'last_text_ms': (last_text - started) / ms,
                   'settled_ms': (observed - started) / ms}
        if workload == 'read':
            assert tool_start is not None and tool_end is not None and tool_start <= tool_end <= first_text
            assert len(self.server.requests) == 2
            initial, followup = self.server.requests
            provider_received = initial['body_received_ns']
            provider_reply = initial['response_start_ns']
            followup_received = followup['body_received_ns']
            followup_reply = followup['response_start_ns']
            assert started <= provider_received <= provider_reply <= tool_start
            assert provider_reply <= followup_received <= followup_reply <= first_text
            metrics['submit_to_provider_request_ms'] = (initial['request_started_ns'] - started) / ms
            metrics['provider_request_body_read_ms'] = (provider_received - initial['request_started_ns']) / ms
            metrics['provider_fixture_processing_ms'] = (provider_reply - provider_received) / ms
            metrics['provider_response_to_observed_tool_start_ms'] = (tool_start - provider_reply) / ms
            metrics['tool_response_ms'] = (tool_end - tool_start) / ms
            metrics['submit_to_tool_result_ms'] = (tool_end - started) / ms
            metrics['submit_to_followup_provider_body_ms'] = (followup_received - started) / ms
            metrics['followup_provider_response_to_observed_text_ms'] = (first_text - followup_reply) / ms
            for phase, elapsed_ns in zpi_phases.items():
                metrics['zpi_' + phase + '_ms'] = elapsed_ns / ms
            if self.server.require_timings:
                required = {'tool_execute_only', 'session_append_tool_result', 'request_encode', 'http_connect_and_send',
                            'http_wait_for_response_headers', 'sse_read_decode_and_delivery', 'rpc_tool_result_write'}
                assert required <= zpi_phases.keys(), f'missing timing phases: {required - zpi_phases.keys()}'
        else:
            assert tool_start is None
        return metrics


def benchmark(tool, binary, root, models, env, server, workload, history_count=0, trace=False):
    opts = ['--no-skills', '--no-prompt-templates']
    if tool == 'zpi':
        opts += ['--models-file', str(models), '--no-proxy']
    else:
        opts += ['--no-extensions', '--no-context-files', '--no-approve']
        if tool == 'pi':
            opts += ['--no-mcp']
    command = [str(binary), '--mode', 'rpc', '--provider', 'fixture', '--model', MODEL,
               '--thinking', 'off', '--system-prompt', 'Benchmark fixture.', *opts]
    command += ['--tools', 'read'] if workload == 'read' else ['--no-tools']
    if workload == 'history':
        if tool == 'rpi':
            sessions = root / 'sessions'
            encoded_cwd = str(root).lstrip('/').translate(str.maketrans('/\\:', '---'))
            project_sessions = sessions / f'--{encoded_cwd}--'
            project_sessions.mkdir(parents=True)
            session = project_sessions / f'1970-01-01T00-00-00-001Z_{SESSION_ID}.jsonl'
            command += ['--session-dir', str(sessions), '--session', SESSION_ID]
        else:
            session = root / 'history.jsonl'
            command += ['--session', str(session)]
        write_history(session, tool, root, server.history)
        fixture_bytes = session.stat().st_size
    elif trace:
        session = root / 'timed-read.jsonl'
        command += ['--session', str(session)]
        env['ZPI_RPC_TIMINGS'] = '1'
    else:
        command += ['--no-session']
    server.failure = None
    server.requests = []
    server.require_timings = trace
    with tempfile.TemporaryFile() as stderr:
        started = time.perf_counter_ns()
        process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=stderr)
        try:
            client = Client(process, server)
            ready_time, state = client.ready()
            if workload == 'history':
                if tool == 'zpi':
                    assert Path(state['sessionFile']).resolve() == session
                elif tool == 'pi':
                    assert state['messageCount'] == history_count, state['messageCount']
                else:
                    assert state['leafId'] == f'{history_count:016x}', state['leafId']
                assert not server.requests
            turn = client.turn(workload)
            assert len(server.requests) == (2 if workload == 'read' else 1)
            process.stdin.close()
            process.wait(timeout=TIMEOUT)
            assert process.returncode == 0, f'exit code {process.returncode}'
            if trace:
                records = [json.loads(line) for line in session.read_text().splitlines()]
                assert any(row.get('message', {}).get('role') == 'tool_result' for row in records)
        except Exception as err:
            stderr.seek(0)
            diagnostics = stderr.read(2048).decode(errors='replace').strip()
            raise RuntimeError(f'{tool} {workload}: {err}; provider={server.failure}; stderr={diagnostics}') from err
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()
    if workload == 'history':
        return {'ready_ms': (ready_time - started) / 1_000_000, 'fixture_bytes': fixture_bytes}
    return turn


def summary(values):
    ordered = sorted(values)
    return dict(p50=statistics.median(ordered), p95=ordered[math.ceil(len(ordered) * .95) - 1], samples=values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for tool in ('zpi', 'pi', 'rpi'):
        parser.add_argument('--' + tool, required=True, help='executable path or PATH name')
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--warmup', type=int, default=3)
    parser.add_argument('--messages', type=int, nargs='+', default=[128, 8192])
    parser.add_argument('--zpi-timings', action='store_true', help='Profile persisted Zpi read phase timings via an opt-in local RPC mode')
    args = parser.parse_args()
    if not (1 <= args.samples <= 100 and 0 <= args.warmup <= 20 and all(1 <= n <= 20000 for n in args.messages)):
        parser.error('samples must be 1..100, warmup 0..20, and messages 1..20000')
    binaries = {tool: Path(shutil.which(getattr(args, tool)) or getattr(args, tool)).resolve(strict=True)
                for tool in ('zpi', 'pi', 'rpi')}
    results = {}
    node = shutil.which('node')
    path = os.pathsep.join((os.defpath, str(Path(node).parent))) if node else os.defpath
    with HTTPServer(('127.0.0.1', 0), Provider) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            workloads = [('history', n, False) for n in dict.fromkeys(args.messages)]
            workloads += [('stream', 0, False), ('read', 0, False)]
            if args.zpi_timings:
                workloads.append(('read', 0, True))
            for workload, count, trace in workloads:
                server.history = history_messages(count)
                order = ['zpi'] if trace else list(binaries)
                samples = {tool: [] for tool in order}
                for i in range(args.warmup + args.samples):
                    for tool in order[i % len(order):] + order[:i % len(order)]:
                        with tempfile.TemporaryDirectory(prefix='zpi-bench-rpc-') as directory:
                            root = Path(directory).resolve()
                            agent = root / 'agent'
                            agent.mkdir()
                            models = agent / 'models.json'
                            models.write_text(json.dumps({'providers': {'fixture': {
                                'api': 'openai-completions', 'apiKey': 'benchmark-fixture',
                                'baseUrl': f'http://127.0.0.1:{server.server_port}/v1',
                                'models': [{'id': MODEL, 'name': 'Fixture', 'input': ['text'],
                                            'contextWindow': 1000000, 'maxTokens': 32768}],
                            }}}))
                            (root / 'fixture.txt').write_text(READ_BODY)
                            env = {'PATH': path, 'HOME': str(root), 'PI_CODING_AGENT_DIR': str(agent),
                                   'RPI_CODING_AGENT_DIR': str(agent), 'PI_OFFLINE': '1', 'RPI_OFFLINE': '1'}
                            result = benchmark(tool, binaries[tool], root, models, env, server, workload, count, trace)
                            if i >= args.warmup:
                                samples[tool].append(result)
                label = f'history_{count}' if count else 'read_persisted_timings' if trace else workload
                results[label] = {tool: {key: summary([row[key] for row in values]) for key in values[0]}
                                  for tool, values in samples.items()}
        finally:
            server.shutdown()
            worker.join()
    metadata = {tool: dict(sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                           version=subprocess.check_output([str(binary), '--version'], timeout=TIMEOUT).decode().strip())
                for tool, binary in binaries.items()}
    print(json.dumps(dict(platform=platform.platform(), python=platform.python_version(),
                          script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                          samples=args.samples, warmup=args.warmup, binaries=metadata,
                          stream_chunks=len(STREAM_CHUNKS), stream_bytes=len(STREAM_BODY),
                          read_file_bytes=len(READ_BODY), results=results), indent=2))


if __name__ == '__main__':
    main()
