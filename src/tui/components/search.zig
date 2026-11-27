//! Bounded literal transcript search for the fullscreen TUI.
//!
//! Scope and policy (0.1.2):
//!   * Search covers the retained transcript lines of the fullscreen
//!     `ConversationView` ring: live turns plus restored
//!     sessions/history/branch-summary text. The ring holds the newest
//!     `ConversationView.max_lines` (8192) rows; older rows that were evicted are
//!     not searchable, and the prompt/search overlay itself is never searched.
//!   * Rows are searched by their stored logical line after trusted renderer
//!     SGR/OSC sequences are removed, so match highlighting can be applied to the
//!     original text without breaking styling.
//!   * Rows hidden by tool folding (folded compact previews and their hint row)
//!     are skipped, because their text is not visible at the current width. The
//!     exception is an individually or globally expanded tool body, whose rows are
//!     visible and therefore searchable.
//!   * Matching is per logical line. A match never spans a line boundary and a
//!     match that would be split by soft wrapping is not found from its pieces.
//!   * Empty queries match nothing. Literal ASCII text compares
//!     case-insensitively; a query containing any non-ASCII byte requires an exact
//!     (case-sensitive) match, so CJK and other scripts behave predictably.
//!   * Results hold absolute, stable row IDs (`ConversationView` row ids), so a
//!     result survives new output, resize reflow and ring eviction. A stored
//!     result whose row was later evicted is dropped before use.
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");
const ConversationView = @import("conversation_view.zig").ConversationView;

pub const SearchState = struct {
    allocator: std.mem.Allocator,
    /// Literal query typed by the user.
    query: std.ArrayList(u8) = .empty,
    /// Absolute row IDs in ascending order.
    matches: std.ArrayList(usize) = .empty,
    cursor: usize = 0,
    // Viewport (exclusive transcript end) captured when search opened.
    saved_anchor: ?usize = null,
    saved_following: bool = false,

    pub const max_query_bytes = 256;
    pub const max_matches = 2048;

    pub fn init(allocator: std.mem.Allocator) SearchState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SearchState) void {
        self.query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }

    pub fn count(self: *const SearchState) usize {
        return self.matches.items.len;
    }

    pub fn isActive(self: *const SearchState) bool {
        return self.query.items.len > 0;
    }

    /// 1-based ordinal of the focused match, or 0 when there is no match.
    pub fn position(self: *const SearchState) usize {
        if (self.matches.items.len == 0) return 0;
        return @min(self.cursor, self.matches.items.len - 1) + 1;
    }

    pub fn current(self: *const SearchState) ?usize {
        if (self.matches.items.len == 0) return null;
        return self.matches.items[@min(self.cursor, self.matches.items.len - 1)];
    }

    pub fn capturePage(self: *SearchState, view: anytype) void {
        self.saved_anchor = view.pageEnd();
        self.saved_following = view.isFollowing();
    }

    /// Last recorded page. `run` calls this itself; the caller uses it to
    /// restore the viewport on Esc.
    pub fn restorePage(self: *SearchState, view: anytype) void {
        view.anchor = if (self.saved_following) null else self.saved_anchor;
        view.search_hit_row = null;
    }

    pub fn pushByte(self: *SearchState, byte: u8) bool {
        if (self.query.items.len >= max_query_bytes) return false;
        self.query.append(self.allocator, byte) catch return false;
        return true;
    }

    pub fn pushSlice(self: *SearchState, bytes: []const u8) bool {
        if (self.query.items.len + bytes.len > max_query_bytes) return false;
        self.query.appendSlice(self.allocator, bytes) catch return false;
        return true;
    }

    pub fn popByte(self: *SearchState) bool {
        if (self.query.items.len == 0) return false;
        // Drop a whole UTF-8 sequence so multi-byte queries stay valid.
        var end = self.query.items.len - 1;
        while (end > 0 and (self.query.items[end] & 0xc0) == 0x80) end -= 1;
        self.query.items.len = end;
        return true;
    }

    /// Clear rows/query after cancel; counts are recomputed on the next key.
    pub fn clear(self: *SearchState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.cursor = 0;
        self.saved_anchor = null;
        self.saved_following = false;
    }
};

/// ASCII-lowercases `byte` and every other ASCII byte in place-independent
/// form, used by `findBytes` for case-insensitive literal search.
inline fn fold(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

pub fn isAsciiQuery(query: []const u8) bool {
    for (query) |byte| if (byte >= 0x80) return false;
    return true;
}

/// Index of the first literal occurrence of `needle` in `haystack`.
/// ASCII needles match ASCII case-insensitively; non-ASCII needles are exact.
pub fn findBytes(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    const ignore_case = isAsciiQuery(needle);
    var i: usize = 0;
    const last = haystack.len - needle.len;
    outer: while (i <= last) : (i += 1) {
        // Align to a UTF-8 boundary of the haystack before comparing.
        if (i > 0 and (haystack[i] & 0xc0) == 0x80) continue;
        for (needle, 0..) |want, offset| {
            const got = haystack[i + offset];
            if (ignore_case) {
                if (fold(got) != fold(want)) continue :outer;
            } else if (got != want) continue :outer;
        }
        return i;
    }
    return null;
}

pub fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var offset: usize = 0;
    while (findBytes(haystack[offset..], needle)) |index| {
        count += 1;
        offset += index + needle.len;
        if (offset >= haystack.len) break;
    }
    return count;
}

/// Copy trusted renderer SGR/OSC segments into `out` but drop their payload so
/// the visible text can be searched and matched positions map back to bytes.
pub fn plainIndexMap(allocator: std.mem.Allocator, text: []const u8) ![]usize {
    var map: std.ArrayList(usize) = .empty;
    errdefer map.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            i = terminal.skipEscapeSequence(text, i);
            continue;
        }
        try map.append(allocator, i);
        i += 1;
    }
    return map.toOwnedSlice(allocator);
}

pub fn plainTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            i = terminal.skipEscapeSequence(text, i);
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Render `text` with all literal query occurrences highlighted (reverse
/// video) without disturbing existing SGR state. Existing sequences are passed
/// through and a reset plus re-open keeps the surrounding style intact.
pub fn highlightAlloc(
    allocator: std.mem.Allocator,
    th: anytype,
    text: []const u8,
    query: []const u8,
) ![]u8 {
    if (query.len == 0) return allocator.dupe(u8, text);
    const plain = try plainTextAlloc(allocator, text);
    defer allocator.free(plain);
    if (findBytes(plain, query) == null) return allocator.dupe(u8, text);
    const map = try plainIndexMap(allocator, text);
    defer allocator.free(map);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var plain_pos: usize = 0;
    var text_pos: usize = 0;
    while (text_pos < text.len) {
        if (text[text_pos] == '\x1b') {
            const next = terminal.skipEscapeSequence(text, text_pos);
            try out.appendSlice(allocator, text[text_pos..next]);
            text_pos = next;
            continue;
        }
        if (findBytes(plain[plain_pos..], query)) |offset| {
            const match_start = plain_pos + offset;
            const byte_start = if (match_start < map.len) map[match_start] else text.len;
            const byte_end = if (match_start + query.len < map.len) map[match_start + query.len] else text.len;
            // Copy text between the cursor and the match start verbatim.
            while (text_pos < byte_start) {
                if (text[text_pos] == '\x1b') {
                    const next = terminal.skipEscapeSequence(text, text_pos);
                    try out.appendSlice(allocator, text[text_pos..next]);
                    text_pos = next;
                    continue;
                }
                try out.append(allocator, text[text_pos]);
                text_pos += 1;
            }
            try th.appendOpen(&out, allocator, theme.Theme.selection);
            try out.appendSlice(allocator, text[byte_start..byte_end]);
            try th.appendClose(&out, allocator);
            text_pos = byte_end;
            plain_pos = match_start + query.len;
            continue;
        }
        try out.append(allocator, text[text_pos]);
        text_pos += 1;
        plain_pos += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Visible prompt row: `/` while typing, plus match counter/focus on the right.
pub fn promptLineAlloc(
    allocator: std.mem.Allocator,
    th: anytype,
    state: *const SearchState,
    width: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try th.paint(&out, allocator, theme.Theme.accent, "/");
    try out.append(allocator, ' ');
    if (state.query.items.len == 0) {
        try th.paint(&out, allocator, theme.Theme.muted, "search transcript");
    } else {
        var safe: std.ArrayList(u8) = .empty;
        defer safe.deinit(allocator);
        _ = try terminal.appendClippedText(&safe, allocator, state.query.items, width);
        try out.appendSlice(allocator, safe.items);
    }
    const status = try statusAlloc(allocator, state);
    defer allocator.free(status);
    const used = terminal.visibleWidth(out.items) + 1;
    if (status.len > 0 and used + status.len + 2 <= width) {
        const pad = width -| (used + status.len);
        try out.appendNTimes(allocator, ' ', pad);
        try th.paint(&out, allocator, theme.Theme.muted, status);
    }
    return out.toOwnedSlice(allocator);
}

pub fn statusAlloc(allocator: std.mem.Allocator, state: *const SearchState) ![]u8 {
    if (state.query.items.len == 0) return allocator.dupe(u8, "");
    if (state.matches.items.len == 0) return allocator.print("no matches · Esc", .{});
    return allocator.print("{d}/{d} · ↑/↓ · Esc", .{ state.position(), state.count() });
}

/// Render rows the search prompt occupies, including its separator rule.
pub const prompt_rows: usize = 2;

test "page snapshot distinguishes live-follow mode from paused-at-tail mode" {
    var following = ConversationView.init(std.testing.allocator);
    defer following.deinit();
    try following.appendText("hello\n");
    var follow_state = SearchState.init(std.testing.allocator);
    defer follow_state.deinit();
    follow_state.capturePage(&following);
    following.anchor = 1;
    follow_state.restorePage(&following);
    try std.testing.expect(following.isFollowing());

    var paused = ConversationView.init(std.testing.allocator);
    defer paused.deinit();
    try paused.appendText("first\nsecond\n");
    paused.anchor = 1;
    var paused_state = SearchState.init(std.testing.allocator);
    defer paused_state.deinit();
    paused_state.capturePage(&paused);
    paused.anchor = null;
    paused_state.restorePage(&paused);
    try std.testing.expect(!paused.isFollowing());
    try std.testing.expectEqual(@as(usize, 1), paused.pageEnd());
}

test "literal search is case-insensitive for ASCII and exact for non-ASCII" {
    try std.testing.expectEqual(@as(?usize, 6), findBytes("Hello World", "world"));
    try std.testing.expectEqual(@as(?usize, 6), findBytes("Hello World", "WORLD"));
    try std.testing.expectEqual(@as(?usize, null), findBytes("Hello World", "worle"));
    try std.testing.expectEqual(@as(?usize, 6), findBytes("你好世界", "世界"));
    try std.testing.expectEqual(@as(?usize, 0), findBytes("ABC", "a"));
    try std.testing.expectEqual(@as(?usize, null), findBytes("abc", "ABC-different-length"));
    try std.testing.expectEqual(@as(?usize, null), findBytes("", "x"));
    // Non-ASCII matching does not fold case.
    try std.testing.expectEqual(@as(?usize, null), findBytes("Ärger", "ärger"));
    try std.testing.expectEqual(@as(?usize, 0), findBytes("Ärger", "Ärger"));
    // A needle only matches at a character boundary of the haystack.
    try std.testing.expectEqual(@as(?usize, null), findBytes("你好", "\xa5\xbd"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("aaaa", "aa"));
    try std.testing.expectEqual(@as(usize, 3), countOccurrences("Foo foo FOO", "foo"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("abc", ""));
}

test "highlightAlloc marks matches without breaking surrounding SGR" {
    const a = std.testing.allocator;
    const th = theme.Theme.init(.ansi16);
    const plain = try highlightAlloc(a, th, "no match here", "zzz");
    defer a.free(plain);
    try std.testing.expectEqualStrings("no match here", plain);

    const styled = try highlightAlloc(a, th, "\x1b[36mRead File\x1b[0m done", "file");
    defer a.free(styled);
    try std.testing.expect(std.mem.startsWith(u8, styled, "\x1b[36mRead "));
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[7mFile\x1b[0m") != null);
    try std.testing.expectEqual(terminal.visibleWidth("\x1b[36mRead File\x1b[0m done"), terminal.visibleWidth(styled));

    const plain_text = try plainTextAlloc(a, "\x1b[31mred\x1b[0m");
    defer a.free(plain_text);
    try std.testing.expectEqualStrings("red", plain_text);
}

test "pushByte/popByte keep UTF-8 queries valid and bound their length" {
    var state = SearchState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(state.pushSlice("你"));
    try std.testing.expectEqualStrings("你", state.query.items);
    try std.testing.expect(state.popByte());
    try std.testing.expectEqual(@as(usize, 0), state.query.items.len);
    try std.testing.expect(!state.popByte());
    for (0..SearchState.max_query_bytes) |_| try std.testing.expect(state.pushByte('x'));
    try std.testing.expect(!state.pushByte('y'));
    try std.testing.expectEqual(SearchState.max_query_bytes, state.query.items.len);
}

test "status line reports no matches and the focused ordinal" {
    const a = std.testing.allocator;
    var state = SearchState.init(a);
    defer state.deinit();
    try state.query.appendSlice(a, "x");
    try state.matches.appendSlice(a, &.{ 3, 7, 9 });
    state.cursor = 1;
    const status = try statusAlloc(a, &state);
    defer a.free(status);
    try std.testing.expectEqualStrings("2/3 · ↑/↓ · Esc", status);
    state.matches.clearRetainingCapacity();
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(a, "none");
    const line = try promptLineAlloc(a, theme.Theme.init(.none), &state, 40);
    defer a.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "no matches") != null);
    try std.testing.expect(std.mem.startsWith(u8, line, "/ none"));
}
