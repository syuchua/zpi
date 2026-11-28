# Security and credentials

The opt-in capability and audit contract is defined in [security-capabilities.md](spec/security-capabilities.md). It adds a policy layer without changing the default compatibility behavior.

## Enable secure mode and OS confinement

Default `compatibility` mode preserves existing behavior (`--sandbox off`, `--env-isolation inherit`). Enabling `--security secure` turns on capability policy checks, requires `--audit-log`, defaults child processes to OS confinement (`--sandbox workspace-write`, `--sandbox-network off`), enforces canonical-path checks on built-in file tools, and enables strict child environment allowlisting (`--env-isolation strict`).

```sh
mkdir -p -m 700 "$HOME/.zpi/audit"
zpi --security secure \
  --audit-log "$HOME/.zpi/audit/review.jsonl" \
  --tools read \
  --allow-capability filesystem.read \
  -p "Read README.md and summarize this project"
```

Keep the audit directory private. In interactive TUI mode, `--security secure` offers one-time `[y/N]` approval prompts for missing grants (auditing both `interactive-approval` and `interactive-denial`). In headless modes (`-p`, `--mode json`, `--mode rpc`), missing grants fail closed with structured denial details and never prompt.

### Trusted Execution controls

- **Target-scoped policy rules (`--security-policy PATH`)**: private (`0600`, single-link, owner-only) version-1 JSON policies support `allow`/`deny` rules for canonical paths (`exact`, `subtree`), commands (`exact`, metacharacter-guarded `prefix`), and network URLs (`exact`, `origin`, `host`). Explicit `deny` always wins.
- **OS sandbox (`--sandbox off|read-only|workspace-write`, `--sandbox-network off|on`, `--sandbox-backend auto|seatbelt|landlock|bwrap`)**: applies a shared OS confinement boundary to `bash`, user shell, `bg_run`, `rg`/`fd`, MCP stdio servers, the TypeScript extension host, and subagent child processes, plus canonical-path symlink checks on built-in file tools (`read`, `write`, `edit`, `ls`, `find`, `grep`). Uses macOS Seatbelt, Linux Landlock + seccomp-bpf, or `bwrap` fallback on Linux; fails closed (`SandboxUnavailable`) when no backend is available.
- **Credential & environment isolation (`--env-isolation strict|inherit`, `--env-allow NAME`)**: strict mode (default with `--security secure` or active `--sandbox`) forwards only a minimal non-credential allowlist (`PATH`, `LANG`, `TERM`, etc.), isolates `HOME` and `TMPDIR` to the workspace, strips ambient provider/cloud/SSH/GPG secrets, and denies reads to host credential directories (`~/.ssh`, `~/.aws`, `~/.zpi`, `~/.pi`, `~/.gnupg`, etc.).
- **Worktree-isolated parallel subagents (`--subagent-isolation shared|worktree|auto`)**: runs concurrent subagents in detached git worktrees with read-only parent `.git` metadata so parallel edits never race on the parent working tree or tamper with repository hooks, returning bounded `changedFiles` and unified `diff` summaries before cleanup.
- **Unattended fail-stop execution (`--unattended`)**: requires headless mode, `--security secure`, `--audit-log`, an explicit private `--security-policy`, an active OS sandbox, and strict environment isolation. Disables interactive prompts and halts immediately on the first policy denial or workspace boundary violation after syncing the audit record.

```sh
zpi --unattended \
  --security secure \
  --security-policy "$HOME/.zpi/policy.json" \
  --audit-log "$HOME/.zpi/audit/unattended.jsonl" \
  --subagent-isolation worktree \
  -p "Run bounded workspace checks"
```

Grant lifetimes and persistent policy schemas are documented in [security-capabilities.md](spec/security-capabilities.md), and the threat model and confinement evidence are mapped in [security-boundaries.md](spec/security-boundaries.md).

In default `compatibility` mode, Zpi runs with the permissions of the account that launches it. `--cwd` sets the working directory for tools, and enabled tools can read and change other files that the account can access unless `--sandbox` or `--security secure` is enabled.

## Select the resources and executables you trust

- Start with `--no-tools` when reviewing unfamiliar or imported conversation history. A restrictive selection such as `--tools read` allows file reads. `--tools` can enable tools even when `--no-tools` is present.
- The `subagent` tool shares the parent working directory and OS permissions. Children can use eligible native tools selected for the parent. Use `--tools subagent,read` for file-reading delegation, or `--exclude-tools subagent` to disable delegation in a wildcard tool selection.
- Project skill, prompt-template, and MCP configuration discovery require separate opt-ins (`--trust-project-skills`, `--trust-project-prompts`, `--trust-project-mcp`). User-level `~/.zpi/agent/mcp.json` can be disabled with `--no-mcp-config`. Review project files before enabling them because they can affect instructions or child commands. Inspect `--system-prompt`, `--append-system-prompt`, and `@file` inputs for the same reason.
- `--extension`, `--native-plugin`, `--mcp-stdio`, and configured `mcp.json` entries authorize executable code. TypeScript extensions and MCP servers run in child processes (and pass through `mcp.start` / `process.exec` capability checks and OS sandboxing when enabled). Native libraries run inside Zpi and can affect its memory and stability. Explicitly selected modules and servers still load when tools are disabled. Use trusted executable paths, SDK installations, and `PATH` entries.
- Built-in `web_search` and `web_fetch` apply SSRF protections (blocking loopback and private/link-local addresses unless `--allow-loopback-web-fetch` is set for local testing) and obey `network.connect` target-URL policy rules in `--security secure`.

## Handle provider credentials and outputs

- Prefer scoped provider keys and an environment reference (`zpi auth set <provider> --api-key-env NAME`) or stdin (`zpi auth set <provider> --stdin`), which writes `~/.zpi/agent/models.json` atomically with `0600` owner-only permissions and never echoes secret values. Command-valued credentials are rejected. Gemini sends keys via the `x-goog-api-key` header rather than URL query parameters. Use `--api-key` only if exposing its value in process arguments and shell history is acceptable.
- Shell commands, MCP servers and the Node extension host inherit ambient environment variables. Native libraries share the host process. Use a clean environment and treat every explicitly loaded component as having access to your account's data and credentials.
- Review the configured endpoint and custom authentication headers. Use HTTPS for a remote provider. With `--no-proxy`, Zpi connects directly to the configured endpoint. The provider clients reject URL userinfo, do not follow HTTP redirects, and discard non-success HTTP response bodies. The connectivity smoke reports a status or error identifier.
- Tool output, model responses, extension events and prompt inputs can contain sensitive data. Review JSONL output and session files before sharing them. `--no-session` keeps conversation history in memory for that run.

## Protect session files

Zpi creates new session files with owner-only permissions. Keep session directories and backups private. Offline pi import writes a new transcript and leaves the source unchanged. On resume, a torn final record can be truncated to the last newline. A previously recorded tool call with no committed result is treated as having an unknown outcome. Inspect any affected files or processes before retrying it.
