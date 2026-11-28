//! Tool selection shared by model declarations and dispatch. No hidden callable
//! tools: the returned indices define the Agent's entire tool table.
const std = @import("std");

pub const Candidate = struct { name: []const u8, builtin: bool };
pub const Selection = struct {
    tools: ?[]const u8 = null,
    exclude: ?[]const u8 = null,
    default_tools: ?[]const []const u8 = null,
    no_tools: bool = false,
    no_builtin_tools: bool = false,
};

pub fn validate(selection: Selection) !void {
    if (selection.tools) |list| {
        var entries = std.mem.splitScalar(u8, list, ',');
        var modifiers: ?bool = null;
        while (entries.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len == 0) continue;
            const modifier = entry[0] == '+' or entry[0] == '-';
            if (modifiers) |prior| if (prior != modifier) return error.MixedToolSelection;
            modifiers = modifier;
            if (modifier and (entry.len == 1 or std.mem.indexOfScalar(u8, entry, '*') != null)) return error.InvalidToolModifier;
        }
    }
}

/// Caller owns indices. The default set matches pi's `read`, `bash`, `edit`,
/// `write`; modifiers and exclusions are applied in order.
pub fn select(a: std.mem.Allocator, candidates: []const Candidate, selection: Selection) ![]usize {
    try validate(selection);
    const enabled = try a.alloc(bool, candidates.len);
    defer a.free(enabled);
    for (candidates, enabled) |candidate, *value| value.* = !selection.no_tools and
        (!candidate.builtin or (!selection.no_builtin_tools and isDefaultBuiltin(candidate.name)));
    if (!selection.no_tools and selection.default_tools != null) {
        const entries = selection.default_tools.?;
        var has_plain = false;
        for (entries) |entry| {
            if (entry.len > 0 and entry[0] != '+' and entry[0] != '-') {
                has_plain = true;
                break;
            }
        }
        if (has_plain or entries.len == 0) {
            for (candidates, enabled) |candidate, *value| {
                if (candidate.builtin) value.* = false;
            }
        }
        for (entries) |entry| {
            if (entry.len == 0) continue;
            if (entry[0] == '+' or entry[0] == '-') {
                for (candidates, enabled) |candidate, *value| {
                    if (std.mem.eql(u8, entry[1..], candidate.name)) value.* = entry[0] == '+';
                }
            } else {
                for (candidates, enabled) |candidate, *value| {
                    if (std.mem.eql(u8, entry, candidate.name)) value.* = true;
                }
            }
        }
    }
    if (selection.tools) |list| {
        var entries = std.mem.splitScalar(u8, list, ',');
        var first: ?[]const u8 = null;
        while (entries.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len > 0) {
                first = entry;
                break;
            }
        }
        const modifiers = if (first) |entry| entry[0] == '+' or entry[0] == '-' else false;
        if (!modifiers) @memset(enabled, false);
        entries.reset();
        while (entries.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len == 0) continue;
            for (candidates, enabled) |candidate, *value| {
                if (modifiers) {
                    if (std.mem.eql(u8, entry[1..], candidate.name)) value.* = entry[0] == '+';
                } else if (matches(entry, candidate.name)) value.* = true;
            }
        }
    }
    if (selection.exclude) |list| {
        var entries = std.mem.splitScalar(u8, list, ',');
        while (entries.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len == 0) continue;
            for (candidates, enabled) |candidate, *value| if (matches(entry, candidate.name)) {
                value.* = false;
            };
        }
    }
    var result: std.ArrayList(usize) = .empty;
    errdefer result.deinit(a);
    for (enabled, 0..) |value, i| if (value) try result.append(a, i);
    return result.toOwnedSlice(a);
}

/// Describe `--tools` pattern entries that matched no candidate. Plain
/// allowlist entries select by name or `*` pattern; `+`/`-` modifiers name
/// exactly one tool. Selection semantics are unchanged: this only explains it.
/// Returns the number of unmatched entries and appends each raw entry to
/// `out` (borrowed from `tools`). The caller formats them for stderr after the
/// tool table is known and before running any turn.
pub fn unmatchedPatterns(out: *std.ArrayList([]const u8), a: std.mem.Allocator, candidates: []const Candidate, tools: ?[]const u8) !usize {
    const list = tools orelse return 0;
    var entries = std.mem.splitScalar(u8, list, ',');
    var first: ?[]const u8 = null;
    var probe = std.mem.splitScalar(u8, list, ',');
    while (probe.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len > 0) {
            first = entry;
            break;
        }
    }
    const modifiers = if (first) |entry| entry[0] == '+' or entry[0] == '-' else false;
    var count: usize = 0;
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;
        var matched = false;
        for (candidates) |candidate| {
            const hit = if (modifiers) std.mem.eql(u8, entry[1..], candidate.name) else matches(entry, candidate.name);
            if (hit) {
                matched = true;
                break;
            }
        }
        if (matched) continue;
        count += 1;
        try out.append(a, entry);
    }
    return count;
}

fn isDefaultBuiltin(name: []const u8) bool {
    inline for (.{ "read", "bash", "edit", "write", "web_fetch", "get_content", "web_search", "bg_run", "bg_status", "bg_logs", "bg_kill" }) |default_name| {
        if (std.mem.eql(u8, name, default_name)) return true;
    }
    return false;
}

/// Only '*' is special; punctuation and '?' match literally, case sensitively.
fn matches(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = n;
        } else if (p < pattern.len and pattern[p] == name[n]) {
            p += 1;
            n += 1;
        } else if (star) |s| {
            retry += 1;
            n = retry;
            p = s + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

const fixture = [_]Candidate{
    .{ .name = "read", .builtin = true },
    .{ .name = "bash", .builtin = true },
    .{ .name = "edit", .builtin = true },
    .{ .name = "write", .builtin = true },
    .{ .name = "grep", .builtin = true },
    .{ .name = "find", .builtin = true },
    .{ .name = "ls", .builtin = true },
    .{ .name = "web_fetch", .builtin = true },
    .{ .name = "web_search", .builtin = true },
    .{ .name = "get_content", .builtin = true },
    .{ .name = "bg_run", .builtin = true },
    .{ .name = "bg_status", .builtin = true },
    .{ .name = "bg_logs", .builtin = true },
    .{ .name = "bg_kill", .builtin = true },
    .{ .name = "echo_native", .builtin = false },
    .{ .name = "hello", .builtin = false },
};
fn expect(selection: Selection, expected: []const usize) !void {
    const result = try select(std.testing.allocator, &fixture, selection);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, expected, result);
}
test "unmatched --tools entries are reported without changing selection" {
    const a = std.testing.allocator;
    var unmatched: std.ArrayList([]const u8) = .empty;
    defer unmatched.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), try unmatchedPatterns(&unmatched, a, &fixture, "read*,r?ad"));
    try std.testing.expectEqualStrings("r?ad", unmatched.items[0]);
    unmatched.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 2), try unmatchedPatterns(&unmatched, a, &fixture, "+bash,gone,nosuch"));
    try std.testing.expectEqualStrings("gone", unmatched.items[0]);
    try std.testing.expectEqualStrings("nosuch", unmatched.items[1]);
    unmatched.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), try unmatchedPatterns(&unmatched, a, &fixture, "read,*"));
    // A modifier list names exact tools; `+bash` and `-write` both match.
    try std.testing.expectEqual(@as(usize, 0), try unmatchedPatterns(&unmatched, a, &fixture, "+bash,-write"));
    try std.testing.expectEqual(@as(usize, 0), try unmatchedPatterns(&unmatched, a, &fixture, null));
    try std.testing.expectEqual(@as(usize, 0), try unmatchedPatterns(&unmatched, a, &fixture, ""));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const selected = try select(arena.allocator(), &fixture, .{ .tools = "read,nosuch" });
    try std.testing.expectEqualSlices(usize, &.{0}, selected);
}

test "tool selection applies pi defaults allowlists modifiers and exclusions" {
    try expect(.{}, &.{ 0, 1, 2, 3, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    try expect(.{ .no_tools = true }, &.{});
    try expect(.{ .no_builtin_tools = true }, &.{ 14, 15 });
    try expect(.{ .tools = " read , echo_*,read,unknown, " }, &.{ 0, 14 });
    try expect(.{ .tools = "*", .exclude = "w*,g*,b*,hello" }, &.{ 0, 2, 5, 6, 14 });
    try expect(.{ .tools = "-write,+write,-write,-bash,-web_fetch,-web_search,-get_content,-bg_run,-bg_status,-bg_logs,-bg_kill,-hello" }, &.{ 0, 2, 14 });
    try expect(.{ .no_tools = true, .tools = "+read,+hello" }, &.{ 0, 15 });
    try expect(.{ .no_tools = true, .tools = "read", .exclude = "read" }, &.{});
    try expect(.{ .no_builtin_tools = true, .tools = "+read" }, &.{ 0, 14, 15 });
    try expect(.{ .tools = "read", .no_builtin_tools = true }, &.{0});
    try expect(.{ .tools = "", .no_builtin_tools = true }, &.{});
    try expect(.{ .exclude = "" }, &.{ 0, 1, 2, 3, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    try std.testing.expectError(error.MixedToolSelection, select(std.testing.allocator, &fixture, .{ .tools = "read,+write" }));
    try std.testing.expectError(error.InvalidToolModifier, select(std.testing.allocator, &fixture, .{ .tools = "+r*" }));
    try std.testing.expectError(error.InvalidToolModifier, select(std.testing.allocator, &fixture, .{ .tools = "-" }));
    try expect(.{ .exclude = "+read" }, &.{ 0, 1, 2, 3, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    try expect(.{ .default_tools = &.{ "-bash", "+grep" } }, &.{ 0, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    try expect(.{ .default_tools = &.{ "read", "ls" }, .tools = "+grep" }, &.{ 0, 4, 6, 14, 15 });
    try expect(.{ .default_tools = &.{} }, &.{ 14, 15 });
}
test "tool selection wildcard matches full names and escapes other punctuation" {
    try std.testing.expect(matches("*", "read"));
    try std.testing.expect(matches("**a*d*", "read"));
    try std.testing.expect(matches("echo_*", "echo_native"));
    try std.testing.expect(!matches("read", "Read"));
    try std.testing.expect(!matches("r?ad", "read"));
    try std.testing.expect(matches("r?ad", "r?ad"));
    try std.testing.expect(!matches("*read", "read_more"));
    try std.testing.expect(!matches("*x*y", "x"));
    try std.testing.expect(matches("*", ""));
    try std.testing.expect(!matches("*a*a*a*", "aa"));
    try std.testing.expect(matches("x*y*z", "x12y3z"));
    try std.testing.expect(!matches("x*y*z", "x12yz!"));
}
