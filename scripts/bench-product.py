#!/usr/bin/env python3
"""Measure Zpi against a fixed PTY, synthetic sessions and a loopback SSE provider."""
import argparse
import errno
import fcntl
import hashlib
import json
import math
import os
import platform
import pty
import select
import statistics
import struct
import subprocess
import tempfile
import termios
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

READY = b'\x1b[?2004h'
ALT_SCREEN = b'\x1b[?1049h'
FRAME_END = b'\x1b[?2026l'
PASTE_OFF = b'\x1b[?2004l'
PICKER = b'Up/Down move  Enter switch  s summarize  Esc cancel'
STREAM_TEXT = ('x' * 63 + '\n') * 4096


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        size = int(self.headers['Content-Length'])
        request = json.loads(self.rfile.read(size))
        messages = request['messages']
        prompt = messages[-1]['content']
        if prompt == 'benchmark first token':
            chunks = ['BenchFirstToken']
        elif prompt == 'benchmark long stream':
            chunks = [STREAM_TEXT[i:i+4096] for i in range(0, len(STREAM_TEXT), 4096)]
            chunks.append('BenchStreamDone')
        elif prompt.startswith('<conversation>\n'):
            chunks = ['BenchCompactedSummary']
        elif prompt == 'benchmark context':
            self.server.context_requests.append({
                'messages': len(messages), 'request_bytes': size,
                'max_tokens': request['max_tokens'],
            })
            chunks = ['BenchContextReply']
        else:
            self.send_error(400)
            return
        body = bytearray()
        for index, text in enumerate(chunks):
            choice = {'index': 0, 'delta': {'content': text},
                      'finish_reason': 'stop' if index == len(chunks) - 1 else None}
            body.extend(f'data: {json.dumps({"choices": [choice]})}\n\n'.encode())
        body.extend(b'data: [DONE]\n\n')
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Terminal:
    def __init__(self, command, directory, environment):
        self.master, slave = pty.openpty()
        self.pending = bytearray()
        self.bytes_read = 0
        self.read_at = None
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            self.started = time.perf_counter_ns()
            self.process = subprocess.Popen(command, cwd=directory, env=environment,
                                            stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)

    def read(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([self.master], [], [], remaining)[0]:
            raise TimeoutError(f'PTY read deadline: {bytes(self.pending[-300:])!r}')
        try:
            data = os.read(self.master, 65536)
            self.bytes_read += len(data)
            self.read_at = time.perf_counter_ns()
            return data
        except OSError as error:
            if error.errno == errno.EIO:
                return b''
            raise

    def expect(self, marker):
        deadline = time.monotonic() + 45
        while (offset := self.pending.find(marker)) < 0:
            chunk = self.read(deadline)
            if not chunk:
                raise RuntimeError(f'PTY closed before {marker!r}: {bytes(self.pending[-500:])!r}')
            self.pending.extend(chunk)
        del self.pending[:offset + len(marker)]
        return self.read_at

    def ready(self):
        self.expect(READY)
        return self.expect(FRAME_END)

    def idle_after_turn(self):
        # Ignore the busy editor's enable marker, which precedes the reply.
        self.expect(PASTE_OFF)
        return self.ready()

    def send(self, data):
        pending = memoryview(data)
        while pending:
            pending = pending[os.write(self.master, pending):]

    def elapsed(self, data, marker):
        started = time.perf_counter_ns()
        self.send(data)
        return self.expect(marker) - started

    def finish(self):
        self.send(b'/exit\n')
        deadline = time.monotonic() + 10
        while self.read(deadline):
            pass
        # Reap once, using wait4 rather than Popen.poll/wait so RSS is per sample.
        while True:
            pid, status, usage = os.wait4(self.process.pid, os.WNOHANG)
            if pid:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError('PTY closed without process exit')
            time.sleep(.001)
        self.process.returncode = os.waitstatus_to_exitcode(status)
        if self.process.returncode:
            raise RuntimeError(f'Zpi exited with {self.process.returncode}')
        return usage.ru_maxrss * (1 if platform.system() == 'Darwin' else 1024)

    def close(self):
        if self.process.returncode is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)


@contextmanager
def terminal(command, directory, environment, session=None):
    args = command + (['--session', str(session)] if session else ['--no-session'])
    instance = Terminal(args, directory, environment)
    try:
        yield instance
    finally:
        instance.close()


def write_session(path, cwd, count, padding):
    with path.open('w', encoding='utf-8') as out:
        print(json.dumps({'type': 'session', 'version': 1, 'cwd': str(cwd)}), file=out)
        for i in range(1, count + 1):
            role = 'user' if i % 2 else 'assistant'
            print(json.dumps({'type': 'message', 'id': f'{i:016x}',
                              'parent_id': f'{i - 1:016x}' if i > 1 else None,
                              'message': {'role': role, 'content': [{'text': f'Message {i}: ' + 'x' * padding}]}}),
                  file=out)


def stats(values, scale=1):
    ordered = sorted(values)
    return {'p50': statistics.median(ordered) / scale,
            'p95': ordered[math.ceil(.95 * len(ordered)) - 1] / scale,
            'max': ordered[-1] / scale, 'samples': [x / scale for x in values]}


def measure(command, root, env, server, history, compact, count):
    values = {}
    with terminal(command, root, env) as tty:
        values['first_screen'] = tty.ready() - tty.started
        started = time.perf_counter_ns()
        tty.send(b'benchmark first token\n')
        first = tty.expect(b'BenchFirstToken')
        values['launch_to_first_text'] = first - tty.started
        values['submit_to_first_text'] = first - started
        tty.idle_after_turn()
        tty.finish()
    with terminal(command, root, env) as tty:
        tty.ready()
        values['stream_completion'] = tty.elapsed(b'benchmark long stream\n', b'BenchStreamDone')
        tty.idle_after_turn()
        values['stream_peak_rss'] = tty.finish()
    original = history.read_bytes()
    with terminal(command, root, env, history) as tty:
        values['session_restore'] = tty.ready() - tty.started
        started = time.perf_counter_ns()
        tty.send(b'z')
        tty.expect(b' z')
        values['editor_update'] = tty.expect(FRAME_END) - started
        tty.send(b'\x7f')
        tty.expect(FRAME_END)
        values['tree_open'] = tty.elapsed(b'/tree\n', PICKER)
        previous = b'\x1b[7m>          ' + f'{count - 1:016x}'.encode()
        started = time.perf_counter_ns()
        tty.send(b'\x1b[A')
        tty.expect(previous)
        values['tree_select_previous'] = tty.expect(PICKER) - started
        tty.send(b'\x1b')
        tty.ready()
        tty.finish()
    if history.read_bytes() != original:
        raise RuntimeError('read-only session fixture changed')
    request_start = len(server.context_requests)
    with terminal(command, root, env, compact) as tty:
        tty.ready()
        started = time.perf_counter_ns()
        tty.send(b'benchmark context\n')
        tty.expect(b'BenchContextReply')
        values['before_compaction_turn'] = tty.idle_after_turn() - started
        started = time.perf_counter_ns()
        tty.send(b'/compact benchmark\n')
        tty.expect(b'[compacted:')
        values['compact'] = tty.ready() - started
        started = time.perf_counter_ns()
        tty.send(b'benchmark context\n')
        tty.expect(b'BenchContextReply')
        values['after_compaction_turn'] = tty.idle_after_turn() - started
        tty.finish()
    records = [json.loads(line) for line in compact.read_text().splitlines()]
    [entry] = [record for record in records if record['type'] == 'compaction']
    before, after = server.context_requests[request_start:]
    if entry['summary'] != 'BenchCompactedSummary' or not entry['first_kept_id'] or not 0 < after['messages'] < before['messages']:
        raise RuntimeError(f'unexpected compaction result: {entry!r}, {before!r}, {after!r}')
    return values, {'estimated_tokens_before': entry['tokens_before'], 'before': before, 'after': after}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--messages', type=int, default=8192)
    parser.add_argument('--message-padding', type=int, default=128)
    parser.add_argument('--environment', required=True, help='Hardware, OS and build description')
    parser.add_argument('--tui-mode', choices=('fullscreen', 'regular'), default='regular')
    parser.add_argument('--restore-only', action='store_true', help='Measure launch to editor readiness and process RSS on resume')
    args = parser.parse_args()
    if not (1 <= args.samples <= 100 and 64 <= args.messages <= 20000 and 32 <= args.message_padding <= 512):
        parser.error('samples must be 1..100, messages 64..20000 and padding 32..512')
    binary = args.binary.resolve(strict=True)
    timings, contexts = [], []
    with tempfile.TemporaryDirectory(prefix='zpi-product-bench-') as tmp, HTTPServer(('127.0.0.1', 0), Provider) as server:
        root = Path(tmp).resolve()
        agent_dir = root / 'agent'
        agent_dir.mkdir()
        (agent_dir / 'settings.json').write_text(json.dumps({'compaction': {'enabled': False, 'keepRecentTokens': 512}}))
        env = {'PATH': os.defpath, 'HOME': str(root), 'TERM': 'xterm-256color', 'PI_CODING_AGENT_DIR': str(agent_dir)}
        config = root / 'models.json'
        config.write_text(json.dumps({'providers': {'bench': {'api': 'openai-completions',
            'baseUrl': f'http://127.0.0.1:{server.server_port}/v1', 'apiKey': 'fixture',
            'models': [{'id': 'bench', 'contextWindow': 128000, 'maxTokens': 1024}]}}}))
        command = [str(binary), '--models-file', str(config), '--provider', 'bench', '--no-tools',
                   '--no-proxy', '--no-skills', '--no-prompt-templates', '--tui-mode', args.tui_mode]
        history, compact = root / 'history.jsonl', root / 'compact.jsonl'
        write_session(history, root, args.messages, args.message_padding)
        compact_count = min(args.messages, 1024)
        server.context_requests = []
        if args.restore_only:
            original = history.read_bytes()
            samples = []
            for _ in range(args.samples):
                with terminal(command, root, env, history) as tty:
                    entered = tty.expect(ALT_SCREEN) if args.tui_mode == 'fullscreen' else None
                    ready = tty.ready()
                    output_bytes = tty.bytes_read - len(tty.pending)
                    peak_rss = tty.finish()
                samples.append((ready - tty.started, output_bytes, peak_rss,
                                (entered - tty.started, ready - entered) if entered is not None else None))
            if history.read_bytes() != original:
                raise RuntimeError('read-only session fixture changed')
            print(json.dumps({
                'environment': args.environment,
                'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'tui_mode': args.tui_mode, 'session_messages': args.messages,
                'session_bytes': len(original), 'pty_columns': 80, 'pty_rows': 24,
                'restore_ms': stats([sample[0] for sample in samples], 1e6),
                'pty_bytes_read_at_ready': stats([sample[1] for sample in samples]),
                'process_peak_rss_bytes': stats([sample[2] for sample in samples]),
                'fullscreen_milestone_ms': ({
                    'launch_to_alternate_screen': stats([sample[3][0] for sample in samples], 1e6),
                    'alternate_screen_to_ready': stats([sample[3][1] for sample in samples], 1e6),
                } if args.tui_mode == 'fullscreen' else {}),
            }, indent=2))
            return
        if args.tui_mode == 'fullscreen':
            parser.error('use --restore-only for fullscreen; the full suite uses regular-mode output markers')
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            for _ in range(args.samples):
                write_session(compact, root, compact_count, args.message_padding)
                result, context = measure(command, root, env, server, history, compact, args.messages)
                timings.append(result)
                contexts.append(context)
        finally:
            server.shutdown()
            worker.join()
        report = {
            'system': platform.system(), 'os_release': platform.release(), 'machine': platform.machine(),
            'python': platform.python_version(), 'environment': args.environment,
            'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'binary_version': subprocess.check_output([str(binary), '--version'], env=env, timeout=10).decode().strip(),
            'sample_count': args.samples, 'pty_columns': 80, 'pty_rows': 24, 'tui_mode': args.tui_mode,
            'session_messages': args.messages, 'session_bytes': history.stat().st_size,
            'session_message_padding': args.message_padding, 'compaction_input_messages': compact_count,
            'stream_text_bytes': len(STREAM_TEXT) + len('BenchStreamDone'),
            'latency_ms': {key: stats([run[key] for run in timings], 1e6)
                           for key in timings[0] if key != 'stream_peak_rss'},
            'long_stream_peak_rss_bytes': stats([run['stream_peak_rss'] for run in timings]),
            'compaction_context': contexts,
        }
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
