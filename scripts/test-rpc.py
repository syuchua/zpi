#!/usr/bin/env python3
"""Black-box client fixture for the Zpi-owned JSONL RPC v1 subset."""
import argparse
import json
import os
import select
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = request["messages"][-1]["content"]
        self.server.prompts.append(prompt)
        if prompt == "abort-me":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b'data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}\n\n')
            self.wfile.flush()
            self.server.abort_release.wait(10)
            return
        if prompt not in ("hello", "after-abort\u2028text\u2029"):
            self.send_error(400)
            return
        content = "hello from rpc" if prompt == "hello" else "reused after abort"
        body = ("data: " + json.dumps({"choices": [{"index": 0,
                "delta": {"content": content}, "finish_reason": "stop"}]}) + "\n\n").encode()
        body += b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def read_record(process, pending, timeout=10):
    deadline = time.monotonic() + timeout
    while b"\n" not in pending:
        remaining = deadline - time.monotonic()
        assert remaining > 0, ("RPC timeout", bytes(pending), process.poll())
        assert select.select([process.stdout], [], [], remaining)[0], ("RPC timeout", bytes(pending))
        data = os.read(process.stdout.fileno(), 65536)
        assert data, ("RPC EOF", bytes(pending), process.poll())
        pending.extend(data)
    line, _, rest = pending.partition(b"\n")
    pending[:] = rest
    return json.loads(line)


def send_bytes(process, data):
    pending = memoryview(data)
    while pending:
        pending = pending[os.write(process.stdin.fileno(), pending):]


def send(process, value, ending=b"\n"):
    send_bytes(process, json.dumps(value, ensure_ascii=False).encode() + ending)


def until(process, pending, predicate, timeout=10):
    deadline = time.monotonic() + timeout
    skipped = []
    for _ in range(100):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            record = read_record(process, pending, remaining)
        except AssertionError as error:
            raise AssertionError(("RPC event deadline", skipped, error)) from error
        if predicate(record):
            return record
        if record["type"] in ("agent_settled", "error"):
            raise AssertionError(("Unexpected terminal record", record, skipped))
        skipped.append(record)
    raise AssertionError(("Expected RPC event missing", skipped))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="zpi-rpc-fixture-") as directory:
        root = Path(directory).resolve()
        server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        server.abort_release = threading.Event()
        server.prompts = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        session = root / "rpc.jsonl"
        command = [str(binary), "--mode", "rpc", "--no-tools", "--no-proxy", "--cwd", str(root),
                   "--endpoint", f"http://127.0.0.1:{server.server_port}/v1",
                   "--api-key", "fixture", "--provider", "openai", "--model", "fixture-model",
                   "--session", str(session)]
        env = {"PATH": os.defpath, "HOME": str(root)}
        process = subprocess.Popen(command, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, bufsize=0)
        pending = bytearray()
        try:
            for frame in (b'{bad json}\n', b'{"id":"a","id":"b"}\n', b'"\xff"\n',
                          b' ' * (1024 * 1024 + 1) + b'\n'):
                send_bytes(process, frame)
                reply = read_record(process, pending)
                assert reply['type'] == 'response' and reply['command'] == 'parse' and not reply['success'], reply
                assert 'id' not in reply, reply
            send(process, {"id": "empty", "type": "prompt", "message": " \t"})
            assert read_record(process, pending) == {"type": "response", "id": "empty", "command": "prompt",
                                                     "success": False, "error": "Expected a nonempty text message"}
            send(process, {"id": "idle", "type": "get_state"}, ending=b"\r\n")
            state = read_record(process, pending)
            assert state["id"] == "idle" and state["command"] == "get_state"
            assert state["success"] and state["data"]["isStreaming"] is False
            assert state["data"]["model"]["id"] == "fixture-model" and state["data"]["pendingMessageCount"] == 0
            assert not session.exists() and not server.prompts
            send(process, {"id": "hello", "type": "prompt", "message": "hello"})
            accepted = read_record(process, pending)
            assert accepted == {"type": "response", "id": "hello", "command": "prompt",
                                "success": True, "data": {"disposition": "started"}}
            event = until(process, pending, lambda value: value.get("event") == {"text_delta": "hello from rpc"})
            assert event["type"] == "provider_event"
            settled = until(process, pending, lambda value: value.get("type") == "agent_settled")
            assert settled["aborted"] is False
            send(process, {"id": "abort-me", "type": "prompt", "message": "abort-me"})
            accepted = read_record(process, pending)
            assert accepted["id"] == "abort-me" and accepted["data"]["disposition"] == "started"
            partial = until(process, pending, lambda value: value.get("event") == {"text_delta": "partial"})
            assert partial["type"] == "provider_event"
            send(process, {"id": "busy", "type": "prompt", "message": "hello"})
            busy = read_record(process, pending)
            assert busy["id"] == "busy" and not busy["success"] and busy["error"] == "Agent is busy"
            send(process, {"id": "cancel", "type": "abort"})
            assert read_record(process, pending) == {"type": "error", "error_code": "Canceled"}
            assert read_record(process, pending) == {"type": "agent_settled", "aborted": True}
            cancel = read_record(process, pending)
            assert cancel == {"type": "response", "id": "cancel", "command": "abort", "success": True}
            send(process, {"id": "reuse", "type": "prompt", "message": "after-abort\u2028text\u2029"})
            accepted = read_record(process, pending)
            assert accepted["id"] == "reuse" and accepted["data"]["disposition"] == "started"
            # EOF is not an abort: the accepted final turn settles before process exit.
            process.stdin.close()
            event = until(process, pending, lambda value: value.get("event") == {"text_delta": "reused after abort"})
            assert event["type"] == "provider_event"
            settled = until(process, pending, lambda value: value.get("type") == "agent_settled")
            assert settled["aborted"] is False
            assert process.wait(timeout=10) == 0
            assert not pending and process.stdout.read() == b"" and process.stderr.read() == b""
            assert server.prompts == ["hello", "abort-me", "after-abort\u2028text\u2029"], server.prompts
            records = [json.loads(line) for line in session.read_bytes().split(b"\n") if line]
            assistants = [r["message"]["content"] for r in records if r.get("message", {}).get("role") == "assistant"]
            assert assistants == [[{"text": "hello from rpc"}], [{"text": "reused after abort"}]], assistants
            truncated = subprocess.run(command, input=b'{"type":"get_state"}', capture_output=True, env=env, timeout=10)
            assert truncated.returncode == 0 and not truncated.stderr, truncated
            assert json.loads(truncated.stdout) == {"type": "response", "command": "parse", "success": False,
                                                    "error": "Unterminated RPC record"}
        finally:
            server.abort_release.set()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if not process.stdin.closed:
                process.stdin.close()
            process.stdout.close()
            process.stderr.close()
            server.shutdown()
            thread.join()
    print("Zpi RPC v1 black-box fixture passed: framing, state, stream, busy, abort, reuse and EOF")


if __name__ == "__main__":
    main()
