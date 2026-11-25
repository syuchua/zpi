//! Bounded transcript and stable scroll anchor for the fullscreen TUI.
const std = @import("std");
const terminal = @import("../terminal.zig");
const search = @import("search.zig");

pub const ConversationView = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    hit_rows: std.ArrayList(?usize) = .empty,
    popup_row: usize = 0,
    popup_rows: usize = 0,
    jump_latest_row: usize = 0,
    pinned_hit_row: ?usize = null,
    pinned_header_rows: usize = 0,
    frame_size: std.posix.winsize = std.mem.zeroes(std.posix.winsize),
    first: usize = 0,
    pinned_users: std.Deque(PinnedUser) = .empty,
    // Absolute row of every user message in the ring, oldest first.
    user_rows: std.Deque(usize) = .empty,
    // User message last navigated/displayed by prompt navigation; keeps
    // forward navigation walking message by message even on a short page.
    user_nav_row: ?usize = null,
    // Absolute row of the focused search match, when it is visible.
    search_hit_row: ?usize = null,
    pending: std.ArrayList(u8) = .empty,
    pending_clipped: bool = false,
    expanded_tools: std.StringHashMapUnmanaged(bool) = .empty,
    tools_expanded: bool = false,
    // Absolute exclusive end of the page being read. Null follows the live tail.
    anchor: ?usize = null,
    first_id: usize = 0,
    body_height: usize = 1,
    tool_layout_width: usize = 0,
    tool_layout_end: usize = 0,

    pub const compact_tool_rows = 2;
    const max_tool_lines = 512;
    const FoldRow = enum { always, output_title, body, hint, expanded_limit };

    const PinnedUser = struct {
        text: []u8,
        row: usize,
    };

    const Line = struct {
        text: []u8,
        tool_id: ?[]u8 = null,
        fold: FoldRow = .always,
        compact_rows: usize = 0,
        foldable: bool = false,

        fn deinit(self: Line, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            if (self.tool_id) |id| allocator.free(id);
        }
    };

    pub const max_lines = 8192;
    const max_line_bytes = 8192;

    pub fn init(allocator: std.mem.Allocator) ConversationView {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConversationView) void {
        self.clear();
        self.lines.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.hit_rows.deinit(self.allocator);
        self.expanded_tools.deinit(self.allocator);
        self.pinned_users.deinit(self.allocator);
        self.user_rows.deinit(self.allocator);
    }

    pub fn clear(self: *ConversationView) void {
        for (self.lines.items) |line| line.deinit(self.allocator);
        self.hit_rows.clearRetainingCapacity();
        self.popup_rows = 0;
        self.jump_latest_row = 0;
        self.pinned_hit_row = null;
        self.pinned_header_rows = 0;
        self.lines.clearRetainingCapacity();
        self.first = 0;
        self.first_id = 0;
        self.tool_layout_end = 0;
        self.anchor = null;
        self.search_hit_row = null;
        self.user_nav_row = null;
        self.pending.clearRetainingCapacity();
        self.pending_clipped = false;
        self.clearToolOverrides();
        while (self.pinned_users.popFront()) |user| self.allocator.free(user.text);
        while (self.user_rows.popFront()) |_| {}
    }

    fn recordPinnedUser(self: *ConversationView, text: []const u8, row: usize) !void {
        const first_line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        var clipped: std.ArrayList(u8) = .empty;
        defer clipped.deinit(self.allocator);
        _ = try terminal.appendClippedText(&clipped, self.allocator, first_line, 256);
        const preview = try terminal.safeUtf8Alloc(self.allocator, clipped.items);
        errdefer self.allocator.free(preview);
        try self.pinned_users.pushBack(self.allocator, .{ .text = preview, .row = row });
    }

    pub fn appendToolText(self: *ConversationView, text: []const u8, id: []const u8) !void {
        var rest = text;
        if (self.pending.items.len > 0 and (rest.len == 0 or rest[0] != '\n')) try self.flush();
        while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
            const line = std.mem.trimEnd(u8, rest[0..newline], "\r");
            try self.appendPending(line);
            try self.flushLine(if (line.len == 0) null else id);
            rest = rest[newline + 1 ..];
        }
        if (rest.len > 0) {
            try self.appendPending(rest);
            try self.flushLine(id);
        }
    }

    /// Keep logical lines so a resize can reflow results without changing row IDs.
    pub fn appendToolBody(self: *ConversationView, text: []const u8, id: []const u8) !void {
        if (self.pending.items.len > 0) try self.flush();
        try self.appendLine("Output", id, .output_title);
        if (text.len == 0) return;
        var rows = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\n');
        var count: usize = 0;
        var truncated = false;
        while (rows.next()) |row| : (count += 1) {
            if (count == max_tool_lines) {
                truncated = true;
                break;
            }
            const line = std.mem.trimEnd(u8, row, "\r");
            const prefix = utf8Prefix(line, max_line_bytes);
            const safe = try terminal.safeUtf8Alloc(self.allocator, line[0..prefix]);
            defer self.allocator.free(safe);
            truncated = truncated or prefix < line.len;
            try self.appendLine(safe, id, .body);
        }
        if (truncated) try self.appendLine("│ … output preview limit reached", id, .expanded_limit);
        try self.appendLine("", id, .hint);
    }

    /// Recompute two-row previews when the terminal width changes. Appends
    /// start at the previous end, so streaming does not reflow old results.
    pub fn layoutTools(self: *ConversationView, width: usize) !void {
        const start = if (width == self.tool_layout_width) @max(self.first_id, self.tool_layout_end) else self.first_id;
        var remaining: usize = compact_tool_rows;
        var overflow = false;
        for (start..self.end()) |id| {
            const line = &self.lines.items[(self.first + id - self.first_id) % max_lines];
            switch (line.fold) {
                .always, .output_title => {},
                .body => {
                    line.compact_rows = 0;
                    if (remaining == 0) {
                        overflow = true;
                        continue;
                    }
                    const wrapped = try terminal.wrapAnsiAlloc(self.allocator, line.text, toolBodyWidth(width));
                    defer self.allocator.free(wrapped);
                    const row_count = std.mem.countScalar(u8, wrapped, '\n') + 1;
                    line.compact_rows = @min(remaining, row_count);
                    remaining -= line.compact_rows;
                    overflow = overflow or row_count > line.compact_rows;
                },
                .expanded_limit => overflow = true,
                .hint => {
                    line.foldable = overflow;
                    remaining = compact_tool_rows;
                    overflow = false;
                },
            }
        }
        self.tool_layout_width = width;
        self.tool_layout_end = self.end();
    }

    pub fn toolBodyWidth(width: usize) usize {
        return @max(1, width -| 2);
    }

    pub fn toggleToolExpanded(self: *ConversationView, id: []const u8) !void {
        if (self.expanded_tools.fetchRemove(id)) |old| {
            self.allocator.free(old.key);
            return;
        }
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.expanded_tools.put(self.allocator, owned, !self.tools_expanded);
    }

    pub fn setToolsExpanded(self: *ConversationView, enabled: bool) void {
        self.tools_expanded = enabled;
        self.clearToolOverrides();
    }

    fn clearToolOverrides(self: *ConversationView) void {
        var keys = self.expanded_tools.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.expanded_tools.clearRetainingCapacity();
    }

    fn appendLine(self: *ConversationView, text: []const u8, tool_id: ?[]const u8, fold: FoldRow) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        const id = if (tool_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (id) |value| self.allocator.free(value);
        const line: Line = .{ .text = owned, .tool_id = id, .fold = fold };
        if (self.lines.items.len == max_lines) {
            self.lines.items[self.first].deinit(self.allocator);
            self.lines.items[self.first] = line;
            self.first = (self.first + 1) % max_lines;
            self.first_id += 1;
            while (self.pinned_users.front()) |user| {
                if (user.row >= self.first_id) break;
                self.allocator.free(self.pinned_users.popFront().?.text);
            }
            while (self.user_rows.front()) |row| {
                if (row >= self.first_id) break;
                _ = self.user_rows.popFront();
            }
            if (self.search_hit_row) |row| {
                if (row < self.first_id) self.search_hit_row = null;
            }
            if (self.user_nav_row) |row| {
                if (row < self.first_id) self.user_nav_row = null;
            }
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

    /// `panel` begins at the first row of the formatted user message.
    pub fn appendUserMessage(self: *ConversationView, text: []const u8, panel: []const u8, content_row: usize) !void {
        if (self.pending.items.len > 0) try self.flush();
        const row = self.end() + content_row;
        try self.appendText(panel);
        if (self.pending.items.len > 0) try self.flush();
        if (row >= self.first_id and row < self.end()) {
            try self.recordPinnedUser(text, row);
            try self.user_rows.pushBack(self.allocator, row);
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
        try self.flushLine(null);
    }

    fn flushLine(self: *ConversationView, tool_id: ?[]const u8) !void {
        try self.appendLine(self.pending.items, tool_id, .always);
        self.pending.clearRetainingCapacity();
        self.pending_clipped = false;
    }

    pub fn isFollowing(self: *const ConversationView) bool {
        return self.anchor == null;
    }

    pub fn followLatest(self: *ConversationView) void {
        self.anchor = null;
        self.user_nav_row = null;
    }

    /// Keep the last user message until it falls beyond the page's newer edge.
    pub fn pinnedUserForPage(self: *const ConversationView) ?PinnedUser {
        const page_end = self.pageEnd();
        var first: usize = 0;
        var limit = self.pinned_users.len;
        while (first < limit) {
            const mid = first + (limit - first) / 2;
            if (self.pinned_users.at(mid).row < page_end) {
                first = mid + 1;
            } else {
                limit = mid;
            }
        }
        return if (first > 0) self.pinned_users.at(first - 1) else null;
    }

    pub fn jumpToUserRow(self: *ConversationView, row: usize) void {
        if (row < self.first_id or row >= self.end()) return;
        // The exclusive end includes the message's first text row even in a short pane.
        // When the target already ends the page, step one row further back so
        // repeated jumps to the same message still move the viewport.
        self.anchor = if (row + 1 == self.pageEnd() and row > self.first_id) row else row + 1;
    }

    /// Absolute row of the newest user message strictly older than `before`.
    /// Returns null when every user message starts at or after `before`.
    pub fn userRowBefore(self: *const ConversationView, before: usize) ?usize {
        if (self.user_rows.len == 0) return null;
        var first: usize = 0;
        var limit = self.user_rows.len;
        while (first < limit) {
            const mid = first + (limit - first) / 2;
            if (self.user_rows.at(mid) < before) first = mid + 1 else limit = mid;
        }
        return if (first > 0) self.user_rows.at(first - 1) else null;
    }

    /// Absolute row of the oldest user message at or after `after`, if any.
    pub fn userRowAtOrAfter(self: *const ConversationView, after: usize) ?usize {
        if (self.user_rows.len == 0) return null;
        var first: usize = 0;
        var limit = self.user_rows.len;
        while (first < limit) {
            const mid = first + (limit - first) / 2;
            if (self.user_rows.at(mid) < after) first = mid + 1 else limit = mid;
        }
        return if (first < self.user_rows.len) self.user_rows.at(first) else null;
    }

    /// Jump to the previous user message; false when none is reachable.
    /// A null anchor means the page is following the live tail, so the newest
    /// message is the first stop.
    pub fn jumpToPreviousUserMessage(self: *ConversationView) bool {
        const page = self.pageEnd();
        const reference = if (self.anchor != null) @min(self.user_nav_row orelse page, page) else page;
        const target = self.userRowBefore(reference) orelse return false;
        self.user_nav_row = target;
        self.jumpToUserRow(target);
        return true;
    }

    /// Jump to the next user message; false only when already following the
    /// newest message. The newest reachable message resumes following.
    pub fn jumpToNextUserMessage(self: *ConversationView) bool {
        if (self.user_rows.len == 0) return false;
        const newest = self.user_rows.at(self.user_rows.len - 1);
        if (self.anchor == null) return false;
        const current = self.user_nav_row orelse {
            // Page moved by scrolling/clicking rather than prompt navigation:
            // resume the next message after the page end.
            const target = self.userRowAtOrAfter(self.pageEnd()) orelse {
                self.followLatest();
                return true;
            };
            self.user_nav_row = target;
            if (target == newest) {
                self.followLatest();
                return true;
            }
            self.jumpToUserRow(target);
            return true;
        };
        const target = self.userRowAtOrAfter(current + 1) orelse {
            self.followLatest();
            return true;
        };
        if (target == newest) {
            self.followLatest();
            return true;
        }
        self.user_nav_row = target;
        self.jumpToUserRow(target);
        return true;
    }

    /// Searchable rows are exactly the rows `renderFullscreenConversation` can
    /// draw for the page at the current width: folded tool bodies and their
    /// hidden hints are skipped, individually expanded bodies are included.
    pub fn isRowVisible(self: *const ConversationView, id: usize) bool {
        return self.lineAt(id) != null;
    }

    /// Collect absolute rows whose visible text contains `query`. Results are
    /// ascending and bounded by `search.SearchState.max_matches`.
    pub fn collectMatches(self: *const ConversationView, query: []const u8, out: *std.ArrayList(usize)) !void {
        out.clearRetainingCapacity();
        if (query.len == 0) return;
        var id = self.first_id;
        while (id < self.end() and out.items.len < search.SearchState.max_matches) : (id += 1) {
            const text = self.lineAt(id) orelse continue;
            if (search.findBytes(text, query) != null) try out.append(self.allocator, id);
        }
    }

    /// Focus a search row: reveal it and mark it so the renderer can highlight
    /// the focused match. Returns false when the row is no longer retained.
    /// Matches already inside the tail viewport keep following so streaming
    /// output does not move the viewport away from them.
    pub fn jumpToSearchRow(self: *ConversationView, row: usize) bool {
        if (row < self.first_id or row >= self.end()) {
            if (self.search_hit_row == row) self.search_hit_row = null;
            return false;
        }
        self.search_hit_row = row;
        // Exclusive end is row + 1, so the matched row is the last page row.
        self.anchor = @min(row + 1, self.end());
        // Measure the tail viewport from the live end, not from the new anchor,
        // and keep following when the match is already visible there.
        var visible: usize = 0;
        var id = self.end();
        while (id > self.first_id and visible < self.body_height) {
            id -= 1;
            if (self.lineAt(id) != null) visible += 1;
        }
        if (id <= row) self.followLatest();
        return true;
    }

    pub fn end(self: *const ConversationView) usize {
        return self.first_id + self.lines.items.len;
    }

    pub fn pageEnd(self: *const ConversationView) usize {
        return @min(@max(self.anchor orelse self.end(), self.first_id), self.end());
    }

    fn expanded(self: *const ConversationView, line: Line) bool {
        return self.expanded_tools.get(line.tool_id.?) orelse self.tools_expanded;
    }

    pub fn lineAt(self: *const ConversationView, id: usize) ?[]const u8 {
        const line = self.lines.items[(self.first + id - self.first_id) % max_lines];
        return switch (line.fold) {
            .always, .output_title => line.text,
            .body => if (line.compact_rows > 0 or self.expanded(line)) line.text else null,
            .expanded_limit => if (self.expanded(line)) line.text else null,
            .hint => if (!line.foldable) null else if (self.expanded(line)) "│ (click to collapse)" else "│ (click to show more)",
        };
    }

    /// Null for non-body rows. Expanded bodies have no per-line display limit.
    pub fn toolBodyRowLimit(self: *const ConversationView, id: usize) ?usize {
        const line = self.lines.items[(self.first + id - self.first_id) % max_lines];
        if (line.fold != .body) return null;
        return if (self.expanded(line)) std.math.maxInt(usize) else line.compact_rows;
    }

    pub const ToolRowKind = enum { text, output_title, hint };

    pub fn toolRowKind(self: *const ConversationView, id: usize) ?ToolRowKind {
        const line = self.lines.items[(self.first + id - self.first_id) % max_lines];
        if (line.tool_id == null) return null;
        return switch (line.fold) {
            .always, .expanded_limit, .body => .text,
            .output_title => .output_title,
            .hint => .hint,
        };
    }

    pub fn toolAtRow(self: *const ConversationView, row: usize) ?[]const u8 {
        if (row == 0 or row > self.hit_rows.items.len) return null;
        const id = self.hit_rows.items[row - 1] orelse return null;
        if (id < self.first_id or id >= self.end()) return null;
        return self.lines.items[(self.first + id - self.first_id) % max_lines].tool_id;
    }

    pub fn scrollUp(self: *ConversationView, amount: usize) void {
        var oldest = self.first_id;
        var visible: usize = 0;
        while (oldest < self.end() and visible < self.body_height) : (oldest += 1) {
            if (self.lineAt(oldest) != null) visible += 1;
        }
        var next = self.pageEnd();
        var remaining = amount;
        while (next > oldest and remaining > 0) {
            next -= 1;
            if (self.lineAt(next) != null) remaining -= 1;
        }
        if (next < self.pageEnd()) self.anchor = next;
    }

    pub fn scrollDown(self: *ConversationView, amount: usize) void {
        if (self.anchor == null) return;
        var next = self.pageEnd();
        var remaining = amount;
        while (next < self.end() and remaining > 0) : (next += 1) {
            if (self.lineAt(next) != null) remaining -= 1;
        }
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

test "tool text rows retain hit targets and result preview stays folded with an affordance" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    try view.appendText("assistant text");
    try std.testing.expectEqualStrings("assistant text", view.pending.items);
    try view.appendToolText("Input · [tool: read]\n", "call-1");
    const start = view.end() + 1;
    try view.appendToolBody("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\n", "call-1");
    try view.layoutTools(80);
    const hint = view.end() - 1;
    try view.appendToolText("╰─ ✓\n", "call-1");
    try view.hit_rows.append(view.allocator, hint);
    try std.testing.expectEqualStrings("call-1", view.toolAtRow(1).?);
    try std.testing.expectEqualStrings("one", view.lineAt(start).?);
    try std.testing.expectEqualStrings("two", view.lineAt(start + 1).?);
    try std.testing.expect(view.lineAt(start + 2) == null);
    try std.testing.expectEqualStrings("│ (click to show more)", view.lineAt(hint).?);
    try view.toggleToolExpanded(view.toolAtRow(1).?);
    try std.testing.expectEqualStrings("nine", view.lineAt(start + 8).?);
    try std.testing.expectEqualStrings("│ (click to collapse)", view.lineAt(hint).?);
    try view.toggleToolExpanded("call-1");
    try std.testing.expect(view.lineAt(start + 8) == null);
    try view.layoutTools(20);
    try std.testing.expect(view.lineAt(hint) != null);
    view.setToolsExpanded(true);
    try std.testing.expect(view.lineAt(start + 8) != null);
    try view.toggleToolExpanded("call-1");
    try std.testing.expect(view.lineAt(start + 8) == null);
}

test "tool preview follows terminal width and keeps its first two display rows" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    const start = view.end() + 1;
    try view.appendToolBody("abcdefghijklmnopqrstu", "long");
    const hint = view.end() - 1;
    try view.layoutTools(30);
    try std.testing.expect(view.lineAt(hint) == null);
    try std.testing.expectEqual(@as(?usize, 1), view.toolBodyRowLimit(start));
    try view.layoutTools(10);
    try std.testing.expectEqual(@as(?usize, 2), view.toolBodyRowLimit(start));
    try std.testing.expectEqualStrings("│ (click to show more)", view.lineAt(hint).?);
    try view.toggleToolExpanded("long");
    try std.testing.expectEqual(@as(?usize, std.math.maxInt(usize)), view.toolBodyRowLimit(start));
    try view.layoutTools(30);
    try std.testing.expect(view.lineAt(hint) == null);
}

test "pinned user jump uses the transcript row and ignores an evicted target" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    try view.appendUserMessage("latest user", "padding\n> latest user\npadding\n", 1);
    try view.appendText("older assistant\n");
    try view.appendUserMessage("next user", "padding\n> next user\npadding\n", 1);
    const latest = view.pinnedUserForPage().?;
    try std.testing.expectEqualStrings("next user", latest.text);
    view.scrollUp(1);
    try std.testing.expectEqualStrings("next user", view.pinnedUserForPage().?.text);
    while (view.pageEnd() > latest.row) view.scrollUp(1);
    try std.testing.expectEqualStrings("latest user", view.pinnedUserForPage().?.text);
    view.followLatest();
    const target = view.pinnedUserForPage().?.row;
    view.jumpToUserRow(target);
    try std.testing.expect(!view.isFollowing());
    try std.testing.expectEqualStrings("> next user", view.lineAt(view.pageEnd() - 1).?);
    try view.appendText("more output\n");
    try std.testing.expectEqual(target + 1, view.pageEnd());
    view.followLatest();
    try view.appendUserMessage("overflow", "padding\n> overflow\npadding\n", 1);
    for (0..ConversationView.max_lines) |_| try view.appendText("\n");
    try std.testing.expect(view.pinned_users.len == 0);
    view.jumpToUserRow(target);
    try std.testing.expect(view.isFollowing());
}

test "paused page survives streamed lines and End resumes following" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    try view.recordPinnedUser("最新消息\nsecond line", 0);
    try std.testing.expectEqualStrings("最新消息", view.pinned_users.at(0).text);
    view.body_height = 2;

    try view.appendText("first\nsecond\nthird\nfourth\npartial");
    try std.testing.expect(view.handleScrollKey('~', "5"));
    const before = view.pageEnd();
    try std.testing.expectEqual(@as(usize, 3), before);
    try view.appendText(" tail\nsixth\n");
    try std.testing.expect(!view.isFollowing());
    try std.testing.expectEqual(before, view.pageEnd());
    try std.testing.expectEqualStrings("third", view.lineAt(before - 1).?);
    try std.testing.expect(view.handleScrollKey('F', ""));
    try std.testing.expect(view.isFollowing());
    try std.testing.expectEqualStrings("sixth", view.lineAt(view.end() - 1).?);
}

test "search covers visible rows only and keeps absolute row IDs stable" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    try view.appendUserMessage("alpha request", "> alpha request\n", 0);
    try view.appendToolText("Input · [tool: read]", "call-1");
    // Two rows show as the compact preview; the rest are hidden while folded.
    try view.appendToolBody("preview one\npreview two\nalpha folded line\n", "call-1");
    try view.layoutTools(80);
    try view.appendToolText("╰─ ok", "call-1");
    try view.appendText("alpha final answer\n");

    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(view.allocator);

    // Folded tool body rows are not visible, so their "alpha" is not found.
    try view.collectMatches("alpha", &matches);
    try std.testing.expectEqualSlices(usize, &.{ 0, view.end() - 1 }, matches.items);

    // Expanded bodies become searchable without changing other row IDs.
    view.setToolsExpanded(true);
    try view.collectMatches("alpha", &matches);
    try std.testing.expectEqualSlices(usize, &.{ 0, 5, view.end() - 1 }, matches.items);

    // ASCII case-insensitive; empty query finds nothing.
    try view.collectMatches("ALPHA", &matches);
    try std.testing.expectEqual(@as(usize, 3), matches.items.len);
    try view.collectMatches("", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);

    // A match never spans a logical line boundary.
    try view.collectMatches("answer\n", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
    try view.collectMatches("answer >", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);

    // Row IDs survive appended output and resize-driven relayout.
    try view.collectMatches("alpha final", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    const target = matches.items[0];
    try view.appendText("more streamed output\n");
    try view.layoutTools(24);
    try std.testing.expect(view.jumpToSearchRow(target));
    try std.testing.expectEqual(target + 1, view.pageEnd());
    try std.testing.expectEqual(@as(?usize, target), view.search_hit_row);
}

test "prompt navigation walks marked user messages in both directions" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    try view.appendUserMessage("one", "> one\n", 0);
    try view.appendText("reply one\nreply two\n");
    try view.appendUserMessage("two", "> two\n", 0);
    try view.appendText("reply three\n");
    try view.appendUserMessage("three", "> three\n", 0);
    try view.appendText("reply four\nreply five\npartial");
    view.body_height = 2;

    // Newest message is first, then progressively older ones.
    try std.testing.expect(view.jumpToPreviousUserMessage());
    try std.testing.expectEqualStrings("> three", view.lineAt(view.pageEnd() - 1).?);
    try std.testing.expect(view.jumpToPreviousUserMessage());
    try std.testing.expectEqualStrings("> two", view.lineAt(view.pageEnd() - 1).?);
    try std.testing.expect(view.jumpToPreviousUserMessage());
    try std.testing.expectEqualStrings("> one", view.lineAt(view.pageEnd() - 1).?);
    // No older message: the page stays put.
    try std.testing.expect(!view.jumpToPreviousUserMessage());
    try std.testing.expectEqualStrings("> one", view.lineAt(view.pageEnd() - 1).?);

    // Forward navigation mirrors the backward walk, and reaching the newest
    // message resumes following so live output stays visible.
    try std.testing.expect(view.jumpToNextUserMessage());
    try std.testing.expectEqualStrings("> two", view.lineAt(view.pageEnd() - 1).?);
    try std.testing.expect(!view.isFollowing());
    try std.testing.expect(view.jumpToNextUserMessage());
    try std.testing.expect(view.isFollowing());
    try std.testing.expectEqualStrings("partial", view.pending.items);
    // Following the newest message leaves no forward target.
    try std.testing.expect(!view.jumpToNextUserMessage());

    // Evicted user rows are forgotten so navigation never targets a dead row.
    for (0..ConversationView.max_lines) |_| try view.appendText("\n");
    try std.testing.expect(view.user_rows.len == 0);
    try std.testing.expect(!view.jumpToPreviousUserMessage());
    try std.testing.expectEqual(@as(?usize, null), view.userRowBefore(view.end()));
}

test "jumpToSearchRow keeps following when the match is inside the tail" {
    var view = ConversationView.init(std.testing.allocator);
    defer view.deinit();
    view.body_height = 3;
    try view.appendText("old marker\n");
    for (0..10) |_| try view.appendText("filler\n");
    try view.appendText("fresh marker\n");
    try std.testing.expect(view.isFollowing());
    try std.testing.expect(view.jumpToSearchRow(view.end() - 1));
    try std.testing.expect(view.isFollowing());
    try std.testing.expect(view.jumpToSearchRow(0));
    try std.testing.expect(!view.isFollowing());
    try std.testing.expectEqual(@as(usize, 1), view.pageEnd());
    // An evicted window no longer accepts a stale row.
    try std.testing.expect(!view.jumpToSearchRow(view.end() + 5));
}
