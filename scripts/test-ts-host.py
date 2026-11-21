#!/usr/bin/env python3
"""Real pi loader/runner subprocess fixtures. Explicit SDK path; no installs."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
SDK = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ['ZPI_PI_SDK']).resolve()

class Host:
    def __init__(self):
        self.process = subprocess.Popen(['node', str(ROOT / 'scripts/ts-host.mjs'), str(SDK)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
        self.records = queue.Queue()
        self.stderr = bytearray()
        def output():
            for line in self.process.stdout:
                try:
                    self.records.put(json.loads(line))
                except Exception as exc:
                    self.records.put(exc)
            self.records.put(EOFError('host stdout closed'))
        def errors():
            for chunk in iter(lambda: self.process.stderr.read(4096), b''):
                self.stderr.extend(chunk)
        self.threads = [threading.Thread(target=output, daemon=True), threading.Thread(target=errors, daemon=True)]
        for thread in self.threads:
            thread.start()
        self.sequence = 0
        self.events = []

    def send(self, op, payload=None, timeout=10000):
        self.sequence += 1
        record = {'id': self.sequence, 'op': op, 'payload': payload or {}, 'timeoutMs': timeout}
        self.process.stdin.write((json.dumps(record) + '\n').encode())
        self.process.stdin.flush()
        return self.sequence

    def receive(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            record = self.records.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(record, BaseException):
                raise AssertionError((record, self.stderr.decode(errors='replace')))
            if predicate(record):
                return record
            self.events.append(record)

    def call(self, op, payload=None, timeout=10000):
        ident = self.send(op, payload, timeout)
        return self.receive(lambda r: r.get('id') == ident and 'ok' in r)

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            stream.close()
        for thread in self.threads:
            thread.join(timeout=2)


def check():
    host = Host()
    try:
        if host.process.poll() is not None:
            raise AssertionError(('TS host exited during startup', host.stderr.decode(errors='replace')))
        result = host.call('load', {'cwd': str(ROOT), 'paths': [
            str(ROOT / '.reference/pi/packages/coding-agent/examples/extensions/hello.ts'),
            str(ROOT / '.reference/pi/packages/coding-agent/examples/extensions/input-transform.ts'),
            str(ROOT / 'scripts/fixtures/ts-extension.ts'),
        ]})
        assert result['ok'], result
        assert result['result']['version'] in ('1.5.2', '1.6.0')
        assert result['result']['context']['hasUI'] is False
        assert {t['name'] for t in result['result']['tools']} == {'hello', 'wait_fixture', 'throw_fixture'}
        transformed = host.call('input', {'text': '?quick Zig'})
        assert transformed['result'] == {'action': 'transform', 'text': 'Respond briefly in 1-2 sentences: Zig'}, transformed
        assert host.call('input', {'text': 'prefix Zig'})['result'] == {'action': 'transform', 'text': 'transformed Zig'}
        assert host.call('input', {'text': 'handled'})['result']['action'] == 'handled'
        assert host.call('input', {'text': '?quick Zig', 'source': 'extension'})['result']['action'] == 'continue'
        greeting = host.call('tool_exec', {'name': 'hello', 'callId': 'hello-1', 'arguments': {'name': 'Zig'}})
        assert greeting['ok'], greeting
        assert greeting['result']['content'] == [{'type': 'text', 'text': 'Hello, Zig!'}]
        assert greeting['result']['details'] == {'greeted': 'Zig'}
        failed_tool = host.call('tool_exec', {'name': 'throw_fixture', 'callId': 'throw-1', 'arguments': {}})
        assert failed_tool['ok'] is False and failed_tool['kind'] == 'tool_error', failed_tool
        # A result hook failure occurs after the built-in effect has completed;
        # preserve the underlying tool result, then accept another operation.
        result_hook = host.call('tool_result', {'name': 'write', 'callId': 'write-1',
            'arguments': {'path': 'mutated.txt'}, 'content': [{'type': 'text', 'text': 'Wrote file'}],
            'details': None, 'isError': False})
        assert result_hook['ok'] and result_hook['result'] is None, result_hook
        assert host.call('input', {'text': 'prefix after failure'})['result']['text'] == 'transformed after failure'
        generic_schema = {'type': 'object', 'additionalProperties': True}
        gate = host.call('tool_call', {'name': 'denied', 'callId': 'gate-1', 'arguments': {}, 'schema': generic_schema})
        assert gate['result']['block'] is True, gate
        changed = host.call('tool_call', {'name': 'mutate', 'callId': 'gate-2', 'arguments': {'value': 'original'}, 'schema': generic_schema})
        assert changed['result']['input'] == {'value': 'changed'}
        denied = host.call('tool_call', {'name': 'throw-gate', 'callId': 'gate-3', 'arguments': {}, 'schema': generic_schema})
        assert denied['ok'] is False and 'fixture gate failure' in denied['error'], denied
        assert host.call('input', {'text': 'throw-input'})['result']['action'] == 'continue'
        if not any(e.get('type') == 'extension_error' and e['error']['message'] == 'fixture input failure' for e in host.events):
            event = host.receive(lambda r: r.get('type') == 'extension_error')
            host.events.append(event)
        assert any(e.get('type') == 'extension_error' and e['error']['message'] == 'fixture input failure' for e in host.events)
        ident = host.send('tool_exec', {'name': 'wait_fixture', 'callId': 'wait-1', 'arguments': {}})
        host.receive(lambda r: r.get('id') == ident and r.get('type') == 'tool_update')
        busy = host.call('input', {'text': 'busy'})
        assert busy['ok'] is False and busy['error'] == 'HostBusy', busy
        cancel_id = host.send('cancel', {'id': ident})
        canceled = host.receive(lambda r: r.get('id') == cancel_id and 'ok' in r)
        assert canceled['result']['canceled'] is True
        finished = host.receive(lambda r: r.get('id') == ident and 'ok' in r)
        assert finished['ok'] is False, finished
        assert host.call('input', {'text': 'prefix after cancel'})['result']['text'] == 'transformed after cancel'
        assert host.call('shutdown')['result']['closed']
        assert host.process.wait(timeout=5) == 0
        print('TS host fixtures passed: real upstream hello/input-transform, SDK imports, tool gates/mutations, errors, progress, cancel, shutdown')
    finally:
        host.close()

def check_deadline():
    host = Host()
    try:
        assert host.call('load', {'cwd': str(ROOT), 'paths': [
            str(ROOT / 'scripts/fixtures/ts-extension.ts'),
        ]})['ok']
        ident = host.send('tool_exec', {'name': 'wait_fixture', 'callId': 'deadline', 'arguments': {}}, timeout=100)
        response = host.receive(lambda r: r.get('id') == ident and 'ok' in r)
        assert response['ok'] is False and response['kind'] == 'fatal', response
        assert response['error'] == 'HostDeadlineExceeded', response
        assert host.process.wait(timeout=5) == 1
        for thread in host.threads:
            thread.join(timeout=2)
        remaining = list(host.records.queue) + host.events
        assert not any(isinstance(r, dict) and r.get('id') == ident and 'ok' in r for r in remaining), remaining
        print('TS host deadline fixture passed: one terminal response, flushed before exit')
    finally:
        host.close()

if __name__ == '__main__':
    check()
    check_deadline()
