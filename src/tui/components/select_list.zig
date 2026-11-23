//! Reusable fuzzy-filterable SelectList component for interactive `/tree` and `/model`.
//! Preserves native scrollback, narrow-width CJK clipping, paste isolation, and termios state.
const std = @import("std");
const agent = @import("agent");
const renderer_mod = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub const Item = struct {
    id: []const u8,
    role: []const u8 = "",
    preview: []const u8 = "",
    search_text: []const u8 = "",
    depth: usize = 0,
    is_active: bool = false,
    is_user_message: bool = false,
    parent_id: ?[]const u8 = null,
    full_text: []const u8 = "",
};

pub const Source = struct {
    context: *const anyopaque,
    len: usize,
    active: ?usize,
    item: *const fn (*const anyopaque, usize) Item,
};

pub const Mode = enum {
    /// Typing `/` enters filter mode; single keys (`s`, `p`, `y`, `n`) act as commands.
    tree,
    /// Typing printable characters filters immediately.
    direct_filter,
};

pub const Options = struct {
    title: []const u8,
    title_hint: []const u8 = "",
    mode: Mode = .direct_filter,
    footer_full: []const u8 = "Up/Down move  Enter select  Esc cancel",
    footer_medium: []const u8 = "Up/Down Enter Esc",
    footer_narrow: []const u8 = "Up/Down Enter Esc",
    confirm_prompt: ?[]const u8 = null,
    max_visible: usize = 20,
};

pub const Action = enum {
    select,
    summarize,
    prefill,
};

pub const Result = struct {
    index: usize,
    item: Item,
    action: Action,
};

/// Case-insensitive subsequence fuzzy match inspired by pi-tui's fuzzy matcher.
/// Higher score means better match; returns null when `query` is not a subsequence.
pub fn fuzzyMatch(query: []const u8, candidate: []const u8) ?i32 {
    if (query.len == 0) return 0;
    if (candidate.len == 0) return null;

    var qi: usize = 0;
    var score: i32 = 0;
    var consecutive: i32 = 0;
    var last_match_idx: ?usize = null;

    for (candidate, 0..) |cb, ci| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(cb) == std.ascii.toLower(query[qi])) {
            score += 10;
            if (ci == 0) {
                score += 15;
            } else {
                const prev = candidate[ci - 1];
                if (prev == '/' or prev == '-' or prev == '_' or prev == ' ' or prev == ':') {
                    score += 12;
                }
            }
            if (last_match_idx) |prev_idx| {
                if (ci == prev_idx + 1) {
                    consecutive += 1;
                    score += consecutive * 8;
                } else {
                    consecutive = 0;
                    score -= @intCast(@min(@as(usize, 10), ci - prev_idx));
                }
            }
            last_match_idx = ci;
            qi += 1;
        }
    }
    if (qi < query.len) return null;
    score -= @intCast(@min(@as(usize, 50), candidate.len / 8));
    return score;
}

pub const FilteredList = struct {
    allocator: std.mem.Allocator,
    indices: std.ArrayList(usize) = .empty,
    filter: std.ArrayList(u8) = .empty,
    selected_pos: usize = 0,
    first_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FilteredList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FilteredList) void {
        self.indices.deinit(self.allocator);
        self.filter.deinit(self.allocator);
    }

    pub fn rebuild(self: *FilteredList, source: Source, prefer_active: bool) !void {
        const previous_item_idx: ?usize = if (!prefer_active and self.indices.items.len > 0 and self.selected_pos < self.indices.items.len)
            self.indices.items[self.selected_pos]
        else
            null;

        self.indices.clearRetainingCapacity();
        if (self.filter.items.len == 0) {
            try self.indices.ensureTotalCapacity(self.allocator, source.len);
            for (0..source.len) |idx| {
                self.indices.appendAssumeCapacity(idx);
            }
            if (prefer_active) {
                self.selected_pos = source.active orelse (source.len -| 1);
            } else if (previous_item_idx) |target| {
                self.selected_pos = @min(target, self.indices.items.len -| 1);
            } else {
                self.selected_pos = source.active orelse (source.len -| 1);
            }
            return;
        }

        const Scored = struct { index: usize, score: i32 };
        var matches: std.ArrayList(Scored) = .empty;
        defer matches.deinit(self.allocator);

        for (0..source.len) |idx| {
            const it = source.item(source.context, idx);
            const hay = if (it.search_text.len > 0) it.search_text else it.preview;
            var best: ?i32 = fuzzyMatch(self.filter.items, hay);
            if (it.id.len > 0) {
                if (fuzzyMatch(self.filter.items, it.id)) |id_score| {
                    best = if (best) |b| @max(b, id_score) else id_score;
                }
            }
            if (it.role.len > 0) {
                if (fuzzyMatch(self.filter.items, it.role)) |role_score| {
                    best = if (best) |b| @max(b, role_score) else role_score;
                }
            }
            if (best) |s| {
                try matches.append(self.allocator, .{ .index = idx, .score = s });
            }
        }
        std.mem.sort(Scored, matches.items, {}, struct {
            fn less(_: void, l: Scored, r: Scored) bool {
                if (l.score != r.score) return l.score > r.score;
                return l.index < r.index;
            }
        }.less);

        try self.indices.ensureTotalCapacity(self.allocator, matches.items.len);
        for (matches.items) |m| self.indices.appendAssumeCapacity(m.index);

        if (previous_item_idx) |target| {
            for (self.indices.items, 0..) |idx, pos| {
                if (idx == target) {
                    self.selected_pos = pos;
                    return;
                }
            }
        }
        self.selected_pos = 0;
        self.first_pos = 0;
    }

    pub fn currentItemIndex(self: *const FilteredList) ?usize {
        if (self.indices.items.len == 0 or self.selected_pos >= self.indices.items.len) return null;
        return self.indices.items[self.selected_pos];
    }

    pub fn backspace(self: *FilteredList) void {
        if (self.filter.items.len == 0) return;
        var len = self.filter.items.len - 1;
        while (len > 0 and (self.filter.items[len] & 0xc0) == 0x80) : (len -= 1) {}
        self.filter.items.len = len;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *terminal.InputQueue,
    cancel: ?agent.model.Cancel,
    source: Source,
    options: Options,
    th: theme.Theme,
) !?Result {
    if (source.len == 0) {
        try output.writeStreamingAll(io, "No items available.\n");
        return null;
    }

    const original = try terminal.enterRawMode(input_fd);
    defer terminal.setTermiosNow(input_fd, original) catch {};
    var renderer = renderer_mod.MainScreenRenderer.init(allocator, th.mode != .none);
    defer renderer.deinit();
    try output.writeStreamingAll(io, "\x1b[?2004h");
    defer output.writeStreamingAll(io, "\x1b[?2004l") catch {};
    defer renderer.clearViewport(io, output) catch {};

    var list = FilteredList.init(allocator);
    defer list.deinit();
    try list.rebuild(source, true);

    var previous_size: ?std.posix.winsize = null;
    var dirty = true;
    var in_paste = false;
    var confirm_summary = false;
    var filtering = options.mode == .direct_filter;

    while (true) {
        const size = terminal.terminalSize(output);
        const can_confirm = if (options.confirm_prompt) |cp|
            size.row >= 2 and size.col > cp.len
        else
            false;
        if (confirm_summary and !can_confirm) {
            confirm_summary = false;
            dirty = true;
        }
        const show_filter_bar = filtering or list.filter.items.len > 0;
        const header_rows: usize = @as(usize, @intFromBool(size.row >= 3)) + @as(usize, @intFromBool(show_filter_bar and size.row >= 4));
        const footer_rows: usize = @intFromBool(size.row >= 2);
        const chrome = header_rows + footer_rows;
        const visible = @max(1, @min(options.max_visible, @as(usize, size.row) -| chrome));

        if (list.indices.items.len == 0) {
            list.selected_pos = 0;
            list.first_pos = 0;
        } else {
            if (list.selected_pos < list.first_pos) list.first_pos = list.selected_pos;
            if (list.selected_pos >= list.first_pos + visible) list.first_pos = list.selected_pos - visible + 1;
            list.first_pos = @min(list.first_pos, list.indices.items.len -| visible);
        }

        const resized = if (previous_size) |old| old.col != size.col or old.row != size.row else false;
        if (dirty or resized) {
            const end = @min(list.indices.items.len, list.first_pos + visible);
            const lines = try renderLinesAlloc(
                allocator,
                source,
                &list,
                .{ list.first_pos, end },
                size,
                confirm_summary,
                show_filter_bar,
                options,
                th,
            );
            defer {
                for (lines) |l| allocator.free(l);
                allocator.free(lines);
            }
            const slices = try allocator.alloc([]const u8, lines.len);
            defer allocator.free(slices);
            for (lines, slices) |l, *s| s.* = l;
            const end_row = if (lines.len > 0) lines.len - 1 else 0;
            const end_col = if (lines.len > 0) terminal.visibleWidth(lines[end_row]) else 0;
            try renderer.renderViewport(io, output, slices, .{ .row = end_row, .col = end_col }, size.col);
            previous_size = size;
            dirty = false;
        }

        const key = (try queue.readByteTimeout(input_fd, cancel, 100)) orelse {
            if (queue.eof) return null;
            continue;
        };

        if (key == 0x1b) {
            const next = (try queue.readByteTimeout(input_fd, cancel, 35)) orelse {
                if (in_paste) continue;
                if (confirm_summary) {
                    confirm_summary = false;
                    dirty = true;
                    continue;
                }
                if (list.filter.items.len > 0) {
                    list.filter.clearRetainingCapacity();
                    if (options.mode == .tree) filtering = false;
                    try list.rebuild(source, true);
                    dirty = true;
                    continue;
                }
                if (options.mode == .tree and filtering) {
                    filtering = false;
                    dirty = true;
                    continue;
                }
                return null;
            };
            if (next == 0x1b) {
                if (in_paste) continue;
                if (confirm_summary) {
                    confirm_summary = false;
                    dirty = true;
                    queue.start -= 1;
                    continue;
                }
                if (list.filter.items.len > 0) {
                    list.filter.clearRetainingCapacity();
                    if (options.mode == .tree) filtering = false;
                    try list.rebuild(source, true);
                    dirty = true;
                    queue.start -= 1;
                    continue;
                }
                if (options.mode == .tree and filtering) {
                    filtering = false;
                    dirty = true;
                    queue.start -= 1;
                    continue;
                }
                return null;
            }
            if (next != '[' and next != 'O') {
                if (in_paste) continue;
                queue.start -= 1;
                return null;
            }
            var params: [32]u8 = undefined;
            var count: usize = 0;
            const final_byte: ?u8 = while (true) {
                const byte = (try queue.readByteTimeout(input_fd, cancel, 35)) orelse break null;
                if (byte >= 0x40 and byte <= 0x7e) break byte;
                if (count < params.len) params[count] = byte;
                count +|= 1;
            };
            const final = final_byte orelse continue;
            if (count > params.len) continue;
            const prefix = params[0..count];
            if (next == '[' and final == '~' and std.mem.eql(u8, prefix, "200")) {
                in_paste = true;
                continue;
            }
            if (next == '[' and final == '~' and std.mem.eql(u8, prefix, "201")) {
                in_paste = false;
                continue;
            }
            if (in_paste or confirm_summary) continue;
            if (list.indices.items.len == 0) continue;
            const previous = list.selected_pos;
            switch (final) {
                'A' => list.selected_pos -|= 1,
                'B' => list.selected_pos = @min(list.selected_pos + 1, list.indices.items.len - 1),
                'H' => list.selected_pos = 0,
                'F' => list.selected_pos = list.indices.items.len - 1,
                '~' => {
                    if (std.mem.eql(u8, prefix, "5")) list.selected_pos -|= visible;
                    if (std.mem.eql(u8, prefix, "6")) list.selected_pos = @min(list.selected_pos + visible, list.indices.items.len - 1);
                    if (std.mem.eql(u8, prefix, "1") or std.mem.eql(u8, prefix, "7")) list.selected_pos = 0;
                    if (std.mem.eql(u8, prefix, "4") or std.mem.eql(u8, prefix, "8")) list.selected_pos = list.indices.items.len - 1;
                },
                else => {},
            }
            dirty = list.selected_pos != previous;
        } else if (key == 0x03) {
            return error.Canceled;
        } else if (!in_paste) {
            switch (key) {
                0x04 => return null,
                '\r', '\n' => {
                    if (!confirm_summary) {
                        if (list.currentItemIndex()) |idx| {
                            return .{ .index = idx, .item = source.item(source.context, idx), .action = .select };
                        }
                    }
                },
                0x7f, 0x08 => {
                    if (!confirm_summary and (filtering or list.filter.items.len > 0)) {
                        list.backspace();
                        try list.rebuild(source, false);
                        dirty = true;
                    }
                },
                0x15 => {
                    if (!confirm_summary and list.filter.items.len > 0) {
                        list.filter.clearRetainingCapacity();
                        try list.rebuild(source, false);
                        dirty = true;
                    }
                },
                else => {
                    if (confirm_summary) {
                        switch (key) {
                            'n', 'N' => {
                                confirm_summary = false;
                                dirty = true;
                            },
                            'y', 'Y' => {
                                const current_size = terminal.terminalSize(output);
                                if (options.confirm_prompt) |cp| {
                                    if (current_size.row >= 2 and current_size.col > cp.len) {
                                        if (list.currentItemIndex()) |idx| {
                                            return .{ .index = idx, .item = source.item(source.context, idx), .action = .summarize };
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                        continue;
                    }
                    if (options.mode == .tree and !filtering) {
                        switch (key) {
                            '/' => {
                                filtering = true;
                                dirty = true;
                            },
                            's', 'S' => {
                                if (options.confirm_prompt != null and can_confirm) {
                                    if (list.currentItemIndex()) |idx| {
                                        if (source.active != idx) {
                                            confirm_summary = true;
                                            dirty = true;
                                        }
                                    }
                                }
                            },
                            'p', 'P' => {
                                if (list.currentItemIndex()) |idx| {
                                    const item = source.item(source.context, idx);
                                    if (item.is_user_message) {
                                        return .{ .index = idx, .item = item, .action = .prefill };
                                    }
                                }
                            },
                            else => {},
                        }
                        continue;
                    }
                    if (key >= 0x20 and key < 0x7f) {
                        if (list.filter.items.len < 128) {
                            try list.filter.append(allocator, key);
                            try list.rebuild(source, false);
                            dirty = true;
                        }
                    } else if (key >= 0xc2 and key <= 0xf4) {
                        const expected_len = std.unicode.utf8ByteSequenceLength(key) catch continue;
                        var utf8_buf: [4]u8 = undefined;
                        utf8_buf[0] = key;
                        var ok = true;
                        for (1..expected_len) |idx| {
                            const cb = try queue.readByteTimeout(input_fd, cancel, 25) orelse {
                                ok = false;
                                break;
                            };
                            if ((cb & 0xc0) != 0x80) {
                                ok = false;
                                break;
                            }
                            utf8_buf[idx] = cb;
                        }
                        if (ok and std.unicode.utf8ValidateSlice(utf8_buf[0..expected_len]) and list.filter.items.len + expected_len <= 128) {
                            try list.filter.appendSlice(allocator, utf8_buf[0..expected_len]);
                            try list.rebuild(source, false);
                            dirty = true;
                        }
                    }
                },
            }
        }
    }
}

pub fn renderLinesAlloc(
    allocator: std.mem.Allocator,
    source: Source,
    list: *const FilteredList,
    range: struct { usize, usize },
    size: std.posix.winsize,
    confirm_summary: bool,
    show_filter_bar: bool,
    options: Options,
    th: theme.Theme,
) ![][]u8 {
    const width = @max(1, @as(usize, size.col) -| 1);
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }

    if (size.row >= 3) {
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(allocator);
        if (options.title_hint.len > 0 and width >= options.title.len + options.title_hint.len + 3) {
            try th.appendOpen(&row, allocator, theme.Theme.accent);
            const used = try terminal.appendClippedText(&row, allocator, options.title, width);
            try th.appendClose(&row, allocator);
            try th.appendOpen(&row, allocator, theme.Theme.muted);
            _ = try terminal.appendClippedText(&row, allocator, options.title_hint, width -| used);
            try th.appendClose(&row, allocator);
        } else {
            _ = try terminal.appendClippedText(&row, allocator, options.title, width);
        }
        try lines.append(allocator, try row.toOwnedSlice(allocator));
    }

    if (show_filter_bar and size.row >= 4) {
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(allocator);
        try th.appendOpen(&row, allocator, theme.Theme.muted);
        const used = try terminal.appendClippedText(&row, allocator, "Filter: ", width);
        try th.appendClose(&row, allocator);
        _ = try terminal.appendClippedText(&row, allocator, list.filter.items, width -| used);
        try lines.append(allocator, try row.toOwnedSlice(allocator));
    }

    if (range[1] <= range[0]) {
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(allocator);
        try th.appendOpen(&row, allocator, theme.Theme.muted);
        _ = try terminal.appendClippedText(&row, allocator, "(no matches)", width);
        try th.appendClose(&row, allocator);
        try lines.append(allocator, try row.toOwnedSlice(allocator));
    } else {
        for (range[0]..range[1]) |pos| {
            var row: std.ArrayList(u8) = .empty;
            errdefer row.deinit(allocator);
            const index = list.indices.items[pos];
            const item = source.item(source.context, index);
            const is_selected = pos == list.selected_pos;
            if (is_selected) try row.appendSlice(allocator, "\x1b[7m");
            const marker: u8 = if (is_selected) '>' else ' ';
            const active: u8 = if (source.active == index or item.is_active) '*' else ' ';
            var remaining = width;
            remaining -= try terminal.appendClippedText(&row, allocator, &.{ marker, active, ' ' }, remaining);
            const indent_len: usize = if (item.depth > 4) 8 else item.depth * 2;
            const indent = "        "[0..indent_len];
            const visible_indent = indent[0..@min(indent.len, remaining)];
            try row.appendSlice(allocator, visible_indent);
            remaining -= visible_indent.len;
            remaining -= try terminal.appendClippedText(&row, allocator, item.id, remaining);
            if (item.role.len > 0) {
                remaining -= try terminal.appendClippedText(&row, allocator, " ", remaining);
                remaining -= try terminal.appendClippedText(&row, allocator, item.role, remaining);
            }
            if (item.preview.len > 0) {
                remaining -= try terminal.appendClippedText(&row, allocator, "  ", remaining);
                _ = try terminal.appendClippedText(&row, allocator, item.preview, remaining);
            }
            if (is_selected) try row.appendSlice(allocator, "\x1b[0m");
            try lines.append(allocator, try row.toOwnedSlice(allocator));
        }
    }

    if (size.row >= 2) {
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(allocator);
        if (confirm_summary and options.confirm_prompt != null) {
            _ = try terminal.appendClippedText(&row, allocator, options.confirm_prompt.?, width);
        } else {
            const shortcuts = if (width >= options.footer_full.len)
                options.footer_full
            else if (options.confirm_prompt != null and width >= options.confirm_prompt.?.len)
                options.footer_medium
            else
                options.footer_narrow;
            _ = try terminal.appendClippedText(&row, allocator, shortcuts, width);
        }
        try lines.append(allocator, try row.toOwnedSlice(allocator));
    }

    return try lines.toOwnedSlice(allocator);
}

pub fn renderFrame(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    source: Source,
    list: *const FilteredList,
    range: struct { usize, usize },
    size: std.posix.winsize,
    previous_rows: usize,
    confirm_summary: bool,
    show_filter_bar: bool,
    options: Options,
    th: theme.Theme,
) !void {
    const lines = try renderLinesAlloc(allocator, source, list, range, size, confirm_summary, show_filter_bar, options, th);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }
    if (previous_rows > 0) try out.print(allocator, "\x1b[{d}A", .{previous_rows});
    try out.appendSlice(allocator, "\r\x1b[J");
    for (lines, 0..) |l, i| {
        if (i > 0) try out.appendSlice(allocator, "\r\n");
        try out.appendSlice(allocator, l);
    }
}

test "fuzzyMatch ranks prefix and boundary matches and FilteredList filters and renders" {
    const a = std.testing.allocator;
    const s1 = fuzzyMatch("gpt5", "openai/gpt-5").?;
    const s2 = fuzzyMatch("gpt5", "anthropic/g-p-t-other-5").?;
    try std.testing.expect(s1 > s2);
    try std.testing.expectEqual(@as(?i32, null), fuzzyMatch("xyz", "openai/gpt-4o"));

    const items = [_]Item{
        .{ .id = "1", .role = "user", .preview = "first question 中文日本語한글", .is_user_message = true, .full_text = "first question 中文日本語한글" },
        .{ .id = "2", .role = "assistant", .preview = "answer about zig" },
    };
    const S = struct {
        fn get(ctx: *const anyopaque, idx: usize) Item {
            const arr: *const [2]Item = @ptrCast(@alignCast(ctx));
            return arr[idx];
        }
    };
    const source = Source{ .context = &items, .len = 2, .active = 1, .item = S.get };
    var fl = FilteredList.init(a);
    defer fl.deinit();
    try fl.rebuild(source, true);
    try std.testing.expectEqual(@as(usize, 2), fl.indices.items.len);
    try std.testing.expectEqual(@as(usize, 1), fl.selected_pos);

    try fl.filter.appendSlice(a, "zig");
    try fl.rebuild(source, false);
    try std.testing.expectEqual(@as(usize, 1), fl.indices.items.len);
    try std.testing.expectEqual(@as(usize, 1), fl.currentItemIndex().?);

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(a);
    try renderFrame(
        &frame,
        a,
        source,
        &fl,
        .{ 0, 1 },
        .{ .row = 6, .col = 28, .xpixel = 0, .ypixel = 0 },
        0,
        false,
        true,
        .{ .title = "Session tree" },
        theme.Theme.init(.none),
    );
    try std.testing.expect(std.mem.indexOf(u8, frame.items, "Filter: zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.items, "\x1b[7m>* 2 assistant") != null);
}
