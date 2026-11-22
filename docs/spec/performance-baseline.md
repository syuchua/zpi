# Performance Baseline

This baseline measures fresh-process startup, pi v3 text-session import, and one resume request against a loopback HTTP/SSE fixture. Resume timings include request encoding, loopback transport, fixture processing and session writes. The fixture checks byte-stable repeated imports, the resumed request's message count and final prompt, and preservation of imported records on resume.

## Reproduce

Build the target binary with Zig 0.17.0 in `ReleaseSafe`, then run:

```sh
python3 scripts/bench-cli.py /absolute/path/to/zpi \
  --samples 20 --environment 'DESCRIBE OS, CPU, build mode and execution method'
```

The harness records raw elapsed-time, per-child peak-RSS and CPU samples; p50/p95; OS, architecture, version and binary SHA-256; and session fixture sizes. It starts a fresh Zpi process for each sample with an isolated temporary home and uses a loopback provider. It requires Python 3.9+ and POSIX `wait4` and `SIGALRM`. Zpi receives only `HOME` and `PATH`. Samples use the operating system's normal filesystem caching.

## CLI Startup Comparison

A local comparison was run on macOS 27.2.0 arm64 with 20 fresh processes per executable. Both commands used the same Python `subprocess.Popen` + `os.wait4` harness, temporary `HOME`, environment limited to `PATH` and `HOME`, and `--version` command. The wall time includes Python launch overhead, process creation, executable/runtime startup and command completion. Peak RSS is the maximum per-child `ru_maxrss` observed across those samples.

| Executable | Version | Binary SHA-256 | `--version` p50/p95 | Maximum sampled peak RSS |
| --- | --- | --- | --- | --- |
| Zpi (`zig-out/bin/zpi`, default build) | `0.1.0-dev` | `4d6f64846cfef64cb0b2e65e451693c39f27717c6ee8ff2df300b4865815266b` | 3.25/3.39 ms | 3.44 MiB |
| pi (`@earendil-works/pi-coding-agent` bundled CLI) | `1.6.0` | `e79626f2dd6f94aa45d30f3fa63cd84319a6eefcd150b353cfaf274366926774` | 104.53/106.70 ms | 114.68 MiB |

Reproduce from the repository root after building Zpi and installing pi:

```sh
zig build
python3 scripts/bench-startup.py --zpi ./zig-out/bin/zpi --pi "$(command -v pi)" --samples 20
```

This comparison is an indicative local CLI startup snapshot, not an apples-to-apples interactive readiness or steady-state memory benchmark. The Zpi binary is the repository's default build and pi uses its bundled Node CLI, so runtime and packaging differ by design. The maximum RSS is sampled peak process RSS for this short command, not a measurement of idle TUI memory. Results vary by machine, OS, filesystem cache, Zig build mode, Node version and launcher. Do not extrapolate this result to provider requests or end-to-end agent turns. Additional optimized-build, interactive-ready, idle process-tree, and same-host cross-platform samples are needed before making broader performance claims.

## Observed Samples

| Runtime | Binary SHA-256 | `--version` p50/p95, peak RSS | 128 messages (~31 kB), import and resume p50/p95 | 8,192 messages (~2.04 MB), import and resume p50/p95 |
| --- | --- | --- | --- | --- |
| macOS arm64 native (Darwin 27.2.0), Zig 0.17.0 ReleaseSafe | `914dd41e08265ed17a7a16a8f8e9a4b7945f1f764beeea754563126ae73ca2a4` | 3.15/7.26 ms, 2.06 MiB | import 3.51/3.98 ms; resume 3.83/4.44 ms | import 45.30/47.47 ms; resume 21.06/22.50 ms |
| Ubuntu 24.04 arm64/glibc 2.39 in Colima, Zig 0.17.0 ReleaseSafe cross-build from macOS | `4bb172e532887089d609124a1c0b4d7189a61d359e92fd1fb581b592b12e608a` | 0.25/0.40 ms, 30.9 MiB | import 1.20/1.66 ms; resume 1.83/2.66 ms | import 30.94/38.72 ms; resume 30.40/39.33 ms |

Each measurement used 20 samples. The Linux guest ran in a macOS-hosted arm64 VM. On Linux `wait4` can include pre-`exec` memory inherited from the Python launcher. The roughly 31 MiB floor in the guest samples is therefore a process-launch measurement and should not be interpreted as Zpi's steady-state memory. The workloads use text-only histories, disable tools and extensions, and define no pass/fail thresholds.

Raw CPU, RSS and elapsed-time samples are in `.pi/tasks/01a1d9a6-2322-729e-9a34-0a4df7c3b930-85015/b7933c3ef.output`. These binaries precede the provider error-body change. Outstanding measurements include native x86_64 Linux and Intel macOS, plugin invocation and lifecycle costs, idle process-tree memory, and equivalent TypeScript and native ABI workloads.
