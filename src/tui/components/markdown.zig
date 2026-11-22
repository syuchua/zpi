//! Incremental Markdown line styler for streaming main-screen terminal output.
//! Preserves plain text latency and never drops or corrupts user-visible characters.
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub const MarkdownStyler = struct {
    in_code_fence: bool = false,

    pub fn hasSyntax(line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return false;
        if (std.mem.startsWith(u8, trimmed, "```")) return true;
        if (trimmed[0] == '#') return true;
        if (std.mem.startsWith(u8, trimmed, "> ")) return true;
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) return true;
        if (isHorizontalRule(trimmed)) return true;
        if (std.mem.indexOfScalar(u8, line, '`') != null) return true;
        if (std.mem.indexOf(u8, line, "**") != null) return true;
        return false;
    }

    pub fn styleLine(self: *MarkdownStyler, allocator: std.mem.Allocator, th: theme.Theme, raw_line: []const u8) ![]u8 {
        var sanitized: std.ArrayList(u8) = .empty;
        defer sanitized.deinit(allocator);
        try terminal.appendSanitizedText(&sanitized, allocator, std.mem.trimEnd(u8, raw_line, "\r"));
        const line = sanitized.items;

        if (th.mode == .none) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                self.in_code_fence = !self.in_code_fence;
            }
            return try allocator.dupe(u8, line);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            self.in_code_fence = !self.in_code_fence;
            try th.paint(&out, allocator, theme.Theme.muted, line);
            return try out.toOwnedSlice(allocator);
        }

        if (self.in_code_fence) {
            try th.paint(&out, allocator, theme.Theme.md_code, line);
            return try out.toOwnedSlice(allocator);
        }

        if (isHorizontalRule(std.mem.trim(u8, line, " \t"))) {
            try th.paint(&out, allocator, theme.Theme.border, "────────────────────────────────");
            return try out.toOwnedSlice(allocator);
        }

        if (headingLevel(trimmed)) |_| {
            try th.paint(&out, allocator, theme.Theme.md_heading, line);
            return try out.toOwnedSlice(allocator);
        }

        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const indent_len = line.len - trimmed.len;
            try out.appendSlice(allocator, line[0..indent_len]);
            try th.paint(&out, allocator, theme.Theme.border, "│ ");
            try th.paint(&out, allocator, theme.Theme.md_quote, trimmed[2..]);
            return try out.toOwnedSlice(allocator);
        }

        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            const indent_len = line.len - trimmed.len;
            try out.appendSlice(allocator, line[0..indent_len]);
            try th.paint(&out, allocator, theme.Theme.accent, "• ");
            try appendInlineStyled(&out, allocator, th, trimmed[2..]);
            return try out.toOwnedSlice(allocator);
        }

        try appendInlineStyled(&out, allocator, th, line);
        return try out.toOwnedSlice(allocator);
    }
};

fn headingLevel(trimmed: []const u8) ?usize {
    var count: usize = 0;
    while (count < trimmed.len and count < 6 and trimmed[count] == '#') : (count += 1) {}
    if (count == 0 or count >= trimmed.len) return null;
    if (trimmed[count] == ' ') return count;
    return null;
}

fn isHorizontalRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const ch = trimmed[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var count: usize = 0;
    for (trimmed) |c| {
        if (c == ch) {
            count += 1;
        } else if (c != ' ') {
            return false;
        }
    }
    return count >= 3;
}

fn appendInlineStyled(out: *std.ArrayList(u8), a: std.mem.Allocator, th: theme.Theme, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                if (end > i + 1) {
                    try th.paint(out, a, theme.Theme.md_code, text[i .. end + 1]);
                    i = end + 1;
                    continue;
                }
            }
        }
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                if (end > i + 2) {
                    try th.paint(out, a, theme.Theme.bold_only, text[i + 2 .. end]);
                    i = end + 2;
                    continue;
                }
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
}

test "MarkdownStyler styles headings, fences, inline code, bold, and blockquotes" {
    const a = std.testing.allocator;
    const th = theme.Theme.init(.ansi16);
    var styler = MarkdownStyler{};

    const h = try styler.styleLine(a, th, "## Overview");
    defer a.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1;36m## Overview\x1b[0m") != null);

    const inline_line = try styler.styleLine(a, th, "- Use **Zig** `0.17.0`");
    defer a.free(inline_line);
    try std.testing.expect(std.mem.indexOf(u8, inline_line, "• ") != null);
    try std.testing.expect(std.mem.indexOf(u8, inline_line, "Zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, inline_line, "`0.17.0`") != null);

    const f1 = try styler.styleLine(a, th, "```zig");
    defer a.free(f1);
    try std.testing.expect(styler.in_code_fence);

    const code = try styler.styleLine(a, th, "const x = 1;");
    defer a.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "\x1b[33mconst x = 1;\x1b[0m") != null);

    const f2 = try styler.styleLine(a, th, "```");
    defer a.free(f2);
    try std.testing.expect(!styler.in_code_fence);

    const plain_styler_out = try (&styler).styleLine(a, theme.Theme.init(.none), "## Plain");
    defer a.free(plain_styler_out);
    try std.testing.expectEqualStrings("## Plain", plain_styler_out);
}
