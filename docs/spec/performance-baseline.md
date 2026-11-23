# Performance baseline

This document records measured performance for specific commands and fixtures only. Measurements use native local execution where noted; they are baselines, not pass/fail thresholds or claims about all platforms.

## Existing CLI/session baseline

The earlier baseline measures fresh-process `--version`, pi v3 text-session import, and one resumed request against a loopback HTTP/SSE fixture. Reproduction and the historical raw samples remain in the sections below. These results use different binaries and workloads from the TUI baseline; do not compare their values directly.

```sh
python3 scripts/bench-cli.py /absolute/path/to/zpi \
  --samples 20 --environment 'Describe OS, CPU, build mode and execution method'
```

It records per-process elapsed, peak-RSS and CPU samples, OS, architecture, version, binary SHA-256, and session fixture sizes. It requires Python 3.9+ and POSIX `wait4` and `SIGALRM`.

## Native TUI/product baseline (20 samples)

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

## CLI startup comparison

A separate local comparison used 20 fresh processes per executable on macOS arm64. Both `--version` commands used Python `Popen` and `wait4` with a temporary HOME. Wall time includes launcher overhead, process creation, runtime startup and command completion.

| Executable | Version | Binary SHA-256 | `--version` p50/p95 | Maximum sampled peak RSS |
| --- | --- | --- | --- | --- |
| Zpi default build | `0.1.0-dev` | `4d6f64846cfef64cb0b2e65e451693c39f27717c6ee8ff2df300b4865815266b` | 3.25/3.39 ms | 3.44 MiB |
| pi bundled CLI | `1.6.0` | `e79626f2dd6f94aa45d30f3fa63cd84319a6eefcd150b353cfaf274366926774` | 104.53/106.70 ms | 114.68 MiB |

Zpi used the repository default build and pi used its bundled Node CLI. Reproduce this command-level comparison with `python3 scripts/bench-startup.py --zpi ./zig-out/bin/zpi --pi "$(command -v pi)" --samples 20`.

## Historical import/resume samples

| Runtime | Binary SHA-256 | `--version` p50/p95, peak RSS | 128 messages (~31 kB), import and resume p50/p95 | 8,192 messages (~2.04 MB), import and resume p50/p95 |
| --- | --- | --- | --- | --- |
| macOS arm64 native (Darwin 27.2.0), Zig 0.17.0 ReleaseSafe | `914dd41e08265ed17a7a16a8f8e9a4b7945f1f764beeea754563126ae73ca2a4` | 3.15/7.26 ms, 2.06 MiB | import 3.51/3.98 ms; resume 3.83/4.44 ms | import 45.30/47.47 ms; resume 21.06/22.50 ms |
| Ubuntu 24.04 arm64/glibc 2.39 in Colima, Zig 0.17.0 ReleaseSafe cross-build from macOS | `4bb172e532887089d609124a1c0b4d7189a61d359e92fd1fb581b592b12e608a` | 0.25/0.40 ms, 30.9 MiB | import 1.20/1.66 ms; resume 1.83/2.66 ms | import 30.94/38.72 ms; resume 30.40/39.33 ms |

Each measurement used 20 samples. The Linux guest ran in a macOS-hosted arm64 VM; Linux `wait4` can include pre-exec Python memory, so its RSS is not Zpi steady-state memory. Raw older samples are in `.pi/tasks/01a1d9a6-2322-729e-9a34-0a4df7c3b930-85015/b7933c3ef.output`. These older binaries predate the provider error-body change.
