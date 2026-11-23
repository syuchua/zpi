# Security and credentials

Zpi runs with the permissions of the account that launches it. `--cwd` sets the working directory for tools. Enabled tools can read and change other files that the account can access, and `bash` can launch processes and use the network. Use an OS-level isolation boundary and a restricted account when running against untrusted projects or data.

## Select the resources and executables you trust

- Start with `--no-tools` when reviewing unfamiliar or imported conversation history. A restrictive selection such as `--tools read` allows file reads. `--tools` can enable tools even when `--no-tools` is present.
- The `subagent` tool shares the parent working directory and OS permissions. Children can use eligible native tools selected for the parent. Use `--tools subagent,read` for file-reading delegation, or `--exclude-tools subagent` to disable delegation in a wildcard tool selection.
- Project skill and prompt-template discovery require separate opt-ins. Review their contents before enabling them because they can affect instructions sent to the model. Inspect `--system-prompt`, `--append-system-prompt`, and `@file` inputs for the same reason.
- `--extension`, `--native-plugin`, and `--mcp-stdio` authorize executable code. TypeScript extensions and MCP servers run in child processes. Native libraries run inside Zpi and can affect its memory and stability. Explicitly selected modules and servers still load when tools are disabled. Use trusted executable paths, SDK installations, and `PATH` entries.

## Handle provider credentials and outputs

- Prefer scoped provider keys and an environment reference in a private `models.json`. Restrict files containing literal keys to your account. Command-valued credentials are rejected. Use `--api-key` only if exposing its value in process arguments and shell history is acceptable.
- Shell commands, MCP servers and the Node extension host inherit ambient environment variables. Native libraries share the host process. Use a clean environment and treat every explicitly loaded component as having access to your account's data and credentials.
- Review the configured endpoint and custom authentication headers. Use HTTPS for a remote provider. With `--no-proxy`, Zpi connects directly to the configured endpoint. The provider clients reject URL userinfo, do not follow HTTP redirects, and discard non-success HTTP response bodies. The connectivity smoke reports a status or error identifier.
- Tool output, model responses, extension events and prompt inputs can contain sensitive data. Review JSONL output and session files before sharing them. `--no-session` keeps conversation history in memory for that run.

## Protect session files

Zpi creates new session files with owner-only permissions. Keep session directories and backups private. Offline pi import writes a new transcript and leaves the source unchanged. On resume, a torn final record can be truncated to the last newline. A previously recorded tool call with no committed result is treated as having an unknown outcome. Inspect any affected files or processes before retrying it.
