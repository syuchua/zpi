# Capability authorization, confinement, and audit contract

Status: contract for the opt-in Trusted Execution layer (capability authorization, target rules, TUI one-time approvals, OS confinement, child environment isolation, worktree subagent isolation, unattended fail-stop mode, and redacted audit).

## Scope and compatibility

Zpi keeps its existing behavior by default. A normal invocation uses `compatibility` policy mode with `--sandbox off`, `--env-isolation inherit`, and `--subagent-isolation shared`: existing tool, MCP, TypeScript, native-plugin, and RPC behavior remains available according to the existing CLI/tool-selection rules. Authorization decisions are still observable through the audit sink when one is configured.

The opt-in `secure` policy mode adds pre-effect capability checks, target-scoped policy rules, TUI one-time approvals (interactive only), fail-closed structured headless denials, OS confinement (`workspace-write`, `network=off` by default), canonical-path file-tool checks, and strict child environment allowlisting (`--env-isolation strict`).

In-process native C/Zig plugins still execute inside the Zpi process without memory or crash isolation; do not load untrusted native libraries. Remote RPC peer authentication and automatic project trust/extension discovery remain out of scope.

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

Use `--security-policy PATH` with secure mode and a configured audit log to load a fresh policy snapshot at startup. Relative paths resolve from the launch directory. Select a trusted directory and a regular, single-link file owned by the effective user with no group or other permission bits. Zpi rejects final-component symlinks, bounds the file to 64 KiB, and rechecks regular-file type, owner-only permissions, link count, size, and timestamps after reading. The format is a JSON object with `version: 1` and a `grants` array. Each grant has `capability`, `effect` (`allow` or `deny`), optional `scope` (`persistent`), and optional `target`:

```json
{
  "version": 1,
  "grants": [
    {
      "capability": "filesystem.write",
      "effect": "allow",
      "target": { "kind": "path", "value": "/abs/canonical/workspace", "match": "subtree" }
    },
    {
      "capability": "process.exec",
      "effect": "allow",
      "target": { "kind": "command", "value": "git", "match": "prefix" }
    },
    {
      "capability": "network.connect",
      "effect": "allow",
      "target": { "kind": "url", "value": "https://api.example.com", "match": "origin" }
    }
  ]
}
```

Supported target rule matchers:
- `path` (`filesystem.read`, `filesystem.write`): canonical absolute path with `match: "exact"` or `match: "subtree"`. Dangling symlinks and unresolved paths fail closed with `unresolved-path`.
- `command` (`process.exec`): `match: "exact"` or `match: "prefix"`. Allow-prefix rules match only at whitespace word boundaries and reject shell control/expansion/quoting metacharacters (`;|&$`()<>\'"#*?[]{}~`), preventing command chaining bypasses; deny-prefix rules still match across trailing shell separators.
- `url` (`network.connect`): `match: "exact"`, `match: "origin"` (case-insensitive scheme/host + normalized effective port), or `match: "host"` (exact case-insensitive hostname). Checked before every HTTP request and every redirect hop.

Legacy `targetKind`-only rules remain rejected (`UnsupportedTargetScopedGrant`). An absent grant is a deny in secure mode. A grant cannot enable a capability that the current invocation has disabled with `--no-tools`, `--exclude-tools`, or an equivalent surface-specific setting. Policy is an additional check, not a replacement for tool selection, canonical-path validation, or OS confinement.

Policy evaluation applies these rules:

1. Malformed policy and any matching active explicit deny are fail-closed.
2. Target constraints on active grants must match the request target kind and canonical/validated target value.
3. Among matching allow grants, invocation/session/persistent grants take precedence over request grants.
4. With no explicit match, compatibility mode implicitly allows; secure mode prompts once in interactive TUI mode (`policySource: "approval"`, recording `interactive-approval` or `interactive-denial`) or denies immediately in headless/unattended modes (`policySource: "validation"`, `reason: "missing-grant"`).
5. Tool/surface selection remains an independent declaration and dispatch filter; a capability grant does not override it.

The evaluator must not call an effectful callback before returning `allow`.

## Lifecycle and failure semantics

A covered dispatch is gated by an authorization check. When a sink is configured, its authorization record is written before dispatch. A policy denial ends at the authorization event. Tool selection happens before authorization, so a tool excluded by selection has no capability event.

An operation event describes the result observed at the checked boundary. `allowed` means the observed step succeeded. `failed` means the host observed a definite error. `cancelled` records an explicit cancellation. `unknown` records an indeterminate result after an interruption, timeout, or protocol failure.

For a child process or external server, `allowed` means only that start was authorized. It is not proof that descendants stopped or that external effects were rolled back. Native library open combines dynamic loading, constructors, and descriptor validation; if this step reports an error, Zpi cannot establish whether constructor code ran, so it audits `unknown`. A failed or blocked native callback does not establish memory safety. For RPC, `rpc.control` authorizes the local request path only; it is not authentication of the peer.

Authorization state is never inherited as a hidden ambient grant by a newly started external component. The host may pass an explicit policy context to a supported protocol, but a Node process, MCP server, or native library cannot self-authorize through an environment variable or callback.

## Headless, interactive, and unattended behavior

- **Interactive TUI (`--security secure`)**: missing grants display a one-time `Allow once? [y/N]` prompt with the full capability and target label (wrapping long labels and requiring full visibility before `y` is accepted; `n`/Enter/cancel denies). Approvals never persist across calls. Both approvals (`policySource: "approval"`, `reason: "interactive-approval"`) and denials (`policySource: "approval"`, `reason: "interactive-denial"`) are written and synced to the audit log.
- **Headless (`-p`, `--mode json`, `--mode rpc`, `-Dtui=none`)**: never waits for interactive input. Missing grants fail closed immediately. Tool denials return a structured redacted `details` object (`{ "type": "authorization_denied", "code": "CapabilityDenied", "capability", "targetKind", "policySource", "reason" }`). RPC `prompt` denials preserve the exact `{"type":"response","id":...,"command":"prompt","success":false,"error":"CapabilityDenied"}` frame.
- **Unattended (`--unattended`)**: requires headless mode, `--security secure`, `--audit-log`, `--security-policy`, active OS sandbox (`workspace-write` or `read-only`), and strict environment isolation. Interactive approvals are disabled. The first policy denial or workspace boundary violation writes and syncs the audit record and immediately halts execution (fail-stop) with a non-zero exit code, canceling any active subagent batch or background task.

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
  "policySource": "compatibility|request|invocation|session|persistent|selection|validation|system|approval",
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
