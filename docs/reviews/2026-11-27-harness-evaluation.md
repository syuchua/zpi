# Zpi agent harness evaluation — 2026-11-27

Status: same-host evaluation snapshot. This is not a compatibility claim, a performance guarantee, or a security audit.

For an agent working in this repository: read the TL;DR and then "Suggested next actions for the working agent". Treat the P0 items as proposed priorities, not as instructions that override the user's current task.

Scope: current working tree at commit `5fddcd5` (`zpi 0.1.2`), macOS arm64, Zig 0.17.0, Node 24.22.1, Python 3.9.6. Local comparisons used pi `1.6.0` and opencode `2.4.2`. Codex CLI and Claude Code were not installed; their comparison is based on official documentation as of 2026-11.

## TL;DR

Zpi is already a working native agent harness, not a demo. File read/edit/shell, sessions, resume, image input, parallel subagents, MCP stdio, and pi TypeScript extensions all worked in live tests. Performance is the standout advantage: 2.4 ms startup, 2 MiB RSS, 11 ms RPC restore for 8,192 messages, and a 1.3 ms read-tool round trip.

It is not yet a daily-driver replacement for pi, opencode, Codex CLI, or Claude Code. The three gating gaps are:

1. **Diagnostics and onboarding.** Errors print only Zig error names; there is no `auth`/`models`/`mcp`/`doctor` command; configuration is hand-edited JSON.
2. **Project context and safety.** `AGENTS.md`/`CLAUDE.md` are not loaded, and there are no approval or sandbox boundaries around tools.
3. **Generality and integration.** Provider/auth coverage is narrow, `web_search` is absent, MCP is CLI-stdio-only, RPC is experimental, and there is no Windows, IDE/ACP, or package-manager path.

Recommended positioning: do not compete head-on with the Claude Code/Codex ecosystem. Make Zpi the fastest, smallest, most hackable native agent runtime and a practical pi-compatible runtime. If the goal is a daily driver, close safety, context, and onboarding first.

## What was tested

### Automated checks

| Check | Result |
| --- | --- |
| `zig build test` | Pass |
| `python3 scripts/test-cli.py` (Debug binary) | Pass |
| `ZPI_TEST_BINARY=<ReleaseSafe binary> python3 scripts/test-cli.py` | Pass |
| `python3 scripts/test-rpc.py <binary>` | Pass |
| `python3 scripts/test-context-budget.py <binary>` | Pass |
| `python3 scripts/test-ts-host.py <installed pi SDK>` | Pass |
| `zig fmt --check build.zig build.zig.zon src` | Pass |

The repository contains about 26.5k lines of Zig in 69 files, 256 inline `test` declarations, and a 5,188-line CLI integration suite with 757 assertions. This is unusually strong test coverage for an experimental harness.

### Live tasks

| Task | Result | Wall time |
| --- | --- | ---: |
| Read `hello.txt`, edit it, run `cat` to verify | Correctly changed to `hello zpi` | 2.7 s |
| Run `calc.py`, observe wrong output, fix the bug, rerun | Correctly printed `42` | 3.7 s |
| Two-turn session, then `-c` and ask for the remembered number | Correctly answered `42` | Normal |
| Image input with a red PNG | Answered `Red` | Normal |
| Two parallel subagents (read README, inspect git log) | Both completed; also caught a stale README version reference | 6.6 s |
| `--mode json`, piped stdin, `--no-tools` | Output and exit behavior normal | Normal |

## Performance

### Startup and memory

| Tool | `--version` p50 / p95 | Peak RSS |
| --- | ---: | ---: |
| Zpi ReleaseSafe | **2.37 ms / 3.39 ms** | **2.05 MiB** |
| pi 1.6.0 | 121.47 ms / 136.34 ms | 117.42 MiB |
| opencode 2.4.2 | 37.6 ms / — | Not measured |

### RPC / agent loop (ReleaseSafe)

| Workload | Zpi | pi | Ratio |
| --- | ---: | ---: | ---: |
| Restore 128 messages | **3.35 ms** | 144.98 ms | ~43x |
| Restore 8,192 messages | **11.21 ms** | 145.79 ms | ~13x |
| 64 KiB stream settled | **1.91 ms** | 23.34 ms | ~12x |
| Read-tool turn settled | **1.26 ms** | 26.65 ms | ~21x |

### TUI restore (8,192 messages, 2.29 MB JSONL)

| Mode | p50 | Peak RSS | PTY output |
| --- | ---: | ---: | ---: |
| Fullscreen (default) | **41.8 ms** | 15.9 MB | 2.1 KB |
| Regular (native scrollback) | **990 ms** | 13.5 MB | 2.57 MB |
| Debug default build, regular | **5.3 s** | — | — |

The regular-mode restore is the one visible performance weak spot. Fullscreen is fast because it renders only the viewport; regular mode streams the full history to preserve native scrollback. This is a deliberate tradeoff, but it should be documented and measured in CI.

### End-to-end prompt (ReleaseFast, same provider/model)

| Tool | p50 | p95 |
| --- | ---: | ---: |
| Zpi | **463 ms** | 739 ms |
| pi | 1,907 ms | 2,329 ms |

Network and model latency dominate this measurement, but the harness-side overhead difference is still substantial.

## Dimension assessment

Scores are subjective and relative to the current experimental state.

| Dimension | Score | Assessment |
| --- | ---: | --- |
| Performance | **5/5** | Best-in-class startup, memory, session restore, and tool round trip |
| Core functionality | **4/5** | Agent loop, tools, sessions, TUI, images, subagents, MCP, and TS extensions all work |
| Daily-use maturity | **2.5/5** | Missing approvals, project context, and onboarding; still experimental |
| Ease of use | **2.5/5** | Good help/docs/TUI, weak error messages, configuration, and first-run flow |
| Generality | **2.5/5** | Narrow provider/auth coverage; MCP/RPC/IDE/Windows gaps |
| Safety | **1.5/5** | No approval or sandbox; tools run with the user's full OS permissions |
| Ecosystem/integration | **1.5/5** | No package manager, IDE/ACP, stable RPC, or stable plugin ABI |
| Engineering quality | **4/5** | Strong tests and honest docs; experimental release process |
| Maturity | **2/5** | `0.1.2`, explicitly not production-ready |

## Comparison

| Dimension | Zpi | pi | opencode | Codex CLI | Claude Code |
| --- | --- | --- | --- | --- | --- |
| Runtime/distribution | Zig single binary, 2.6 MB; source/archive | Node; npm | Client/server; brew/npm | Rust; npm/brew | Node; npm/native installer |
| Startup/memory | **2.4 ms / 2 MB** | 121 ms / 117 MB | 38 ms / — | Not measured | Not measured |
| Provider/auth | OpenAI Chat/Responses subset, Anthropic subset; API key | Broad; OAuth | Broad; auth | OpenAI/ChatGPT | Anthropic/Claude |
| Project context | **No AGENTS.md** | AGENTS.md/CLAUDE.md | AGENTS.md | AGENTS.md | CLAUDE.md |
| Permissions/sandbox | **None** | Project trust; no OS sandbox | Permission prompts | **OS sandbox + approvals** | Permission modes/hooks |
| MCP | CLI stdio only | stdio/HTTP/OAuth + `mcp.json` | MCP | MCP | MCP |
| Extensions | pi TS host (experimental) + native ABI | Rich TS/packages | Plugins | Skills/MCP/cloud | Plugins/marketplace/hooks/skills |
| Subagents | Experimental, up to 4 parallel | Extension/package | Agents | Cloud/limited | **Strong** |
| Web search | **None** | Extension/package | Configuration-dependent | Yes | Yes |
| IDE/protocol | Experimental RPC | RPC/SDK | ACP/server | IDE/exec | IDE/stream-json |
| Windows | **No** | Yes | Yes | Yes | Yes |
| Maturity | 0.1.2 experimental | 1.6.0 | 2.4.2 | 0.167.x | 2.1.332 |

## Findings

### P0 — daily-use blockers

1. **Errors are not actionable.**
   - No configuration: `zpi: HttpRequestFailed`
   - Unknown model: `zpi: HttpRequestFailed`
   - Invalid session directory: `zpi: SessionCommitFailed`
   - Missing flag value: `zpi: MissingValue`

   `src/main.zig` prints `@errorName(err)` directly. The security intent is reasonable, but users need redacted, actionable diagnostics: HTTP status, provider, endpoint host, retry advice, the missing flag name, and a hint to run a setup command. Do not print request bodies, headers, or credentials.

2. **No onboarding or management subcommands.**
   - There is no `zpi auth`, `zpi models`, `zpi mcp`, `zpi doctor`, or first-run wizard.
   - Users must hand-edit `~/.zpi/agent/models.json`.
   - Missing credentials are not rejected before an HTTP attempt.
   - Compare pi's `auth`/`models`/`mcp`/`config` and opencode's `auth`/`models`/`mcp`.

3. **Project instruction files are ignored.**
   - Zpi loads skills and prompt templates, but not `AGENTS.md` or `CLAUDE.md`.
   - Real repositories rely on these for conventions, commands, and constraints.
   - Codex, Claude Code, and pi all support project context files.

4. **No approval or sandbox boundary.**
   - Tools execute immediately with the launching user's OS permissions.
   - `bash` can run arbitrary commands; `--cwd` is not a sandbox.
   - Codex provides OS sandbox modes plus approvals; Claude Code provides permission modes and hooks; opencode provides permission prompts.
   - A capability-authorization design draft was present in the working tree during this review. Implementing it is the right next step, but it is not current behavior.

5. **The default build is Debug.**
   - `zig build` produces an 8.6 MB binary and takes about 5.3 s to restore 8,192 messages in regular mode.
   - `ReleaseSafe` produces a 2.6 MB binary and takes about 0.99 s for the same workload; fullscreen restore is about 42 ms.
   - The README quick start says `zig build`, while the performance numbers clearly come from a release build. This is a trap for new users and for benchmark reproducibility.

6. **Unknown `--tools` patterns fail silently.**
   - `--tools definitely_not_a_tool` does not report an error; it selects no tools.
   - In a live test the model then emitted pseudo tool-call text, which looked like a leaked special token.
   - Validate requested patterns against registered tools and report unmatched entries, with an explicit escape hatch if forward references are intentional.

### P1 — generality gaps

7. **Narrow provider/auth coverage.** No Gemini, Bedrock, or OAuth. API-key-only access excludes subscription users and complicates enterprise gateway/SSO setups.
8. **No `web_search`.** `web_fetch` can retrieve a known URL but cannot discover one, which limits research workflows.
9. **MCP is CLI-stdio-only.** There is no `mcp.json`, HTTP/SSE, OAuth, resources, or prompts. Compare `pi mcp add/list/login`.
10. **TUI gaps.** No interactive image paste, custom themes/keybindings, session naming, or export.
11. **Integration surface is narrow.** RPC supports only `prompt`/`get_state`/`abort` and is experimental; there is no ACP/IDE integration or stable `exec --json`; Windows is unsupported.
12. **Extension and installation friction.** The TypeScript host requires an external Node runtime and pi SDK; the native ABI is experimental; there is no package manager. Installing requires Zig 0.17.0 and source/archive builds.

## Recommendations

### If only three things are done

1. **Make errors actionable and add `--verbose`.**
   - Map known errors to user-facing messages with redacted context.
   - Fail fast on missing credentials before making a request.
   - Include the offending flag name for parse errors.
   - This is the smallest change with the largest perceived-quality gain.

2. **Add project context and a permission boundary.**
   - Implement `AGENTS.md`/`CLAUDE.md` discovery with `--no-context-files` and project trust.
   - Implement the capability-authorization contract, then add interactive approvals and OS-level sandboxing.
   - Without these, users will not run Zpi on real repositories as a daily driver.

3. **Make Release the default and fix the documentation.**
   - Default `zig build` to ReleaseSafe, or make the README's first build command `zig build -Doptimize=ReleaseSafe`.
   - Record the build mode in every performance table.
   - Add a ReleaseSafe benchmark to CI to catch Debug/Release drift.

### P0 quick wins

- `zpi doctor`: check build mode, models file, credentials, `rg`/`fd`, Node/pi SDK, and terminal capabilities.
- `zpi auth` / `zpi models` / `zpi mcp` subcommands, or a first-run wizard.
- Reject or warn on unmatched `--tools` patterns.
- Add 3–5 common examples to `--help`.
- Add a short “first five minutes” path to the README instead of leading with long comparison tables.

### P1 strategic work

- **Permissions/sandbox:** secure mode, capability grants, audit events, TUI approval, macOS Seatbelt/Linux Landlock or bwrap, network off by default, workspace-write restrictions.
- **MCP productization:** `mcp.json`, HTTP/SSE, OAuth, resources/prompts, `zpi mcp add/list/login`.
- **`web_search`:** provider-native or search API, with citations and SSRF protections.
- **Provider/auth breadth:** Gemini, Bedrock, OAuth; at minimum support subscription login so API keys are not mandatory.
- **TUI:** image paste, themes/keybindings, session naming/export, `/cost`, `/context`.
- **Integration:** stable RPC schema, ACP server, `zpi exec --json`, GitHub Action.
- **Performance:** regular-mode restore is the weak spot; consider a “restore last N messages” option or incremental rendering without giving up native scrollback.

### P2 long term

- Self-contained extension host (no external pi SDK), stable native plugin ABI, package manager/plugin registry.
- Windows support, or an explicit non-goal.
- LSP/code intelligence, hooks, dynamic workflows, cross-session messaging.

## Suggested next actions for the working agent

1. Add a redacted diagnostic layer around `src/main.zig`'s error printing and a `--verbose` flag. Cover `HttpRequestFailed`, `ProviderNotConfigured`, `SessionCommitFailed`, and `MissingValue`.
2. Add credential/config preflight in `src/cli/config.zig` so missing credentials fail before the first HTTP request.
3. Validate requested tool patterns after registration in `src/harness.zig`; extend `src/cli/tool_selection.zig` with an unmatched-pattern result.
4. Extend `src/cli/system_prompt.zig` with `AGENTS.md`/`CLAUDE.md` discovery, `--no-context-files`, and project-trust semantics.
5. Implement the capability/audit contract in `docs/spec/security-capabilities.md`, then add an approval path and OS sandbox.
6. Change `build.zig`'s default optimize mode or update the README quick start to `ReleaseSafe`, and add the build mode to benchmark output.
7. Add `zpi doctor` before adding more provider integrations; it will make every support issue cheaper to diagnose.

## Caveats

- Codex CLI and Claude Code were not installed, so their rows are documentation-based, not same-host measurements.
- Benchmarks use local fake providers and synthetic sessions; real model latency dominates end-to-end time.
- `bench-rpc.py` requires `--rpi`; rpi was not installed. The zpi-vs-pi comparison used a local copy patched to make `--rpi` optional.
- The Debug-vs-Release difference is a build-configuration effect, not a different implementation.
- Scores are subjective and intended to guide priorities, not to rank projects absolutely.
- The security-capability design present in the working tree at review time is a contract draft, not implemented behavior.
