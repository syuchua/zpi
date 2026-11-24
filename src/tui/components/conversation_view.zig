//! Bounded transcript and stable scroll anchor for the fullscreen TUI.
const std = @import("std");
const terminal = @import("../terminal.zig");

pub const ConversationView = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    hit_rows: std.ArrayList(?usize) = .empty,
    popup_row: usize = 0,
    popup_rows: usize = 0,
    frame_size: std.posix.winsize = std.mem.zeroes(std.posix.winsize),
    first: usize = 0,
    pinned_user: ?[]u8 = null,
    pending: std.ArrayList(u8) = .empty,
    pending_clipped: bool = false,
    // Absolute exclusive end of the page being read. Null follows the live tail.
    anchor: ?usize = null,
    first_id: usize = 0,
    body_height: usize = 1,

    const Line = struct {
        text: []u8,
        tool_id: ?[]u8 = null,

        fn deinit(self: Line, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            if (self.tool_id) |id| allocator.free(id);
        }
    };

    const max_lines = 8192;
    const max_line_bytes = 8192;

    pub fn init(allocator: std.mem.Allocator) ConversationView {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConversationView) void {
        self.clear();
        self.lines.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.hit_rows.deinit(self.allocator);
    }

    pub fn clear(self: *ConversationView) void {
        for (self.lines.items) |line| line.deinit(self.allocator);
        self.hit_rows.clearRetainingCapacity();
        self.popup_rows = 0;
        self.lines.clearRetainingCapacity();
        self.first = 0;
        self.first_id = 0;
        self.anchor = null;
        self.pending.clearRetainingCapacity();
        self.pending_clipped = false;
        if (self.pinned_user) |text| self.allocator.free(text);
        self.pinned_user = null;
    }

    pub fn setPinnedUser(self: *ConversationView, text: []const u8) !void {
        const first_line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        var clipped: std.ArrayList(u8) = .empty;
        defer clipped.deinit(self.allocator);
        _ = try terminal.appendClippedText(&clipped, self.allocator, first_line, 256);
        const preview = try terminal.safeUtf8Alloc(self.allocator, clipped.items);
        if (self.pinned_user) |old| self.allocator.free(old);
        self.pinned_user = preview;
    }

    pub fn appendToolHeader(self: *ConversationView, header: []const u8, id: []const u8) !void {
        // A tool header begins and ends with a newline.
        try self.appendText("\n");
        try self.appendLine(std.mem.trim(u8, header, "\n"), id);
    }

    fn appendLine(self: *ConversationView, text: []const u8, tool_id: ?[]const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        const id = if (tool_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (id) |value| self.allocator.free(value);
        const line: Line = .{ .text = owned, .tool_id = id };
        if (self.lines.items.len == max_lines) {
            self.lines.items[self.first].deinit(self.allocator);
            self.lines.items[self.first] = line;
            self.first = (self.first + 1) % max_lines;
            self.first_id += 1;
        } else try self.lines.append(self.allocator, line);
    }

    fn appendPending(self: *ConversationView, text: []const u8) !void {
        if (self.pending_clipped) return;
        const remaining = (max_line_bytes - 3) - self.pending.items.len;
        const count = utf8Prefix(text, remaining);
        try self.pending.appendSlice(self.allocator, text[0..count]);
        if (count < text.len) {
            try self.pending.appendSlice(self.allocator, "…");
            self.pending_clipped = true;
        }
    }

    /// The caller supplies display text and any trusted renderer SGR sequences.
    pub fn appendText(self: *ConversationView, text: []const u8) !void {
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
            try self.appendPending(std.mem.trimEnd(u8, rest[0..newline], "\r"));
            try self.flush();
            rest = rest[newline + 1 ..];
        }
        try self.appendPending(rest);
    }

    pub fn flush(self: *ConversationView) !void {
        try self.appendLine(self.pending.items, null);
        self.pending.clearRetainingCapacity();
        self.pending_clipped = false;
    }

    pub fn isFollowing(self: *const ConversationView) bool {
        return self.anchor == null;
    }

    pub fn followLatest(self: *ConversationView) void {
        self.anchor = null;
    }

    pub fn end(self: *const ConversationView) usize {
        return self.first_id + self.lines.items.len;
    }

    pub fn pageEnd(self: *const ConversationView) usize {
        return @min(@max(self.anchor orelse self.end(), self.first_id), self.end());
    }

    pub fn lineAt(self: *const ConversationView, id: usize) []const u8 {
        return self.lines.items[(self.first + id - self.first_id) % max_lines].text;
    }

    pub fn toolAtRow(self: *const ConversationView, row: usize) ?[]const u8 {
        if (row == 0 or row > self.hit_rows.items.len) return null;
        const id = self.hit_rows.items[row - 1] orelse return null;
        if (id < self.first_id or id >= self.end()) return null;
        return self.lines.items[(self.first + id - self.first_id) % max_lines].tool_id;
    }

    pub fn scrollUp(self: *ConversationView, amount: usize) void {
        const oldest = self.first_id +| @min(self.body_height, self.lines.items.len);
        if (self.pageEnd() > oldest) self.anchor = @max(oldest, self.pageEnd() -| amount);
    }

    pub fn scrollDown(self: *ConversationView, amount: usize) void {
        if (self.anchor == null) return;
        const next = self.pageEnd() +| amount;
        self.anchor = if (next >= self.end()) null else next;
    }

    pub fn handleScrollKey(self: *ConversationView, final: u8, params: []const u8) bool {
        if (final == 'F' and params.len == 0 or final == '~' and
            (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")))
        {
            self.followLatest();
        } else if (final == '~' and std.mem.eql(u8, params, "5")) {
            self.scrollUp(@max(1, self.body_height -| 1));
        } else if (final == '~' and std.mem.eql(u8, params, "6")) {
            self.scrollDown(@max(1, self.body_height -| 1));
        } else return false;
        return true;
    }
};

fn utf8Prefix(text: []const u8, limit: usize) usize {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return end;
}

test "paused page survives streamed lines and End resumes following" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    try view.setPinnedUser("最新消息\nsecond line");
    try std.testing.expectEqualStrings("最新消息", view.pinned_user.?);
    view.body_height = 2;
    try view.appendText("first\nsecond\nthird\nfourth\npartial");
    try std.testing.expect(view.handleScrollKey('~', "5"));
    const before = view.pageEnd();
    try std.testing.expectEqual(@as(usize, 3), before);
    try view.appendText(" tail\nsixth\n");
    try std.testing.expect(!view.isFollowing());
    try std.testing.expectEqual(before, view.pageEnd());
    try std.testing.expectEqualStrings("third", view.lineAt(before - 1));
    try std.testing.expect(view.handleScrollKey('F', ""));
    try std.testing.expect(view.isFollowing());
    try std.testing.expectEqualStrings("sixth", view.lineAt(view.end() - 1));
}
