//! User settings loader (`<agent-dir>/settings.json`). Uses the same bounded
//! JSON-with-comments subset as models.json and fails closed on invalid data.
const std = @import("std");
const zpi = @import("zpi");
const models_json = @import("models_json.zig");

const max_settings_bytes = 4 * 1024 * 1024;

pub const CompactionOverride = struct {
    reserve_tokens: ?u64 = null,
    keep_recent_tokens: ?u64 = null,
};

pub const ModelCompactionEntry = struct {
    key: []const u8,
    override: CompactionOverride,
};

pub const ModelThinkingEntry = struct {
    key: []const u8,
    level: zpi.model.ThinkingLevel,
};

pub const Settings = struct {
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    default_thinking_level: ?zpi.model.ThinkingLevel = null,
    model_thinking_levels: []const ModelThinkingEntry = &.{},
    default_tools: ?[]const []const u8 = null,
    compaction: zpi.compaction.Settings = .{},
    compaction_overrides: []const ModelCompactionEntry = &.{},
    retry: zpi.agent.RetryPolicy = .{},
    session_dir: ?[]const u8 = null,
    hide_thinking_block: bool = false,
    tool_outputs_expanded: bool = false,
    quiet_startup: bool = false,

    pub fn thinkingFor(self: Settings, allocator: std.mem.Allocator, provider: []const u8, model_id: []const u8) !?zpi.model.ThinkingLevel {
        if (self.model_thinking_levels.len > 0) {
            const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, model_id });
            defer allocator.free(key);
            for (self.model_thinking_levels) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.level;
            }
        }
        return self.default_thinking_level;
    }

    pub fn compactionFor(self: Settings, allocator: std.mem.Allocator, provider: []const u8, model_id: []const u8) !zpi.compaction.Settings {
        var resolved = self.compaction;
        if (self.compaction_overrides.len > 0) {
            const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, model_id });
            defer allocator.free(key);
            for (self.compaction_overrides) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    if (entry.override.reserve_tokens) |r| resolved.reserve_tokens = r;
                    if (entry.override.keep_recent_tokens) |k| resolved.keep_recent_tokens = k;
                    break;
                }
            }
        }
        return resolved;
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, launch_cwd: []const u8, env: *const std.process.Environ.Map) !Settings {
    const path = try settingsFilePath(allocator, launch_cwd, env) orelse return .{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_settings_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.StreamTooLong => return error.SettingsFileTooLarge,
        else => return err,
    };
    if (text.len > max_settings_bytes) return error.SettingsFileTooLarge;
    const normalized = try models_json.normalize(allocator, text);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, normalized, .{ .parse_numbers = false }) catch return error.InvalidSettings;
    if (parsed.value != .object) return error.InvalidSettings;
    return parseObject(allocator, parsed.value);
}

fn settingsFilePath(allocator: std.mem.Allocator, launch_cwd: []const u8, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |agent_dir| {
        if (agent_dir.len > 0) {
            if (std.mem.indexOfScalar(u8, agent_dir, 0) != null or !std.unicode.utf8ValidateSlice(agent_dir)) return error.InvalidAgentDirectory;
            if (std.mem.eql(u8, agent_dir, "~") or std.mem.startsWith(u8, agent_dir, "~/")) {
                const home = env.get("HOME") orelse return error.MissingHome;
                const expanded = if (agent_dir.len == 1) try allocator.dupe(u8, home) else try std.fs.path.join(allocator, &.{ home, agent_dir[2..] });
                const resolved = try std.fs.path.resolveAlloc(allocator, &.{ launch_cwd, expanded });
                return try std.fs.path.join(allocator, &.{ resolved, "settings.json" });
            }
            const resolved = try std.fs.path.resolveAlloc(allocator, &.{ launch_cwd, agent_dir });
            return try std.fs.path.join(allocator, &.{ resolved, "settings.json" });
        }
    }
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(allocator, &.{ home, ".zpi", "agent", "settings.json" });
}

fn parseObject(allocator: std.mem.Allocator, root: std.json.Value) !Settings {
    var out: Settings = .{};
    const obj = root.object;

    if (obj.get("defaultProvider")) |v| {
        if (v != .string or v.string.len == 0) return error.InvalidSettings;
        out.default_provider = v.string;
    }
    if (obj.get("defaultModel")) |v| {
        if (v != .string or v.string.len == 0) return error.InvalidSettings;
        out.default_model = v.string;
    }
    if (obj.get("defaultThinkingLevel")) |v| {
        if (v != .string) return error.InvalidSettings;
        out.default_thinking_level = zpi.model.ThinkingLevel.parse(v.string) orelse return error.InvalidSettings;
    }
    if (obj.get("modelThinkingLevels")) |v| {
        if (v != .object) return error.InvalidSettings;
        var entries: std.ArrayList(ModelThinkingEntry) = .empty;
        var it = v.object.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.* != .string) return error.InvalidSettings;
            const lvl = zpi.model.ThinkingLevel.parse(item.value_ptr.string) orelse return error.InvalidSettings;
            try entries.append(allocator, .{ .key = item.key_ptr.*, .level = lvl });
        }
        out.model_thinking_levels = try entries.toOwnedSlice(allocator);
    }
    if (obj.get("defaultTools")) |v| {
        if (v != .array) return error.InvalidSettings;
        var list = try allocator.alloc([]const u8, v.array.items.len);
        for (v.array.items, 0..) |item, i| {
            if (item != .string or item.string.len == 0) return error.InvalidSettings;
            list[i] = item.string;
        }
        out.default_tools = list;
    }
    if (obj.get("sessionDir")) |v| {
        if (v != .string or v.string.len == 0) return error.InvalidSettings;
        out.session_dir = v.string;
    }
    if (obj.get("hideThinkingBlock")) |v| {
        if (v != .bool) return error.InvalidSettings;
        out.hide_thinking_block = v.bool;
    }
    if (obj.get("toolOutputsExpanded")) |v| {
        if (v != .bool) return error.InvalidSettings;
        out.tool_outputs_expanded = v.bool;
    }
    if (obj.get("quietStartup")) |v| {
        switch (v) {
            .bool => |b| out.quiet_startup = b,
            .string => |s| {
                if (std.mem.eql(u8, s, "header")) out.quiet_startup = false else return error.InvalidSettings;
            },
            else => return error.InvalidSettings,
        }
    }
    if (obj.get("compaction")) |comp_val| {
        if (comp_val != .object) return error.InvalidSettings;
        const cobj = comp_val.object;
        if (cobj.get("enabled")) |v| {
            if (v != .bool) return error.InvalidSettings;
            out.compaction.enabled = v.bool;
        }
        if (cobj.get("reserveTokens")) |v| out.compaction.reserve_tokens = try parseNonNegativeInt(v);
        if (cobj.get("keepRecentTokens")) |v| out.compaction.keep_recent_tokens = try parseNonNegativeInt(v);
        if (cobj.get("modelOverrides")) |ov_val| {
            if (ov_val != .object) return error.InvalidSettings;
            var entries: std.ArrayList(ModelCompactionEntry) = .empty;
            var it = ov_val.object.iterator();
            while (it.next()) |item| {
                if (item.value_ptr.* != .object) return error.InvalidSettings;
                var ov: CompactionOverride = .{};
                if (item.value_ptr.object.get("reserveTokens")) |r| ov.reserve_tokens = try parseNonNegativeInt(r);
                if (item.value_ptr.object.get("keepRecentTokens")) |k| ov.keep_recent_tokens = try parseNonNegativeInt(k);
                try entries.append(allocator, .{ .key = item.key_ptr.*, .override = ov });
            }
            out.compaction_overrides = try entries.toOwnedSlice(allocator);
        }
    }
    if (obj.get("retry")) |retry_val| {
        if (retry_val != .object) return error.InvalidSettings;
        const robj = retry_val.object;
        if (robj.get("enabled")) |v| {
            if (v != .bool) return error.InvalidSettings;
            out.retry.enabled = v.bool;
        }
        if (robj.get("maxRetries")) |v| {
            const n = try parseNonNegativeInt(v);
            if (n > 20) return error.InvalidSettings;
            out.retry.max_retries = @intCast(n);
        }
        if (robj.get("baseDelayMs")) |v| out.retry.base_delay_ms = try parseNonNegativeInt(v);
        if (robj.get("maxAgentDelayMs")) |v| out.retry.max_delay_ms = try parseNonNegativeInt(v);
    }
    return out;
}

fn parseNonNegativeInt(v: std.json.Value) !u64 {
    return switch (v) {
        .integer => |n| if (n < 0) error.InvalidSettings else @intCast(n),
        .number_string => |s| blk: {
            if (std.mem.indexOfAny(u8, s, ".eE+-") != null) return error.InvalidSettings;
            break :blk std.fmt.parseInt(u64, s, 10) catch return error.InvalidSettings;
        },
        else => error.InvalidSettings,
    };
}

test "settings loads defaults, per-model overrides, tools, compaction, and retry policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data =
        \\// user settings
        \\{
        \\  "defaultProvider": "anthropic",
        \\  "defaultModel": "claude-sonnet-4-5",
        \\  "defaultThinkingLevel": "medium",
        \\  "modelThinkingLevels": { "openai/gpt-5": "high" },
        \\  "defaultTools": ["-bash", "+grep"],
        \\  "sessionDir": "~/custom-sessions",
        \\  "hideThinkingBlock": true,
        \\  "toolOutputsExpanded": true,
        \\  "quietStartup": true,
        \\  "compaction": {
        \\    "enabled": true,
        \\    "reserveTokens": 8192,
        \\    "keepRecentTokens": 4096,
        \\    "modelOverrides": { "openai/gpt-5": { "reserveTokens": 24000 } }
        \\  },
        \\  "retry": { "enabled": false, "maxRetries": 5, "baseDelayMs": 500, "maxAgentDelayMs": 15000 },
        \\}
        ,
    });
    const dir = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(dir);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_CODING_AGENT_DIR", dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try load(arena.allocator(), std.testing.io, ".", &env);

    try std.testing.expectEqualStrings("anthropic", s.default_provider.?);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", s.default_model.?);
    try std.testing.expectEqual(zpi.model.ThinkingLevel.medium, s.default_thinking_level.?);
    try std.testing.expectEqual(zpi.model.ThinkingLevel.high, (try s.thinkingFor(arena.allocator(), "openai", "gpt-5")).?);
    try std.testing.expectEqual(zpi.model.ThinkingLevel.medium, (try s.thinkingFor(arena.allocator(), "anthropic", "claude-sonnet-4-5")).?);
    try std.testing.expectEqual(@as(usize, 2), s.default_tools.?.len);
    try std.testing.expectEqualStrings("-bash", s.default_tools.?[0]);
    try std.testing.expectEqualStrings("~/custom-sessions", s.session_dir.?);
    try std.testing.expect(s.hide_thinking_block);
    try std.testing.expect(s.tool_outputs_expanded);
    try std.testing.expect(s.quiet_startup);

    const comp_default = try s.compactionFor(arena.allocator(), "anthropic", "claude-sonnet-4-5");
    try std.testing.expectEqual(@as(u64, 8192), comp_default.reserve_tokens);
    try std.testing.expectEqual(@as(u64, 4096), comp_default.keep_recent_tokens);

    const comp_ov = try s.compactionFor(arena.allocator(), "openai", "gpt-5");
    try std.testing.expectEqual(@as(u64, 24000), comp_ov.reserve_tokens);
    try std.testing.expectEqual(@as(u64, 4096), comp_ov.keep_recent_tokens);

    try std.testing.expect(!s.retry.enabled);
    try std.testing.expectEqual(@as(u8, 5), s.retry.max_retries);
    try std.testing.expectEqual(@as(u64, 500), s.retry.base_delay_ms);
    try std.testing.expectEqual(@as(u64, 15000), s.retry.max_delay_ms);
}
