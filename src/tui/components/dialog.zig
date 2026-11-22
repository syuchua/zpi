//! Dismissible inline dialog box component for `/help` and `/hotkeys`.
//! Renders inside the main screen viewport and retracts cleanly on dismiss.
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub const DialogSpec = struct {
    title: []const u8,
    lines: []const []const u8,
    hint: []const u8 = "Esc/Enter/type to close",
};

pub const help_lines = [_][]const u8{
    "Enter a task to stream a response and run tools. /exit leaves.",
    "Use --session PATH to reopen; --branch ENTRY-ID switches branches.",
    "Tab completes /commands and @paths; Up/Down history; Alt+Enter newline.",
};

pub const hotkeys_lines = [_][]const u8{
    "Enter       Submit prompt (or queue follow-up while busy)",
    "Ctrl-C      Cancel current turn or clear prompt",
    "Ctrl-D      Exit on empty line / delete char",
    "Ctrl-O      Toggle compact/expanded thinking and tool output",
    "Ctrl-S      Steer active turn mid-execution (while busy)",
    "Up/Down     Navigate history or lines",
    "Left/Right  Move cursor (Ctrl-A/E home/end, Ctrl-W/U/K delete)",
    "Tab         Complete /command or @path",
    "Shift+Tab   Cycle thinking level (off -> minimal -> ... -> max)",
    "Alt+Enter   Insert newline (or trailing \\)",
    "Alt+Up      Edit queued follow-up messages",
    "Esc         Clear draft while busy / dismiss overlay",
    "/model      Fuzzy model picker (/model [ref] | --list)",
    "/thinking   Set thinking level (/thinking [level])",
    "/tree       Branch picker (/ filter, p prefill, s summary, Enter)",
    "/compact    Summarize older context (/compact [focus])",
    "/jobs       List background tasks (/jobs [id])",
    "/resume     Resume a previous session (/resume [path] | --list)",
    "/session    Session summary  ·  /help  Help  ·  /exit  Exit",
};

pub fn renderLinesAlloc(
    allocator: std.mem.Allocator,
    th: theme.Theme,
    spec: DialogSpec,
    cols_raw: usize,
) ![][]u8 {
    const max_cols = @max(12, cols_raw -| 1);

    var content_w = terminal.visibleWidth(spec.title) + 4;
    if (spec.hint.len > 0) {
        content_w = @max(content_w, terminal.visibleWidth(spec.hint) + 4);
    }
    for (spec.lines) |line| {
        content_w = @max(content_w, terminal.visibleWidth(line));
    }
    const inner_w = @min(content_w, max_cols -| 4);
    const box_w = inner_w + 4;

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |l| allocator.free(l);
        out.deinit(allocator);
    }

    // Top border: ╭─ Title ───╮
    {
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(allocator);
        try th.paint(&row, allocator, theme.Theme.border, "╭─ ");
        try th.appendOpen(&row, allocator, theme.Theme.accent);
        const title_w = try terminal.appendClippedText(&row, allocator, spec.title, inner_w);
        try th.appendClose(&row, allocator);
        const rem = box_w -| (3 + title_w + 1);
        if (rem > 0) {
            try th.appendOpen(&row, allocator, theme.Theme.border);
            try row.append(allocator, ' ');
            var i: usize = 1;
            while (i < rem) : (i += 1) try row.appendSlice(allocator, "─");
            try row.appendSlice(allocator, "╮");
            try th.appendClose(&row, allocator);
        }
        try out.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Body lines: │ <text>    │
    for (spec.lines) |line| {
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(allocator);
        try th.paint(&row, allocator, theme.Theme.border, "│ ");
        const used = try terminal.appendClippedText(&row, allocator, line, inner_w);
        if (used < inner_w) {
            for (0..inner_w - used) |_| try row.append(allocator, ' ');
        }
        try th.paint(&row, allocator, theme.Theme.border, " │");
        try out.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Bottom border: ╰─── hint ─╯
    {
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(allocator);
        const hint_w = @min(terminal.visibleWidth(spec.hint), inner_w -| 1);
        const overhead: usize = if (hint_w > 0) 5 else 2;
        const dashes = box_w -| (hint_w + overhead);
        try th.appendOpen(&row, allocator, theme.Theme.border);
        try row.appendSlice(allocator, "╰");
        for (0..dashes) |_| try row.appendSlice(allocator, "─");
        try th.appendClose(&row, allocator);
        if (hint_w > 0) {
            try row.append(allocator, ' ');
            try th.appendOpen(&row, allocator, theme.Theme.muted);
            const actual_hint_w = try terminal.appendClippedText(&row, allocator, spec.hint, hint_w);
            try th.appendClose(&row, allocator);
            if (actual_hint_w < hint_w) {
                try th.appendOpen(&row, allocator, theme.Theme.border);
                for (0..hint_w - actual_hint_w) |_| try row.appendSlice(allocator, "─");
                try th.appendClose(&row, allocator);
            }
            try th.paint(&row, allocator, theme.Theme.border, " ─╯");
        } else {
            try th.paint(&row, allocator, theme.Theme.border, "╯");
        }
        try out.append(allocator, try row.toOwnedSlice(allocator));
    }

    return try out.toOwnedSlice(allocator);
}

test "PopupDialog renders width-bounded bordered cards and honors NO_COLOR" {
    const a = std.testing.allocator;
    const lines = try renderLinesAlloc(
        a,
        theme.Theme.init(.none),
        .{ .title = "Keyboard shortcuts", .lines = &hotkeys_lines },
        80,
    );
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expectEqual(hotkeys_lines.len + 2, lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "Keyboard shortcuts") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "Submit prompt") != null);
    for (lines) |l| {
        try std.testing.expect(std.mem.indexOf(u8, l, "\x1b[") == null);
        try std.testing.expect(terminal.visibleWidth(l) <= 79);
    }

    const narrow = try renderLinesAlloc(
        a,
        theme.Theme.init(.ansi16),
        .{ .title = "Help", .lines = &help_lines },
        24,
    );
    defer {
        for (narrow) |l| a.free(l);
        a.free(narrow);
    }
    for (narrow) |l| {
        try std.testing.expect(terminal.visibleWidth(l) <= 23);
    }
}
