//! Main-screen line-differential renderer with synchronized output.
//! Commits finalized lines to native terminal scrollback and updates only the
//! changed tail of the active bottom viewport without entering alt-screen.
//! Also provides `FullscreenRenderer`, a retained row-differential painter for
//! the alternate screen that never scrolls, autowraps, or repaints clean rows.
const std = @import("std");
const terminal = @import("terminal.zig");

pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const MainScreenRenderer = struct {
    allocator: std.mem.Allocator,
    synchronized_output: bool = true,
    previous_lines: std.ArrayList([]u8) = .empty,
    previous_cursor: Cursor = .{},
    previous_cols: usize = 0,

    pub fn init(allocator: std.mem.Allocator, synchronized_output: bool) MainScreenRenderer {
        return .{ .allocator = allocator, .synchronized_output = synchronized_output };
    }

    pub fn deinit(self: *MainScreenRenderer) void {
        self.clearState();
        self.previous_lines.deinit(self.allocator);
    }

    fn clearState(self: *MainScreenRenderer) void {
        for (self.previous_lines.items) |line| self.allocator.free(line);
        self.previous_lines.clearRetainingCapacity();
        self.previous_cursor = .{};
    }

    /// Render `new_lines` into the live viewport using line-level diffing
    /// against the previous frame. Returns owned ANSI byte sequence.
    pub fn renderViewportAlloc(
        self: *MainScreenRenderer,
        new_lines: []const []const u8,
        cursor: Cursor,
        cols_raw: usize,
    ) ![]u8 {
        const cols = @max(cols_raw, 4);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        const has_prev = self.previous_lines.items.len > 0;
        if (!has_prev and new_lines.len == 0) {
            return try out.toOwnedSlice(self.allocator);
        }
        const resized = has_prev and cols != self.previous_cols;

        var first_diff: usize = 0;
        if (has_prev and !resized) {
            const common = @min(self.previous_lines.items.len, new_lines.len);
            while (first_diff < common and std.mem.eql(u8, self.previous_lines.items[first_diff], new_lines[first_diff])) : (first_diff += 1) {}
            if (first_diff == common and self.previous_lines.items.len == new_lines.len) {
                if (cursor.row == self.previous_cursor.row and cursor.col == self.previous_cursor.col) {
                    return try out.toOwnedSlice(self.allocator);
                }
                if (self.synchronized_output) try out.appendSlice(self.allocator, sync_begin);
                try appendCursorMove(&out, self.allocator, self.previous_cursor, cursor);
                if (self.synchronized_output) try out.appendSlice(self.allocator, sync_end);
                self.previous_cursor = cursor;
                self.previous_cols = cols;
                return try out.toOwnedSlice(self.allocator);
            }
        }

        if (self.synchronized_output) try out.appendSlice(self.allocator, sync_begin);
        if (resized) {
            try out.appendSlice(self.allocator, "\r\n");
            first_diff = 0;
        } else if (has_prev) {
            if (self.previous_cursor.row > first_diff) {
                try out.print(self.allocator, "\x1b[{d}A", .{self.previous_cursor.row - first_diff});
            } else if (self.previous_cursor.row < first_diff) {
                try out.print(self.allocator, "\x1b[{d}B", .{first_diff - self.previous_cursor.row});
            }
            try out.appendSlice(self.allocator, "\r\x1b[J");
        }

        if (new_lines.len > 0) {
            if (first_diff < new_lines.len) {
                for (new_lines[first_diff..], first_diff..) |line, idx| {
                    if (idx > first_diff) try out.appendSlice(self.allocator, "\r\n");
                    try out.appendSlice(self.allocator, line);
                }
                const end_row = new_lines.len - 1;
                const end_col = terminal.visibleWidth(new_lines[end_row]);
                try appendCursorMove(&out, self.allocator, .{ .row = end_row, .col = end_col }, cursor);
            } else {
                // Viewport shrank; cursor currently sits at `(first_diff, 0)`.
                try appendCursorMove(&out, self.allocator, .{ .row = first_diff, .col = 0 }, cursor);
            }
        }
        if (self.synchronized_output) try out.appendSlice(self.allocator, sync_end);

        try self.replacePrevious(new_lines, cursor, cols);
        return try out.toOwnedSlice(self.allocator);
    }

    /// Permanently commit `committed_lines` into native terminal scrollback,
    /// erasing any previous live viewport first, and optionally paint `next_viewport`.
    pub fn commitAndRenderAlloc(
        self: *MainScreenRenderer,
        committed_lines: []const []const u8,
        next_viewport: []const []const u8,
        cursor: Cursor,
        cols_raw: usize,
    ) ![]u8 {
        const cols = @max(cols_raw, 4);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        if (committed_lines.len == 0 and self.previous_lines.items.len == 0 and next_viewport.len == 0) {
            return try out.toOwnedSlice(self.allocator);
        }

        if (self.synchronized_output) try out.appendSlice(self.allocator, sync_begin);
        if (self.previous_lines.items.len > 0) {
            if (self.previous_cursor.row > 0) {
                try out.print(self.allocator, "\x1b[{d}A", .{self.previous_cursor.row});
            }
            try out.appendSlice(self.allocator, "\r\x1b[J");
            self.clearState();
        }
        for (committed_lines) |line| {
            try out.appendSlice(self.allocator, line);
            try out.appendSlice(self.allocator, "\r\n");
        }
        if (next_viewport.len > 0) {
            for (next_viewport, 0..) |line, idx| {
                if (idx > 0) try out.appendSlice(self.allocator, "\r\n");
                try out.appendSlice(self.allocator, line);
            }
            const end_row = next_viewport.len - 1;
            const end_col = terminal.visibleWidth(next_viewport[end_row]);
            try appendCursorMove(&out, self.allocator, .{ .row = end_row, .col = end_col }, cursor);
            try self.replacePrevious(next_viewport, cursor, cols);
        }
        if (self.synchronized_output) try out.appendSlice(self.allocator, sync_end);
        return try out.toOwnedSlice(self.allocator);
    }

    pub fn clearViewportAlloc(self: *MainScreenRenderer) ![]u8 {
        return self.renderViewportAlloc(&.{}, .{}, if (self.previous_cols > 0) self.previous_cols else 80);
    }

    pub fn renderViewport(
        self: *MainScreenRenderer,
        io: std.Io,
        output: std.Io.File,
        new_lines: []const []const u8,
        cursor: Cursor,
        cols: usize,
    ) !void {
        const bytes = try self.renderViewportAlloc(new_lines, cursor, cols);
        defer self.allocator.free(bytes);
        if (bytes.len > 0) try output.writeStreamingAll(io, bytes);
    }

    pub fn commitAndRender(
        self: *MainScreenRenderer,
        io: std.Io,
        output: std.Io.File,
        committed_lines: []const []const u8,
        next_viewport: []const []const u8,
        cursor: Cursor,
        cols: usize,
    ) !void {
        const bytes = try self.commitAndRenderAlloc(committed_lines, next_viewport, cursor, cols);
        defer self.allocator.free(bytes);
        if (bytes.len > 0) try output.writeStreamingAll(io, bytes);
    }

    pub fn clearViewport(self: *MainScreenRenderer, io: std.Io, output: std.Io.File) !void {
        const bytes = try self.clearViewportAlloc();
        defer self.allocator.free(bytes);
        if (bytes.len > 0) try output.writeStreamingAll(io, bytes);
    }

    fn replacePrevious(self: *MainScreenRenderer, new_lines: []const []const u8, cursor: Cursor, cols: usize) !void {
        self.clearState();
        try self.previous_lines.ensureTotalCapacity(self.allocator, new_lines.len);
        for (new_lines) |line| {
            self.previous_lines.appendAssumeCapacity(try self.allocator.dupe(u8, line));
        }
        self.previous_cursor = cursor;
        self.previous_cols = cols;
    }
};

/// Retained, row-differential painter for a full-screen (alternate screen) UI.
///
/// Each frame supplies one already-clipped ANSI row per terminal row. Rows are
/// compared against the last painted frame and only changed rows are rewritten
/// at their absolute position, with a style reset and an erase-to-end-of-line so
/// stale suffixes disappear. Nothing is scrolled and nothing autowraps (rows are
/// clipped by the caller); an identical frame with an unchanged cursor emits
/// zero bytes.
///
/// Out-of-band writes (dialogs, autocomplete popups, shell output, ...) must call
/// `invalidate` so the next frame repaints every row instead of diffing against
/// a screen that no longer matches the retained rows.
pub const FullscreenRenderer = struct {
    allocator: std.mem.Allocator,
    synchronized_output: bool = true,
    rows: std.ArrayList([]u8) = .empty,
    painted: bool = false,
    cols: usize = 0,
    cursor: ?Cursor = null,
    /// Test-only hook that makes row retention fail after the bytes are built.
    store_fail_for_test: bool = false,

    pub fn init(allocator: std.mem.Allocator, synchronized_output: bool) FullscreenRenderer {
        return .{ .allocator = allocator, .synchronized_output = synchronized_output };
    }

    pub fn deinit(self: *FullscreenRenderer) void {
        self.dropRows();
        self.rows.deinit(self.allocator);
    }

    /// Forget what is on screen so the next frame is a full repaint.
    pub fn invalidate(self: *FullscreenRenderer) void {
        self.dropRows();
        self.painted = false;
        self.cursor = null;
    }

    /// True when the next frame would repaint every row.
    pub fn needsFullPaint(self: *const FullscreenRenderer) bool {
        return !self.painted;
    }

    /// Number of rows currently retained as the on-screen truth.
    pub fn paintedRows(self: *const FullscreenRenderer) usize {
        return if (self.painted) self.rows.items.len else 0;
    }

    fn dropRows(self: *FullscreenRenderer) void {
        for (self.rows.items) |row| self.allocator.free(row);
        self.rows.clearRetainingCapacity();
    }

    /// Paint `frame` (one entry per terminal row, each already clipped to the
    /// terminal width) at absolute positions and park the cursor at `cursor`.
    /// Returns owned bytes; an unchanged frame and cursor produce none.
    ///
    /// A row is repainted whenever its bytes differ, even when the cursor did
    /// not move (steady streaming keeps the cursor on the same editor cell).
    pub fn renderAlloc(self: *FullscreenRenderer, frame: []const []const u8, cursor: ?Cursor, cols_raw: usize) ![]u8 {
        const cols = @max(cols_raw, 4);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        // Rewriting every row (not just changed rows) is required when nothing
        // is on screen yet, when the geometry changed, or when the row count
        // shrank so trailing rows must be erased.
        const relayout = !self.painted or frame.len != self.rows.items.len or cols != self.cols;
        var changed = false;
        if (!relayout) {
            for (frame, self.rows.items) |row, previous| {
                if (!std.mem.eql(u8, row, previous)) {
                    changed = true;
                    break;
                }
            }
        }
        if (!relayout and !changed and std.meta.eql(self.cursor, cursor)) {
            return try out.toOwnedSlice(self.allocator);
        }

        if (self.synchronized_output) try out.appendSlice(self.allocator, sync_begin);
        if (relayout) {
            // Repaint every row, then erase rows the previous frame owned past
            // the new height so no stale line can survive a shrink.
            try out.appendSlice(self.allocator, "\x1b[H");
            for (frame, 0..) |row, index| try self.paintRow(&out, index, row);
            if (self.painted and self.rows.items.len > frame.len) {
                try out.print(self.allocator, "\x1b[{d};1H\x1b[J", .{frame.len + 1});
            }
        } else {
            for (frame, 0..) |row, index| {
                if (std.mem.eql(u8, row, self.rows.items[index])) continue;
                try self.paintRow(&out, index, row);
            }
        }
        if (cursor) |target| {
            try out.print(self.allocator, "\x1b[{d};{d}H", .{ target.row + 1, target.col + 1 });
        } else {
            try out.appendSlice(self.allocator, "\x1b[0m");
        }
        if (self.synchronized_output) try out.appendSlice(self.allocator, sync_end);
        const bytes = try out.toOwnedSlice(self.allocator);
        // The bytes now exist, so the retained rows must match them exactly.
        // A failed retention drops the snapshot instead of keeping a partial
        // truth that later diffs would trust.
        self.store(frame, cursor, cols) catch |err| {
            self.allocator.free(bytes);
            self.invalidate();
            return err;
        };
        return bytes;
    }

    /// Address one row, write it, reset styles and clear any stale suffix.
    fn paintRow(self: *FullscreenRenderer, out: *std.ArrayList(u8), index: usize, row: []const u8) !void {
        try out.print(self.allocator, "\x1b[{d};1H", .{index + 1});
        if (row.len > 0) try out.appendSlice(self.allocator, row);
        try out.appendSlice(self.allocator, "\x1b[0m\x1b[K");
    }

    /// Record the painted frame. Rows that are byte-identical to the retained
    /// ones keep their existing allocation so steady streaming does not copy
    /// the whole screen on every frame.
    fn store(self: *FullscreenRenderer, frame: []const []const u8, cursor: ?Cursor, cols: usize) !void {
        if (self.store_fail_for_test) return error.OutOfMemory;
        const reusable = self.painted and self.rows.items.len == frame.len;
        // A height change must not append onto the rows of the old frame.
        if (!reusable) self.dropRows();
        try self.rows.ensureTotalCapacity(self.allocator, frame.len);
        for (frame, 0..) |row, index| {
            if (reusable and std.mem.eql(u8, row, self.rows.items[index])) continue;
            const owned = try self.allocator.dupe(u8, row);
            if (reusable) {
                self.allocator.free(self.rows.items[index]);
                self.rows.items[index] = owned;
            } else {
                self.rows.appendAssumeCapacity(owned);
            }
        }
        self.painted = true;
        self.cols = cols;
        self.cursor = cursor;
    }

    pub fn render(self: *FullscreenRenderer, io: std.Io, output: std.Io.File, frame: []const []const u8, cursor: ?Cursor, cols: usize) !void {
        const bytes = try self.renderAlloc(frame, cursor, cols);
        defer self.allocator.free(bytes);
        if (bytes.len > 0) try output.writeStreamingAll(io, bytes);
    }
};

fn appendCursorMove(out: *std.ArrayList(u8), a: std.mem.Allocator, from: Cursor, to: Cursor) !void {
    if (from.row > to.row) {
        try out.print(a, "\x1b[{d}A", .{from.row - to.row});
    } else if (from.row < to.row) {
        try out.print(a, "\x1b[{d}B", .{to.row - from.row});
    }
    if (from.col != to.col or from.row != to.row) {
        try out.append(a, '\r');
        if (to.col > 0) try out.print(a, "\x1b[{d}C", .{to.col});
    }
}

test "MainScreenRenderer performs synchronized line-diff updates and no-ops on identical frames" {
    const a = std.testing.allocator;
    var r = MainScreenRenderer.init(a, true);
    defer r.deinit();

    const frame1 = [_][]const u8{ "header", "body one", "footer" };
    const b1 = try r.renderViewportAlloc(&frame1, .{ .row = 1, .col = 4 }, 80);
    defer a.free(b1);
    try std.testing.expectEqualStrings(
        sync_begin ++ "header\r\nbody one\r\nfooter\x1b[1A\r\x1b[4C" ++ sync_end,
        b1,
    );

    // Identical frame and cursor produces zero bytes.
    const b2 = try r.renderViewportAlloc(&frame1, .{ .row = 1, .col = 4 }, 80);
    defer a.free(b2);
    try std.testing.expectEqual(@as(usize, 0), b2.len);

    // Changing only line 2 leaves line 0 ("header") untouched and rewrites from line 1.
    const frame2 = [_][]const u8{ "header", "body two", "footer" };
    const b3 = try r.renderViewportAlloc(&frame2, .{ .row = 2, .col = 6 }, 80);
    defer a.free(b3);
    try std.testing.expectEqualStrings(
        sync_begin ++ "\r\x1b[Jbody two\r\nfooter" ++ sync_end,
        b3,
    );

    // Shrinking frame erases trailing lines and places cursor cleanly.
    const frame3 = [_][]const u8{"header"};
    const b4 = try r.renderViewportAlloc(&frame3, .{ .row = 0, .col = 6 }, 80);
    defer a.free(b4);
    try std.testing.expectEqualStrings(
        sync_begin ++ "\x1b[1A\r\x1b[J\x1b[1A\r\x1b[6C" ++ sync_end,
        b4,
    );
}

test "MainScreenRenderer commits scrollback lines and resets viewport on resize" {
    const a = std.testing.allocator;
    var r = MainScreenRenderer.init(a, false);
    defer r.deinit();

    const vp = [_][]const u8{ "status", "> edit" };
    const init_bytes = try r.renderViewportAlloc(&vp, .{ .row = 1, .col = 6 }, 80);
    defer a.free(init_bytes);

    const committed = [_][]const u8{"Assistant: done"};
    const commit_bytes = try r.commitAndRenderAlloc(&committed, &.{"> next"}, .{ .row = 0, .col = 6 }, 80);
    defer a.free(commit_bytes);
    try std.testing.expectEqualStrings(
        "\x1b[1A\r\x1b[JAssistant: done\r\n> next",
        commit_bytes,
    );

    // Resize emits a clean newline separator instead of moving up over reflowed lines.
    const resized = try r.renderViewportAlloc(&.{"> next"}, .{ .row = 0, .col = 6 }, 40);
    defer a.free(resized);
    try std.testing.expectEqualStrings("\r\n> next", resized);

    // Clearing retracts the viewport and becomes a zero-byte no-op afterward.
    const cleared = try r.clearViewportAlloc();
    defer a.free(cleared);
    try std.testing.expectEqualStrings("\r\x1b[J", cleared);

    const cleared_again = try r.clearViewportAlloc();
    defer a.free(cleared_again);
    try std.testing.expectEqual(@as(usize, 0), cleared_again.len);
}

test "FullscreenRenderer paints every row once and then only changed rows at absolute positions" {
    const a = std.testing.allocator;
    var r = FullscreenRenderer.init(a, true);
    defer r.deinit();
    try std.testing.expect(r.needsFullPaint());

    const frame1 = [_][]const u8{ "header", "body", "footer" };
    const cursor: Cursor = .{ .row = 2, .col = 2 };
    const b1 = try r.renderAlloc(&frame1, cursor, 80);
    defer a.free(b1);
    try std.testing.expectEqualStrings(
        sync_begin ++ "\x1b[H" ++
            "\x1b[1;1Hheader\x1b[0m\x1b[K" ++
            "\x1b[2;1Hbody\x1b[0m\x1b[K" ++
            "\x1b[3;1Hfooter\x1b[0m\x1b[K" ++
            "\x1b[3;3H" ++ sync_end,
        b1,
    );
    try std.testing.expect(!r.needsFullPaint());
    try std.testing.expectEqual(@as(usize, 3), r.paintedRows());

    // Only the changed row is addressed; unchanged rows are skipped entirely.
    const frame2 = [_][]const u8{ "header", "BODY!", "footer" };
    const b2 = try r.renderAlloc(&frame2, cursor, 80);
    defer a.free(b2);
    try std.testing.expectEqualStrings(sync_begin ++ "\x1b[2;1HBODY!\x1b[0m\x1b[K\x1b[3;3H" ++ sync_end, b2);
    // Exactly one row address was emitted for the single changed row.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, b2, "\x1b[2;1H"));

    // Identical rows and cursor: nothing is emitted at all.
    const b3 = try r.renderAlloc(&frame2, cursor, 80);
    defer a.free(b3);
    try std.testing.expectEqual(@as(usize, 0), b3.len);

    // Same rows but a moved cursor still costs only one absolute cursor move.
    const b4 = try r.renderAlloc(&frame2, .{ .row = 2, .col = 0 }, 80);
    defer a.free(b4);
    try std.testing.expectEqualStrings(sync_begin ++ "\x1b[3;1H" ++ sync_end, b4);
}

test "FullscreenRenderer repaints a changed row even when the cursor never moves" {
    // Streaming keeps the caret parked on the same editor cell while the
    // transcript above it changes; that must not be mistaken for a clean frame.
    const a = std.testing.allocator;
    var r = FullscreenRenderer.init(a, true);
    defer r.deinit();
    const cursor: Cursor = .{ .row = 3, .col = 5 };

    const first = [_][]const u8{ "prompt", "assistant", "", "> " };
    const b1 = try r.renderAlloc(&first, cursor, 80);
    defer a.free(b1);
    try std.testing.expect(std.mem.indexOf(u8, b1, "\x1b[2;1Hassistant") != null);

    var streamed = [_][]const u8{ "prompt", "assistant token", "", "> " };
    const b2 = try r.renderAlloc(&streamed, cursor, 80);
    defer a.free(b2);
    try std.testing.expect(b2.len > 0);
    try std.testing.expectEqualStrings(sync_begin ++ "\x1b[2;1Hassistant token\x1b[0m\x1b[K\x1b[4;6H" ++ sync_end, b2);

    streamed[1] = "assistant token two";
    const b3 = try r.renderAlloc(&streamed, cursor, 80);
    defer a.free(b3);
    try std.testing.expect(std.mem.indexOf(u8, b3, "\x1b[2;1Hassistant token two\x1b[0m\x1b[K") != null);
    // The streamed updates are far smaller than repainting the whole screen.
    const full = try r.renderAlloc(&streamed, cursor, 80);
    defer a.free(full);
    try std.testing.expect(b3.len < b1.len);

    // A shorter row must erase its stale suffix on the same paint.
    streamed[1] = "assistant";
    const b4 = try r.renderAlloc(&streamed, cursor, 80);
    defer a.free(b4);
    try std.testing.expectEqualStrings(sync_begin ++ "\x1b[2;1Hassistant\x1b[0m\x1b[K\x1b[4;6H" ++ sync_end, b4);
    try std.testing.expect(std.mem.endsWith(u8, b4, "\x1b[0m\x1b[K\x1b[4;6H" ++ sync_end));
}

test "FullscreenRenderer repaints fully on first frame, width change, shrink and invalidation" {
    const a = std.testing.allocator;
    var r = FullscreenRenderer.init(a, false);
    defer r.deinit();

    const tall = [_][]const u8{ "one", "two", "three" };
    const b1 = try r.renderAlloc(&tall, .{ .row = 0, .col = 1 }, 80);
    defer a.free(b1);
    try std.testing.expect(std.mem.indexOf(u8, b1, "H\x1b[1;1Hone") != null);

    // A width change invalidates the assumption that clipped rows still fit.
    const wide = try r.renderAlloc(&tall, .{ .row = 0, .col = 1 }, 40);
    defer a.free(wide);
    try std.testing.expect(std.mem.indexOf(u8, wide, "H\x1b[1;1Hone\x1b[0m\x1b[K\x1b[2;1Htwo") != null);

    // Shrinking erases the rows the previous frame owned past the new height.
    const short = [_][]const u8{ "one", "two" };
    const settled_cursor: Cursor = .{ .row = 1, .col = 0 };
    const shrink = try r.renderAlloc(&short, settled_cursor, 40);
    defer a.free(shrink);
    try std.testing.expect(std.mem.indexOf(u8, shrink, "\x1b[3;1H\x1b[J") != null);

    // The shrunken frame is now the retained truth, so repeating it is a no-op.
    const clean = try r.renderAlloc(&short, settled_cursor, 40);
    defer a.free(clean);
    try std.testing.expectEqual(@as(usize, 0), clean.len);

    // Out-of-band writes invalidate the retained rows; the next frame is full.
    r.invalidate();
    try std.testing.expect(r.needsFullPaint());
    try std.testing.expectEqual(@as(usize, 0), r.paintedRows());
    const after = try r.renderAlloc(&short, .{ .row = 1, .col = 0 }, 40);
    defer a.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "H\x1b[1;1Hone\x1b[0m\x1b[K\x1b[2;1Htwo") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\x1b[J") == null);
}

test "FullscreenRenderer rows never overwrite each other and blank rows stay empty" {
    const a = std.testing.allocator;
    var r = FullscreenRenderer.init(a, false);
    defer r.deinit();

    const frame = [_][]const u8{ "", "", "\x1b[1mbold\x1b[0m" };
    const b1 = try r.renderAlloc(&frame, .{ .row = 2, .col = 0 }, 80);
    defer a.free(b1);
    // Empty rows cost one address plus the reset/erase suffix, never a payload.
    try std.testing.expectEqualStrings(
        "\x1b[H" ++
            "\x1b[1;1H\x1b[0m\x1b[K" ++
            "\x1b[2;1H\x1b[0m\x1b[K" ++
            "\x1b[3;1H\x1b[1mbold\x1b[0m\x1b[0m\x1b[K" ++
            "\x1b[3;1H",
        b1,
    );
}

test "FullscreenRenderer drops its snapshot instead of trusting a partial store" {
    const a = std.testing.allocator;
    var r = FullscreenRenderer.init(a, false);
    defer r.deinit();
    const frame = [_][]const u8{ "one", "two" };
    const b1 = try r.renderAlloc(&frame, .{ .row = 0, .col = 0 }, 80);
    defer a.free(b1);
    try std.testing.expect(!r.needsFullPaint());

    // Force the retention path to fail: the painted bytes are not returned and
    // the renderer must forget everything so the next frame is a full paint.
    r.store_fail_for_test = true;
    try std.testing.expectError(error.OutOfMemory, r.renderAlloc(&.{ "one", "TWO" }, .{ .row = 0, .col = 0 }, 80));
    try std.testing.expect(r.needsFullPaint());
    try std.testing.expectEqual(@as(usize, 0), r.paintedRows());

    r.store_fail_for_test = false;
    const recovered = try r.renderAlloc(&.{ "one", "TWO" }, .{ .row = 0, .col = 0 }, 80);
    defer a.free(recovered);
    try std.testing.expect(std.mem.indexOf(u8, recovered, "\x1b[2;1HTWO") != null);
}
