#!/usr/bin/env python3
"""Measure fresh Zpi processes with synthetic sessions and a loopback provider."""
import argparse
import hashlib
import json
import math
import os
import platform
import signal
import statistics
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = payload['messages']
        if self.path != '/v1/chat/completions' or len(messages) != self.server.expected_messages:
            self.send_error(400)
            return
        if messages[-1] != {'role': 'user', 'content': 'Resume benchmark'} or 'tools' in payload:
            self.send_error(400)
            return
        chunk = {'choices': [{'index': 0, 'delta': {'content': 'ok'}, 'finish_reason': 'stop'}]}
        body = f'data: {json.dumps(chunk)}\n\ndata: [DONE]\n\n'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def measure(command, directory, environment, expected):
    # wait4 supplies resource usage for this child, avoiding cumulative peaks
    # across samples. Output files avoid pipe backpressure before wait4.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        start = time.perf_counter_ns()
        with subprocess.Popen(command, cwd=directory, env=environment, stdin=subprocess.DEVNULL,
                              stdout=stdout, stderr=stderr) as process:
            signal.alarm(30)
            try:
                _, status, usage = os.wait4(process.pid, 0)
                elapsed = time.perf_counter_ns() - start
                process.returncode = os.waitstatus_to_exitcode(status)
            except TimeoutError:
                process.kill()
                raise RuntimeError(f'{command[1]} exceeded the sample deadline') from None
            finally:
                signal.alarm(0)
        stdout.seek(0)
        stderr.seek(0)
        if process.returncode != 0 or stdout.read() != expected or stderr.read(1):
            raise RuntimeError(f'{command[1]} returned unexpected output or exit status {process.returncode}')
    rss_bytes = usage.ru_maxrss if platform.system() == 'Darwin' else usage.ru_maxrss * 1024
    return {'elapsed_ns': elapsed, 'peak_rss_bytes': rss_bytes,
            'cpu_seconds': usage.ru_utime + usage.ru_stime}


def sample_timeout(_signal, _frame):
    raise TimeoutError


def summarize(samples):
    durations = sorted(sample['elapsed_ns'] for sample in samples)
    return {'p50_ms': statistics.median(durations) / 1_000_000,
            'p95_ms': durations[math.ceil(0.95 * len(durations)) - 1] / 1_000_000,
            'peak_rss_bytes': max(sample['peak_rss_bytes'] for sample in samples),
            'samples': samples}


def create_session(path, directory, count):
    with path.open('w', encoding='utf-8') as transcript:
        print(json.dumps({'type': 'session', 'version': 3, 'id': 'bench', 'cwd': str(directory)}), file=transcript)
        for index in range(count):
            print(json.dumps({'type': 'message', 'id': str(index), 'parentId': str(index - 1) if index else None,
                              'message': {'role': 'user', 'content': f'Synthetic message {index} ' + 'x' * 128}}),
                  file=transcript)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--environment', required=True, help='Build mode and execution environment for the report')
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('--samples must be between 1 and 100')
    binary = args.binary.resolve(strict=True)
    signal.signal(signal.SIGALRM, sample_timeout)
    with tempfile.TemporaryDirectory(prefix='zpi-benchmark-') as scratch, HTTPServer(('127.0.0.1', 0), Provider) as server:
        directory = Path(scratch).resolve()
        environment = {'PATH': os.defpath, 'HOME': scratch}
        base = [str(binary)]
        version = subprocess.check_output(base + ['--version'], cwd=directory, env=environment,
                                          stdin=subprocess.DEVNULL, timeout=30)
        report = {'system': platform.system(), 'release': platform.release(), 'machine': platform.machine(),
                  'environment': args.environment, 'zpi_version': version.decode().strip(),
                  'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'version': summarize([measure(base + ['--version'], directory, environment, version)
                                        for _ in range(args.samples)]), 'sessions': []}
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            config = directory / 'models.json'
            config.write_text(json.dumps({'providers': {'bench': {
                'api': 'openai-completions', 'baseUrl': f'http://127.0.0.1:{server.server_port}/v1',
                'models': [{'id': 'benchmark'}],
            }}}), encoding='utf-8')
            for count in (128, 8192):
                source = directory / 'source.jsonl'
                session = directory / 'converted.jsonl'
                create_session(source, directory, count)
                server.expected_messages = count + 1
                import_command = base + ['--import-pi-session', str(source), '--session', str(session)]
                resume_command = base + ['--models-file', str(config), '--provider', 'bench',
                                         '--no-skills', '--no-prompt-templates', '--no-proxy', '--no-tools',
                                         '--session', str(session), '-p', 'Resume benchmark']
                imports, resumes = [], []
                import_bytes = None
                for _ in range(args.samples):
                    imports.append(measure(import_command, directory, environment, b''))
                    if import_bytes is None:
                        import_bytes = session.read_bytes()
                    elif session.read_bytes() != import_bytes:
                        raise RuntimeError('repeated import produced a different transcript')
                    resumes.append(measure(resume_command, directory, environment, b'ok\n'))
                    if not session.read_bytes().startswith(import_bytes):
                        raise RuntimeError('resume rewrote imported history')
                    session.unlink()
                report['sessions'].append({'history_messages': count, 'source_bytes': source.stat().st_size,
                                           'import': summarize(imports), 'resume': summarize(resumes)})
        finally:
            server.shutdown()
            thread.join()
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
