//! Actionable startup errors. Hints are static text chosen by error name, so
//! diagnostics never echo configuration values, URLs, commands, project file
//! contents, or child/provider output. Verbose detail is build metadata only.
const std = @import("std");

/// Exit codes keep historical behavior: 1 for runtime failures, 2 for
/// argument/configuration mistakes detected before work starts.
pub const Hint = struct { text: []const u8, exit_code: u8 = 1 };

const Rule = struct { name: []const u8, text: []const u8, exit_code: u8 = 1 };

/// Unlisted errors keep the bare name and exit 1.
pub fn hintFor(name: []const u8) ?Hint {
    for (&rules) |*rule| {
        if (std.mem.eql(u8, name, rule.name)) return .{ .text = rule.text, .exit_code = rule.exit_code };
    }
    return null;
}

/// Print an error name and, with `verbose`, static build details. The first
/// line keeps the historical `zpi: <ErrorName>` shape. No argv, environment,
/// credential, URL, project content, or child/provider output is echoed.
pub fn report(stderr: *std.Io.Writer, err: anyerror, verbose: bool) !void {
    try stderr.print("zpi: {s}\n", .{@errorName(err)});
    if (verbose) {
        try stderr.print("zpi: version {s}, optimize mode {s}\n", .{ @import("zpi").VERSION, @tagName(@import("builtin").mode) });
        if (hintFor(@errorName(err))) |hint| try stderr.print("zpi: hint: {s}\n", .{hint.text});
        try stderr.writeAll("zpi: diagnostics omit conversation, configuration, URLs and command output\n");
    }
}

const rules = [_]Rule{
    .{ .name = "UnknownOption", .text = "unrecognized option; run `zpi --help` for the complete flag list", .exit_code = 2 },
    .{ .name = "MissingValue", .text = "an option is missing its value; run `zpi --help` for accepted forms", .exit_code = 2 },
    .{ .name = "InvalidMode", .text = "use --mode text|json|print|rpc", .exit_code = 2 },
    .{ .name = "ConflictingMode", .text = "choose one output mode: -p or --mode text|json|rpc", .exit_code = 2 },
    .{ .name = "EmptyPrompt", .text = "pass a prompt, pipe text on stdin, or run without arguments in a terminal for the TUI", .exit_code = 2 },
    .{ .name = "ConflictingSessionOptions", .text = "--continue, --session and --no-session cannot be combined", .exit_code = 2 },
    .{ .name = "TuiDisabled", .text = "this binary was built with -Dtui=none; use -p, --mode json or --mode rpc", .exit_code = 2 },
    .{ .name = "InvalidSecurityMode", .text = "choose --security compatibility or --security secure" },
    .{ .name = "InvalidCapability", .text = "use an exact capability ID such as filesystem.read (see docs/spec/security-capabilities.md)" },
    .{ .name = "InvalidSecurityPolicy", .text = "pass a policy file with version 1 JSON and a grants array containing valid persistent rules" },
    .{ .name = "InvalidAuditPath", .text = "--audit-log needs a writable path to a private regular file" },
    .{ .name = "AuditIdExhausted", .text = "the audit event sequence is exhausted. Start a new audit run" },
    .{ .name = "InvalidAuditTime", .text = "check the system clock for a timestamp within the audit format range" },
    .{ .name = "SecureModeRequiresAuditLog", .text = "secure mode requires --audit-log PATH so decisions can be recorded" },
    .{ .name = "RequestGrantRequiresAuditLog", .text = "one-shot grants require --audit-log PATH for durable authorization records" },
    .{ .name = "PersistentPolicyRequiresSecureMode", .text = "use --security-policy with --security secure and --audit-log PATH" },
    .{ .name = "InsecureSecurityPolicyPermissions", .text = "use a regular policy file you own with one hard link and owner-only permissions" },
    .{ .name = "SecurityPolicyTooLarge", .text = "reduce the policy file to 64 KiB or less" },
    .{ .name = "SecurityPolicyChanged", .text = "the policy file changed during validation. Inspect it before retrying" },
    .{ .name = "CapabilityDenied", .text = "check for an explicit deny or a missing grant for the operation" },
    .{ .name = "UnsupportedTargetScopedGrant", .text = "grant a capability without a target scope" },
    .{ .name = "AuditLogBusy", .text = "wait for the other process to release the log or select a separate log" },
    .{ .name = "InvalidAuditFile", .text = "use a regular audit file you own with one hard link and owner-only permissions" },
    .{ .name = "IncompleteAuditLog", .text = "preserve the log with the partial final record and select a valid log" },
    .{ .name = "AuditLogFailed", .text = "check write permissions and free space for the audit log" },
    .{ .name = "InvalidSandboxMode", .text = "use --sandbox off|read-only|workspace-write", .exit_code = 2 },
    .{ .name = "InvalidSandboxNetwork", .text = "use --sandbox-network off|on", .exit_code = 2 },
    .{ .name = "InvalidSandboxBackend", .text = "use --sandbox-backend auto|seatbelt|landlock|bwrap", .exit_code = 2 },
    .{ .name = "InvalidEnvIsolation", .text = "use --env-isolation inherit|strict", .exit_code = 2 },
    .{ .name = "InvalidEnvAllowlist", .text = "pass a valid environment variable name without = or NUL bytes", .exit_code = 2 },
    .{ .name = "InvalidSubagentIsolation", .text = "use --subagent-isolation shared|worktree|auto", .exit_code = 2 },
    .{ .name = "SandboxUnavailable", .text = "no supported OS sandbox backend is available on this host; run without --sandbox or install bwrap on older Linux kernels", .exit_code = 1 },
    .{ .name = "SandboxBackendUnsupported", .text = "the requested sandbox backend is not supported on this OS", .exit_code = 2 },
    .{ .name = "PathOutsideWorkspace", .text = "canonical path escapes the confined workspace", .exit_code = 1 },
    .{ .name = "SandboxWriteDenied", .text = "writes are denied in read-only sandbox mode", .exit_code = 1 },
    .{ .name = "UnattendedRequiresHeadlessMode", .text = "--unattended requires headless print, JSON, or RPC mode", .exit_code = 2 },
    .{ .name = "UnattendedRequiresSecureMode", .text = "--unattended requires --security secure", .exit_code = 2 },
    .{ .name = "UnattendedRequiresSecurityPolicy", .text = "--unattended requires an explicit private --security-policy PATH", .exit_code = 2 },
    .{ .name = "UnattendedRequiresSandbox", .text = "--unattended requires an active OS sandbox (workspace-write or read-only)", .exit_code = 2 },
    .{ .name = "UnattendedRequiresEnvIsolation", .text = "--unattended requires strict child environment isolation", .exit_code = 2 },
    .{ .name = "WorktreeRequiresGitRepository", .text = "worktree subagent isolation requires a git repository with a valid HEAD commit", .exit_code = 1 },
    .{ .name = "ProviderNotConfigured", .text = "configure a provider in models.json or choose openai/anthropic; run `zpi doctor` to inspect configuration", .exit_code = 2 },
    .{ .name = "MissingProviderEndpoint", .text = "a configured provider needs baseUrl in models.json or --endpoint", .exit_code = 2 },
    .{ .name = "MissingCredentialEnvironment", .text = "a credential environment variable is unset or empty; run `zpi doctor` to check availability", .exit_code = 2 },
    .{ .name = "InvalidCredential", .text = "credentials must be one line of at most 16 KiB; supply them via environment or models.json", .exit_code = 1 },
    .{ .name = "CommandCredentialUnsupported", .text = "credential commands are not executed; use $ENV_NAME interpolation or a literal value", .exit_code = 2 },
    .{ .name = "InvalidModelsConfig", .text = "models.json uses an unsupported shape; run `zpi doctor` to see which file is in effect", .exit_code = 1 },
    .{ .name = "InvalidModelsUtf8", .text = "models.json must be UTF-8 text", .exit_code = 1 },
    .{ .name = "InvalidSettings", .text = "settings.json uses an unsupported shape; fix or remove it and rerun", .exit_code = 1 },
    .{ .name = "UnsupportedProviderApi", .text = "supported api values are openai-completions, openai-responses and anthropic-messages", .exit_code = 1 },
    .{ .name = "InvalidAgentDirectory", .text = "PI_CODING_AGENT_DIR must be a UTF-8 path without NUL bytes", .exit_code = 2 },
    .{ .name = "MissingHome", .text = "a ~ path needs HOME to be set", .exit_code = 2 },
    .{ .name = "FileNotFound", .text = "a referenced file is missing; check --session, --models-file, --image and @file paths", .exit_code = 2 },
    .{ .name = "AccessDenied", .text = "permission denied for a referenced path", .exit_code = 2 },
    .{ .name = "NotDir", .text = "a referenced path component is not a directory", .exit_code = 2 },
    .{ .name = "InvalidSessionDirectory", .text = "--session-dir needs a local directory path", .exit_code = 2 },
    .{ .name = "UnsupportedSessionDirectoryUrl", .text = "--session-dir needs a local directory path, not a URL", .exit_code = 2 },
    .{ .name = "StdinTooLarge", .text = "piped stdin is limited to 1 MiB of UTF-8 text", .exit_code = 1 },
    .{ .name = "InvalidStdinUtf8", .text = "piped stdin must be UTF-8 text", .exit_code = 1 },
    .{ .name = "UnsupportedImageType", .text = "--image accepts PNG, JPEG, GIF or WebP files, up to 8 files and 2 MiB total", .exit_code = 1 },
    .{ .name = "RipgrepNotInstalled", .text = "the grep tool needs `rg` on PATH; run `zpi doctor`", .exit_code = 1 },
    .{ .name = "FdNotInstalled", .text = "the find tool needs `fd` or `fdfind` on PATH; run `zpi doctor`", .exit_code = 1 },
    .{ .name = "HttpRequestFailed", .text = "the provider request failed; check connectivity, endpoint and credentials (`zpi doctor` checks presence only)", .exit_code = 1 },
    .{ .name = "HttpStatusError", .text = "the provider rejected the request; check provider, model and credentials", .exit_code = 1 },
    .{ .name = "ConnectionTimedOut", .text = "the provider connection timed out; check network and endpoint", .exit_code = 1 },
    .{ .name = "TlsInitializationFailed", .text = "TLS setup failed; check SSL_CERT_FILE and system certificate stores", .exit_code = 1 },
    .{ .name = "MissingPiSdk", .text = "-e/--extension also needs --pi-sdk pointing at an installed pi SDK", .exit_code = 2 },
    .{ .name = "PiSdkDependencyNotFound", .text = "the pi SDK directory is missing @earendil-works/pi-ai; reinstall it or run `zpi doctor`", .exit_code = 1 },
    .{ .name = "PiSdkDependencyVersionDrift", .text = "the installed pi-ai version differs from the SDK; reinstall matching versions", .exit_code = 1 },
    .{ .name = "InvalidExtensionHandshake", .text = "the extension host reported an unsupported SDK or protocol; check `zpi doctor`", .exit_code = 1 },
    .{ .name = "ExtensionHostFailed", .text = "the extension host failed; check Node availability and --pi-sdk (host output is never printed)", .exit_code = 1 },
    .{ .name = "InvalidExtensionConfig", .text = "extension paths must be absolute and the host script must be installed beside the binary", .exit_code = 2 },
};

test "diagnostics keep the error-name line and add static detail only when verbose" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report(&out.writer, error.SomeUnlistedError, false);
    try std.testing.expectEqualStrings("zpi: SomeUnlistedError\n", out.written());
    out.clearRetainingCapacity();
    try report(&out.writer, error.FileNotFound, true);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "zpi: FileNotFound\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zpi: hint: a referenced file is missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "optimize mode") != null);
    try std.testing.expectEqualStrings("use --mode text|json|print|rpc", hintFor("InvalidMode").?.text);
    try std.testing.expectEqual(@as(u8, 2), hintFor("UnknownOption").?.exit_code);
    try std.testing.expectEqual(@as(u8, 1), hintFor("HttpRequestFailed").?.exit_code);
    inline for (.{
        "InvalidSecurityMode",                "InvalidCapability",                 "InvalidSecurityPolicy",      "InvalidAuditPath",
        "AuditIdExhausted",                   "InvalidAuditTime",                  "SecureModeRequiresAuditLog", "RequestGrantRequiresAuditLog",
        "PersistentPolicyRequiresSecureMode", "InsecureSecurityPolicyPermissions", "SecurityPolicyTooLarge",     "SecurityPolicyChanged",
        "CapabilityDenied",                   "UnsupportedTargetScopedGrant",      "AuditLogBusy",               "InvalidAuditFile",
        "IncompleteAuditLog",                 "AuditLogFailed",
    }) |name| try std.testing.expect(hintFor(name) != null);
    try std.testing.expect(hintFor("SomeUnlistedError") == null);
    for (&rules) |*rule| {
        try std.testing.expect(rule.text.len > 0);
        try std.testing.expect(!std.mem.endsWith(u8, rule.text, " "));
    }
}
