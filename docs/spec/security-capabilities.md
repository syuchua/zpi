# Capability authorization and audit contract

Status: MVP contract for the opt-in authorization and audit layer. This document defines policy and observability semantics; it does not claim OS sandboxing or memory isolation.

## Scope and compatibility

Zpi keeps its existing behavior by default. A normal invocation uses `compatibility` policy mode: existing tool, MCP, TypeScript, native-plugin, and RPC behavior remains available according to the existing CLI/tool-selection rules. Authorization decisions are still observable through the audit sink when one is configured.

The opt-in `secure` policy mode is a reference-monitor layer inside Zpi. It denies sensitive effects unless a matching capability grant is present. It does not reduce the OS permissions of Zpi or any child process. A trusted native library can still execute constructors before Zpi validates its descriptor, and an already loaded extension or MCP process can use APIs outside this contract.

This MVP does not provide:

- an OS-level sandbox, container, seccomp profile, MAC policy, or privilege drop;
- memory or crash isolation for native plugins;
- authentication or authorization for remote RPC clients;
- automatic project trust or extension discovery;
- a hidden approval prompt that claims to contain an already started process.

The existing explicit executable paths and tool-selection rules remain in force in both modes.

## Capability identifiers

Capability identifiers are stable lowercase ASCII names. A request has one primary capability and may include a target descriptor. The initial registry is:

| Capability | Sensitive effect | Covered surfaces |
| --- | --- | --- |
| `filesystem.read` | Read files or retrieve previously fetched content | `read`, `grep`, `find`, `ls`, `get_content` |
| `filesystem.write` | Create, replace, or edit files through a built-in tool | `write`, `edit`; there is no separate built-in delete tool in this MVP |
| `process.exec` | Dispatch shell or process-management work | `bash`, interactive shell, `bg_*`, native subagent dispatch, clipboard helpers, MCP and TypeScript child startup |
| `network.connect` | Fetch network content through a built-in tool | `web_fetch` |
| `clipboard.write` | Send transcript text to a clipboard helper | Selection copy and latest-reply copy |
| `extension.load` | Load TypeScript extensions and invoke their registered tools | Extension startup and model-callable TypeScript tools |
| `native_plugin.load` | Load a native library and invoke its registered tools | C/Zig plugin loading and model-callable native tools |
| `mcp.start` | Start an MCP stdio server and invoke its registered tools | MCP initialization and model-callable MCP tools |
| `rpc.control` | Admit a model turn through local JSONL RPC | RPC `prompt` |

Clipboard copy first resolves a supported helper and validates the payload, then requires both `process.exec` and `clipboard.write` before invoking the helper. `process.exec` is checked first. The `clipboard.write` authorization records that event as its `parentId`; the helper's result is recorded against both authorizations. Thus a missing `process.exec` grant does not consume a request-scoped `clipboard.write` grant. MCP and TypeScript startup require both the component capability and `process.exec`. Their registered tools are checked again at dispatch under the component capability. A wrapped built-in retains its original capability. A running extension host can handle input and tool hooks under the trust granted at startup.

Provider HTTP, startup reads of configuration and resources, and session storage are outside this policy layer. Shell grants authorize command dispatch and can permit arbitrary file changes, creations, deletions, network access, and other effects through that command. Deletion through shell, helper, or component code is not intercepted as a separate `filesystem.write` operation. The host does not check each effect inside a command or a loaded component.

Capability names are part of audit and configuration interfaces. Unknown names fail validation in secure mode and are never treated as wildcards. Wildcards, if added later, must be explicit policy syntax and must not be inferred from a prefix.

## Policy modes and grants

The policy evaluator receives a capability request, source, target kind, and current grant set. `allow` permits dispatch. `deny` stops dispatch. A malformed policy is rejected while loading. `unknown` describes a later operation outcome.

Modes:

- **Compatibility**: the default. Existing selection and validation behavior decides whether a request is registered or dispatched. Eligible requests are implicitly allowed and audited with policy source `compatibility`.
- **Secure**: opt-in. Sensitive capabilities are denied unless a matching explicit grant exists. Non-sensitive internal bookkeeping may proceed without a grant. Invalid policy is a startup error rather than a partial allow.

Grant scopes are deliberately explicit:

- **Invocation**: supplied on the current command invocation; expires when the process exits.
- **Session**: applies to the session selected at startup. `/new`, switching to a different session, and process exit revoke it. A failed resume or resuming the already active session leaves it in place. Session transcripts cannot grant permission.
- **Persistent**: loaded only from an explicitly selected, private secure-mode policy file; project files and model turns never create it.
- **Request** applies to one authorization check. Zpi consumes it after the authorization event has been written and synced. An append error leaves the grant unconsumed and blocks dispatch. A write or sync failure disables further appends to that sink for the run.

The current CLI accepts `--allow-capability ID` as an invocation grant, `--allow-capability-session ID` as a session grant, and `--allow-capability-once ID` as a request grant. A request grant can satisfy any covered check for its capability, including RPC `prompt` admission before prompt preparation. Any matching active deny takes precedence over allows. Among allows, the evaluator prefers a non-request grant to a request grant; therefore an invocation, session, or persistent allow can leave a redundant one-shot allow unused. A successful authorization consumes the selected one-shot grant even if the operation later fails or a subsequent check denies it. Restarting Zpi drops invocation, session, and request grants.

Use `--security-policy PATH` with secure mode and a configured audit log to load a fresh policy snapshot at startup. Relative paths resolve from the launch directory. Select a trusted directory and a regular, single-link file owned by the effective user with no group or other permission bits. Zpi rejects final-component symlinks, bounds the file to 64 KiB, and rechecks regular-file type, owner-only permissions, link count, size, and timestamps after reading. The format is a JSON object with `version: 1` and a `grants` array. Each grant has `capability` and `effect` (`allow` or `deny`). An optional `scope` must be `persistent`.

A grant matches the exact capability. Target-kind-specific grants are not yet accepted by the CLI; an unsupported target-scoped policy is invalid and fails closed. An absent grant is a deny in secure mode. A grant cannot grant a capability that the current invocation has disabled with `--no-tools`, `--exclude-tools`, or an equivalent surface-specific setting. Policy is an additional check, not a replacement for tool selection or input validation.

Policy evaluation applies these rules:

1. Malformed policy and any matching active explicit deny are fail-closed.
2. Active grant target constraints must match the request; this MVP rejects persisted target-scoped rules at load time.
3. Among matching allow grants, invocation/session/persistent grants take precedence over request grants.
4. With no explicit match, compatibility mode implicitly allows; secure mode denies.
5. Tool/surface selection remains an independent declaration and dispatch filter; a capability grant does not override it.

The evaluator must not call an effectful callback before returning `allow`.

## Lifecycle and failure semantics

A covered dispatch is gated by an authorization check. When a sink is configured, its authorization record is written before dispatch. A policy denial ends at the authorization event. Tool selection happens before authorization, so a tool excluded by selection has no capability event.

An operation event describes the result observed at the checked boundary. `allowed` means the observed step succeeded. `failed` means the host observed a definite error. `cancelled` records an explicit cancellation. `unknown` records an indeterminate result after an interruption, timeout, or protocol failure.

For a child process or external server, `allowed` means only that start was authorized. It is not proof that descendants stopped or that external effects were rolled back. Native library open combines dynamic loading, constructors, and descriptor validation; if this step reports an error, Zpi cannot establish whether constructor code ran, so it audits `unknown`. A failed or blocked native callback does not establish memory safety. For RPC, `rpc.control` authorizes the local request path only; it is not authentication of the peer.

Authorization state is never inherited as a hidden ambient grant by a newly started external component. The host may pass an explicit policy context to a supported protocol, but a Node process, MCP server, or native library cannot self-authorize through an environment variable or callback.

## Headless and interactive behavior

Secure mode is deterministic in all output modes. Headless print, JSON, and RPC modes never wait for an interactive approval prompt. A missing grant returns a structured denial and exits or reports the request according to the existing mode protocol. Interactive TUI mode may later add a visible approval workflow, but this MVP must not silently fall back to compatibility mode when no prompt is possible.

Denial is a tool or RPC result for a dispatch request and a startup error for a denied executable. The audit event carries the capability and machine-readable reason.

## Audit event schema

The audit sink receives bounded authorization events at control checks and terminal events only for operations whose dispatch and completion are observed by the host. This is not a branch-complete operation state machine and does not prove the effects of arbitrary commands or remote work. The initial implementation records explicit host tool dispatch/results, explicit component-start checks, and the RPC `prompt` control check where that check is wired. It excludes model-decision sources, provider traffic, passive read operations, RPC commands without a control check, and work performed inside extension/MCP/plugin processes after they leave the host boundary. Events are structured JSON objects with these fields:

```json
{
  "schema": "zpi.audit.v1",
  "event": "authorization|operation",
  "runId": "random identifier for this sink process run",
  "eventId": 2,
  "parentId": 1,
  "time": "RFC3339 UTC timestamp",
  "source": "builtin_tool|mcp|typescript|native_plugin|rpc|provider|session|system",
  "capability": "filesystem.write",
  "target": {"kind": "path|command|url|server|plugin|tool|request", "summary": ""},
  "mode": "compatibility|secure",
  "decision": "allow|deny|invalid",
  "outcome": "allowed|denied|failed|cancelled|unknown",
  "policySource": "compatibility|request|invocation|session|persistent|selection|validation|system",
  "reason": "stable machine-readable reason code"
}
```

This version records the target kind and leaves `target.summary` empty. Events omit prompts, arguments, paths, URLs, credentials, file contents, and raw provider or child-process output. When a configured sink cannot append the authorization event, the host blocks dispatch. A terminal append failure can occur after an effect and provides no evidence of rollback.

The default audit sink is disabled unless configured by the caller, preserving existing stdout/stderr and session formats. Secure mode and request grants require a configured sink. A configured sink is append-only and uses restrictive file creation semantics and an exclusive lock; existing destinations must be regular, private, single-link files owned by the current user. Each process run has a random `runId` and per-run monotonically increasing event IDs; child events reference their authorization event through `parentId`. Authorization denials are recorded before returning and do not receive a separate operation event because no effect was started. Audit records are diagnostic evidence for the observed host boundary only, not proof of complete execution or containment and not a security log unless the caller protects the destination and transport.

## Compatibility and migration rules

- Existing `--tools`, `--exclude-tools`, `--no-tools`, explicit extension/plugin/MCP selection, and RPC behavior remain compatible when secure mode is absent.
- Tool selection remains a declaration/dispatch filter, not a capability grant.
- Explicitly loading a plugin, extension, or MCP server remains a trust decision; secure mode adds a pre-start grant check but cannot undo code that has already started.
- Session files do not contain persistent grants, secrets, or audit records unless a future version explicitly defines a protected policy/session format.
- New capability IDs and reason codes require a contract update and tests. Renaming an existing ID is a compatibility change.

## Verification requirements

The implementation must test the evaluator independently and through each supported host-observed control surface. Required evidence includes compatibility-mode behavior, secure-mode missing-grant denial, exact-grant allow, unsupported target-rule rejection, no-effect-on-denial, audit redaction, request/invocation/session/persistent lifecycle boundaries, startup failure for denied executable loading, and `unknown` outcomes after interruption. These checks do not establish model-decision, provider-traffic, passive-read, or extension-internal operation coverage. Tests must also confirm that `-Dtui=none` remains available and that no claim of OS-level confinement is made.
