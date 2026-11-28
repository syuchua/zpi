#!/usr/bin/env python3
"""Black-box client fixture for the Zpi-owned JSONL RPC v1 subset."""
import argparse
import json
import os
import select
import subprocess
import sys
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
        if prompt == "fail":
            body = b'{"error":"provider-secret-should-not-be-logged"}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
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


def check_one_shot_authorization(command, env, root, server):
    audit = root / "secure-rpc-audit.jsonl"
    before = len(server.prompts)
    secret = "denied-prompt-must-not-be-logged"
    secure = command + ["--security=secure", "--audit-log", str(audit),
                        "--allow-capability-once=rpc.control"]
    with subprocess.Popen(secure, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, bufsize=0) as process:
        pending = bytearray()
        try:
            send(process, {"id": "once", "type": "prompt", "message": "hello"})
            accepted = read_record(process, pending)
            assert accepted["id"] == "once" and accepted["success"], accepted
            settled = until(process, pending, lambda record: record["type"] == "agent_settled")
            assert settled["aborted"] is False, settled
            send(process, {"id": "reused", "type": "prompt", "message": secret})
            assert read_record(process, pending) == {"type": "response", "id": "reused",
                                                      "command": "prompt", "success": False,
                                                      "error": "CapabilityDenied"}
            process.stdin.close()
            assert process.wait(timeout=10) == 0
            assert not pending and not process.stdout.read() and not process.stderr.read()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
    assert server.prompts[before:] == ["hello"], server.prompts[before:]
    raw = audit.read_bytes()
    assert secret.encode() not in raw and b"hello" not in raw and b"fixture" not in raw
    events = [json.loads(line) for line in raw.splitlines()]
    assert len(events) == 3, events
    check_audit_pair(events[:2], "allow", "request", "allowed", "allowed")
    check_denial_event(events[2])
    assert len({event["runId"] for event in events}) == 1
    assert [event["eventId"] for event in events] == [1, 2, 3]


def check_audit_pair(events, decision, policy_source, outcome, reason, mode="secure", authorization_reason=None):
    authorization, operation = events
    assert authorization["event"] == "authorization" and authorization["parentId"] is None
    expected_authorization_reason = authorization_reason or ("explicit-grant" if decision == "allow" and policy_source != "compatibility" else reason)
    assert authorization["reason"] == expected_authorization_reason
    assert operation["event"] == "operation" and operation["outcome"] == outcome
    assert operation["reason"] == reason
    assert operation["parentId"] == authorization["eventId"]
    for event in events:
        assert (event["decision"], event["policySource"]) == (decision, policy_source), event
        assert (event["capability"], event["source"], event["mode"]) == ("rpc.control", "rpc", mode), event
        assert event["target"] == {"kind": "request", "summary": ""}
        assert event["runId"] == authorization["runId"]


def check_denial_event(event, policy_source="validation", reason="missing-grant"):
    assert event["event"] == "authorization"
    assert event["parentId"] is None
    assert (event["decision"], event["outcome"], event["policySource"], event["reason"]) == ("deny", "denied", policy_source, reason)
    assert (event["capability"], event["source"], event["mode"]) == ("rpc.control", "rpc", "secure")
    assert event["target"] == {"kind": "request", "summary": ""}


def check_failure_audit(command, env, root, server):
    audit = root / "failure-rpc-audit.jsonl"
    secure = command + ["--security=secure", "--audit-log", str(audit),
                        "--allow-capability=rpc.control"]
    with subprocess.Popen(secure, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, bufsize=0) as process:
        pending = bytearray()
        send(process, {"id": "failure", "type": "prompt", "message": "fail"})
        accepted = read_record(process, pending)
        assert accepted["success"] and accepted["data"]["disposition"] == "started", accepted
        terminal = until(process, pending, lambda record: record["type"] == "error")
        assert terminal["error_code"] == "HttpRequestFailed", terminal
        assert read_record(process, pending) == {"type": "agent_settled", "aborted": False}
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        assert not process.stdout.read() and not process.stderr.read()
    raw = audit.read_bytes()
    assert b"provider-secret" not in raw and b'"fail"' not in raw and b"fixture" not in raw
    events = [json.loads(line) for line in raw.splitlines()]
    assert len(events) == 2, events
    check_audit_pair(events, "allow", "invocation", "failed", "failed")
    assert server.prompts[-1] == "fail"


def check_mcp_denial(command, env, root):
    audit = root / "mcp-denial-audit.jsonl"
    marker = root / "mcp-server-started"
    script = root / "mcp-fixture.py"
    script.write_text("from pathlib import Path\nPath('mcp-server-started').write_text('started')\n")
    mcp = [sys.executable, str(script)]
    # Prove the fixture leaves a marker if the executable actually starts.
    subprocess.run(mcp, cwd=root, env=env, check=True, timeout=10)
    assert marker.read_text() == "started"
    marker.unlink()
    argv = command + ["--no-session", "--security=secure", "--audit-log", str(audit),
                      "--allow-capability=mcp.start", "--mcp-stdio", "probe", "--", *mcp]
    result = subprocess.run(argv, cwd=root, input=b"", capture_output=True, env=env, timeout=10)
    assert result.returncode != 0 and not result.stdout, result
    assert b"CapabilityDenied" in result.stderr
    assert not marker.exists()
    raw = audit.read_bytes()
    assert all(value not in raw for value in (b"fixture", script.name.encode(), str(root).encode()))
    records = [json.loads(line) for line in raw.splitlines()]
    assert len(records) == 2, records
    mcp_auth, process_denial = records
    assert all(record["event"] == "authorization" for record in records)
    assert process_denial["runId"] == mcp_auth["runId"]
    assert (mcp_auth["capability"], mcp_auth["source"], mcp_auth["target"]["kind"]) == ("mcp.start", "mcp", "server")
    assert mcp_auth["decision"] == "allow" and mcp_auth["outcome"] == "allowed"
    assert (process_denial["capability"], process_denial["source"], process_denial["target"]["kind"]) == ("process.exec", "mcp", "command")
    assert (process_denial["decision"], process_denial["outcome"], process_denial["policySource"]) == ("deny", "denied", "validation")
    assert process_denial["parentId"] == mcp_auth["eventId"]


def check_component_denials(binary, env, root, server):
    shared = [str(binary), "--print", "--no-session", "--cwd", str(root),
              "--provider", "openai", "--model", "fixture-model", "--no-proxy",
              "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "fixture",
              "--security=secure"]
    plugin = root / "native-must-not-open.dylib"
    native_audit = root / "native-denial-audit.jsonl"
    native = subprocess.run(shared + ["--audit-log", str(native_audit), "--native-plugin", str(plugin), "denial"],
                            cwd=root, capture_output=True, env=env, timeout=10)
    assert native.returncode != 0 and not native.stdout, native
    assert b"CapabilityDenied" in native.stderr and not plugin.exists()
    native_events = [json.loads(line) for line in native_audit.read_bytes().splitlines()]
    assert len(native_events) == 1, native_events
    denial = native_events[0]
    assert (denial["event"], denial["capability"], denial["source"], denial["target"]["kind"]) == ("authorization", "native_plugin.load", "native_plugin", "plugin")
    assert (denial["decision"], denial["outcome"], denial["policySource"]) == ("deny", "denied", "validation")
    assert str(plugin).encode() not in native_audit.read_bytes()

    # A local stand-in for Node marks process startup without requiring an SDK.
    marker = root / "typescript-host-started"
    node = root / "node"
    node.write_text('#!/bin/sh\nprintf started > typescript-host-started\nexit 1\n')
    node.chmod(0o700)
    extension_env = dict(env, PATH=str(root) + os.pathsep + env["PATH"])
    extension = root / "denied-extension.ts"
    extension_args = ["--pi-sdk", str(root), "--extension-host", str(root / "fixture-host.mjs"),
                      "-e", str(extension), "denial"]
    typescript_audit = root / "typescript-denial-audit.jsonl"
    typescript = subprocess.run(shared + ["--audit-log", str(typescript_audit),
                                          "--allow-capability=extension.load"] + extension_args,
                                cwd=root, capture_output=True, env=extension_env, timeout=10)
    assert typescript.returncode != 0 and not typescript.stdout, typescript
    assert b"CapabilityDenied" in typescript.stderr
    assert not marker.exists()
    events = [json.loads(line) for line in typescript_audit.read_bytes().splitlines()]
    assert len(events) == 2, events
    extension_auth, process_denial = events
    assert (extension_auth["capability"], extension_auth["source"], extension_auth["target"]["kind"]) == ("extension.load", "typescript", "plugin")
    assert (extension_auth["decision"], extension_auth["outcome"], extension_auth["policySource"]) == ("allow", "allowed", "invocation")
    assert (process_denial["capability"], process_denial["source"], process_denial["target"]["kind"]) == ("process.exec", "typescript", "command")
    assert (process_denial["decision"], process_denial["outcome"], process_denial["policySource"]) == ("deny", "denied", "validation")
    assert process_denial["parentId"] == extension_auth["eventId"]
    assert extension_auth["runId"] == process_denial["runId"]
    assert not any(secret in typescript_audit.read_bytes() for secret in (str(extension).encode(), b"fixture"))
    allowed_audit = root / "typescript-allowed-audit.jsonl"
    allowed = subprocess.run(shared + ["--audit-log", str(allowed_audit),
                                       "--allow-capability=extension.load", "--allow-capability=process.exec"] + extension_args,
                             cwd=root, capture_output=True, env=extension_env, timeout=10)
    assert allowed.returncode != 0 and marker.exists(), (allowed.returncode, allowed.stdout, allowed.stderr, marker.exists())
    started_events = [json.loads(line) for line in allowed_audit.read_bytes().splitlines()]
    assert len(started_events) == 4, started_events
    extension_authorization, process_authorization, process_outcome, extension_outcome = started_events
    assert (extension_authorization["event"], extension_authorization["capability"], extension_authorization["policySource"]) == ("authorization", "extension.load", "invocation")
    assert (process_authorization["event"], process_authorization["capability"], process_authorization["policySource"]) == ("authorization", "process.exec", "invocation")
    assert (process_outcome["event"], process_outcome["capability"], process_outcome["outcome"]) == ("operation", "process.exec", "allowed")
    assert process_outcome["parentId"] == process_authorization["eventId"]
    assert (extension_outcome["event"], extension_outcome["capability"], extension_outcome["outcome"]) == ("operation", "extension.load", "unknown")
    assert extension_outcome["parentId"] == extension_authorization["eventId"]


def check_persistent_policy(command, env, root, server):
    audit = root / "persistent-rpc-audit.jsonl"
    policy = root / "private-policy.json"
    policy.write_text(json.dumps({"version": 1, "grants": [
        {"capability": "rpc.control", "effect": "allow"},
    ]}))
    policy.chmod(0o600)
    frame = b'{"id":"persistent","type":"prompt","message":"hello"}\n'
    secure = command + ["--security=secure", "--audit-log", str(audit)]
    selected = ["--security-policy", policy.name]
    before = len(server.prompts)

    def run(argv):
        return subprocess.run(argv, input=frame, capture_output=True, cwd=root, env=env, timeout=10)

    for _ in range(2):
        result = run(secure + selected)
        assert result.returncode == 0 and not result.stderr, result
        records = [json.loads(line) for line in result.stdout.splitlines()]
        assert records[0]["success"] and records[-1] == {"type": "agent_settled", "aborted": False}, records

    result = run(secure)
    assert result.returncode == 0 and not result.stderr, result
    assert json.loads(result.stdout)["error"] == "CapabilityDenied"
    raw = audit.read_bytes()
    assert all(marker not in raw for marker in (b"fixture", b"hello", policy.name.encode(), b'"persistent","type"'))
    events = [json.loads(line) for line in raw.splitlines()]
    assert len(events) == 5, events
    check_audit_pair(events[:2], "allow", "persistent", "allowed", "allowed")
    check_audit_pair(events[2:4], "allow", "persistent", "allowed", "allowed")
    check_denial_event(events[4])
    assert [record["eventId"] for record in events] == [1, 2, 1, 2, 1]
    assert len({record["runId"] for record in events}) == 3

    result = run(command + selected)
    assert result.returncode != 0 and not result.stdout, result
    assert b"PersistentPolicyRequiresSecureMode" in result.stderr
    policy.chmod(0o644)
    result = run(secure + selected)
    assert result.returncode != 0 and not result.stdout, result
    assert b"InsecureSecurityPolicyPermissions" in result.stderr
    policy.chmod(0o600)
    hardlink = root / "policy-hardlink.json"
    os.link(policy, hardlink)
    result = run(secure + selected)
    assert result.returncode != 0 and not result.stdout, result
    assert b"InsecureSecurityPolicyPermissions" in result.stderr
    hardlink.unlink()
    symlink = root / "policy-symlink.json"
    symlink.symlink_to(policy)
    fifo = root / "policy.fifo"
    os.mkfifo(fifo, 0o600)
    for path in (symlink, fifo):
        result = run(secure + ["--security-policy", path.name])
        assert result.returncode != 0 and not result.stdout, result
    policy.write_bytes(b" " * (64 * 1024 + 1))
    result = run(secure + selected)
    assert result.returncode != 0 and not result.stdout, result
    assert b"SecurityPolicyTooLarge" in result.stderr
    assert audit.read_bytes() == raw

    policy.write_text(json.dumps({"version": 1, "grants": [
        {"capability": "rpc.control", "effect": "deny"},
    ]}))
    result = run(secure + selected + ["--allow-capability=rpc.control"])
    assert result.returncode == 0 and not result.stderr, result
    assert json.loads(result.stdout)["error"] == "CapabilityDenied"
    appended = audit.read_bytes()
    assert appended.startswith(raw)
    denied = json.loads(appended[len(raw):])
    check_denial_event(denied, "persistent", "explicit-deny")
    assert denied["runId"] not in {record["runId"] for record in events}
    assert denied["eventId"] == 1
    assert server.prompts[before:] == ["hello", "hello"], server.prompts[before:]


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
        compatibility_audit = root / "compatibility-rpc-audit.jsonl"
        process = subprocess.Popen(command + ["--audit-log", str(compatibility_audit)], cwd=root,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
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
            audit_raw = compatibility_audit.read_bytes()
            assert not any(marker in audit_raw for marker in (b"hello", b"abort-me", b"after-abort", b"fixture"))
            audited = [json.loads(line) for line in audit_raw.splitlines()]
            assert len(audited) == 6, audited
            for index, outcome in enumerate(("allowed", "unknown", "allowed")):
                check_audit_pair(audited[2 * index:2 * index + 2], "allow", "compatibility", outcome,
                                 outcome, mode="compatibility", authorization_reason="compatibility-implicit-allow")
            records = [json.loads(line) for line in session.read_bytes().split(b"\n") if line]
            assistants = [r["message"]["content"] for r in records if r.get("message", {}).get("role") == "assistant"]
            assert assistants == [[{"text": "hello from rpc"}], [{"text": "reused after abort"}]], assistants
            truncated = subprocess.run(command, input=b'{"type":"get_state"}', capture_output=True, env=env, timeout=10)
            assert truncated.returncode == 0 and not truncated.stderr, truncated
            assert json.loads(truncated.stdout) == {"type": "response", "command": "parse", "success": False,
                                                    "error": "Unterminated RPC record"}
            no_session = command[:-2] + ["--no-session"]
            check_one_shot_authorization(no_session, env, root, server)
            check_failure_audit(no_session, env, root, server)
            check_mcp_denial(command[:-2], env, root)
            check_component_denials(Path(command[0]), env, root, server)
            check_persistent_policy(no_session, env, root, server)
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
    print("Zpi RPC v1 fixture passed: framing, state, streaming, abort, EOF, grant lifetimes and audit")


if __name__ == "__main__":
    main()
