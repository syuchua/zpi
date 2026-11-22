//! Message presentation helpers (user prompt badge and thinking block styling).
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub fn formatUserEchoAlloc(allocator: std.mem.Allocator, th: theme.Theme, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.user_badge, "> ");
    try terminal.appendSafeTerminalBytes(&out, allocator, text);
    return try out.toOwnedSlice(allocator);
}

pub fn formatThinkingHeaderAlloc(allocator: std.mem.Allocator, th: theme.Theme) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.thinking, "· thinking");
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

pub fn formatThinkingDeltaAlloc(allocator: std.mem.Allocator, th: theme.Theme, delta: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.appendOpen(&out, allocator, theme.Theme.thinking);
    try terminal.appendSanitizedText(&out, allocator, delta);
    try th.appendClose(&out, allocator);
    return try out.toOwnedSlice(allocator);
}

test "UserMessage and ThinkingBlock honor NO_COLOR and sanitize control chars" {
    const a = std.testing.allocator;
    const colored = try formatUserEchoAlloc(a, theme.Theme.init(.ansi16), "hello\x07");
    defer a.free(colored);
    try std.testing.expectEqualStrings("\x1b[1;36m> \x1b[0mhello?", colored);

    const plain = try formatThinkingDeltaAlloc(a, theme.Theme.init(.none), "step\x08");
    defer a.free(plain);
    try std.testing.expectEqualStrings("step?", plain);
}
