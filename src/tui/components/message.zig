//! Message presentation helpers for user transcript panels and thinking blocks.
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

/// Render a user message in a full-width semantic panel that wraps to the
/// available terminal width. Colored panels include bottom padding and a line
/// break. The caller terminates the message, leaving a blank line after it.
pub fn formatUserEchoAlloc(allocator: std.mem.Allocator, th: theme.Theme, text: []const u8, terminal_cols: usize) ![]u8 {
    const safe = try terminal.safeUtf8Alloc(allocator, text);
    defer allocator.free(safe);
    const width = @max(@as(usize, 1), terminal_cols -| 1); // Leave a cell before the terminal's autowrap boundary.
    if (th.mode == .none or width < 4) {
        var plain: std.ArrayList(u8) = .empty;
        errdefer plain.deinit(allocator);
        try plain.appendSlice(allocator, "> ");
        try terminal.appendSafeTerminalBytes(&plain, allocator, safe);
        return plain.toOwnedSlice(allocator);
    }

    const expanded = try std.mem.replaceOwned(u8, allocator, safe, "\t", "    ");
    defer allocator.free(expanded);
    const wrapped = try terminal.wrapAnsiAlloc(allocator, expanded, width - 2);
    defer allocator.free(wrapped);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, wrapped, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        try th.appendOpen(&out, allocator, theme.Theme.user_panel);
        try out.appendSlice(allocator, if (first) "> " else "  ");
        try out.appendSlice(allocator, line);
        try out.appendNTimes(allocator, ' ', width -| (terminal.visibleWidth(line) + 2));
        try th.appendClose(&out, allocator);
        first = false;
    }
    // Pad the bottom of the panel, then leave space for a plain spacer row.
    try out.append(allocator, '\n');
    try th.appendOpen(&out, allocator, theme.Theme.user_panel);
    try out.appendNTimes(allocator, ' ', width);
    try th.appendClose(&out, allocator);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
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

test "user panel wraps to terminal cells and closes its background on every row" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 9, 40, 80 }) |cols| {
        const user = try formatUserEchoAlloc(allocator, theme.Theme.init(.truecolor), "较长的输入\twrap\nsecond", cols);
        defer allocator.free(user);
        const background = "\x1b[48;2;25;43;61m";
        const reset = "\x1b[0m";
        try std.testing.expect(std.mem.endsWith(u8, user, "\n"));
        var rows = std.mem.splitScalar(u8, user[0 .. user.len - 1], '\n');
        var last: []const u8 = "";
        var count: usize = 0;
        while (rows.next()) |row| {
            try std.testing.expectEqual(cols - 1, terminal.visibleWidth(row));
            try std.testing.expect(std.mem.startsWith(u8, row, background));
            try std.testing.expect(std.mem.endsWith(u8, row, reset));
            try std.testing.expect(std.mem.indexOfScalar(u8, row, '\t') == null);
            last = row;
            count += 1;
        }
        try std.testing.expect(count >= 3);
        try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, last[background.len .. last.len - reset.len], " ").len);
    }
}

test "UserMessage and ThinkingBlock honor NO_COLOR and sanitize control chars" {
    const allocator = std.testing.allocator;
    const user = try formatUserEchoAlloc(allocator, theme.Theme.init(.none), "hello\x07", 80);
    defer allocator.free(user);
    try std.testing.expectEqualStrings("> hello?", user);
    const plain = try formatThinkingDeltaAlloc(allocator, theme.Theme.init(.none), "step\x08");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("step?", plain);
}
