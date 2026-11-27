//! Cell ranges shared by fullscreen highlighting and clipboard extraction.
const std = @import("std");
const terminal = @import("terminal.zig");

pub const Point = struct { row: usize, col: usize }; // 1-based terminal cells
pub const Row = struct {
    id: ?usize,
    wrap_from_end: usize = 0,
    prefix: usize = 0,
    width: usize = 0,
    selectable: bool = false,
    fingerprint: u64 = 0,
};
const Columns = struct { start: usize, end: usize }; // zero-based, half-open

/// The press stays fixed even when the pointer crosses it.
pub const Gesture = struct {
    anchor: Point,
    focus: Point,
    selectable: bool,
    moved: bool = false,

    pub fn move(self: *Gesture, focus: Point) void {
        self.moved = self.moved or !std.meta.eql(self.anchor, focus);
        self.focus = focus;
    }

    pub fn range(self: Gesture) ?Range {
        if (!self.selectable) return null;
        return Range.init(self.anchor, self.focus);
    }

    pub fn sameRows(previous: []const ?Row, current: []const ?Row) bool {
        if (previous.len != current.len) return false;
        for (previous, current) |old, new| {
            if (old == null or new == null) {
                if (old != null or new != null) return false;
                continue;
            }
            const a = old.?;
            const b = new.?;
            if (a.id != b.id or a.wrap_from_end != b.wrap_from_end or a.prefix != b.prefix or
                a.width != b.width or a.selectable != b.selectable or a.fingerprint != b.fingerprint) return false;
        }
        return true;
    }
};

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

    pub fn copyAlloc(self: Range, allocator: std.mem.Allocator, hits: []const ?Row, painted: []const []const u8) !?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var have_row = false;
        const limit = @min(self.last.row, hits.len, painted.len);
        if (self.first.row > limit) return null;
        for (self.first.row..limit + 1) |row| {
            const hit = hits[row - 1] orelse continue;
            if (!hit.selectable) continue;
            const selected = self.columns(row, hit);
            if (have_row) try out.append(allocator, '\n');
            have_row = true;
            if (selected) |cols| {
                var cells: Cells = .{ .text = painted[row - 1] };
                while (cells.next()) |chunk| {
                    if (!chunk.escape and chunk.intersects(cols)) try out.appendSlice(allocator, chunk.bytes);
                }
            }
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
    const painted = [_][]const u8{ "│ abc\x1b[31m中\x1b[0m", "fold toggle", "│ e\xcc\x81xy  " };
    const hits = [_]?Row{
        .{ .id = 1, .prefix = 2, .width = 7, .selectable = true },
        .{ .id = 2 },
        .{ .id = 3, .prefix = 2, .width = 5, .selectable = true },
    };
    const range = Range.init(.{ .row = 3, .col = 3 }, .{ .row = 1, .col = 7 }).?;
    const copied = (try range.copyAlloc(allocator, &hits, &painted)).?;
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("中\ne\xcc\x81", copied);
    const styled = try highlightAlloc(allocator, painted[0], range.columns(1, hits[0].?).?);
    defer allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[7m中") != null);
}

test "frame changes cancel gestures even when the text width stays the same" {
    const previous = [_]?Row{.{ .id = 1, .width = 5, .selectable = true, .fingerprint = 1 }};
    var current = previous;
    try std.testing.expect(Gesture.sameRows(&previous, &current));
    current[0].?.fingerprint = 2;
    try std.testing.expect(!Gesture.sameRows(&previous, &current));
    current = previous;
    current[0].?.wrap_from_end = 1;
    try std.testing.expect(!Gesture.sameRows(&previous, &current));
}

test "copy preserves content spaces while excluding panel fill" {
    const allocator = std.testing.allocator;
    const painted = [_][]const u8{"│ a b    "};
    const hits = [_]?Row{.{ .id = 1, .prefix = 2, .width = 5, .selectable = true }};
    const range = Range.init(.{ .row = 1, .col = 3 }, .{ .row = 1, .col = 9 }).?;
    const copied = (try range.copyAlloc(allocator, &hits, &painted)).?;
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("a b", copied);
}

test "crossing and returning to the press keeps the original anchor" {
    const anchor: Point = .{ .row = 2, .col = 5 };
    var gesture: Gesture = .{ .anchor = anchor, .focus = anchor, .selectable = true };
    gesture.move(.{ .row = 2, .col = 2 });
    try std.testing.expectEqual(anchor, gesture.range().?.last);
    gesture.move(.{ .row = 3, .col = 2 });
    try std.testing.expectEqual(anchor, gesture.range().?.first);
    gesture.move(anchor);
    try std.testing.expect(gesture.range() == null and gesture.moved);
}
