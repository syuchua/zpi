//! Bordered, status-colored tool execution cards and unified diff formatting.
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub fn formatStartAlloc(allocator: std.mem.Allocator, th: theme.Theme, tool_name: []const u8, cols_raw: usize) ![]u8 {
    return formatStartWithArgAlloc(allocator, th, tool_name, "", cols_raw);
}

pub fn formatStartWithArgAlloc(
    allocator: std.mem.Allocator,
    th: theme.Theme,
    tool_name: []const u8,
    arg_summary: []const u8,
    cols_raw: usize,
) ![]u8 {
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

    var arg_w: usize = 0;
    if (arg_summary.len > 0) {
        const prefix_w = 3 + 7 + terminal.visibleWidth(safe_name.items) + 1;
        const arg_budget = (max_cols -| prefix_w) -| 4;
        if (arg_budget >= 4) {
            var safe_arg: std.ArrayList(u8) = .empty;
            defer safe_arg.deinit(allocator);
            _ = try terminal.appendClippedText(&safe_arg, allocator, arg_summary, arg_budget);
            if (safe_arg.items.len > 0) {
                try out.append(allocator, ' ');
                try th.appendOpen(&out, allocator, theme.Theme.accent);
                try out.appendSlice(allocator, safe_arg.items);
                try th.appendClose(&out, allocator);
                arg_w = 1 + terminal.visibleWidth(safe_arg.items);
            }
        }
    }
    try out.append(allocator, ' ');

    const used = 3 + 7 + terminal.visibleWidth(safe_name.items) + 1 + arg_w + 1;
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

pub fn formatBodyBlockAlloc(
    allocator: std.mem.Allocator,
    th: theme.Theme,
    text: []const u8,
    max_lines: usize,
) !struct { text: []u8, lines_written: usize, truncated: bool } {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    var truncated = false;
    while (it.next()) |raw_line| {
        if (count >= max_lines) {
            truncated = true;
            break;
        }
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        try th.paint(&out, allocator, theme.Theme.border, "│ ");
        try terminal.appendSanitizedText(&out, allocator, line);
        try out.append(allocator, '\n');
        count += 1;
    }
    return .{
        .text = try out.toOwnedSlice(allocator),
        .lines_written = count,
        .truncated = truncated,
    };
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

    const with_arg = try formatStartWithArgAlloc(a, theme.Theme.init(.none), "edit", "src/main.zig", 60);
    defer a.free(with_arg);
    try std.testing.expect(std.mem.indexOf(u8, with_arg, "[tool: edit] src/main.zig") != null);

    const block = try formatBodyBlockAlloc(a, theme.Theme.init(.none), "one\ntwo\nthree", 2);
    defer a.free(block.text);
    try std.testing.expectEqual(@as(usize, 2), block.lines_written);
    try std.testing.expect(block.truncated);
    try std.testing.expectEqualStrings("│ one\n│ two\n", block.text);
}
