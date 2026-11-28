//! Out-of-box CLI management subcommands:
//! - `zpi auth status|set|remove`
//! - `zpi models list|set-default`
//! - `zpi mcp list|add|remove`
//!
//! Security invariants:
//! - Never prints credential values to stdout or stderr.
//! - Prefers `$ENV_NAME` references or `--stdin` for credentials so secrets do
//!   not appear in shell command-line history.
//! - Writes `models.json`, `settings.json`, and `mcp.json` atomically with
//!   `0600` owner-only permissions.
const std = @import("std");
const config = @import("config");
const settings_mod = @import("settings");
const models_json = @import("models_json");
const mcp_config = @import("mcp_config");

const max_file_bytes: usize = 4 * 1024 * 1024;
const max_secret_bytes: usize = 16 * 1024;

pub fn runAuth(
    io: std.Io,
    a: std.mem.Allocator,
    launch_cwd: []const u8,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
    stdin_override: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "status")) {
        var models_file: ?[]const u8 = null;
        var i: usize = if (args.len > 0) 1 else 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--models-file")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                models_file = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--models-file=")) {
                models_file = args[i]["--models-file=".len..];
            } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
                try writer.writeAll(auth_help);
                return;
            } else return error.InvalidAuthArguments;
        }
        try authStatus(io, a, launch_cwd, env, models_file, writer);
        return;
    }
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try writer.writeAll(auth_help);
        return;
    }
    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len < 2) return error.InvalidAuthArguments;
        const provider = args[1];
        if (!validProviderName(provider)) return error.InvalidProviderName;

        var api_key_env: ?[]const u8 = null;
        var use_stdin = false;
        var base_url: ?[]const u8 = null;
        var api_name: ?[]const u8 = null;
        var models_file: ?[]const u8 = null;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--api-key-env")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                api_key_env = args[i];
            } else if (std.mem.startsWith(u8, arg, "--api-key-env=")) {
                api_key_env = arg["--api-key-env=".len..];
            } else if (std.mem.eql(u8, arg, "--stdin")) {
                use_stdin = true;
            } else if (std.mem.eql(u8, arg, "--base-url")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                base_url = args[i];
            } else if (std.mem.startsWith(u8, arg, "--base-url=")) {
                base_url = arg["--base-url=".len..];
            } else if (std.mem.eql(u8, arg, "--api")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                api_name = args[i];
            } else if (std.mem.startsWith(u8, arg, "--api=")) {
                api_name = arg["--api=".len..];
            } else if (std.mem.eql(u8, arg, "--models-file")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                models_file = args[i];
            } else if (std.mem.startsWith(u8, arg, "--models-file=")) {
                models_file = arg["--models-file=".len..];
            } else return error.InvalidAuthArguments;
        }

        if (api_key_env != null and use_stdin) return error.InvalidAuthArguments;
        if (api_key_env == null and !use_stdin and base_url == null and api_name == null) {
            return error.InvalidAuthArguments;
        }

        var api_key_value: ?[]const u8 = null;
        if (api_key_env) |env_name| {
            if (!validEnvName(env_name)) return error.InvalidCredential;
            api_key_value = try a.print("${s}", .{env_name});
        } else if (use_stdin) {
            const raw_secret = if (stdin_override) |s| s else blk: {
                var buf: [4096]u8 = undefined;
                var reader = std.Io.File.stdin().readerStreaming(io, &buf);
                const data = reader.interface.allocRemaining(a, .limited(max_secret_bytes + 1)) catch |err| switch (err) {
                    error.StreamTooLong => return error.InvalidCredential,
                    else => return err,
                };
                break :blk data;
            };
            const trimmed = std.mem.trim(u8, raw_secret, " \t\r\n");
            if (trimmed.len == 0 or trimmed.len > max_secret_bytes or std.mem.indexOfAny(u8, trimmed, "\r\n") != null or !std.unicode.utf8ValidateSlice(trimmed)) {
                return error.InvalidCredential;
            }
            api_key_value = trimmed;
        }

        if (base_url) |u| {
            if (!std.mem.startsWith(u8, u, "https://") and !std.mem.startsWith(u8, u, "http://")) return error.InvalidEndpoint;
        }
        if (api_name) |api_str| {
            if (!validApiString(api_str)) return error.UnsupportedProviderApi;
        }

        const path = try resolveModelsFilePath(a, launch_cwd, env, models_file);
        var root = try readJsonObjectOrEmpty(a, io, path);
        const provs_gop = try root.getOrPut(a, "providers");
        if (!provs_gop.found_existing or provs_gop.value_ptr.* != .object) {
            provs_gop.value_ptr.* = .{ .object = .empty };
        }
        const entry_gop = try provs_gop.value_ptr.object.getOrPut(a, provider);
        if (!entry_gop.found_existing or entry_gop.value_ptr.* != .object) {
            entry_gop.value_ptr.* = .{ .object = .empty };
        }
        if (api_key_value) |k| try entry_gop.value_ptr.object.put(a, "apiKey", .{ .string = k });
        if (base_url) |u| try entry_gop.value_ptr.object.put(a, "baseUrl", .{ .string = u });
        if (api_name) |an| try entry_gop.value_ptr.object.put(a, "api", .{ .string = an });

        try mcp_config.writeJsonPrivateAtomic(a, io, path, .{ .object = root });
        if (api_key_env) |env_name| {
            try writer.print("Updated provider '{s}' credential reference (${s}) in {s}\n", .{ provider, env_name, path });
        } else if (use_stdin) {
            try writer.print("Stored provider '{s}' credential (redacted, mode 0600) in {s}\n", .{ provider, path });
        } else {
            try writer.print("Updated provider '{s}' settings in {s}\n", .{ provider, path });
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "remove")) {
        if (args.len < 2) return error.InvalidAuthArguments;
        const provider = args[1];
        if (!validProviderName(provider)) return error.InvalidProviderName;
        var models_file: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--models-file")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                models_file = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--models-file=")) {
                models_file = args[i]["--models-file=".len..];
            } else return error.InvalidAuthArguments;
        }
        const path = try resolveModelsFilePath(a, launch_cwd, env, models_file);
        var root = try readJsonObjectOrEmpty(a, io, path);
        const provs_ptr = root.getPtr("providers") orelse return error.ProviderNotConfigured;
        if (provs_ptr.* != .object) return error.InvalidModelsConfig;
        const entry_ptr = provs_ptr.object.getPtr(provider) orelse return error.ProviderNotConfigured;
        if (entry_ptr.* != .object) return error.InvalidModelsConfig;
        _ = entry_ptr.object.orderedRemove("apiKey");
        if (entry_ptr.object.count() == 0) _ = provs_ptr.object.orderedRemove(provider);
        try mcp_config.writeJsonPrivateAtomic(a, io, path, .{ .object = root });
        try writer.print("Removed stored credential for provider '{s}' in {s}\n", .{ provider, path });
        return;
    }
    return error.InvalidAuthArguments;
}

pub fn runModels(
    io: std.Io,
    a: std.mem.Allocator,
    launch_cwd: []const u8,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        var models_file: ?[]const u8 = null;
        var i: usize = if (args.len > 0) 1 else 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--models-file")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                models_file = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--models-file=")) {
                models_file = args[i]["--models-file=".len..];
            } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
                try writer.writeAll(models_help);
                return;
            } else return error.InvalidModelsArguments;
        }

        const user_settings = settings_mod.load(a, io, launch_cwd, env) catch settings_mod.Settings{};
        const def_prov = user_settings.default_provider orelse "openai";
        const def_model = user_settings.default_model orelse if (std.mem.eql(u8, def_prov, "anthropic"))
            "claude-sonnet-4-5"
        else if (std.mem.eql(u8, def_prov, "gemini"))
            "gemini-2.5-flash"
        else
            "gpt-4o-mini";

        const choices = try config.listModels(a, io, env, models_file);
        try writer.writeAll("Available models (* = default):\n");
        for (choices) |choice| {
            const is_default = std.mem.eql(u8, choice.provider, def_prov) and std.mem.eql(u8, choice.id, def_model);
            try writer.print("  {s} {s}/{s}  ({s})\n", .{
                if (is_default) "*" else " ",
                choice.provider,
                choice.id,
                apiLabel(choice.api),
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try writer.writeAll(models_help);
        return;
    }
    if (std.mem.eql(u8, args[0], "set-default")) {
        if (args.len != 2) return error.InvalidModelsArguments;
        const spec = args[1];
        const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return error.InvalidModelsArguments;
        const provider = spec[0..slash];
        const model_id = spec[slash + 1 ..];
        if (!validProviderName(provider) or model_id.len == 0 or std.mem.indexOfAny(u8, model_id, "\r\n") != null) {
            return error.InvalidModelsArguments;
        }

        const dir = (try mcp_config.resolveAgentDir(a, launch_cwd, env)) orelse return error.MissingHome;
        const path = try std.fs.path.join(a, &.{ dir, "settings.json" });
        var root = try readJsonObjectOrEmpty(a, io, path);
        try root.put(a, "defaultProvider", .{ .string = provider });
        try root.put(a, "defaultModel", .{ .string = model_id });
        try mcp_config.writeJsonPrivateAtomic(a, io, path, .{ .object = root });
        try writer.print("Default model set to {s}/{s} in {s}\n", .{ provider, model_id, path });
        return;
    }
    return error.InvalidModelsArguments;
}

pub fn runMcp(
    io: std.Io,
    a: std.mem.Allocator,
    launch_cwd: []const u8,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        var project_cwd: []const u8 = launch_cwd;
        var trust_project = false;
        var no_mcp_config = false;
        var i: usize = if (args.len > 0) 1 else 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--trust-project-mcp")) {
                trust_project = true;
            } else if (std.mem.eql(u8, arg, "--no-mcp-config")) {
                no_mcp_config = true;
            } else if (std.mem.eql(u8, arg, "--cwd")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                project_cwd = args[i];
            } else if (std.mem.startsWith(u8, arg, "--cwd=")) {
                project_cwd = arg["--cwd=".len..];
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try writer.writeAll(mcp_help);
                return;
            } else return error.InvalidMcpArguments;
        }
        const entries = try mcp_config.load(a, io, launch_cwd, project_cwd, env, trust_project, no_mcp_config);
        if (entries.len == 0) {
            try writer.writeAll("No MCP servers configured. Add one with: zpi mcp add <name> -- <command> [args...]\n");
            return;
        }
        try writer.writeAll("Configured MCP servers:\n");
        for (entries) |entry| {
            try writer.print("  {s}  [{s}]  command={s} ({d} arg(s))\n", .{
                entry.name,
                @tagName(entry.source),
                std.fs.path.basename(entry.argv[0]),
                entry.argv.len -| 1,
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try writer.writeAll(mcp_help);
        return;
    }
    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 4) return error.InvalidMcpArguments;
        const name = args[1];
        if (!std.mem.eql(u8, args[2], "--")) return error.MissingMcpCommandSeparator;
        var cmd_slices = try a.alloc([]const u8, args.len - 3);
        for (args[3..], 0..) |arg, idx| cmd_slices[idx] = arg;
        const path = try mcp_config.addServer(a, io, launch_cwd, env, name, cmd_slices);
        try writer.print("Added MCP server '{s}' to {s}\n", .{ name, path });
        return;
    }
    if (std.mem.eql(u8, args[0], "remove")) {
        if (args.len != 2) return error.InvalidMcpArguments;
        const path = try mcp_config.removeServer(a, io, launch_cwd, env, args[1]);
        try writer.print("Removed MCP server '{s}' from {s}\n", .{ args[1], path });
        return;
    }
    return error.InvalidMcpArguments;
}

fn authStatus(
    io: std.Io,
    a: std.mem.Allocator,
    launch_cwd: []const u8,
    env: *const std.process.Environ.Map,
    models_file_override: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    const path = resolveModelsFilePath(a, launch_cwd, env, models_file_override) catch null;
    const root: std.json.ObjectMap = if (path) |p|
        readJsonObjectOrEmpty(a, io, p) catch .empty
    else
        .empty;
    const providers_obj: ?std.json.ObjectMap = if (root.get("providers")) |pv| (if (pv == .object) pv.object else null) else null;

    const user_settings = settings_mod.load(a, io, launch_cwd, env) catch settings_mod.Settings{};
    const def_prov = user_settings.default_provider orelse "openai";
    try writer.print("Default provider: {s}\n", .{def_prov});
    if (path) |p| try writer.print("Models file:      {s}\n", .{p});
    try writer.writeAll("\nProviders (presence only; secrets are never shown):\n");

    const builtins = [_]struct { name: []const u8, env1: []const u8, env2: ?[]const u8 }{
        .{ .name = "openai", .env1 = "OPENAI_API_KEY", .env2 = null },
        .{ .name = "anthropic", .env1 = "ANTHROPIC_API_KEY", .env2 = null },
        .{ .name = "gemini", .env1 = "GEMINI_API_KEY", .env2 = "GOOGLE_API_KEY" },
    };
    for (builtins) |b| {
        const cfg_entry = if (providers_obj) |po| po.get(b.name) else null;
        try writer.print("  {s:<12} ", .{b.name});
        try writeProviderCredStatus(writer, env, cfg_entry, b.env1, b.env2);
        try writer.writeByte('\n');
    }
    if (providers_obj) |po| {
        var it = po.iterator();
        while (it.next()) |kv| {
            const pname = kv.key_ptr.*;
            if (std.mem.eql(u8, pname, "openai") or std.mem.eql(u8, pname, "anthropic") or std.mem.eql(u8, pname, "gemini")) continue;
            try writer.print("  {s:<12} ", .{pname});
            try writeProviderCredStatus(writer, env, kv.value_ptr.*, null, null);
            try writer.writeByte('\n');
        }
    }
}

fn writeProviderCredStatus(
    writer: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    cfg_entry: ?std.json.Value,
    env1: ?[]const u8,
    env2: ?[]const u8,
) !void {
    if (cfg_entry) |entry| {
        if (entry == .object) {
            if (entry.object.get("apiKey")) |kval| {
                if (kval == .string and kval.string.len > 0) {
                    const raw = kval.string;
                    if (std.mem.startsWith(u8, raw, "$") and validEnvName(raw[1..])) {
                        const var_name = raw[1..];
                        const present = if (env.get(var_name)) |v| v.len > 0 else false;
                        try writer.print("configured via models.json (${s}: {s})", .{ var_name, if (present) "set" else "unset" });
                        return;
                    }
                    try writer.writeAll("configured via models.json (stored credential, redacted)");
                    return;
                }
            }
        }
    }
    if (env1) |e1| {
        if (env.get(e1)) |v| {
            if (v.len > 0) {
                try writer.print("set via env {s}", .{e1});
                return;
            }
        }
    }
    if (env2) |e2| {
        if (env.get(e2)) |v| {
            if (v.len > 0) {
                try writer.print("set via env {s}", .{e2});
                return;
            }
        }
    }
    try writer.writeAll("not set");
}

fn resolveModelsFilePath(
    a: std.mem.Allocator,
    launch_cwd: []const u8,
    env: *const std.process.Environ.Map,
    override_path: ?[]const u8,
) ![]const u8 {
    if (override_path) |p| return p;
    if (env.get("ZPI_MODELS_FILE")) |p| {
        if (p.len > 0) return p;
    }
    const dir = (try mcp_config.resolveAgentDir(a, launch_cwd, env)) orelse return error.MissingHome;
    return try std.fs.path.join(a, &.{ dir, "models.json" });
}

fn readJsonObjectOrEmpty(a: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.ObjectMap {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .empty,
        error.StreamTooLong => return error.InvalidModelsConfig,
        else => return err,
    };
    if (text.len > max_file_bytes) return error.InvalidModelsConfig;
    const normalized = try models_json.normalize(a, text);
    const parsed = std.json.parseFromSlice(std.json.Value, a, normalized, .{ .parse_numbers = false }) catch return error.InvalidModelsConfig;
    if (parsed.value != .object) return error.InvalidModelsConfig;
    return parsed.value.object;
}

fn validProviderName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn validApiString(name: []const u8) bool {
    return std.mem.eql(u8, name, "openai-completions") or
        std.mem.eql(u8, name, "openai-responses") or
        std.mem.eql(u8, name, "anthropic-messages") or
        std.mem.eql(u8, name, "gemini-generate-content") or
        std.mem.eql(u8, name, "google-generative-ai") or
        std.mem.eql(u8, name, "gemini");
}

fn apiLabel(api: config.Api) []const u8 {
    return switch (api) {
        .openai_completions => "openai-completions",
        .openai_responses => "openai-responses",
        .anthropic_messages => "anthropic-messages",
        .gemini_generate_content => "gemini-generate-content",
    };
}

const auth_help =
    \\Usage:
    \\  zpi auth status [--models-file PATH]
    \\  zpi auth set <provider> [--api-key-env ENV | --stdin] [--base-url URL] [--api API] [--models-file PATH]
    \\  zpi auth remove <provider> [--models-file PATH]
    \\
    \\Credentials are stored with 0600 permissions and never printed to stdout/stderr.
    \\Prefer --api-key-env NAME (stores $NAME reference) or pipe via --stdin.
    \\
;

const models_help =
    \\Usage:
    \\  zpi models list [--models-file PATH]
    \\  zpi models set-default <provider>/<model>
    \\
;

const mcp_help =
    \\Usage:
    \\  zpi mcp list [--cwd PATH] [--trust-project-mcp] [--no-mcp-config]
    \\  zpi mcp add <name> -- <command> [args...]
    \\  zpi mcp remove <name>
    \\
;

// -----------------------------------------------------------------------------
// Unit tests
// -----------------------------------------------------------------------------

test "auth, models, and mcp subcommands manage private JSON configs without leaking secrets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const agent_dir = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "agent" });
    defer std.testing.allocator.free(agent_dir);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_CODING_AGENT_DIR", agent_dir);
    try env.put("GEMINI_API_KEY", "super-secret-env-key");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();

    // 1. auth set --stdin stores secret privately without echoing it.
    try runAuth(std.testing.io, a, ".", &env, &.{ "set", "openai", "--stdin" }, "sk-never-echo-me\n", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sk-never-echo-me") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Stored provider 'openai'") != null);

    // 2. auth set custom provider via --api-key-env + --base-url + --api.
    out.clearRetainingCapacity();
    try runAuth(std.testing.io, a, ".", &env, &.{ "set", "mygem", "--api-key-env", "GEMINI_API_KEY", "--base-url", "https://example.invalid/v1beta", "--api", "gemini-generate-content" }, null, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "$GEMINI_API_KEY") != null);

    // 3. auth status reports presence only, never secret values.
    out.clearRetainingCapacity();
    try runAuth(std.testing.io, a, ".", &env, &.{"status"}, null, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sk-never-echo-me") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "super-secret-env-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "set via env GEMINI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "$GEMINI_API_KEY: set") != null);

    // 4. models set-default + list marks gemini/gemini-2.5-flash as default.
    out.clearRetainingCapacity();
    try runModels(std.testing.io, a, ".", &env, &.{ "set-default", "gemini/gemini-2.5-flash" }, &out.writer);
    out.clearRetainingCapacity();
    try runModels(std.testing.io, a, ".", &env, &.{"list"}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "* gemini/gemini-2.5-flash") != null);

    // 5. mcp add / list / remove round-trip.
    out.clearRetainingCapacity();
    try runMcp(std.testing.io, a, ".", &env, &.{ "add", "docs", "--", "npx", "-y", "docs-mcp" }, &out.writer);
    out.clearRetainingCapacity();
    try runMcp(std.testing.io, a, ".", &env, &.{"list"}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "docs  [user]") != null);
    out.clearRetainingCapacity();
    try runMcp(std.testing.io, a, ".", &env, &.{ "remove", "docs" }, &out.writer);
    out.clearRetainingCapacity();
    try runMcp(std.testing.io, a, ".", &env, &.{"list"}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No MCP servers configured") != null);

    // 6. auth remove removes stored key.
    out.clearRetainingCapacity();
    try runAuth(std.testing.io, a, ".", &env, &.{ "remove", "openai" }, null, &out.writer);
    out.clearRetainingCapacity();
    try runAuth(std.testing.io, a, ".", &env, &.{"status"}, null, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "openai       not set") != null);
}
