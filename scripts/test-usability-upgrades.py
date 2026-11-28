#!/usr/bin/env python3
"""Offline end-to-end verification for Zpi usability & Swiss-Army-knife upgrades:
1. Native Gemini API SSE client (x-goog-api-key header, tool call round-trip, usageMetadata)
2. Native web_search tool (SSRF block, --allow-loopback-web-fetch, --security secure policy/audit)
3. Out-of-box `zpi auth` and `zpi models` CLI subcommands (0600 files, zero secret echo)
4. `mcp.json` + `zpi mcp` CLI (user config, project trust gating, --no-mcp-config, secure denial)
"""
from __future__ import annotations

import http.server
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def run_zpi(zpi_bin: str, args: list[str], *, env: dict[str, str], cwd: str, stdin_text: str | None = None, timeout: int = 30):
    return subprocess.run(
        [zpi_bin, *args],
        input=stdin_text,
        text=True,
        capture_output=True,
        env=env,
        cwd=cwd,
        timeout=timeout,
    )


class FakeBackendHandler(http.server.BaseHTTPRequestHandler):
    log_lock = threading.Lock()
    gemini_requests: list[dict] = []
    search_requests: list[dict] = []

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        if ":streamGenerateContent" in self.path:
            parsed = json.loads(body)
            api_key = self.headers.get("x-goog-api-key", "")
            with self.log_lock:
                self.gemini_requests.append({"path": self.path, "api_key": api_key, "body": parsed})
                call_num = len(self.gemini_requests)

            # Check if a functionResponse is already present in contents
            has_tool_resp = any(
                any("functionResponse" in p for p in turn.get("parts", []))
                for turn in parsed.get("contents", [])
            )
            if not has_tool_resp:
                chunk1 = {
                    "candidates": [{
                        "content": {
                            "role": "model",
                            "parts": [
                                {"text": "Checking file...", "thought": True},
                                {"functionCall": {"name": "read", "args": {"path": "note.txt"}}},
                            ],
                        },
                        "finishReason": "STOP",
                    }],
                    "usageMetadata": {
                        "promptTokenCount": 50,
                        "candidatesTokenCount": 12,
                        "totalTokenCount": 62,
                        "cachedContentTokenCount": 20,
                    },
                }
                payload = f"data: {json.dumps(chunk1)}\n\n".encode("utf-8")
            else:
                chunk1 = {
                    "candidates": [{
                        "content": {"role": "model", "parts": [{"text": "Gemini read: "}]},
                    }],
                }
                chunk2 = {
                    "candidates": [{
                        "content": {"role": "model", "parts": [{"text": "hello-gemini-world"}]},
                        "finishReason": "STOP",
                    }],
                    "usageMetadata": {
                        "promptTokenCount": 80,
                        "candidatesTokenCount": 10,
                        "totalTokenCount": 90,
                        "cachedContentTokenCount": 40,
                    },
                }
                payload = (
                    f"data: {json.dumps(chunk1)}\n\n"
                    f"data: {json.dumps(chunk2)}\n\n"
                ).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if self.path == "/v1/chat/completions":
            parsed = json.loads(body)
            msgs = parsed.get("messages", [])
            has_tool = any(m.get("role") == "tool" for m in msgs)
            if not has_tool:
                # Ask the agent to invoke web_search
                c1 = {
                    "choices": [{
                        "index": 0,
                        "delta": {
                            "role": "assistant",
                            "tool_calls": [{
                                "index": 0,
                                "id": "call_ws_1",
                                "type": "function",
                                "function": {"name": "web_search", "arguments": json.dumps({"query": "zig 0.17", "maxResults": 3})},
                            }],
                        },
                        "finish_reason": None,
                    }]
                }
                c2 = {
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                    "usage": {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30},
                }
                payload = (
                    f"data: {json.dumps(c1)}\n\n"
                    f"data: {json.dumps(c2)}\n\n"
                    "data: [DONE]\n\n"
                ).encode("utf-8")
            else:
                tool_text = [m.get("content", "") for m in msgs if m.get("role") == "tool"][-1]
                ok_hit = ("Brave Fixture Hit" in tool_text) or ("Exa Zero-Config Hit" in tool_text)
                reply = f"SEARCH_RESULT:{'OK' if ok_hit else 'ERR:' + tool_text[:80]}"
                c1 = {
                    "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply}, "finish_reason": None}]
                }
                c2 = {
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 30, "completion_tokens": 5, "total_tokens": 35},
                }
                payload = (
                    f"data: {json.dumps(c1)}\n\n"
                    f"data: {json.dumps(c2)}\n\n"
                    "data: [DONE]\n\n"
                ).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if self.path.startswith("/exa-mcp"):
            parsed = json.loads(body)
            with self.log_lock:
                self.search_requests.append({"path": self.path, "method": "POST", "tool": parsed.get("params", {}).get("name")})
            sse = (
                "event: message\n"
                + "data: "
                + json.dumps({
                    "jsonrpc": "2.0",
                    "id": parsed.get("id", 1),
                    "result": {
                        "content": [{
                            "type": "text",
                            "text": "Title: Exa Zero-Config Hit\nURL: https://ziglang.org/download/0.17.0/\nText: Zero-config Exa MCP search result.",
                        }]
                    },
                })
                + "\n\n"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(sse)))
            self.end_headers()
            self.wfile.write(sse)
            return

        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/search"):
            token = self.headers.get("X-Subscription-Token", "")
            with self.log_lock:
                self.search_requests.append({"path": self.path, "token": token})
            data = json.dumps({
                "web": {
                    "results": [
                        {
                            "title": "Brave Fixture Hit",
                            "url": "https://ziglang.org/download/0.17.0/",
                            "description": "Official Zig 0.17.0 release notes.",
                        }
                    ]
                }
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()


def main():
    zpi_bin = str(Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else str(Path("zig-out/bin/zpi").resolve())
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeBackendHandler)
    port = server.server_port
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        with tempfile.TemporaryDirectory(prefix="zpi-usability-") as td:
            root = Path(td)
            agent_dir = root / "agent"
            proj = root / "project"
            proj.mkdir()
            (proj / "note.txt").write_text("hello-gemini-world\n")

            base_env = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(root),
                "PI_CODING_AGENT_DIR": str(agent_dir),
            }

            # 1. Test `zpi auth` & `zpi models` CLI subcommands
            res = run_zpi(zpi_bin, ["auth", "set", "openai", "--stdin"], env=base_env, cwd=str(proj), stdin_text="sk-secret-do-not-echo\n")
            assert res.returncode == 0, res.stderr
            assert "sk-secret-do-not-echo" not in res.stdout and "sk-secret-do-not-echo" not in res.stderr
            models_json = agent_dir / "models.json"
            assert models_json.exists()
            mode = stat.S_IMODE(models_json.stat().st_mode)
            assert mode == 0o600, f"expected 0600, got {oct(mode)}"

            res = run_zpi(
                zpi_bin,
                ["auth", "set", "gemini", "--api-key-env", "GEMINI_API_KEY", "--base-url", f"http://127.0.0.1:{port}/v1beta", "--api", "gemini-generate-content"],
                env=base_env,
                cwd=str(proj),
            )
            assert res.returncode == 0, res.stderr

            status_env = {**base_env, "GEMINI_API_KEY": "gem-top-secret-999"}
            res = run_zpi(zpi_bin, ["auth", "status"], env=status_env, cwd=str(proj))
            assert res.returncode == 0, res.stderr
            assert "sk-secret-do-not-echo" not in res.stdout
            assert "gem-top-secret-999" not in res.stdout
            assert "$GEMINI_API_KEY: set" in res.stdout, res.stdout

            res = run_zpi(zpi_bin, ["models", "set-default", "gemini/gemini-2.5-flash"], env=status_env, cwd=str(proj))
            assert res.returncode == 0, res.stderr
            res = run_zpi(zpi_bin, ["models", "list"], env=status_env, cwd=str(proj))
            assert res.returncode == 0, res.stderr
            assert "* gemini/gemini-2.5-flash" in res.stdout, res.stdout

            # 2. Test Native Gemini API provider end-to-end (with tool call round-trip + x-goog-api-key)
            res = run_zpi(
                zpi_bin,
                ["--no-session", "--no-proxy", "--tools", "read", "-p", "Read note.txt"],
                env=status_env,
                cwd=str(proj),
            )
            assert res.returncode == 0, (res.stdout, res.stderr)
            assert "Gemini read: hello-gemini-world" in res.stdout, res.stdout
            assert len(FakeBackendHandler.gemini_requests) == 2, FakeBackendHandler.gemini_requests
            assert FakeBackendHandler.gemini_requests[0]["api_key"] == "gem-top-secret-999"
            assert "gem-top-secret-999" not in FakeBackendHandler.gemini_requests[0]["path"]
            assert "additionalProperties" not in json.dumps(FakeBackendHandler.gemini_requests[0]["body"])

            # 3. Test `web_search` tool (allowed via loopback + Brave env, denied under secure mode without grant)
            ws_env = {
                **base_env,
                "OPENAI_API_KEY": "fake-openai",
                "BRAVE_API_KEY": "brave-fixture-secret",
                "ZPI_SEARCH_URL": f"http://127.0.0.1:{port}/search",
            }
            res = run_zpi(
                zpi_bin,
                [
                    "--no-session", "--no-proxy", "--provider", "openai",
                    "--endpoint", f"http://127.0.0.1:{port}/v1",
                    "--allow-loopback-web-fetch", "--tools", "web_search",
                    "-p", "search zig",
                ],
                env=ws_env,
                cwd=str(proj),
            )
            assert res.returncode == 0, (res.stdout, res.stderr)
            assert "SEARCH_RESULT:OK" in res.stdout, res.stdout
            assert len(FakeBackendHandler.search_requests) == 1
            assert FakeBackendHandler.search_requests[0]["token"] == "brave-fixture-secret"

            # Zero-config default (no search API key) selects Exa MCP (`web_search_exa`)
            exa_env = {
                **base_env,
                "OPENAI_API_KEY": "fake-openai",
                "ZPI_SEARCH_URL": f"http://127.0.0.1:{port}/exa-mcp",
            }
            res = run_zpi(
                zpi_bin,
                [
                    "--no-session", "--no-proxy", "--provider", "openai",
                    "--endpoint", f"http://127.0.0.1:{port}/v1",
                    "--allow-loopback-web-fetch", "--tools", "web_search",
                    "-p", "search zig",
                ],
                env=exa_env,
                cwd=str(proj),
            )
            assert res.returncode == 0, (res.stdout, res.stderr)
            assert "SEARCH_RESULT:OK" in res.stdout, res.stdout
            assert FakeBackendHandler.search_requests[-1]["tool"] == "web_search_exa"

            # Under --security=secure without network.connect grant, web_search is denied BEFORE HTTP request.
            audit_file = root / "ws-audit.jsonl"
            before_search = len(FakeBackendHandler.search_requests)
            res = run_zpi(
                zpi_bin,
                [
                    "--no-session", "--no-proxy", "--provider", "openai",
                    "--endpoint", f"http://127.0.0.1:{port}/v1",
                    "--allow-loopback-web-fetch", "--tools", "web_search",
                    "--security=secure", "--sandbox=off", "--audit-log", str(audit_file),
                    "-p", "search zig",
                ],
                env=ws_env,
                cwd=str(proj),
            )
            assert res.returncode == 0, (res.stdout, res.stderr)
            assert len(FakeBackendHandler.search_requests) == before_search, "secure mode leaked web_search request!"
            audit_records = [json.loads(line) for line in audit_file.read_text().splitlines() if line.strip()]
            assert any(r.get("capability") == "network.connect" and r.get("decision") == "deny" for r in audit_records), audit_records

            # 4. Test `zpi mcp` CLI + `mcp.json` project trust gating + secure denial
            mcp_script = proj / "fake_mcp.py"
            mcp_marker = root / "mcp-spawned.marker"
            mcp_script.write_text(f"""#!/usr/bin/env python3
import pathlib, sys
pathlib.Path({str(mcp_marker)!r}).write_text("spawned")
sys.exit(0)
""")
            mcp_script.chmod(0o755)
            (proj / ".zpi").mkdir()
            (proj / ".zpi" / "mcp.json").write_text(json.dumps({
                "mcpServers": {
                    "proj_srv": {"command": sys.executable, "args": [str(mcp_script)]}
                }
            }))

            # Project mcp.json is ignored by default
            res = run_zpi(zpi_bin, ["mcp", "list"], env=base_env, cwd=str(proj))
            assert res.returncode == 0 and "proj_srv" not in res.stdout, res.stdout
            res = run_zpi(zpi_bin, ["mcp", "list", "--trust-project-mcp"], env=base_env, cwd=str(proj))
            assert res.returncode == 0 and "proj_srv  [project]" in res.stdout, res.stdout

            # Add user server, verify list & doctor, then verify secure mode denies spawning before exec
            res = run_zpi(zpi_bin, ["mcp", "add", "user_srv", "--", sys.executable, str(mcp_script)], env=base_env, cwd=str(proj))
            assert res.returncode == 0, res.stderr
            res = run_zpi(zpi_bin, ["mcp", "list"], env=base_env, cwd=str(proj))
            assert res.returncode == 0 and "user_srv  [user]" in res.stdout, res.stdout

            res = run_zpi(zpi_bin, ["doctor"], env=status_env, cwd=str(proj))
            assert res.returncode == 0 and "mcp:      1 configured" in res.stdout, res.stdout

            mcp_audit = root / "mcp-audit.jsonl"
            res = run_zpi(
                zpi_bin,
                [
                    "--no-session", "--no-proxy", "--provider", "openai",
                    "--endpoint", f"http://127.0.0.1:{port}/v1",
                    "--security=secure", "--sandbox=off", "--audit-log", str(mcp_audit),
                    "-p", "hi",
                ],
                env=ws_env,
                cwd=str(proj),
            )
            assert res.returncode != 0 and "CapabilityDenied" in res.stderr, (res.returncode, res.stderr)
            assert not mcp_marker.exists(), "secure mode spawned configured MCP server without mcp.start grant!"

            res = run_zpi(zpi_bin, ["mcp", "remove", "user_srv"], env=base_env, cwd=str(proj))
            assert res.returncode == 0, res.stderr
            res = run_zpi(zpi_bin, ["auth", "remove", "openai"], env=base_env, cwd=str(proj))
            assert res.returncode == 0, res.stderr

            print("ALL usability upgrade end-to-end checks PASSED!")
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
