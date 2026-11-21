//! Tool selection shared by model declarations and dispatch. No hidden callable
//! tools: the returned indices define the Agent's entire tool table.
const std = @import("std");

pub const Candidate = struct { name: []const u8, builtin: bool };
pub const Selection = struct {
    tools: ?[]const u8 = null,
    exclude: ?[]const u8 = null,
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

fn isDefaultBuiltin(name: []const u8) bool {
    inline for (.{ "read", "bash", "edit", "write" }) |default_name| {
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
    .{ .name = "echo_native", .builtin = false },
    .{ .name = "hello", .builtin = false },
};
fn expect(selection: Selection, expected: []const usize) !void {
    const result = try select(std.testing.allocator, &fixture, selection);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, expected, result);
}
test "tool selection applies pi defaults allowlists modifiers and exclusions" {
    try expect(.{}, &.{ 0, 1, 2, 3, 7, 8 });
    try expect(.{ .no_tools = true }, &.{});
    try expect(.{ .no_builtin_tools = true }, &.{ 7, 8 });
    try expect(.{ .tools = " read , echo_*,read,unknown, " }, &.{ 0, 7 });
    try expect(.{ .tools = "*", .exclude = "w*,hello" }, &.{ 0, 1, 2, 4, 5, 6, 7 });
    try expect(.{ .tools = "-write,+write,-write,-hello" }, &.{ 0, 1, 2, 7 });
    try expect(.{ .no_tools = true, .tools = "+read,+hello" }, &.{ 0, 8 });
    try expect(.{ .no_tools = true, .tools = "read", .exclude = "read" }, &.{});
    try expect(.{ .no_builtin_tools = true, .tools = "+read" }, &.{ 0, 7, 8 });
    try expect(.{ .tools = "read", .no_builtin_tools = true }, &.{0});
    try expect(.{ .tools = "", .no_builtin_tools = true }, &.{});
    try expect(.{ .exclude = "" }, &.{ 0, 1, 2, 3, 7, 8 });
    try std.testing.expectError(error.MixedToolSelection, select(std.testing.allocator, &fixture, .{ .tools = "read,+write" }));
    try std.testing.expectError(error.InvalidToolModifier, select(std.testing.allocator, &fixture, .{ .tools = "+r*" }));
    try std.testing.expectError(error.InvalidToolModifier, select(std.testing.allocator, &fixture, .{ .tools = "-" }));
    try expect(.{ .exclude = "+read" }, &.{ 0, 1, 2, 3, 7, 8 });
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
