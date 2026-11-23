# Zpi

```text
 ____  ____  ___
|__ / |  _ \|_ _|
 / /  | |_) || |
/___| |  __/|___|
      |_|   zpi
```

**Zpi is an experimental terminal coding agent written in Zig.** It takes inspiration from [pi](https://github.com/earendil-works/pi) and [pi-rust](https://github.com/bigfish1913/pi-rust), with a focus on native startup, a small standalone executable, and a Zig-native interactive terminal. Zpi is an independent implementation, not a drop-in replacement for pi; the compatibility matrix documents the supported subset.

## At A Glance

| | Zpi | pi |
| --- | --- | --- |
| Runtime | Zig executable; no Node runtime required for core CLI/TUI | Node.js 22.19+ |
| Interactive UI | Regular terminal with native scrollback, streaming responses, session resume, steering and queued prompts | Full-featured interactive TUI with a broader extension UI |
| Built-in web/background tools | `web_fetch`, `get_content`, `bg_run`, `bg_status`, `bg_logs`, `bg_kill` | `web_search`, `web_fetch` and related tools are available through pi's tool/extension ecosystem, depending on setup |
| Sessions | Zpi JSONL format; offline import for a supported subset of pi v3 sessions | pi session format and broader session tooling |
| Extensions | Experimental opt-in compatibility host for selected pi TypeScript extensions; experimental C/Zig native plugins | Broad TypeScript extension and package ecosystem |

Zpi's `web_fetch` retrieves a URL supplied by the model; it is **not** a search engine and does not discover URLs like `web_search`. Its web access applies fail-closed SSRF protections. Background commands run in separate process groups and can notify the agent on completion. Tools run with the current user's OS permissions; Zpi is not a sandbox.

### Startup Snapshot

On macOS arm64, a local 20-sample `--version` process-start comparison measured Zpi at **3.25 ms p50 / 3.39 ms p95**, with **3.44 MiB maximum peak RSS**, and pi 1.6.0 at **104.53 ms / 106.70 ms**, with **114.68 MiB maximum peak RSS**. This is a narrow CLI startup measurement, not interactive TUI readiness or steady-state memory. It compares a default Zig build with pi's bundled Node CLI; it does not establish a general speedup. See [method, hashes and caveats](docs/spec/performance-baseline.md#cli-startup-comparison).

## Build And Run

Requires Zig **0.17.0** on macOS or Linux. The binary uses system C library facilities for native plugins. `grep` uses `rg`; `find` uses `fd` or `fdfind`. These utilities are optional and installed separately.

```sh
zig build
./zig-out/bin/zpi --help
export OPENAI_API_KEY=...    # or configure another supported provider
./zig-out/bin/zpi -p "Explain this project"
./zig-out/bin/zpi             # interactive terminal
```

Zpi supports OpenAI Chat Completions, a text/tool subset of OpenAI Responses, and a text/tool subset of Anthropic Messages. Configure providers and models in `~/.zpi/agent/models.json` or point to an existing compatible file with `--models-file`. Choose a provider/model with `--provider` and `--model`; credentials can come from provider environment variables or configuration.

Useful options include `--continue`, `--session PATH`, `--no-session`, `--tools`, `--no-tools`, `--skill PATH`, `--prompt-template PATH`, `--system-prompt`, and `--cwd`. Run `zpi --help` for the complete CLI reference. Build a headless binary without the interactive UI using `zig build -Dtui=none`.

Interactive commands include `/help`, `/hotkeys`, `/model`, `/thinking`, `/resume`, `/tree`, `/compact`, `/session`, `/jobs`, and `/exit`. The editor supports `Shift+Tab` to cycle thinking levels, `Ctrl+O` to toggle compact output, `Ctrl+S` to steer an active turn, and queued follow-up prompts.

Experimental `--mode rpc` supports `prompt`, `get_state`, and `abort` over Zpi's own JSONL protocol. Commands accept an optional string `id`, and each started turn emits `agent_settled` on completion, failure, or cancellation. RPC works with `-Dtui=none`. See the [Zpi JSONL RPC v1 contract](docs/spec/zpi-rpc-v1.md) for message shapes, ordering, and the independent client fixture.

## Native Subagents

Enable `subagent` with `--tools +subagent`. The tool accepts a self-contained `task`, or a `tasks` array with up to four named tasks to run concurrently. Children use the current model, system instructions and eligible parent-enabled native tools. Each child starts with a fresh in-memory conversation and its own model client and tool state. Children share the working directory and filesystem permissions with the parent.

```json
{"tasks":[{"name":"review","task":"Review src/agent.zig and summarize cancellation handling"},{"name":"tests","task":"Read scripts/test-cli.py and summarize the existing regression coverage"}],"timeoutSeconds":120,"maxTurns":8}
```

The parent receives live progress and bounded results in task order, including individual errors and truncation flags. Parent cancellation stops the batch. `timeoutSeconds` defaults to 300 and applies to the whole batch, and `maxTurns` defaults to 16 per child. Child results contain up to 8 KiB of text each. Cancellation and deadlines are cooperative, and cleanup waits for child tools to return. File and search operations retain their existing per-tool bounds. Child tools are drawn from the parent's enabled, unwrapped native file, shell, search and web tools. Extensions, MCP tools, background task tools and recursive delegation remain outside this initial child tool set. Parallel workers can modify the same files, so assign disjoint files when delegating edits.

## Current Status

Zpi is a tested, useful subset and is **not production-ready or broadly pi-compatible**. Current strengths include:

- Fast native CLI startup and low measured process memory for the `--version` command; see the caveats and reproducible results above.
- Native Zig terminal UI, streaming text/tool output, Markdown rendering, session history display and resume, compaction, and branch navigation.
- Built-in file/shell tools, URL fetching and cached content search, persistent background task management (`bg_run` and companions), and opt-in native single/parallel subagents.
- OpenAI and Anthropic text/tool workflows, optional MCP stdio servers, and experimental native C/Zig plugins.
- Offline import of a limited subset of pi v3 session history and an opt-in host for a limited set of existing pi TypeScript extensions.

Important gaps include `web_search`, broad provider and OAuth support, images, pi session-format parity, fullscreen TUI mode, full RPC compatibility, stable plugin ABI/Rust interoperability, package management, and general project trust/approval controls. See the [compatibility matrix](docs/spec/compatibility-matrix.md) for feature-level status.

## Roadmap

Priorities are subject to change; this is a project direction, not a release promise.

1. **Compatibility and daily-use reliability**: broaden provider/auth and session compatibility, improve project trust and tool approval controls, and keep native macOS/Linux verification current.
2. **Search and orchestration**: evaluate a first-party `web_search` integration and extend native subagents with additional model selection, persistent child sessions and background orchestration.
3. **Integration surface**: extend the experimental RPC command and event subset, then strengthen plugin lifecycle/ABI guarantees and Rust interoperability.
4. **Product maturity**: assess package/resource management, settings parity, fullscreen TUI behavior, and release provenance/signing based on user needs and maintenance capacity.

## Documentation

- [Compatibility matrix](docs/spec/compatibility-matrix.md)
- [Performance baseline and comparison method](docs/spec/performance-baseline.md)
- [Platform verification](docs/spec/platform-verification.md)
- [Security notes](docs/security.md) and [execution policy boundaries](docs/spec/security-boundaries.md)
- [Install, upgrade and remove](docs/install.md)
- [v0.1.0 release notes](docs/releases/v0.1.0.md)
- [Native plugin ABI](docs/spec/native-plugin-abi.md) and [runtime](docs/spec/native-plugin-runtime.md)
- [TypeScript extension host](docs/spec/typescript-extension-host.md)
- [Implementation specification](docs/spec/implementation-spec.md)

Run the core checks with `zig build test`, `zig build`, `zig fmt --check build.zig build.zig.zon src`, and `python3 scripts/test-cli.py`. The platform verification document lists additional SDK, native-plugin, release, and Linux guest checks.
