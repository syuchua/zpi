//! Main-screen line-differential renderer with synchronized output.
//! Commits finalized lines to native terminal scrollback and updates only the
//! changed tail of the active bottom viewport without entering alt-screen.
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
}
