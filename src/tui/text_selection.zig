//! Cell ranges shared by fullscreen highlighting and clipboard extraction.
const std = @import("std");
const terminal = @import("terminal.zig");

pub const Point = struct { row: usize, col: usize }; // 1-based terminal cells
pub const Row = struct {
    id: ?usize,
    wrap: usize = 0,
    prefix: usize = 0,
    width: usize = 0,
    selectable: bool = false,
};
const Columns = struct { start: usize, end: usize }; // zero-based, half-open

pub const Range = struct {
    first: Point,
    last: Point,

    pub fn init(anchor: Point, focus: Point) ?Range {
        if (std.meta.eql(anchor, focus)) return null;
        if (anchor.row < focus.row or (anchor.row == focus.row and anchor.col < focus.col)) {
            return .{ .first = anchor, .last = focus };
        }
        return .{ .first = focus, .last = anchor };
    }

    pub fn columns(self: Range, row: usize, hit: Row) ?Columns {
        if (!hit.selectable or row < self.first.row or row > self.last.row) return null;
        const start = if (row == self.first.row) @max(self.first.col - 1, hit.prefix) else hit.prefix;
        const end = if (row == self.last.row) @min(self.last.col, hit.width) else hit.width;
        return if (start < end) .{ .start = start, .end = end } else null;
    }

    pub fn copyAlloc(self: Range, allocator: std.mem.Allocator, rows: []const []u8, hits: []const ?Row) !?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var have_row = false;
        const limit = @min(self.last.row, @min(rows.len, hits.len));
        if (self.first.row > limit) return null;
        for (self.first.row..limit + 1) |row| {
            const hit = hits[row - 1] orelse continue;
            if (!hit.selectable) continue;
            if (have_row) try out.append(allocator, '\n');
            have_row = true;
            const selected = self.columns(row, hit) orelse continue;
            const start = out.items.len;
            var cells: Cells = .{ .text = rows[row - 1] };
            while (cells.next()) |chunk| {
                if (!chunk.escape and chunk.intersects(selected)) try out.appendSlice(allocator, chunk.bytes);
            }
            // User panels can contain right-side fill in their stored rows.
            out.items.len = start + std.mem.trimEnd(u8, out.items[start..], " ").len;
        }
        if (std.mem.trim(u8, out.items, "\n").len == 0) return null;
        return try out.toOwnedSlice(allocator);
    }
};

pub fn highlightAlloc(allocator: std.mem.Allocator, text: []const u8, selected: Columns) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cells: Cells = .{ .text = text };
    var active = false;
    while (cells.next()) |chunk| {
        if (chunk.escape) {
            try out.appendSlice(allocator, chunk.bytes);
            // SGR resets within styled content can turn reverse video off.
            if (active and std.mem.startsWith(u8, chunk.bytes, "\x1b[") and std.mem.endsWith(u8, chunk.bytes, "m")) {
                try out.appendSlice(allocator, "\x1b[7m");
            }
            continue;
        }
        const selected_cell = chunk.intersects(selected);
        if (active != selected_cell) {
            try out.appendSlice(allocator, if (selected_cell) "\x1b[7m" else "\x1b[27m");
            active = selected_cell;
        }
        try out.appendSlice(allocator, chunk.bytes);
    }
    if (active) try out.appendSlice(allocator, "\x1b[27m");
    return out.toOwnedSlice(allocator);
}

const Cells = struct {
    text: []const u8,
    offset: usize = 0,
    col: usize = 0,
    glyph_start: usize = 0,

    const Chunk = struct {
        bytes: []const u8,
        start: usize,
        end: usize,
        escape: bool = false,

        fn intersects(self: Chunk, columns: Columns) bool {
            return self.start < columns.end and self.end > columns.start;
        }
    };

    fn next(self: *Cells) ?Chunk {
        if (self.offset == self.text.len) return null;
        const start = self.offset;
        if (self.text[start] == '\x1b') {
            self.offset = terminal.skipEscapeSequence(self.text, start);
            return .{ .bytes = self.text[start..self.offset], .start = self.col, .end = self.col, .escape = true };
        }
        const len = std.unicode.utf8ByteSequenceLength(self.text[start]) catch 1;
        self.offset = @min(self.text.len, start + len);
        const bytes = self.text[start..self.offset];
        const cp = std.unicode.utf8Decode(bytes) catch 0xfffd;
        const width = terminal.codepointWidth(cp);
        if (width > 0) self.glyph_start = self.col;
        self.col += width;
        return .{ .bytes = bytes, .start = self.glyph_start, .end = self.col };
    }
};

test "reverse drag includes wide and combining characters without ANSI or tool gutter" {
    const allocator = std.testing.allocator;
    var first = "│ abc\x1b[31m中\x1b[0m".*;
    var hidden = "fold toggle".*;
    var last = "│ e\xcc\x81xy  ".*;
    const rows = [_][]u8{ &first, &hidden, &last };
    const hits = [_]?Row{
        .{ .id = 1, .prefix = 2, .width = 7, .selectable = true },
        .{ .id = 2 },
        .{ .id = 3, .prefix = 2, .width = 5, .selectable = true },
    };
    const range = Range.init(.{ .row = 3, .col = 3 }, .{ .row = 1, .col = 7 }).?;
    const copied = (try range.copyAlloc(allocator, &rows, &hits)).?;
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("中\ne\xcc\x81", copied);
    const styled = try highlightAlloc(allocator, &first, range.columns(1, hits[0].?).?);
    defer allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[7m中") != null);
}
