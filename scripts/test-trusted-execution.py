#!/usr/bin/env python3
"""End-to-end Trusted Execution regressions for Zpi (Phases 1-4):
- Phase 1: path/command/network rules, TUI one-time approvals, structured headless denials, audit
- Phase 2: shared OS sandbox (Seatbelt / Landlock+seccomp / bwrap) + canonical file-tool checks
- Phase 3: child environment allowlisting, credential isolation, escape regressions
  (out-of-workspace writes, network access, child processes, symlinks, MCP, TypeScript)
- Phase 4: worktree-isolated parallel subagents & explicit-policy unattended fail-stop mode
"""
import argparse
import errno
import json
import os
import pty
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class ScriptedProvider(BaseHTTPRequestHandler):
    """OpenAI-compatible SSE fake provider driven by per-prompt scripted tool plans."""

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body["messages"]
        self.server.requests.append(messages)

        # Find initial user prompt and count prior tool_result messages.
        user_prompt = ""
        tool_results = []
        for msg in messages:
            if msg["role"] == "user" and not user_prompt:
                content = msg["content"]
                user_prompt = content if isinstance(content, str) else content[0]["text"]
            elif msg["role"] == "tool":
                tool_results.append(msg["content"])

        plan = self.server.plans.get(user_prompt)
        if plan is None:
            self.send_error(400, f"unknown prompt: {user_prompt}")
            return

        step = len(tool_results)
        if step < len(plan):
            tool_name, tool_args = plan[step]
            call_id = f"call_{step}_{int(time.time() * 1000) % 100000}"
            payload = {
                "choices": [{
                    "index": 0,
                    "delta": {
                        "tool_calls": [{
                            "index": 0,
                            "id": call_id,
                            "type": "function",
                            "function": {
                                "name": tool_name,
                                "arguments": json.dumps(tool_args),
                            },
                        }],
                    },
                    "finish_reason": "tool_calls",
                }],
            }
        else:
            summary = json.dumps({"results": tool_results})
            payload = {
                "choices": [{
                    "index": 0,
                    "delta": {"content": summary},
                    "finish_reason": "stop",
                }],
            }

        data = ("data: " + json.dumps(payload) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.server.get_paths.append(self.path)
        if self.path == "/allowed":
            body = b"<html><title>Allowed</title><body>allowed body</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/denied":
            body = b"<html><title>Denied</title><body>denied body</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


class TcpProbe:
    """Loopback TCP listener counting any connection attempts from confined children."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.connections = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self):
        while not self._stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections += 1
            conn.close()

    def close(self):
        self._stop.set()
        self.sock.close()
        self._thread.join(timeout=2)


def write_private_policy(path: Path, grants: list):
    path.write_text(json.dumps({"version": 1, "grants": grants}))
    path.chmod(0o600)


def run_zpi(binary, args, cwd, env, timeout=20):
    return subprocess.run(
        [str(binary)] + args,
        cwd=str(cwd),
        env=env,
        input="",
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def check_phase1_policy_and_headless_denials(binary, server, root, ws, env):
    audit = root / "p1-policy-audit.jsonl"
    policy = root / "p1-policy.json"
    allowed_dir = ws / "allowed"
    allowed_dir.mkdir()
    denied_dir = ws / "denied"
    denied_dir.mkdir()

    write_private_policy(policy, [
        {"capability": "filesystem.write", "effect": "allow", "target": {"kind": "path", "value": str(allowed_dir), "match": "subtree"}},
        {"capability": "process.exec", "effect": "allow", "target": {"kind": "command", "value": "echo", "match": "prefix"}},
        {"capability": "process.exec", "effect": "deny", "target": {"kind": "command", "value": "echo blocked", "match": "exact"}},
        {"capability": "network.connect", "effect": "allow", "target": {"kind": "url", "value": f"http://127.0.0.1:{server.server_port}/allowed", "match": "exact"}},
    ])

    server.plans["p1-rules"] = [
        ("write", {"path": "allowed/ok.txt", "content": "ok"}),
        ("write", {"path": "denied/no.txt", "content": "nope"}),
        ("bash", {"command": "echo safe_prefix"}),
        ("bash", {"command": "echo safe_prefix; echo injected"}),
        ("bash", {"command": "echo blocked"}),
        ("web_fetch", {"url": f"http://127.0.0.1:{server.server_port}/allowed"}),
        ("web_fetch", {"url": f"http://127.0.0.1:{server.server_port}/denied"}),
    ]

    common = [
        "--mode", "json", "--no-session", "--cwd", str(ws),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-provider-secret",
        "--security=secure", "--security-policy", str(policy), "--audit-log", str(audit),
        "--allow-loopback-web-fetch",
        "p1-rules",
    ]
    res = run_zpi(binary, common, ws, env)
    assert res.returncode == 0, (res.stdout, res.stderr)

    # Verify effects
    assert (allowed_dir / "ok.txt").read_text() == "ok"
    assert not (denied_dir / "no.txt").exists()
    assert "/allowed" in server.get_paths
    assert "/denied" not in server.get_paths

    # Verify structured headless denials in JSONL events
    events = [json.loads(line) for line in res.stdout.splitlines() if line.strip()]
    tool_ends = [e for e in events if e.get("type") == "tool_execution_end"]
    assert len(tool_ends) == 7, tool_ends
    # denied write, injected bash, explicitly denied bash, denied web_fetch
    for idx, expected_cap, expected_kind, expected_reason in [
        (1, "filesystem.write", "path", "missing-grant"),
        (3, "process.exec", "command", "missing-grant"),
        (4, "process.exec", "command", "explicit-deny"),
        (6, "network.connect", "url", "missing-grant"),
    ]:
        details = tool_ends[idx]["result"].get("details")
        assert details is not None, (idx, tool_ends[idx])
        assert details["type"] == "authorization_denied", details
        assert details["code"] == "CapabilityDenied", details
        assert details["capability"] == expected_cap, details
        assert details["targetKind"] == expected_kind, details
        assert details["reason"] == expected_reason, details

    # Audit log must have zero leaked paths/commands/URLs/credentials.
    audit_raw = audit.read_text()
    for secret in ("sk-provider-secret", "safe_prefix", "injected", "/allowed", "/denied", "denied/no.txt"):
        assert secret not in audit_raw, (secret, audit_raw)
    print("  [ok] Phase 1: path/command/network rules + structured headless denials + audit redaction")


def check_phase1_tui_one_time_approval(binary, server, root, ws, env):
    audit = root / "p1-tui-approval-audit.jsonl"
    server.plans["p1-tui-approve"] = [
        ("write", {"path": "approved-once.txt", "content": "yes"}),
        ("write", {"path": "denied-second.txt", "content": "no"}),
    ]

    argv = [
        str(binary), "--tui-mode", "regular", "--no-session", "--cwd", str(ws),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-provider-secret",
        "--security=secure", "--audit-log", str(audit),
        "--no-skills", "--no-prompt-templates",
    ]

    pid, master = pty.fork()
    if pid == 0:
        os.chdir(ws)
        os.execve(str(binary), argv, env)

    transcript = bytearray()

    def read_until(marker, start=0, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            pos = transcript.find(marker, start)
            if pos != -1:
                return pos + len(marker)
            remaining = deadline - time.monotonic()
            assert remaining > 0, ("TUI timeout waiting for", marker, bytes(transcript[start:]))
            if not select.select([master], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    raise AssertionError(("TUI exited early", marker, bytes(transcript))) from exc
                raise
            assert chunk, bytes(transcript)
            transcript.extend(chunk)

    try:
        pos = read_until(b"Ctrl-D exits")
        # Wait for prompt
        pos = read_until(b"\x1b[36m>\x1b[0m ", pos)
        os.write(master, b"p1-tui-approve\n")
        # First approval prompt -> approve once with 'y'
        pos = read_until(b"Allow once? [y/N]", pos)
        os.write(master, b"y")
        # Second approval prompt (proves one-time!) -> deny with 'n'
        pos = read_until(b"Allow once? [y/N]", pos)
        os.write(master, b"n")
        # Wait for turn completion and prompt return
        pos = read_until(b"approved-once.txt", pos)
        pos = read_until(b"\x1b[?2004l", pos)
        pos = read_until(b"\x1b[36m>\x1b[0m ", pos)
        os.write(master, b"\x04")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            wpid, status = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                assert os.waitstatus_to_exitcode(status) == 0, status
                pid = 0
                break
            if select.select([master], [], [], 0.1)[0]:
                try:
                    os.read(master, 4096)
                except OSError:
                    break
        assert pid == 0, "TUI did not exit cleanly after Ctrl-D"
    finally:
        os.close(master)
        if pid != 0:
            os.kill(pid, 9)
            os.waitpid(pid, 0)

    assert (ws / "approved-once.txt").read_text() == "yes"
    assert not (ws / "denied-second.txt").exists()

    records = [json.loads(line) for line in audit.read_text().splitlines() if line.strip()]
    auths = [r for r in records if r["event"] == "authorization" and r["capability"] == "filesystem.write"]
    ops = [r for r in records if r["event"] == "operation" and r["capability"] == "filesystem.write"]
    assert len(auths) == 2, records
    assert (auths[0]["decision"], auths[0]["policySource"], auths[0]["reason"]) == ("allow", "approval", "interactive-approval"), auths[0]
    assert (auths[1]["decision"], auths[1]["policySource"], auths[1]["reason"]) == ("deny", "approval", "interactive-denial"), auths[1]
    assert len(ops) == 1 and ops[0]["outcome"] == "allowed" and ops[0]["parentId"] == auths[0]["eventId"], ops
    assert "approved-once.txt" not in audit.read_text()
    assert "denied-second.txt" not in audit.read_text()
    print("  [ok] Phase 1: TUI one-time approval (approve + deny) and audit records")


def check_phase2_and_3_escape_regressions(binary, server, root, ws, outside, real_home, tcp_probe, env):
    audit = root / "p23-escape-audit.jsonl"
    policy = root / "p23-policy.json"
    write_private_policy(policy, [
        {"capability": "filesystem.read", "effect": "allow"},
        {"capability": "filesystem.write", "effect": "allow"},
        {"capability": "process.exec", "effect": "allow"},
        {"capability": "mcp.start", "effect": "allow"},
        {"capability": "extension.load", "effect": "allow"},
    ])

    # Prepare outside files & symlinks inside workspace
    outside_secret = outside / "outside-secret.txt"
    outside_secret.write_text("OUTSIDE_SECRET_DATA")
    (ws / "link-outside.txt").symlink_to(outside_secret)
    (ws / "dir-link").symlink_to(outside)
    (ws / "dangling-link.txt").symlink_to(outside / "dangling-target.txt")
    (ws / "inside.txt").write_text("hello inside\n")

    bash_escape = outside / "bash-escape.txt"
    tmp_escape = Path(f"/tmp/zpi-escape-regression-{os.getpid()}.txt")
    if tmp_escape.exists():
        tmp_escape.unlink()
    bg_escape = outside / "bg-escape.txt"
    grandchild_escape = outside / "grandchild-escape.txt"
    subagent_escape = outside / "subagent-escape.txt"
    mcp_escape = outside / "mcp-escape.txt"
    ts_escape = outside / "ts-escape.txt"

    # Build minimal MCP stdio server script (outside ws to verify explicit MCP script reads still work)
    mcp_dir = root / "mcp-bin"
    mcp_dir.mkdir()
    mcp_script = mcp_dir / "probe_mcp.py"
    mcp_script.write_text(f"""import json, os, socket, sys
from pathlib import Path

for line in sys.stdin:
    msg = json.loads(line)
    req_id = msg.get("id")
    method = msg.get("method")
    if method == "initialize":
        resp = {{"jsonrpc": "2.0", "id": req_id, "result": {{
            "protocolVersion": "2025-11-25",
            "serverInfo": {{"name": "probe", "version": "1.0"}},
            "capabilities": {{"tools": {{}}}},
        }}}}
    elif method == "notifications/initialized":
        continue
    elif method == "tools/list":
        resp = {{"jsonrpc": "2.0", "id": req_id, "result": {{"tools": [{{
            "name": "probe_escape",
            "description": "Probe sandbox and env isolation",
            "inputSchema": {{"type": "object", "properties": {{}}}},
        }}]}}}}
    elif method == "tools/call":
        report = {{}}
        report["env_openai"] = os.environ.get("OPENAI_API_KEY", "ABSENT")
        report["env_aws"] = os.environ.get("AWS_SECRET_ACCESS_KEY", "ABSENT")
        report["env_allowed"] = os.environ.get("ZPI_ALLOWED_VAR", "ABSENT")
        try:
            Path({str(mcp_escape)!r}).write_text("pwned")
            report["outside_write"] = "ESCAPED"
        except Exception as e:
            report["outside_write"] = "BLOCKED"
        try:
            c = socket.create_connection(("127.0.0.1", {tcp_probe.port}), 1)
            c.close()
            report["network"] = "ESCAPED"
        except Exception:
            report["network"] = "BLOCKED"
        try:
            Path({str(real_home / ".zpi/agent/models.json")!r}).read_text()
            report["cred_read"] = "ESCAPED"
        except Exception:
            report["cred_read"] = "BLOCKED"
        try:
            Path("mcp-inside.txt").write_text("mcp-ok")
            report["inside_write"] = "OK"
        except Exception as e:
            report["inside_write"] = f"ERR:{{e}}"
        resp = {{"jsonrpc": "2.0", "id": req_id, "result": {{
            "content": [{{"type": "text", "text": json.dumps(report)}}],
            "isError": False,
        }}}}
    else:
        continue
    sys.stdout.write(json.dumps(resp) + "\\n")
    sys.stdout.flush()
""")

    # Build minimal Node TypeScript extension host fixture
    ts_dir = root / "ts-host-fixture"
    ts_dir.mkdir()
    ts_sdk = ts_dir / "fake-sdk"
    ts_sdk.mkdir()
    ts_ext = ts_dir / "probe-ext.ts"
    ts_ext.write_text("// probe extension\n")
    ts_host = ts_dir / "ts-host.mjs"
    ts_host.write_text(f"""import fs from 'node:fs';
import net from 'node:net';
import readline from 'node:readline';

const rl = readline.createInterface({{ input: process.stdin, crlfDelay: Infinity }});
rl.on('line', async (line) => {{
  const req = JSON.parse(line);
  if (req.op === 'load') {{
    process.stdout.write(JSON.stringify({{
      id: req.id, ok: true, result: {{
        protocol: 'zpi-ts-host', protocolVersion: 1, version: '1.6.0',
        tools: [{{ name: 'ts_probe', description: 'Probe TS sandbox', parameters: {{ type: 'object', properties: {{}} }} }}],
      }}
    }}) + '\\n');
    return;
  }}
  if (req.op === 'input') {{
    process.stdout.write(JSON.stringify({{ id: req.id, ok: true, result: {{ action: 'continue' }} }}) + '\\n');
    return;
  }}
  if (req.op === 'tool_call') {{
    process.stdout.write(JSON.stringify({{ id: req.id, ok: true, result: {{ block: false, input: req.payload.arguments }} }}) + '\\n');
    return;
  }}
  if (req.op === 'tool_result') {{
    process.stdout.write(JSON.stringify({{ id: req.id, ok: true, result: {{}} }}) + '\\n');
    return;
  }}
  if (req.op === 'tool_exec') {{
    const report = {{
      env_openai: process.env.OPENAI_API_KEY || 'ABSENT',
      env_aws: process.env.AWS_SECRET_ACCESS_KEY || 'ABSENT',
      env_allowed: process.env.ZPI_ALLOWED_VAR || 'ABSENT',
    }};
    try {{ fs.writeFileSync({str(ts_escape)!r}, 'pwned'); report.outside_write = 'ESCAPED'; }}
    catch {{ report.outside_write = 'BLOCKED'; }}
    try {{ fs.readFileSync({str(real_home / ".zpi/agent/models.json")!r}, 'utf8'); report.cred_read = 'ESCAPED'; }}
    catch {{ report.cred_read = 'BLOCKED'; }}
    try {{ fs.writeFileSync('ts-inside.txt', 'ts-ok'); report.inside_write = 'OK'; }}
    catch (e) {{ report.inside_write = 'ERR:' + e.message; }}
    report.network = await new Promise((resolve) => {{
      const s = net.createConnection({{ host: '127.0.0.1', port: {tcp_probe.port} }});
      s.on('connect', () => {{ s.destroy(); resolve('ESCAPED'); }});
      s.on('error', () => resolve('BLOCKED'));
      setTimeout(() => {{ s.destroy(); resolve('BLOCKED'); }}, 1000);
    }});
    process.stdout.write(JSON.stringify({{
      id: req.id, ok: true, result: {{
        content: [{{ type: 'text', text: JSON.stringify(report) }}],
        isError: false,
      }}
    }}) + '\\n');
    return;
  }}
  if (req.op === 'shutdown') {{
    process.stdout.write(JSON.stringify({{ id: req.id, ok: true, result: {{}} }}) + '\\n');
    process.exit(0);
  }}
}});
""")

    node_bin = shutil.which("node")
    assert node_bin, "node is required for TypeScript host escape regression"

    # Subagent child prompt plan (run without -e extension wrapper so child inherits bash)
    server.plans["subagent-parent"] = [
        ("subagent", {"name": "confined-child", "task": "subagent-probe"}),
    ]
    server.plans["subagent-probe"] = [
        ("bash", {"command": f"printf '%s|%s' \"${{OPENAI_API_KEY:-ABSENT}}\" \"${{ZPI_ALLOWED_VAR:-ABSENT}}\" > sub-env.txt && (echo pwn > '{subagent_escape}' 2>/dev/null || echo BLOCKED_OUTSIDE) && ({sys.executable} -c \"import socket; socket.create_connection(('127.0.0.1', {tcp_probe.port}), 1)\" 2>/dev/null || echo NET_BLOCKED)"}),
    ]

    # Parent escape test plan covering file tools, bash, bg_run, MCP, and TypeScript host
    server.plans["escape-suite"] = [
        # 1. Built-in file tools canonical-path & symlink checks
        ("read", {"path": "../outside/outside-secret.txt"}),
        ("read", {"path": "link-outside.txt"}),
        ("write", {"path": "../outside/tool-write-escape.txt", "content": "pwn"}),
        ("write", {"path": "dir-link/escape.txt", "content": "pwn"}),
        ("write", {"path": "dangling-link.txt", "content": "pwn"}),
        ("edit", {"path": "link-outside.txt", "oldText": "OUTSIDE", "newText": "PWNED"}),
        # 2. bash out-of-workspace writes (including /tmp and via symlink) + grandchild + env + cred read
        ("bash", {"command": f"echo pwn > '{bash_escape}'"}),
        ("bash", {"command": f"echo pwn > '{tmp_escape}'"}),
        ("bash", {"command": "echo pwn > link-outside.txt"}),
        ("bash", {"command": f"/bin/sh -c 'printf \"%s|%s|%s\" \"${{OPENAI_API_KEY:-ABSENT}}\" \"${{AWS_SECRET_ACCESS_KEY:-ABSENT}}\" \"${{ZPI_ALLOWED_VAR:-ABSENT}}\"'"}),
        ("bash", {"command": f"cat '{real_home / '.ssh/id_rsa'}'"}),
        ("bash", {"command": f"/bin/sh -c \"echo pwn > '{grandchild_escape}'\""}),
        # 3. Network access blocked for bash
        ("bash", {"command": f"{sys.executable} -c \"import socket; socket.create_connection(('127.0.0.1', {tcp_probe.port}), 1)\""}),
        # 4. Background command out-of-workspace write + network blocked
        ("bg_run", {"name": "bg-escape", "command": f"echo pwn > '{bg_escape}'; {sys.executable} -c \"import socket; socket.create_connection(('127.0.0.1', {tcp_probe.port}), 1)\""}),
        # 5. MCP probe
        ("mcp__probe__probe_escape", {}),
        # 6. TypeScript host probe
        ("ts_probe", {}),
    ]

    secret_env = dict(env)
    secret_env["OPENAI_API_KEY"] = "sk-env-openai-secret"
    secret_env["ANTHROPIC_API_KEY"] = "sk-env-anthropic-secret"
    secret_env["AWS_SECRET_ACCESS_KEY"] = "aws-env-secret"
    secret_env["ZPI_TEST_SECRET"] = "must-not-leak"
    secret_env["ZPI_ALLOWED_VAR"] = "explicitly-allowed-value"

    args = [
        "--print", "--no-session", "--cwd", str(ws),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-cli-secret",
        "--security=secure", "--security-policy", str(policy), "--audit-log", str(audit),
        "--env-allow", "ZPI_ALLOWED_VAR",
        "--tools", "read,write,edit,bash,bg_run,subagent,mcp__probe__probe_escape,ts_probe",
        "--pi-sdk", str(ts_sdk), "--extension-host", str(ts_host), "-e", str(ts_ext),
        "--mcp-stdio", "probe", "--", sys.executable, str(mcp_script),
    ]
    # Note: --mcp-stdio consumes remaining argv until next --mcp-stdio, so place prompt BEFORE --mcp-stdio!
    args = [
        "--print", "--no-session", "--cwd", str(ws),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-cli-secret",
        "--security=secure", "--security-policy", str(policy), "--audit-log", str(audit),
        "--env-allow", "ZPI_ALLOWED_VAR",
        "--tools", "read,write,edit,bash,bg_run,subagent,mcp__probe__probe_escape,ts_probe",
        "--pi-sdk", str(ts_sdk), "--extension-host", str(ts_host), "-e", str(ts_ext),
        "escape-suite",
        "--mcp-stdio", "probe", "--", sys.executable, str(mcp_script),
    ]

    res = run_zpi(binary, args, ws, secret_env, timeout=40)
    assert res.returncode == 0, (res.stdout, res.stderr)
    summary = json.loads(res.stdout)["results"]
    assert len(summary) == 16, summary

    # 1. File tools blocked
    for idx in range(6):
        assert "OUTSIDE_SECRET_DATA" not in summary[idx], (idx, summary[idx])
        assert ("PathOutsideWorkspace" in summary[idx] or "InvalidPath" in summary[idx] or "Capability denied" in summary[idx]), (idx, summary[idx])
    assert outside_secret.read_text() == "OUTSIDE_SECRET_DATA"
    assert not (outside / "tool-write-escape.txt").exists()
    assert not (outside / "escape.txt").exists()
    assert not (outside / "dangling-target.txt").exists()

    # 2. Bash / grandchild / env / cred read blocked
    assert not bash_escape.exists()
    assert not tmp_escape.exists()
    assert not grandchild_escape.exists()
    assert outside_secret.read_text() == "OUTSIDE_SECRET_DATA"
    assert summary[9] == "ABSENT|ABSENT|explicitly-allowed-value", summary[9]
    assert "PRIVATE_SSH_KEY_SECRET" not in summary[10], summary[10]

    # 3. Network blocked (ZERO connections across bash, bg_run, MCP, TS!)
    time.sleep(0.3)
    assert not bg_escape.exists()
    assert tcp_probe.connections == 0, f"Unexpected network escape: {tcp_probe.connections} connections"

    # 4. MCP probe assertions
    mcp_report = json.loads(summary[14])
    assert mcp_report == {
        "env_openai": "ABSENT",
        "env_aws": "ABSENT",
        "env_allowed": "explicitly-allowed-value",
        "outside_write": "BLOCKED",
        "network": "BLOCKED",
        "cred_read": "BLOCKED",
        "inside_write": "OK",
    }, mcp_report
    assert not mcp_escape.exists()
    assert (ws / "mcp-inside.txt").read_text() == "mcp-ok"

    # 5. TypeScript host probe assertions
    ts_report = json.loads(summary[15])
    assert ts_report == {
        "env_openai": "ABSENT",
        "env_aws": "ABSENT",
        "env_allowed": "explicitly-allowed-value",
        "outside_write": "BLOCKED",
        "network": "BLOCKED",
        "cred_read": "BLOCKED",
        "inside_write": "OK",
    }, ts_report
    assert not ts_escape.exists()
    assert (ws / "ts-inside.txt").read_text() == "ts-ok"

    # 6. Subagent child probe assertions (dedicated invocation so child inherits bash)
    sub_audit = root / "p23-subagent-audit.jsonl"
    sub_args = [
        "--print", "--no-session", "--cwd", str(ws),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-cli-secret",
        "--security=secure", "--security-policy", str(policy), "--audit-log", str(sub_audit),
        "--env-allow", "ZPI_ALLOWED_VAR",
        "--tools", "bash,subagent",
        "subagent-parent",
    ]
    sub_res = run_zpi(binary, sub_args, ws, secret_env, timeout=30)
    assert sub_res.returncode == 0, (sub_res.stdout, sub_res.stderr)
    assert not subagent_escape.exists()
    assert (ws / "sub-env.txt").read_text() == "ABSENT|explicitly-allowed-value"
    assert tcp_probe.connections == 0, f"Unexpected subagent network escape: {tcp_probe.connections} connections"

    print("  [ok] Phases 2-3: OS sandbox + env allowlist + escape regressions (writes, network, children, symlinks, MCP, TypeScript)")


def check_phase4_worktree_parallel_subagents(binary, server, root, env):
    repo = root / "git-repo"
    repo.mkdir()
    for git_args in (
        ["init"],
        ["config", "user.email", "test@example.com"],
        ["config", "user.name", "Test"],
    ):
        subprocess.run(["git", "-C", str(repo)] + git_args, check=True, capture_output=True)
    (repo / "shared.txt").write_text("base\n")
    subprocess.run(["git", "-C", str(repo), "add", "shared.txt"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-m", "initial"], check=True, capture_output=True)

    audit = root / "p4-worktree-audit.jsonl"
    policy = root / "p4-worktree-policy.json"
    write_private_policy(policy, [
        {"capability": "filesystem.read", "effect": "allow", "target": {"kind": "path", "value": str(repo), "match": "subtree"}},
        {"capability": "filesystem.write", "effect": "allow", "target": {"kind": "path", "value": str(repo), "match": "subtree"}},
        {"capability": "process.exec", "effect": "allow"},
    ])

    hook_escape = repo / ".git/hooks/zpi-pwn"
    server.plans["wt-child-a"] = [
        ("write", {"path": "shared.txt", "content": "change-from-a\n"}),
        ("bash", {"command": f"echo pwn > '{hook_escape}' 2>/dev/null || echo HOOK_BLOCKED"}),
    ]
    server.plans["wt-child-b"] = [
        ("write", {"path": "shared.txt", "content": "change-from-b\n"}),
        ("bash", {"command": f"echo pwn > '{hook_escape}' 2>/dev/null || echo HOOK_BLOCKED"}),
    ]
    server.plans["wt-parent"] = [
        ("subagent", {
            "tasks": [
                {"name": "worker-a", "task": "wt-child-a"},
                {"name": "worker-b", "task": "wt-child-b"},
            ],
        }),
    ]

    args = [
        "--print", "--no-session", "--cwd", str(repo),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-cli-secret",
        "--security=secure", "--security-policy", str(policy), "--audit-log", str(audit),
        "--subagent-isolation", "worktree",
        "--tools", "read,write,bash,subagent",
        "wt-parent",
    ]
    res = run_zpi(binary, args, repo, env, timeout=40)
    assert res.returncode == 0, (res.stdout, res.stderr)

    # Parent repo working tree and .git/hooks must be completely untouched.
    assert (repo / "shared.txt").read_text() == "base\n"
    assert not hook_escape.exists()

    # Both parallel workers must have succeeded with isolated worktree diffs.
    outer = json.loads(res.stdout)["results"]
    batch = json.loads(outer[0])
    assert batch["timedOut"] is False, batch
    by_name = {r["name"]: r for r in batch["results"]}
    assert set(by_name.keys()) == {"worker-a", "worker-b"}, batch
    for name, expected_line in (("worker-a", "+change-from-a"), ("worker-b", "+change-from-b")):
        entry = by_name[name]
        assert entry["status"] == "completed", entry
        wt = entry.get("worktree")
        assert wt is not None and wt["isolated"] is True, entry
        assert wt["changedFiles"] == ["shared.txt"], wt
        assert expected_line in wt["diff"], wt
        assert wt["preserved"] is False, wt

    # Ensure no leaked worktrees remain registered with git.
    wt_list = subprocess.check_output(["git", "-C", str(repo), "worktree", "list", "--porcelain"], text=True)
    assert wt_list.count("worktree ") == 1, wt_list

    # Explicit worktree isolation in a non-git directory must fail closed.
    non_git = root / "non-git"
    non_git.mkdir()
    non_git_audit = root / "p4-nongit-audit.jsonl"
    non_git_policy = root / "p4-nongit-policy.json"
    write_private_policy(non_git_policy, [{"capability": "process.exec", "effect": "allow"}])
    server.plans["wt-nongit-parent"] = [("subagent", {"name": "child", "task": "wt-child-a"})]
    ng_res = run_zpi(binary, [
        "--print", "--no-session", "--cwd", str(non_git),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-cli-secret",
        "--security=secure", "--security-policy", str(non_git_policy), "--audit-log", str(non_git_audit),
        "--subagent-isolation", "worktree", "--tools", "subagent",
        "wt-nongit-parent",
    ], non_git, env, timeout=20)
    assert ng_res.returncode == 0, (ng_res.stdout, ng_res.stderr)
    ng_batch = json.loads(json.loads(ng_res.stdout)["results"][0])
    assert ng_batch["results"][0]["status"] == "failed"
    assert ng_batch["results"][0]["error_code"] == "WorktreeRequiresGitRepository", ng_batch
    print("  [ok] Phase 4: worktree-isolated parallel subagents (concurrent edits, read-only .git, cleanup, non-git fail-closed)")


def check_phase4_unattended_fail_stop(binary, server, root, ws, env):
    unattended_ws = root / "unattended-ws"
    unattended_ws.mkdir()
    allowed_dir = unattended_ws / "allowed"
    allowed_dir.mkdir()
    forbidden_dir = unattended_ws / "forbidden"
    forbidden_dir.mkdir()

    policy = root / "p4-unattended-policy.json"
    write_private_policy(policy, [
        {"capability": "filesystem.write", "effect": "allow", "target": {"kind": "path", "value": str(allowed_dir), "match": "subtree"}},
    ])
    audit = root / "p4-unattended-audit.jsonl"

    base = [
        "--print", "--no-session", "--cwd", str(unattended_ws),
        "--provider", "openai", "--model", "fixture-model", "--no-proxy",
        "--endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--api-key", "sk-cli-secret",
    ]

    # 1. Fail-closed startup validation for missing unattended requirements.
    for extra, expected_err in [
        (["--unattended", "ignored"], "UnattendedRequiresSecureMode"),
        (["--unattended", "--security=secure", "--audit-log", str(root / "u1.jsonl"), "ignored"], "UnattendedRequiresSecurityPolicy"),
        (["--unattended", "--security=secure", "--audit-log", str(root / "u2.jsonl"), "--security-policy", str(policy), "--sandbox=off", "ignored"], "UnattendedRequiresSandbox"),
        (["--unattended", "--security=secure", "--audit-log", str(root / "u3.jsonl"), "--security-policy", str(policy), "--env-isolation=inherit", "ignored"], "UnattendedRequiresEnvIsolation"),
    ]:
        r = run_zpi(binary, base + extra, unattended_ws, env)
        assert r.returncode != 0 and expected_err in r.stderr, (extra, r.returncode, r.stderr)

    # 2. Fail-stop runtime behavior: step 1 succeeds, step 2 denied -> halts immediately, step 3 never executes.
    server.plans["unattended-fail-stop"] = [
        ("write", {"path": "allowed/step1.txt", "content": "one"}),
        ("write", {"path": "forbidden/step2.txt", "content": "two"}),
        ("write", {"path": "allowed/step3.txt", "content": "three"}),
    ]
    req_before = len(server.requests)
    r_stop = run_zpi(binary, base + [
        "--unattended", "--security=secure", "--security-policy", str(policy), "--audit-log", str(audit),
        "--tools", "write",
        "unattended-fail-stop",
    ], unattended_ws, env)
    assert r_stop.returncode != 0, (r_stop.stdout, r_stop.stderr)
    assert "CapabilityDenied" in r_stop.stderr, r_stop.stderr
    assert (allowed_dir / "step1.txt").read_text() == "one"
    assert not (forbidden_dir / "step2.txt").exists()
    assert not (allowed_dir / "step3.txt").exists()
    # Provider saw only step 1 request and step 2 request; never asked for step 3 after fail-stop.
    assert len(server.requests) - req_before == 2, len(server.requests) - req_before

    records = [json.loads(line) for line in audit.read_text().splitlines() if line.strip()]
    assert len(records) == 3, records
    assert (records[0]["event"], records[0]["decision"]) == ("authorization", "allow")
    assert (records[1]["event"], records[1]["outcome"]) == ("operation", "allowed")
    assert (records[2]["event"], records[2]["decision"], records[2]["reason"]) == ("authorization", "deny", "missing-grant")

    # 3. Compliant unattended run completes cleanly with exit 0 and full audit trail.
    ok_audit = root / "p4-unattended-ok-audit.jsonl"
    server.plans["unattended-ok"] = [
        ("write", {"path": "allowed/ok.txt", "content": "clean"}),
    ]
    r_ok = run_zpi(binary, base + [
        "--unattended", "--security=secure", "--security-policy", str(policy), "--audit-log", str(ok_audit),
        "--tools", "write",
        "unattended-ok",
    ], unattended_ws, env)
    assert r_ok.returncode == 0, (r_ok.stdout, r_ok.stderr)
    assert (allowed_dir / "ok.txt").read_text() == "clean"
    ok_records = [json.loads(line) for line in ok_audit.read_text().splitlines() if line.strip()]
    assert len(ok_records) == 2 and ok_records[1]["outcome"] == "allowed", ok_records
    print("  [ok] Phase 4: explicit-policy unattended execution with audit and fail-stop")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, nargs="?", default=Path("zig-out/bin/zpi"))
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)

    with tempfile.TemporaryDirectory(prefix="zpi-trusted-exec-") as td:
        root = Path(td).resolve()
        ws = root / "workspace"
        outside = root / "outside"
        real_home = root / "home"
        ws.mkdir()
        outside.mkdir()
        (real_home / ".ssh").mkdir(parents=True)
        (real_home / ".ssh/id_rsa").write_text("PRIVATE_SSH_KEY_SECRET")
        (real_home / ".zpi/agent").mkdir(parents=True)
        (real_home / ".zpi/agent/models.json").write_text('{"providers":{"openai":{"apiKey":"sk-disk-secret"}}}')

        server = ThreadingHTTPServer(("127.0.0.1", 0), ScriptedProvider)
        server.plans = {}
        server.requests = []
        server.get_paths = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        tcp_probe = TcpProbe()

        env = {
            "PATH": os.environ.get("PATH", os.defpath),
            "HOME": str(real_home),
            "TERM": "xterm-256color",
        }
        try:
            check_phase1_policy_and_headless_denials(binary, server, root, ws, env)
            check_phase1_tui_one_time_approval(binary, server, root, ws, env)
            check_phase2_and_3_escape_regressions(binary, server, root, ws, outside, real_home, tcp_probe, env)
            check_phase4_worktree_parallel_subagents(binary, server, root, env)
            check_phase4_unattended_fail_stop(binary, server, root, ws, env)
        finally:
            tcp_probe.close()
            server.shutdown()
            thread.join()

    print("Trusted Execution regression suite (Phases 1-4) passed!")


if __name__ == "__main__":
    main()
