# Zpi

```text
 ____  ____  ___
|__ / |  _ \|_ _|
 / /  | |_) || |
/___| |  __/|___|
      |_|   zpi
```

**Zpi is an experimental terminal coding agent written in Zig.** It takes inspiration from [pi](https://github.com/earendil-works/pi) and [pi-rust](https://github.com/bigfish1913/pi-rust), with a focus on native startup, a small standalone executable, and a Zig-native interactive terminal. Zpi is an independent implementation, not a drop-in replacement for pi; the compatibility matrix documents the supported subset.

## First five minutes

Zpi needs a supported provider credential. Building from source requires Zig **0.17.0**. `rg` and `fd` (or `fdfind`) power the optional `grep` and `find` tools.

For a published release, the installer detects macOS or Linux (x64/arm64 and glibc/musl), verifies the matching archive checksum, extracts it under `~/.local/opt/zpi`, and updates `~/.local/bin/zpi` atomically without replacing a regular file. It also checks for `rg` and `fd` or `fdfind`. In a terminal it asks whether the detected package manager should install missing search tools. Use `--without-search-tools` to skip the question or `--with-search-tools` to request installation explicitly.

```sh
curl -fsSL https://raw.githubusercontent.com/syuchua/zpi/main/install.sh | bash
```

(The installer is POSIX `sh`-compatible and also works with `| sh`.) Add `~/.local/bin` to `PATH` if it is not already present.

1. Build and check the install: `zig build` then `./zig-out/bin/zpi --version`. Plain `zig build` produces a ReleaseSafe binary; add `-Doptimize=Debug` for a debug build, or `--release=fast|small` for other modes. `-Dtui=none` builds a headless binary for `-p`, `--mode json` and `--mode rpc`.
2. Configure a provider in `~/.zpi/agent/models.json` (or point at an existing file with `--models-file`), and provide its credential through the environment or that file.
3. Run `zpi doctor`. It reports the build mode, the effective provider/model and which file supplied it, whether a credential is available (never its value), `rg`/`fd` availability, Node and the configured pi SDK version, project context opt-in, and terminal capabilities. It makes no network requests, runs no project or user code, and exits 0 with advisories.
4. Make a first request: `zpi -p "Explain this project"`, or start the interactive UI with `zpi`.
5. When something fails, rerun with `--verbose`. Diagnostics print the error name plus a static hint and, with `--verbose`, the build mode. They never print configuration values, credentials, URLs, commands, project contents, or child/provider output.

Optional next steps: `zpi --continue` resumes the newest session in this directory; `-s/--skills PATH` and `--prompt-template PATH` add Skills and Markdown commands; run `zpi --help` for the complete flag list and worked examples.

### Project context files

`AGENTS.md` and `CLAUDE.md` in the project root are **untrusted project data**, not commands or authorization. Zpi never loads them implicitly: either pass `--enable-project-context`, or set `"loadProjectContext": true` in the project's own `.zpi/agent/settings.json`. A user-level settings file cannot opt a project in. Loading is bounded to those two regular files, 64 KiB each and 128 KiB total, skips symlinks and oversized or non-UTF-8 files rather than truncating them, and frames the text in the system prompt as data. `--no-context-files` always disables them, overriding either opt-in.

## At A Glance

| | Zpi | pi |
| --- | --- | --- |
| Runtime | Zig executable; no Node runtime required for core CLI/TUI | Node.js 22.19+ |
| Interactive UI | Fullscreen transcript with search and an optional native-scrollback mode, plus streaming, session resume, steering and queued prompts | Full-featured interactive TUI with a broader extension UI |
| Built-in web/background tools | `web_fetch`, `get_content`, `bg_run`, `bg_status`, `bg_logs`, `bg_kill` | `web_search`, `web_fetch` and related tools are available through pi's tool/extension ecosystem, depending on setup |
| Sessions | Zpi JSONL format; offline import for a supported subset of pi v3 sessions | pi session format and broader session tooling |
| Extensions | Experimental opt-in compatibility host for selected pi TypeScript extensions; experimental C/Zig native plugins | Broad TypeScript extension and package ecosystem |

Zpi's `web_fetch` retrieves a URL supplied by the model; it is **not** a search engine and does not discover URLs like `web_search`. Its web access applies fail-closed SSRF protections. Background commands run in separate process groups and can notify the agent on completion. Tools run with the current user's OS permissions; Zpi is not a sandbox.

### Startup Snapshot

On macOS arm64, a same-host 20-sample `--version` comparison measured Zpi 0.1.1 at **2.562 ms p50 / 2.999 ms p95**, with **2.06 MiB maximum peak RSS**; rpi 0.29.0 at **4.762 ms / 6.783 ms**, with **8.87 MiB**; and pi 1.6.0 at **103.877 ms / 105.099 ms**, with **114.67 MiB**. This is a narrow CLI startup measurement, not interactive TUI readiness or steady-state memory. It does not establish a general speedup. See [method, hashes, comparison rules and caveats](docs/spec/performance-baseline.md#cli-startup-comparison-zpi-vs-pi).

## Build And Run

Requires Zig **0.17.0** on macOS or Linux. The binary uses system C library facilities for native plugins. `grep` uses `rg`; `find` uses `fd` or `fdfind`. These utilities are optional and installed separately.

```sh
zig build
./zig-out/bin/zpi --help
export OPENAI_API_KEY=...    # or configure another supported provider
./zig-out/bin/zpi -p "Explain this project"
./zig-out/bin/zpi             # interactive terminal
```

Zpi supports OpenAI Chat Completions, a text/tool/image subset of OpenAI Responses, and a text/tool/image subset of Anthropic Messages. OpenAI-compatible chat models can also receive images. Pass `--image PATH` (up to eight PNG/JPEG/GIF/WebP files, 2 MiB total) with `-p` or a positional prompt; the same flag can accompany piped input. Configure providers and models in `~/.zpi/agent/models.json` or point to an existing compatible file with `--models-file`. Choose a provider/model with `--provider` and `--model`; credentials can come from provider environment variables or configuration.

Useful options include `--continue`, `--session PATH`, `--no-session`, `--tui-mode fullscreen|regular` (fullscreen is the default; regular preserves native terminal scrollback), `--tools`, `--no-tools`, `-s/--skills PATH`, `--prompt-template PATH`, `--system-prompt`, and `--cwd`. Skills in `~/.agents/skills` load automatically; `-s/--skills PATH` adds a skill directory or `SKILL.md`, and `--no-skills` disables skill discovery. Run `zpi --help` for the complete CLI reference. Build a headless binary without the interactive UI using `zig build -Dtui=none`.

Interactive commands include `/help`, `/hotkeys`, `/model`, `/thinking`, `/resume`, `/new`, `/tree`, `/compact`, `/copy`, `/session`, `/jobs`, and `/exit`. `/new` starts a fresh session without leaving the process. Use `--image PATH` on startup with an initial prompt; interactive image attachment commands are not yet implemented. Set `toolOutputsExpanded` in `~/.zpi/agent/settings.json` to `true` to start with tool output expanded; it defaults to `false` and is reapplied when resuming another session. The editor supports `Shift+Tab` to cycle thinking levels, `Ctrl+O` to toggle compact output, `Ctrl+S` to steer an active turn, `Ctrl-X` to copy the last assistant reply, and queued follow-up prompts.

In the default full-screen interface, use `Ctrl-F` or `/search` to search visible transcript rows, with `Ctrl-P`/`Ctrl-N` or Up/Down cycling matches. Search is ASCII case-insensitive and matches non-ASCII text exactly. Folded tool-result text and matches that cross line boundaries are excluded. Use `Ctrl-P`/`Ctrl-N` at an empty prompt to jump between user messages. `Esc` restores the previous history page. Use `/copy` or `Ctrl-X` to copy the last assistant reply as raw Markdown to the system clipboard. This requires `pbcopy` on macOS or `wl-copy` for Wayland / `xclip` for X11 on Linux. The query limit is 256 bytes, and search covers the retained 8,192 transcript rows. Click the pinned user message at the top to jump to it in the transcript. It keeps its text and vertical padding while you browse, switching to the preceding user message when you scroll past it. Scroll the wheel or use `PgUp` and `PgDn` to browse history. Click **Jump to latest** near the editor or press `End` to resume following new output. Tool results that wrap to more than two display rows at the current terminal width show `click to show more` below the preview; resizing the terminal recalculates the preview. Click the result or its hint to toggle that call, or press `Ctrl+O` to toggle all results. Startup and `/resume` use `toolOutputsExpanded` from the agent's `settings.json`, which defaults to `false`. Clicking a slash-command candidate fills the editor. Press `Enter` to submit it. Mouse support requires an ANSI terminal with xterm SGR mouse reports. In fullscreen mode, drag across transcript text with the left button and release to copy the selected terminal cells; a plain click keeps existing tool and navigation behavior. Use `--tui-mode regular` for native terminal scrollback and text selection; restored sessions retain their complete history display. On `/quit` or `/exit`, Zpi restores the terminal and prints one line with the saved session's JSONL filename, if a session file exists.

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

Important gaps include `web_search`, broad provider and OAuth support, image input to experimental RPC/extensions and pi session export/parity, full RPC compatibility, stable plugin ABI/Rust interoperability, package management, and general project trust/approval controls. See the [compatibility matrix](docs/spec/compatibility-matrix.md) for feature-level status.

## Roadmap

Priorities are subject to change; this is a project direction, not a release promise.

1. **Compatibility and daily-use reliability**: broaden provider/auth and session compatibility, improve project trust and tool approval controls, and keep native macOS/Linux verification current.
2. **Search and orchestration**: evaluate a first-party `web_search` integration and extend native subagents with additional model selection, persistent child sessions and background orchestration.
3. **Integration surface**: extend the experimental RPC command and event subset, then strengthen plugin lifecycle/ABI guarantees and Rust interoperability.
4. **Product maturity**: assess package/resource management, settings parity, further fullscreen TUI behavior, and release provenance/signing based on user needs and maintenance capacity.

## Performance Benchmarks

The performance benchmark document now includes same-host Zpi/pi/rpi measurements for native-session loading (128 and 8,192 messages), a local 64 KiB streamed response, and a local file-read tool call. Results include p50/p95 and methodology caveats; see [the benchmark report and reproduction commands](docs/spec/performance-baseline.md#cross-tool-rpc-benchmark).

## Documentation

- [Compatibility matrix](docs/spec/compatibility-matrix.md)
- [Performance baseline and comparison method](docs/spec/performance-baseline.md)
- [Platform verification](docs/spec/platform-verification.md)
- [Security notes](docs/security.md), [capability authorization and audit contract](docs/spec/security-capabilities.md), and [execution policy boundaries](docs/spec/security-boundaries.md)
- [Install, upgrade and remove](docs/install.md)
- [v0.1.3 release notes](docs/releases/v0.1.3.md), [v0.1.2 release notes](docs/releases/v0.1.2.md), [v0.1.1 release notes](docs/releases/v0.1.1.md), and [v0.1.0 release notes](docs/releases/v0.1.0.md)
- [Native plugin ABI](docs/spec/native-plugin-abi.md) and [runtime](docs/spec/native-plugin-runtime.md)
- [TypeScript extension host](docs/spec/typescript-extension-host.md)
- [Implementation specification](docs/spec/implementation-spec.md)

Run the core checks with `zig build test`, `zig build`, `zig fmt --check build.zig build.zig.zon src`, and `python3 scripts/test-cli.py`. Plain `zig build` emits ReleaseSafe; use `-Doptimize=Debug` for a debug build or `zig build -Dtui=none` for a headless binary. The platform verification document lists additional SDK, native-plugin, release, and Linux guest checks.
