//! Bordered, status-colored tool execution cards and unified diff formatting.
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub fn formatStartAlloc(allocator: std.mem.Allocator, th: theme.Theme, tool_name: []const u8, cols_raw: usize) ![]u8 {
    const max_cols = @max(cols_raw, 20) -| 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '\n');
    try th.paint(&out, allocator, theme.Theme.border, "╭─ ");
    try th.appendOpen(&out, allocator, theme.Theme.tool_header);
    try out.appendSlice(allocator, "[tool: ");
    var safe_name: std.ArrayList(u8) = .empty;
    defer safe_name.deinit(allocator);
    _ = try terminal.appendClippedText(&safe_name, allocator, tool_name, max_cols -| 14);
    try out.appendSlice(allocator, safe_name.items);
    try out.append(allocator, ']');
    try th.appendClose(&out, allocator);
    try out.append(allocator, ' ');

    const used = 3 + 7 + terminal.visibleWidth(safe_name.items) + 2;
    const fill = @min(max_cols -| used, 32);
    if (fill > 0) {
        try th.appendOpen(&out, allocator, theme.Theme.border);
        for (0..fill) |_| try out.appendSlice(allocator, "─");
        try th.appendClose(&out, allocator);
    }
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

pub fn formatBodyLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.border, "│ ");
    try terminal.appendSanitizedText(&out, allocator, text);
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

pub fn formatSpillLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.border, "│ ");
    try th.appendOpen(&out, allocator, theme.Theme.muted);
    try out.appendSlice(allocator, "[full output: ");
    try terminal.appendSanitizedText(&out, allocator, path);
    try out.append(allocator, ']');
    try th.appendClose(&out, allocator);
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

pub fn formatEndOkAlloc(allocator: std.mem.Allocator, th: theme.Theme) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.border, "╰─ ");
    try th.paint(&out, allocator, theme.Theme.tool_ok, "✓");
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

pub fn formatEndErrorAlloc(allocator: std.mem.Allocator, th: theme.Theme, err_text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.border, "╰─ ");
    try th.appendOpen(&out, allocator, theme.Theme.tool_err);
    try out.appendSlice(allocator, "✗ ");
    try terminal.appendSanitizedText(&out, allocator, err_text);
    try th.appendClose(&out, allocator);
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

pub fn formatDiffLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.border, "│ ");
    const spec = if (std.mem.startsWith(u8, line, "+"))
        theme.Theme.diff_add
    else if (std.mem.startsWith(u8, line, "-"))
        theme.Theme.diff_del
    else if (std.mem.startsWith(u8, line, "@@"))
        theme.Theme.diff_hunk
    else
        theme.Theme.muted;
    try th.appendOpen(&out, allocator, spec);
    try terminal.appendSanitizedText(&out, allocator, line);
    try th.appendClose(&out, allocator);
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

test "ToolCard and DiffView preserve tool markers and diff colors" {
    const a = std.testing.allocator;
    const th = theme.Theme.init(.ansi16);

    const start = try formatStartAlloc(a, th, "bash", 60);
    defer a.free(start);
    try std.testing.expect(std.mem.indexOf(u8, start, "[tool: bash]") != null);
    try std.testing.expect(std.mem.indexOf(u8, start, "╭─") != null);

    const plus = try formatDiffLineAlloc(a, th, "+2 BETA");
    defer a.free(plus);
    try std.testing.expect(std.mem.indexOf(u8, plus, "\x1b[32m+2 BETA\x1b[0m") != null);

    const minus = try formatDiffLineAlloc(a, th, "-2 beta");
    defer a.free(minus);
    try std.testing.expect(std.mem.indexOf(u8, minus, "\x1b[31m-2 beta\x1b[0m") != null);

    const end_err = try formatEndErrorAlloc(a, th, "boom");
    defer a.free(end_err);
    try std.testing.expect(std.mem.indexOf(u8, end_err, "╰─") != null);
    try std.testing.expect(std.mem.indexOf(u8, end_err, "boom") != null);
}
