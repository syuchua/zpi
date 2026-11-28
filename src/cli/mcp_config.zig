//! Bounded MCP server configuration loader (`~/.zpi/agent/mcp.json` and
//! opt-in project `.zpi/mcp.json` / `.mcp.json`).
//!
//! Security model:
//! - User-level `<agent-dir>/mcp.json` loads by default unless `--no-mcp-config`.
//! - Project-level `.zpi/mcp.json` / `.mcp.json` is NEVER loaded unless
//!   `--trust-project-mcp` is explicitly passed.
//! - Servers discovered here pass through the exact same `Harness` startup path
//!   as `--mcp-stdio`, so `mcp.start` + `process.exec` authorization, audit
//!   logging, and OS sandbox confinement apply identically.
const std = @import("std");
const models_json = @import("models_json");

pub const max_config_bytes: usize = 1024 * 1024;
pub const max_servers: usize = 16;
pub const max_argv_len: usize = 128;
pub const max_arg_bytes: usize = 16 * 1024;

pub const Source = enum { user, project, cli };

pub const Entry = struct {
    name: []const u8,
    argv: []const [:0]const u8,
    source: Source,
};

pub const CliServer = struct {
    name: []const u8,
    argv: []const [:0]const u8,
};

pub fn resolveAgentDir(allocator: std.mem.Allocator, launch_cwd: []const u8, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |agent_dir| {
        if (agent_dir.len > 0) {
            if (std.mem.indexOfScalar(u8, agent_dir, 0) != null or !std.unicode.utf8ValidateSlice(agent_dir)) return error.InvalidAgentDirectory;
            if (std.mem.eql(u8, agent_dir, "~") or std.mem.startsWith(u8, agent_dir, "~/")) {
                const home = env.get("HOME") orelse return error.MissingHome;
                const expanded = if (agent_dir.len == 1) try allocator.dupe(u8, home) else try std.fs.path.join(allocator, &.{ home, agent_dir[2..] });
                return try std.fs.path.resolveAlloc(allocator, &.{ launch_cwd, expanded });
            }
            return try std.fs.path.resolveAlloc(allocator, &.{ launch_cwd, agent_dir });
        }
    }
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(allocator, &.{ home, ".zpi", "agent" });
}

pub fn userConfigPath(allocator: std.mem.Allocator, launch_cwd: []const u8, env: *const std.process.Environ.Map) !?[]const u8 {
    const dir = (try resolveAgentDir(allocator, launch_cwd, env)) orelse return null;
    return try std.fs.path.join(allocator, &.{ dir, "mcp.json" });
}

pub fn validateServerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

pub fn sameNamespace(a_name: []const u8, b_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a_name, b_name);
}

/// Allocates into `allocator` (typically an invocation arena).
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    launch_cwd: []const u8,
    project_cwd: []const u8,
    env: *const std.process.Environ.Map,
    trust_project: bool,
    no_mcp_config: bool,
) ![]Entry {
    if (no_mcp_config) return &.{};

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    if (try userConfigPath(allocator, launch_cwd, env)) |user_path| {
        _ = try loadFileInto(allocator, io, user_path, .user, &entries);
    }

    if (trust_project) {
        const project_root = try std.fs.path.resolveAlloc(allocator, &.{ launch_cwd, project_cwd });
        const zpi_project_path = try std.fs.path.join(allocator, &.{ project_root, ".zpi", "mcp.json" });
        const loaded_zpi = try loadFileInto(allocator, io, zpi_project_path, .project, &entries);
        if (!loaded_zpi) {
            const dot_mcp_path = try std.fs.path.join(allocator, &.{ project_root, ".mcp.json" });
            _ = try loadFileInto(allocator, io, dot_mcp_path, .project, &entries);
        }
    }

    return entries.toOwnedSlice(allocator);
}

pub fn mergeWithCli(
    allocator: std.mem.Allocator,
    configured: []const Entry,
    cli_servers: []const CliServer,
) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(allocator);
    for (configured) |entry| {
        try upsertEntry(allocator, &out, entry);
    }
    for (cli_servers) |cli| {
        try upsertEntry(allocator, &out, .{
            .name = cli.name,
            .argv = cli.argv,
            .source = .cli,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn upsertEntry(allocator: std.mem.Allocator, list: *std.ArrayList(Entry), entry: Entry) !void {
    for (list.items) |*existing| {
        if (sameNamespace(existing.name, entry.name)) {
            existing.* = entry;
            return;
        }
    }
    if (list.items.len >= max_servers) return error.TooManyMcpServers;
    try list.append(allocator, entry);
}

/// Returns true if the file existed and was loaded, false if FileNotFound/NotDir.
fn loadFileInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: Source,
    out: *std.ArrayList(Entry),
) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidMcpConfig;
    if (stat.size > max_config_bytes) return error.McpConfigTooLarge;

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        error.StreamTooLong => return error.McpConfigTooLarge,
        else => return err,
    };
    if (text.len > max_config_bytes) return error.McpConfigTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidMcpConfig;

    const normalized = models_json.normalize(allocator, text) catch return error.InvalidMcpConfig;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, normalized, .{ .parse_numbers = false }) catch return error.InvalidMcpConfig;
    if (parsed.value != .object) return error.InvalidMcpConfig;

    const servers_val = parsed.value.object.get("mcpServers") orelse return true;
    if (servers_val != .object) return error.InvalidMcpConfig;

    var it = servers_val.object.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (!validateServerName(name)) return error.InvalidMcpServerName;
        if (kv.value_ptr.* != .object) return error.InvalidMcpConfig;
        const obj = kv.value_ptr.object;
        if (obj.get("disabled")) |dis| {
            if (dis != .bool) return error.InvalidMcpConfig;
            if (dis.bool) continue;
        }
        const cmd_val = obj.get("command") orelse return error.InvalidMcpCommand;
        if (cmd_val != .string or cmd_val.string.len == 0 or cmd_val.string.len > max_arg_bytes or std.mem.indexOfScalar(u8, cmd_val.string, 0) != null or !std.unicode.utf8ValidateSlice(cmd_val.string)) {
            return error.InvalidMcpCommand;
        }

        var argv: std.ArrayList([:0]const u8) = .empty;
        errdefer argv.deinit(allocator);
        try argv.append(allocator, try allocator.dupeSentinel(u8, cmd_val.string, 0));

        if (obj.get("args")) |args_val| {
            if (args_val != .array) return error.InvalidMcpCommand;
            if (args_val.array.items.len + 1 > max_argv_len) return error.InvalidMcpCommand;
            for (args_val.array.items) |arg_item| {
                if (arg_item != .string or arg_item.string.len > max_arg_bytes or std.mem.indexOfScalar(u8, arg_item.string, 0) != null or !std.unicode.utf8ValidateSlice(arg_item.string)) {
                    return error.InvalidMcpCommand;
                }
                try argv.append(allocator, try allocator.dupeSentinel(u8, arg_item.string, 0));
            }
        }

        try upsertEntry(allocator, out, .{
            .name = try allocator.dupe(u8, name),
            .argv = try argv.toOwnedSlice(allocator),
            .source = source,
        });
    }
    return true;
}

/// Add or replace an MCP server entry in `<agent-dir>/mcp.json` atomically (mode 0600).
pub fn addServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    launch_cwd: []const u8,
    env: *const std.process.Environ.Map,
    name: []const u8,
    argv: []const []const u8,
) ![]const u8 {
    if (!validateServerName(name)) return error.InvalidMcpServerName;
    if (argv.len == 0 or argv.len > max_argv_len or argv[0].len == 0) return error.InvalidMcpCommand;
    for (argv) |arg| {
        if (arg.len > max_arg_bytes or std.mem.indexOfScalar(u8, arg, 0) != null or !std.unicode.utf8ValidateSlice(arg)) {
            return error.InvalidMcpCommand;
        }
    }

    const path = (try userConfigPath(allocator, launch_cwd, env)) orelse return error.MissingHome;
    var root = try readOrEmptyObject(allocator, io, path);
    const servers_gop = try root.getOrPut(allocator, "mcpServers");
    if (!servers_gop.found_existing or servers_gop.value_ptr.* != .object) {
        servers_gop.value_ptr.* = .{ .object = .empty };
    }

    var entry_obj: std.json.ObjectMap = .empty;
    try entry_obj.put(allocator, "command", .{ .string = argv[0] });
    var args_arr = std.json.Array.init(allocator);
    for (argv[1..]) |arg| {
        try args_arr.append(.{ .string = arg });
    }
    try entry_obj.put(allocator, "args", .{ .array = args_arr });

    // Remove any existing key that matches case-insensitively to prevent duplicates.
    var existing_key: ?[]const u8 = null;
    var it = servers_gop.value_ptr.object.iterator();
    while (it.next()) |kv| {
        if (sameNamespace(kv.key_ptr.*, name)) {
            existing_key = kv.key_ptr.*;
            break;
        }
    }
    if (existing_key) |old_k| _ = servers_gop.value_ptr.object.orderedRemove(old_k);
    if (servers_gop.value_ptr.object.count() >= max_servers) return error.TooManyMcpServers;

    try servers_gop.value_ptr.object.put(allocator, name, .{ .object = entry_obj });
    try writeJsonPrivateAtomic(allocator, io, path, .{ .object = root });
    return path;
}

/// Remove an MCP server entry from `<agent-dir>/mcp.json` atomically (mode 0600).
pub fn removeServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    launch_cwd: []const u8,
    env: *const std.process.Environ.Map,
    name: []const u8,
) ![]const u8 {
    if (!validateServerName(name)) return error.InvalidMcpServerName;
    const path = (try userConfigPath(allocator, launch_cwd, env)) orelse return error.MissingHome;
    var root = try readOrEmptyObject(allocator, io, path);
    const servers_ptr = root.getPtr("mcpServers") orelse return error.McpServerNotFound;
    if (servers_ptr.* != .object) return error.InvalidMcpConfig;

    var found_key: ?[]const u8 = null;
    var it = servers_ptr.object.iterator();
    while (it.next()) |kv| {
        if (sameNamespace(kv.key_ptr.*, name)) {
            found_key = kv.key_ptr.*;
            break;
        }
    }
    const key = found_key orelse return error.McpServerNotFound;
    _ = servers_ptr.object.orderedRemove(key);
    try writeJsonPrivateAtomic(allocator, io, path, .{ .object = root });
    return path;
}

fn readOrEmptyObject(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.ObjectMap {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .empty,
        error.StreamTooLong => return error.McpConfigTooLarge,
        else => return err,
    };
    if (text.len > max_config_bytes) return error.McpConfigTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidMcpConfig;
    const normalized = models_json.normalize(allocator, text) catch return error.InvalidMcpConfig;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, normalized, .{ .parse_numbers = false }) catch return error.InvalidMcpConfig;
    if (parsed.value != .object) return error.InvalidMcpConfig;
    return parsed.value.object;
}

pub fn writeJsonPrivateAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, value: std.json.Value) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);
    const with_nl = try allocator.print("{s}\n", .{encoded});
    defer allocator.free(with_nl);

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .fromMode(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, with_nl, 0);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

// -----------------------------------------------------------------------------
// Unit tests
// -----------------------------------------------------------------------------

test "mcp_config loads user mcp.json, gates project config behind trust_project, and supports add/remove" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_dir = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_dir);
    const agent_dir = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "agent" });
    defer std.testing.allocator.free(agent_dir);
    const proj_dir = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "proj" });
    defer std.testing.allocator.free(proj_dir);

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "proj/.zpi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "proj/.zpi/mcp.json",
        .data = "{\"mcpServers\":{\"proj_srv\":{\"command\":\"echo\",\"args\":[\"from-project\"]}}}",
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_CODING_AGENT_DIR", agent_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Add a user server via addServer.
    _ = try addServer(a, std.testing.io, ".", &env, "user_srv", &.{ "node", "server.js" });

    // Without trust_project, only user_srv loads.
    const user_only = try load(a, std.testing.io, ".", proj_dir, &env, false, false);
    try std.testing.expectEqual(@as(usize, 1), user_only.len);
    try std.testing.expectEqualStrings("user_srv", user_only[0].name);
    try std.testing.expectEqual(Source.user, user_only[0].source);
    try std.testing.expectEqual(@as(usize, 2), user_only[0].argv.len);
    try std.testing.expectEqualStrings("node", user_only[0].argv[0]);
    try std.testing.expectEqualStrings("server.js", user_only[0].argv[1]);

    // With no_mcp_config, nothing loads.
    const disabled = try load(a, std.testing.io, ".", proj_dir, &env, true, true);
    try std.testing.expectEqual(@as(usize, 0), disabled.len);

    // With trust_project, both user and project servers load.
    const both = try load(a, std.testing.io, ".", proj_dir, &env, true, false);
    try std.testing.expectEqual(@as(usize, 2), both.len);

    // CLI override replaces matching name.
    const cli_argv = [_][:0]const u8{ "python3", "override.py" };
    const merged = try mergeWithCli(a, both, &.{.{ .name = "USER_SRV", .argv = &cli_argv }});
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqual(Source.cli, merged[0].source);
    try std.testing.expectEqualStrings("python3", merged[0].argv[0]);

    // Remove user_srv.
    _ = try removeServer(a, std.testing.io, ".", &env, "user_srv");
    const after_rm = try load(a, std.testing.io, ".", proj_dir, &env, false, false);
    try std.testing.expectEqual(@as(usize, 0), after_rm.len);
    try std.testing.expectError(error.McpServerNotFound, removeServer(a, std.testing.io, ".", &env, "user_srv"));
}
