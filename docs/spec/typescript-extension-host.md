# TypeScript Extension Host Compatibility

Status: experimental opt-in Node child host integrated into Zpi's CLI/agent loop for the enumerated subset below. The existing `scripts/probe-ts-extensions.mjs` remains a stub-only feasibility probe. `scripts/ts-host.mjs` uses the actual loader, `ExtensionRunner`, SDK tool validator and an unmodified upstream extension in executable fixtures. Current test evidence uses installed `@earendil-works/pi-coding-agent` **1.5.2** and **1.6.0**, Node 24.22.1, and the matching installed `pi-ai` and TypeBox dependency graph. The pinned pi source is a post-release snapshot at `c815ddaa3736bd0b009ce6a997ee5003f8a3a532`; same-version package identity does not establish exact source equivalence. Runtime host refuses unsupported coding-agent SDK versions and `pi-ai` version drift.

## Runtime Boundary

- Node remains an optional external runtime. The caller supplies its absolute pi SDK package directory and explicit extension paths. The host does not discover project/global extensions, install packages, load `auth.json`, access Zpi's sessions, or execute the rest of the agent loop. The Zig CLI invokes input handlers and wraps enabled built-in/extension tools with gate and result hooks.
- Extensions are arbitrary trusted JavaScript with the launching user's OS permissions. This process boundary is not a sandbox. The caller must explicitly choose paths and should treat each path and its dependencies as executable code. Project trust and auto-discovery have not been implemented.
- Protocol v1 is JSONL over stdin/stdout, one outstanding operation at a time, with request IDs, 1 MiB line/response limits, structural depth/node caps, backpressure termination and 1-300 second operation deadlines. Progress messages correlate to the originating request. The Node protocol accepts a separate cancellation request and aborts its signal; this is tested by the Python protocol client. The Zig client is synchronous per RPC, so interactive `Ctrl-C` cancels waiting on an in-flight RPC and terminates the child host process group cleanly, while `abort()` inside extensions remains unsupported. Deadlines also cancel transport work, join tasks and kill the child process group so uncooperative extension code cannot mutate shared state after a timeout or interrupt. Child exit invalidates the entire runtime.
- Extension logs go to stderr; raw fd-1 writes by extensions violate the protocol and cause the client to reject/terminate the host. The Zig parent must use absolute executable/script paths, avoid shell command construction, validate protocol records, stop the child on EOF/corruption, and never trust a tool spec until all paths and registrations have passed checks.
- A real `ExtensionRunner` supplies `mode: "print"`, `hasUI: false`, honest no-op UI behavior, `isProjectTrusted(): false`, `ctx.signal`, and `ctx.executeTool`. Unsupported calls (session manager/model registry state, nested tool execution, commands, compaction, providers, MCP, dynamic registration) fail explicitly. Read-only pi session methods are not yet backed by Zpi session projections.
- Initial supported events are `input`, `tool_call`, `tool_result`, and `session_start`/`session_shutdown`. Tool definitions are exported as JSON Schema and validated using the installed matching `pi-ai` SDK validator before execution. Tool updates and errors are correlated; JSON mode forwards both as `extension_event` records. The regular terminal reports handler errors on stderr but does not render tool progress yet. Event handlers use the upstream runner's composition/error policy: input-handler errors are emitted and input continues; tool-call exceptions reject/deny the operation; tool-call mutations are returned to the caller; tool-result transforms are returned to the caller. Extension tool execution errors become ordinary error results while the host remains usable. A deadline is fatal and kills the host process group.

## Verified Fixture Slice

Use explicitly selected trusted extensions and a user-installed SDK:

```sh
./zig-out/bin/zpi --pi-sdk /absolute/path/to/@earendil-works/pi-coding-agent \
  -e /absolute/path/to/extension.ts -p "Use my extension tool"
```

`zig build` installs `ts-host.mjs` and its `pi-sdk.mjs` helper under `share/zpi/`. When using `--extension-host` with a relocated copy of the bundled host, keep those files together. The helper resolves `pi-ai` from the selected SDK, including installations where npm hoists the dependency. Both packages must report the same supported version (`1.5.2` or `1.6.0`). This slice always exposes print-mode extension context, even when Zpi itself uses its regular terminal or JSON mode. `--no-tools` disables model tools, including extension tools, by default; explicit `--tools` selection can enable them again. `--no-builtin-tools` retains extension tools, including replacements. Allowlist/modifier selection and final exclusions apply after registration. Input handlers still run. Tool-result `details` are copied into Zpi session records. Tool contents are currently text-only and bounded to 50 KiB; multimodal results and extra metadata are rejected or remain unsupported as documented below.

Run offline fixtures with the user-installed SDK path, without credentials or network:

```sh
python3 scripts/test-ts-host.py /absolute/path/to/@earendil-works/pi-coding-agent
ZPI_PI_SDK=/absolute/path/to/@earendil-works/pi-coding-agent zig build test
ZPI_PI_SDK=/absolute/path/to/@earendil-works/pi-coding-agent python3 scripts/test-cli.py
```

The test loads upstream `hello.ts` and `input-transform.ts` unchanged, plus `scripts/fixtures/ts-extension.ts`. It asserts real pi SDK imports, TypeBox schema registration/validation, input transform/handled/source routing, tool execution, tool-call block/mutation/throw semantics, error surfacing, progress output, `ctx.signal` identity and cancellation, busy rejection, recovery after cancellation, session shutdown, version metadata, and stdout purity. The Zig bridge fixture checks response ownership across requests, tool validation rejection, shutdown and timeout cleanup. The CLI fixture drives the real upstream `hello` tool plus input transformation, checks that a blocked write produces no file, verifies mutated write arguments, and checks persisted extension result details. These establish a bounded real-host subset, not full extension compatibility.

## Deferred Compatibility

TUI components and rendering, commands/flags/shortcuts, session lifecycle replacement and mutation, a faithful read-only `SessionManager` projection, model/provider registries and OAuth, compaction, prompt/context pipeline, MCP, tool exposure/prepareLoadout/nested tools, reload/generation semantics, and project auto-discovery/trust are not implemented. Extensions registering unsupported hooks/metadata fail load instead of being silently ignored. `notify`/`setStatus` are no-ops in print mode. Provider handlers and background services must not be assumed to run.

The actual package exports the SDK runner but its extension loader is an internal package entrypoint, and extension imports depend on a coherent package-local dependency graph. The host intentionally pins/validates a known package version and its core `pi-ai` validator package; upgrades require fixture review. No dependencies are vendored. MIT-covered upstream examples are referenced for testing but not copied into the product; Zpi's behavior fixture is independently authored. Any redistributed Node/npm dependency set needs a third-party license inventory and notices.
