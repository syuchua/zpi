# Performance baseline

This document records measured performance for specific commands and fixtures only. Measurements use native local execution where noted; they are baselines, not pass/fail thresholds or claims about all platforms. Zpi, pi, and rpi comparisons must use the same host, isolated configuration, offline/local fixtures, warmup policy, build mode, and process-level measurement boundary. Never compare numbers from different machines or different workloads.

## What matters most: message loading

For an interactive coding agent, restoring a long conversation is a first-class performance path. It determines how quickly a user can resume work, how much terminal output is produced, and how much memory is retained before the next prompt. `--version` is useful as a floor-cost sanity check, but it does not measure session parsing, active-branch projection, Markdown/tool-card rendering, or terminal output.

The primary Zpi workload is therefore the native session restore benchmark, not the version benchmark:

```sh
python3 scripts/bench-product.py /path/to/zpi \
  --restore-only --tui-mode fullscreen \
  --samples 20 --messages 8192 --message-padding 128 \
  --environment 'OS, CPU, build mode, binary hash'
```

Run the same command with `--tui-mode regular` to measure native scrollback restoration. Regular mode retains the full-history display semantics; optimize output buffering without truncating the visible transcript. The benchmark uses a synthetic linked transcript, an isolated HOME, a local fake provider, a fixed 80x24 PTY, and verifies that the session bytes remain unchanged. It reports restore time, PTY bytes emitted at readiness, and peak RSS separately.

The cross-tool RPC benchmark generates the same logical history for each CLI and encodes it in that CLI’s native session format. The Zpi PTY benchmark above also captures viewport and scrollback rendering. Regular-mode restore remains unpaged: history output now uses one fixed 32 KiB streaming writer per render call instead of a separate terminal streaming operation for each text fragment. This preserves the full display and lets the writer drain in bounded chunks; the final chunk is flushed before the editor resumes. The batching path is covered by the CLI PTY integration tests. Local checks pass, but the 8,192-message ReleaseSafe before/after run did not demonstrate a reliable improvement: unbuffered p50/p95 were 888.01/903.23 ms, and buffered were 893.38/902.98 ms (20 samples each). Output size and peak RSS were effectively unchanged. Treat batching as syscall reduction, not a proven latency optimization, until a lower-noise measurement establishes otherwise.

## Comparison matrix

| Track | Zpi | pi | rpi | Purpose |
| --- | --- | --- | --- | --- |
| Startup | `scripts/bench-startup.py` | native `pi --version` | `rpi --version` from the release binary | Process creation and version command |
| Session restore | `scripts/bench-rpc.py` with Zpi JSONL | Native pi v3 JSONL | Native rpi v4 JSONL | Process launch through the `get_state` response |
| Stream and tool response | `scripts/bench-rpc.py` | Same loopback SSE fixture | Same loopback SSE fixture | First and last text, tool result, turn settlement |
| TUI restore | `scripts/bench-product.py --restore-only` | — | — | Restore latency, PTY output and peak RSS |

## Cross-tool RPC benchmark

The history fixture uses linked text-only user messages. The runner starts a fresh process with the native session file, times the first successful `get_state` response, and validates the loaded history with a subsequent untimed prompt. The loopback provider checks the full sequence of historical user messages. The timed path includes process startup, CLI setup, session restore, and the implementation’s `get_state` work.

The streaming fixture sends 64 KiB in 64 SSE text chunks over loopback. The read fixture enables only `read` and checks that the agent returns the contents of the same 4,097-byte local file before issuing its follow-up model request. Turn timings start after RPC readiness. The tool response interval uses the client's observed `tool_execution_start` and `tool_execution_end` events, including each CLI’s event delivery overhead. The runner also timestamps the loopback provider’s request and response boundaries.

```sh
python3 scripts/bench-rpc.py \
  --zpi /path/to/zpi --pi /path/to/pi --rpi /path/to/rpi \
  --messages 128 8192 --warmup 3 --samples 20 > rpc-benchmark.json
```

Each sample uses an isolated temporary home and project directory. The runner rotates CLI order and records executable hashes, native fixture sizes and raw timings. This RPC workload covers the client-observed event stream. Zpi’s terminal rendering and peak RSS are measured in the PTY restore benchmark below.

Add `--zpi-timings` to run an additional Zpi-only read turn with session persistence enabled. It opts into `zpi_performance` RPC records with `ZPI_RPC_TIMINGS=1`. The report includes request encoding, connection and send, wait for response headers, SSE reading and event delivery, local tool execution, session append and sync by message role, and serialization and writing of the RPC tool result. Phase totals sum matching records within one turn. Provider and transport totals include their subphases, so the totals overlap. The three-product runs keep these diagnostics off.

### macOS arm64 results: Zpi v0.1.1, pi 1.6.0, rpi 0.29.0

Measured on Apple M4, macOS 27.2.1 (Darwin 27.2.0), native arm64, Python 3.9.6; 3 warmups and 20 samples per CLI/workload. Values are p50 / p95 milliseconds. Each CLI received the same logical history in its native session format.

| Workload | CLI | Session bytes | Metric p50 / p95 |
| --- | --- | ---: | ---: |
| Load 128 messages | Zpi | 35,694 | ready 3.452 / 4.025 |
| Load 128 messages | pi | 41,413 | ready 125.685 / 128.061 |
| Load 128 messages | rpi | 45,887 | ready 26.004 / 30.000 |
| Load 8,192 messages | Zpi | 2,277,486 | ready 11.900 / 12.936 |
| Load 8,192 messages | pi | 2,638,021 | ready 133.473 / 134.956 |
| Load 8,192 messages | rpi | 2,939,992 | ready 69.998 / 76.088 |
| Stream 64 KiB in 64 SSE chunks | Zpi | — | first 1.047 / 1.165; last 1.595 / 1.688; settled 1.812 / 1.928 |
| Stream 64 KiB in 64 SSE chunks | pi | — | first 17.116 / 17.421; last 20.996 / 21.261; settled 21.782 / 22.048 |
| Stream 64 KiB in 64 SSE chunks | rpi | — | first 1.193 / 1.273; last 1.728 / 1.912; settled 2.217 / 2.398 |
| Read a 4,097-byte fixture | Zpi | — | submit→tool result 0.906 / 1.012; tool start→end 0.054 / 0.064; settled 1.214 / 1.320 |
| Read a 4,097-byte fixture | pi | — | submit→tool result 21.847 / 22.808; tool start→end 2.351 / 2.606; settled 24.453 / 25.382 |
| Read a 4,097-byte fixture | rpi | — | submit→tool result 1.375 / 1.436; tool start→end 0.423 / 0.454; settled 1.770 / 1.869 |

History `ready` includes process creation, CLI startup, session parse/projection, and RPC response. It is not a parser-only timing. The history contains only user text; it excludes systems, tools, images, resource discovery, and project context. The fake provider and read tool use loopback/local files, so network/model latency is excluded. Streaming is synthetic. Each implementation has different system prompts, token accounting, event protocols, and storage formats; these figures compare the practical paths under this fixture, not equal internal work. RSS is not measured in this RPC run.

Raw samples, hashes, versions and fixture metadata are in `/tmp/zpi-rpc-benchmark.json` from successful task `be7a792c9` (exit 0; benchmark script SHA-256 `dffa6207d45ec66c0961379ec7ceb49061af9c1d0b7c2fde219c3e194bfbce70`). The file is local, not checked in.

## Existing CLI/session baseline

This is a secondary CLI/import/resume track. It complements, but does not replace, the message-loading benchmark above.

The earlier baseline measures fresh-process `--version`, pi v3 text-session import, and one resumed request against a loopback HTTP/SSE fixture. Reproduction and the historical raw samples remain in the sections below. These results use different binaries and workloads from the TUI baseline; do not compare their values directly.

```sh
python3 scripts/bench-cli.py /absolute/path/to/zpi \
  --samples 20 --environment 'Describe OS, CPU, build mode and execution method'
```

For the startup comparison:

```sh
python3 scripts/bench-startup.py \
  --zpi ./zig-out/bin/zpi --pi "$(command -v pi)" \
  --rpi /absolute/path/to/rpi --samples 20
```

The optional rpi path is not available in the Zpi checkout by default. Build or download rpi separately, record its version and SHA-256, and run all three binaries on the same host.

It records per-process elapsed, peak-RSS and CPU samples, OS, architecture, version, binary SHA-256, and session fixture sizes. It requires Python 3.9+ and POSIX `wait4` and `SIGALRM`.

## Zpi native TUI/product baseline (20 samples)

Measured 2026-11-23 on Apple M4, macOS 27.2.1 (Darwin kernel 27.2.0), native arm64. The measured executable is the downloaded `v0.1.0` macOS arm64 ReleaseSafe archive binary, SHA-256 `6a1c3fc903501f92393bffaf85f4f25f3ce15ac33c0910760c535829ce32f1c3`; Zig is 0.17.0. Python 3.9.6 provides a fixed 80-column by 24-row PTY and a local synthetic OpenAI Chat Completions SSE provider. Each sample starts fresh Zpi processes with a temporary HOME/agent directory and `--no-tools`, `--no-skills`, and `--no-prompt-templates`. The baseline uses 8,192 synthetic linked session messages with 128 padding bytes each (2,288,671-byte JSONL) and a 1,024-message compaction history. The local stream emits 262,159 bytes of assistant text. Timings are wall clock.

| Measurement | p50 | p95 | Interpretation |
| --- | ---: | ---: | --- |
| Launch to initial PTY screen marker | 2.819 ms | 3.110 ms | Process launch through bracketed-paste/editor readiness, on fresh session |
| Launch to first streamed text (local provider) | 3.574 ms | 3.962 ms | End-to-end local prompt + HTTP/SSE + rendering |
| Submit to first streamed text | 0.722 ms | 0.928 ms | After the benchmark prompt is written to the PTY |
| Restore 8,192-message session to editor readiness | 221.053 ms | 235.026 ms | Parse, project, render resumed history, and initialize editor |
| `/tree` open on the same history | 0.085 ms | 0.102 ms | Command write through tree-picker footer marker |
| Select previous entry in tree | 0.034 ms | 0.045 ms | Arrow key through selected-entry marker/footer |
| Editor update frame | 0.050 ms | 0.063 ms | Single-character PTY input through synchronized frame output |
| Complete 262,159-byte local stream | 8.022 ms | 8.981 ms | Prompt through final streamed marker; synthetic server writes immediately |
| Peak RSS during long-stream process | 5.16 MiB | 5.16 MiB | `wait4` per-child `ru_maxrss`; this is not process-tree memory |
| `/compact benchmark` (1,024-message history) | 1.902 ms | 2.025 ms | Command through compaction summary frame, local summarizer |
| Follow-up local request before compaction | 3.211 ms | 3.431 ms | Full 1,025-message provider request |
| Follow-up local request after compaction | 0.506 ms | 0.544 ms | Projected 17-message request |

Across all 20 compaction samples, the recorded context request decreased from 1,025 to 17 messages and from 176,705 to 2,664 request-body bytes; the stored pre-compaction estimate was 41,895 tokens. This synthetic fixture verifies compaction/session projection and measured request size; it does not evaluate summary quality or claim a proportional end-to-end provider speedup.

The [raw JSON report](performance-baseline-macos-arm64-v0.1.0.json) contains every sample, fixture size, hash and context request. The benchmark source SHA-256 was `2c126374d6c876ef7a5ca802b3850f5e7e78605c04511c8fa6ecc1605d99c170`. Run the following from the project root with Python 3.9+ on macOS arm64.

```sh
scratch=$(mktemp -d)
gh release download v0.1.0 -R syuchua/zpi -D "$scratch" \
  -p 'zpi-0.1.0-macos-arm64.tar.gz' -p 'zpi-0.1.0-macos-arm64.tar.gz.sha256'
(cd "$scratch" && shasum -a 256 -c zpi-0.1.0-macos-arm64.tar.gz.sha256 && \
  tar -xzf zpi-0.1.0-macos-arm64.tar.gz)
python3 scripts/bench-product.py \
  "$scratch/zpi-0.1.0-macos-arm64/bin/zpi" --samples 20 --messages 8192 \
  --message-padding 128 \
  --environment 'Describe hardware, OS, build mode and execution method' > product-baseline.json
```

Reproducibility caveats: wall-clock numbers include Python harness scheduling and PTY I/O. First-screen readiness ends at the synchronized editor frame after bracketed-paste enable. The editor update measures keypress-to-frame time at the PTY. Both measurements include kernel buffering and scheduling. `wait4` RSS is per-child maximum RSS, not a process tree. The test provider is local, synthetic and unauthenticated; its latency is not representative of the Internet or a production model. The synthetic history contains alternating user/assistant text, not arbitrary tool/image content. Tree and editor measurements are interactive command response intervals. Compaction response latency uses a synthetic local summary. No thresholds are defined. Compare only the same host/OS, binary hash, PTY geometry, workload and sample count.

## CLI startup comparison: Zpi vs pi

The existing startup comparison is the first direct Zpi/pi track. It measures `--version` only, from before process creation through exit, using Python `wait4`. It does not measure agent readiness. The harness now accepts `--rpi PATH` for the same `--version` process boundary; use isolated rpi-specific configuration variables when extending it to cold-start or ready-state comparisons.


A direct three-way comparison used 20 fresh processes per executable on macOS arm64. All `--version` commands used the same Python `wait4` harness, temporary HOME, host and process boundary. Zpi used its ReleaseSafe archive, rpi used its published macOS arm64 archive, and pi used the installed Node CLI. Wall time includes launcher overhead, process creation, runtime startup and command completion.

| Executable | Version | Binary SHA-256 | `--version` p50/p95 | Maximum sampled peak RSS |
| --- | --- | --- | ---: | ---: |
| Zpi | `0.1.1` | `91e1b34853f1e2a0cc1180987fe535d6ea50a4a80247f5b32fbc8e8c9919c473` | **2.562 / 2.999 ms** | **2.06 MiB** |
| rpi | `0.29.0` | `94bf14e9d0bb9f14a5ea0f927385bd81d045c45bda6cf0783b9a20f63a467d38` | **4.762 / 6.783 ms** | **8.87 MiB** |
| pi | `1.6.0` | `e79626f2dd6f94aa45d30f3fa63cd84319a6eefcd150b353cfaf274366926774` | **103.877 / 105.099 ms** | **114.67 MiB** |

Environment: Apple M4, macOS 27.2.1 / Darwin 27.2.0, arm64, Python 3.9.6, 20 samples. The raw report is `.pi/tasks/01a1d9a6-2322-729e-9a34-0a4df7c3b930-29562/b897b6bb1.output`. This is a process/version startup comparison, not a cold agent readiness comparison and not a TUI or tool-loop benchmark. The rpi archive was downloaded from `bigfish1913/pi-rust` v0.29.0; Zpi was downloaded from `syuchua/zpi` v0.1.1.

Reproduce the same track with:

```sh
python3 scripts/bench-startup.py \
  --zpi /path/to/zpi \
  --pi "$(command -v pi)" \
  --rpi /path/to/rpi \
  --samples 20
```

## Zpi v0.1.1 session restore baseline

Measured from the published macOS arm64 ReleaseSafe `v0.1.1` archive, SHA-256 `91e1b34853f1e2a0cc1180987fe535d6ea50a4a80247f5b32fbc8e8c9919c473`, Apple M4, macOS 27.2.1, native arm64, 20 samples, 8,192 linked messages, 2,288,671-byte session fixture, fixed 80x24 PTY:

| Mode | Restore p50 | Restore p95 | PTY bytes at readiness | Peak RSS |
| --- | ---: | ---: | ---: | ---: |
| fullscreen | 38.1 ms | 39.7 ms | 1,821 bytes | 19.53 MiB |
| regular | 897.4 ms | 963.8 ms | 2.45 MiB | 17.23 MiB |

A fresh ReleaseSafe before/after check compared the regular-output buffering change with an otherwise identical build from before that change. In fullscreen, the unbuffered binary (SHA-256 `251cf2d70b130fb9d20a25173e18d152155b6fe7d11656e9a7ec119d83972d5f`) measured **38.05 / 39.12 ms** p50/p95; the current binary (`c8ba14dbc42c14d9dd6b0748ff7cdccc15e10e83cf6990863efef9ec0ce5edf1`) measured **37.72 / 38.23 ms**. Both emitted 1,821 PTY bytes and had 15.17 MiB peak RSS. The 0.32 ms p50 difference is small and does not establish a fullscreen improvement; fullscreen does not use the regular-history output buffer.

With the instrumented benchmark script, the old binary measured launch-to-alternate-screen **11.38 / 11.85 ms** and alternate-screen-to-ready **25.47 / 26.03 ms** p50/p95. The current binary measured **11.36 / 18.03 ms** and **25.69 / 38.57 ms**, respectively. Most current p50 phase times remain close, but two high-latency samples inflate its p95 and maximum (56.61 ms total). The split timer records the parent process's PTY read timestamp when a marker is observed, so these are wall-clock milestones—not internal CPU timers. Instrumented runs have observer overhead and show host scheduling outliers; use the non-instrumented run for the primary total. Reports are local at `/tmp/zpi-fullscreen-{unbuffered,current}.json` and `/tmp/zpi-fullscreen-{unbuffered,current}-phases-correct.json`; the latter use benchmark script SHA-256 `c88bfdf672a8afa03470a90804c9411b0e186a436a9a90b7eb195d9d47777e8d`.

The original v0.1.1 reports are `/tmp/zpi-restore-fullscreen.json` and `/tmp/zpi-restore-regular.json` from task `b0b082f0c`. The new comparisons use the current synthetic PTY fixture (2,288,671-byte session), while the historical v0.1.1 line above used a different fixture size; do not compare those rows as a strict before/after. The older full-product fullscreen benchmarks `bf87f8598`, `b25a8f575`, and `be98a2ac6` failed in the harness while waiting for a streaming/editor marker and are not evidence.

## Historical import/resume samples

| Runtime | Binary SHA-256 | `--version` p50/p95, peak RSS | 128 messages (~31 kB), import and resume p50/p95 | 8,192 messages (~2.04 MB), import and resume p50/p95 |
| --- | --- | --- | --- | --- |
| macOS arm64 native (Darwin 27.2.0), Zig 0.17.0 ReleaseSafe | `914dd41e08265ed17a7a16a8f8e9a4b7945f1f764beeea754563126ae73ca2a4` | 3.15/7.26 ms, 2.06 MiB | import 3.51/3.98 ms; resume 3.83/4.44 ms | import 45.30/47.47 ms; resume 21.06/22.50 ms |
| Ubuntu 24.04 arm64/glibc 2.39 in Colima, Zig 0.17.0 ReleaseSafe cross-build from macOS | `4bb172e532887089d609124a1c0b4d7189a61d359e92fd1fb581b592b12e608a` | 0.25/0.40 ms, 30.9 MiB | import 1.20/1.66 ms; resume 1.83/2.66 ms | import 30.94/38.72 ms; resume 30.40/39.33 ms |

Each measurement used 20 samples. The Linux guest ran in a macOS-hosted arm64 VM; Linux `wait4` can include pre-exec Python memory, so its RSS is not Zpi steady-state memory. Raw older samples are in `.pi/tasks/01a1d9a6-2322-729e-9a34-0a4df7c3b930-85015/b7933c3ef.output`. These older binaries predate the provider error-body change.
