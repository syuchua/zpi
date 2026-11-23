# Zpi JSONL RPC protocol (experimental v1)

This document defines the experimental Zpi stdio RPC v1 contract for `--mode rpc`, as implemented in v0.1.0. The version identifies this documented subset. Clients select it by launching a known Zpi release. The server sends no startup handshake or protocol-version field. Pi RPC interoperability is outside this contract.

## Transport and framing

- The client writes one UTF-8 JSON object per line to stdin; the server writes one UTF-8 JSON object per line to stdout. LF and CRLF delimiters are accepted. The trailing CR is removed before parsing.
- A record is at most 1 MiB excluding LF and optional CR. Oversized records are drained through their next LF and produce an error record; the stream remains usable.
- EOF ends input. A final unterminated record within the size limit produces `{"type":"response","command":"parse","success":false,"error":"Unterminated RPC record"}`. The server waits for an accepted turn to settle and writes its final events before exiting.
- Inputs must be valid UTF-8 with unique object keys and at most 32 nested containers. The parser makes up to 4,096 scanner steps, including the end-of-document marker. JSON strings may contain U+2028/U+2029.
- RPC records and events are the only protocol data on stdout. Diagnostics may be written to stderr. Clients must parse each stdout line independently and tolerate interleaving of asynchronous turn events with responses to state/abort requests.
- Transport EOF is process shutdown, not a request. There is no TCP listener, authentication handshake, or remote authorization layer. The local process inherits its configured tools and account permissions.

## Request envelopes

`id` is optional and, when present, must be a JSON string. The server echoes it on the corresponding synchronous command response. The ID is an opaque correlation value; the current implementation does not require it to be unique. Asynchronous events have no request ID. A tool event's `id` identifies the tool call.

### `get_state`

Request: `{"id":"optional","type":"get_state"}`

Success:

```json
{"type":"response","id":"optional","command":"get_state","success":true,"data":{"model":{"id":"MODEL","provider":"PROVIDER","api":"openai-completions","contextWindow":0},"thinkingLevel":"off","isStreaming":false,"cwd":"/absolute/path","pendingMessageCount":0}}
```

`contextWindow` is an integer and is zero when no limit is configured. `sessionFile` is an optional path and may point to a session file that has yet to be created. `isStreaming` covers the entire active prompt worker, including tool execution. `pendingMessageCount` is always zero in v1.

### `prompt`

Request: `{"id":"optional","type":"prompt","message":"nonempty text"}`. The message must be a string containing a character other than space, tab, CR or LF. The presence of `images` or `streamingBehavior` rejects the request, including when the field value is `null`. Only one prompt may run at a time.

Accepted and started: `{"type":"response","id":"optional","command":"prompt","success":true,"data":{"disposition":"started"}}`.

Extension-handled prompt: success response with `data.disposition` equal to `handled`; no agent turn is started.

The acceptance response precedes events from the prompt worker. Extension events from prompt preparation may precede acceptance. A started turn ends with one `agent_settled` record as long as the process and its output remain available. A turn-level failure emits `error` before settlement. An individual tool can report a failed result while the turn continues. Clients can submit a new prompt after settlement.

### `abort`

Request: `{"id":"optional","type":"abort"}`. If a worker is active, cancellation is requested, the server waits for it to settle and then responds. The abort response is not an event and carries the request ID. If there is no active worker, abort succeeds immediately. Clients should wait for `agent_settled` before treating an accepted prompt as closed; then consume the abort response.

### Errors

Parse and dispatch errors produce a response with `success:false`. The server echoes a valid `id` if it reached ID validation. The `command` field defaults to `parse` until a string command type has been read.

```json
{"type":"response","id":"optional","command":"unknown","success":false,"error":"Unsupported RPC command"}
```

The `error` field is a human-readable current error name/message, not a versioned machine-readable taxonomy. Common errors include malformed JSON/parser error names, `Unsupported RPC command`, `Expected a string id`, `Missing prompt message`, `Expected a nonempty text message`, `Images and queued prompts are not supported`, and `Agent is busy`. A client must not make authorization decisions by matching these strings.

## Turn event records

Events use Zpi's event shape, not Pi's RPC event schema. Supported records include:

| `type` | Payload fields |
| --- | --- |
| `provider_event` | `event`, such as `{"text_delta":"Hello"}` or `{"thinking_delta":"…"}`. Concatenate successive text deltas to reconstruct streamed text. |
| `message_end` | `message`, with `role` and tagged `content` blocks, such as `{"role":"assistant","content":[{"text":"Hello"}]}`. Other fields depend on the message. |
| `tool_execution_start` | `id`, `name` |
| `tool_execution_update` | `id`, `name`, `result` |
| `tool_execution_end` | `id`, `result` |
| `auto_retry_start` | `attempt`, `max_attempts`, `delay_ms`, `error_code` |
| `auto_retry_end` | `success`, `attempt`, optional `error_code` |
| `compaction` | `tokens_before`, optional `first_kept_id`, `automatic` |
| `extension_event` | `event`, with the extension-host payload |
| `error` | `error_code`, such as `Canceled` or `HttpRequestFailed` |
| `agent_settled` | `aborted` is `true` when the turn settles as canceled and `false` on other completions, including turn failures. |

Tool results contain `text`, `is_error` and optional `details`. Read response envelopes by `type`, `command` and `id`. The optional properties shown above are omitted when absent.

`agent_settled` is ordered after the turn's terminal event(s) and is the settlement barrier. Each complete JSON line is written under a mutex. A client can receive `get_state` while a prompt is active; its response can interleave with that prompt's events, and it must inspect its own `id`/`command` to identify the response. A busy prompt receives a failed response and is not queued.

## Lifecycle and security

One worker owns harness mutation during an active turn. The reader can still dispatch `get_state` and `abort`. On EOF the reader stops accepting requests and joins the active worker. A provider/tool that does not honor cancellation can delay abort/EOF settlement; stdio RPC does not impose an independent hard kill boundary around the in-process harness.

RPC is a local control interface, not an authorization mechanism. Any process able to write the server's stdin may submit prompts and invoke tools enabled for that Zpi invocation. Use restrictive OS process/pipe access and explicitly configure tool selection. `--no-tools` disables tools by default but explicit `--tools` selection may re-enable them. See [security boundaries](security-boundaries.md).

## Independent client fixture

`scripts/test-rpc.py` drives the installed executable as a subprocess using Python's standard library and a loopback SSE provider. It checks request IDs, LF/CRLF, malformed and oversized records, busy rejection, streamed text, abort ordering, reuse, EOF while a turn is accepted, an unterminated final record, and U+2028/U+2029 in strings. Run it against either a native TUI build or a headless build.

```sh
python3 scripts/test-rpc.py /absolute/path/to/zpi
```

`python3 scripts/test-cli.py --rpc-only` also covers state queries during a turn, provider failure, and a simulated provider request for a disabled `write` tool. That test verifies that the requested file stays absent.
