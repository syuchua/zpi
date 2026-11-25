//! Inline `/` command and `@` path autocomplete popup rendered below the editor.
//! Uses subsequence fuzzy matching, keeps scrollback intact, and clips to terminal width.
const std = @import("std");
const select_list = @import("select_list.zig");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub const Kind = enum {
    command,
    path,
};

pub const Candidate = struct {
    label: []u8,
    description: []const u8 = "",
    score: i32 = 0,
    is_dir: bool = false,
};

pub const BuiltinCommandDesc = struct {
    name: []const u8,
    description: []const u8,
};

pub const builtin_commands = [_]BuiltinCommandDesc{
    .{ .name = "/help", .description = "Show help" },
    .{ .name = "/hotkeys", .description = "Show keyboard shortcuts" },
    .{ .name = "/search", .description = "Search transcript (Ctrl-F / Esc)" },
    .{ .name = "/session", .description = "Show session info" },
    .{ .name = "/resume", .description = "Switch session" },
    .{ .name = "/tree", .description = "Browse session branches" },
    .{ .name = "/model", .description = "Switch model" },
    .{ .name = "/thinking", .description = "Set thinking level" },
    .{ .name = "/compact", .description = "Compact conversation context" },
    .{ .name = "/copy", .description = "Copy last assistant reply to clipboard" },
    .{ .name = "/jobs", .description = "List background tasks" },
    .{ .name = "/exit", .description = "Exit zpi" },
    .{ .name = "/quit", .description = "Quit zpi" },
};

pub fn isBuiltin(name: []const u8) bool {
    for (builtin_commands) |command| if (std.mem.eql(u8, command.name, name)) return true;
    return false;
}

pub const Popup = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Candidate) = .empty,
    kind: Kind = .command,
    token_start: usize = 0,
    token_end: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    user_navigated: bool = false,
    dismissed: bool = false,
    last_token: []u8 = &.{},
    last_token_start: usize = 0,

    pub const max_visible: usize = 6;
    pub const max_dir_scan: usize = 256;
    pub const max_results: usize = 64;

    pub fn init(allocator: std.mem.Allocator) Popup {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Popup) void {
        self.clearItems();
        self.items.deinit(self.allocator);
        if (self.last_token.len > 0) self.allocator.free(self.last_token);
    }

    fn clearItems(self: *Popup) void {
        for (self.items.items) |item| self.allocator.free(item.label);
        self.items.clearRetainingCapacity();
        self.selected = 0;
        self.scroll = 0;
        self.user_navigated = false;
    }

    pub fn isOpen(self: *const Popup) bool {
        return !self.dismissed and self.items.items.len > 0;
    }

    pub fn dismiss(self: *Popup) void {
        self.dismissed = true;
        self.user_navigated = false;
    }

    pub fn clear(self: *Popup) void {
        self.clearItems();
        self.dismissed = false;
        if (self.last_token.len > 0) {
            self.allocator.free(self.last_token);
            self.last_token = &.{};
        }
        self.last_token_start = 0;
    }

    pub fn selectedItem(self: *const Popup) ?Candidate {
        if (!self.isOpen()) return null;
        if (self.selected >= self.items.items.len) return null;
        return self.items.items[self.selected];
    }

    pub fn moveUp(self: *Popup) void {
        if (!self.isOpen()) return;
        self.user_navigated = true;
        if (self.selected > 0) {
            self.selected -= 1;
        } else {
            self.selected = self.items.items.len - 1;
        }
        self.syncScroll();
    }

    pub fn moveDown(self: *Popup) void {
        if (!self.isOpen()) return;
        self.user_navigated = true;
        if (self.selected + 1 < self.items.items.len) {
            self.selected += 1;
        } else {
            self.selected = 0;
        }
        self.syncScroll();
    }

    fn syncScroll(self: *Popup) void {
        if (self.selected < self.scroll) {
            self.scroll = self.selected;
        } else if (self.selected >= self.scroll + max_visible) {
            self.scroll = self.selected + 1 - max_visible;
        }
    }

    pub fn commonPrefixLen(self: *const Popup) usize {
        if (self.items.items.len == 0) return 0;
        var len = self.items.items[0].label.len;
        for (self.items.items[1..]) |item| {
            len = @min(len, item.label.len);
            var i: usize = 0;
            while (i < len and self.items.items[0].label[i] == item.label[i]) : (i += 1) {}
            len = i;
        }
        return len;
    }

    pub fn refresh(
        self: *Popup,
        io: std.Io,
        buf: []const u8,
        cursor: usize,
        extra_commands: []const []const u8,
        cwd: ?[]const u8,
    ) !void {
        const clamped = @min(cursor, buf.len);
        var token_start = clamped;
        while (token_start > 0 and !std.ascii.isWhitespace(buf[token_start - 1])) : (token_start -= 1) {}
        const token = buf[token_start..clamped];

        const active_kind: ?Kind = if (token_start == 0 and token.len >= 1 and token[0] == '/')
            .command
        else if (token.len >= 1 and token[0] == '@')
            .path
        else
            null;

        if (active_kind == null) {
            self.clear();
            return;
        }

        const same_token = token_start == self.last_token_start and std.mem.eql(u8, token, self.last_token);
        if (same_token and self.dismissed) return;
        if (!same_token) {
            self.dismissed = false;
            if (self.last_token.len > 0) self.allocator.free(self.last_token);
            self.last_token = try self.allocator.dupe(u8, token);
            self.last_token_start = token_start;
        } else if (self.items.items.len > 0) {
            self.token_start = token_start;
            self.token_end = clamped;
            return;
        }

        self.clearItems();
        self.kind = active_kind.?;
        self.token_start = token_start;
        self.token_end = clamped;

        switch (active_kind.?) {
            .command => try self.populateCommands(token, extra_commands),
            .path => try self.populatePaths(io, token, cwd orelse "."),
        }
    }

    fn populateCommands(self: *Popup, token: []const u8, extra_commands: []const []const u8) !void {
        const query = token[1..];
        // Prefer prefix matches when any command starts with `query`; fall back to
        // subsequence fuzzy matching only when there are zero prefix matches.
        var has_prefix = false;
        if (query.len > 0) {
            for (builtin_commands) |cmd| {
                const body = if (cmd.name.len > 0 and cmd.name[0] == '/') cmd.name[1..] else cmd.name;
                if (body.len >= query.len and std.ascii.eqlIgnoreCase(body[0..query.len], query)) {
                    has_prefix = true;
                    break;
                }
            }
            if (!has_prefix) {
                for (extra_commands) |cmd| {
                    const body = if (cmd.len > 0 and cmd[0] == '/') cmd[1..] else cmd;
                    if (body.len >= query.len and std.ascii.eqlIgnoreCase(body[0..query.len], query)) {
                        has_prefix = true;
                        break;
                    }
                }
            }
        }

        for (builtin_commands) |cmd| {
            const score = rankCommand(query, cmd.name, has_prefix) orelse continue;
            try self.appendUniqueCommand(cmd.name, cmd.description, score);
        }
        for (extra_commands) |cmd| {
            const score = rankCommand(query, cmd, has_prefix) orelse continue;
            const desc: []const u8 = if (std.mem.startsWith(u8, cmd, "/skill:")) "Skill" else "Template";
            try self.appendUniqueCommand(cmd, desc, score);
        }
        std.mem.sort(Candidate, self.items.items, {}, struct {
            fn less(_: void, l: Candidate, r: Candidate) bool {
                if (l.score != r.score) return l.score > r.score;
                return std.mem.order(u8, l.label, r.label) == .lt;
            }
        }.less);
    }

    fn rankCommand(query: []const u8, name: []const u8, prefix_only: bool) ?i32 {
        if (query.len == 0) return 0;
        const body = if (name.len > 0 and name[0] == '/') name[1..] else name;
        const is_prefix = body.len >= query.len and std.ascii.eqlIgnoreCase(body[0..query.len], query);
        if (prefix_only and !is_prefix) return null;
        const fuzzy = select_list.fuzzyMatch(query, body) orelse return null;
        return fuzzy + (if (is_prefix) @as(i32, 100) else 0);
    }

    fn appendUniqueCommand(self: *Popup, name: []const u8, desc: []const u8, score: i32) !void {
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing.label, name)) return;
        }
        try self.items.append(self.allocator, .{
            .label = try self.allocator.dupe(u8, name),
            .description = desc,
            .score = score,
        });
    }

    fn populatePaths(self: *Popup, io: std.Io, token: []const u8, base_dir: []const u8) !void {
        const raw_prefix = token[1..];
        const slash_pos = std.mem.lastIndexOfScalar(u8, raw_prefix, '/');
        const dir_part = if (slash_pos) |idx| raw_prefix[0 .. idx + 1] else "";
        const leaf_part = if (slash_pos) |idx| raw_prefix[idx + 1 ..] else raw_prefix;

        const scan_dir = if (dir_part.len == 0)
            try self.allocator.dupe(u8, base_dir)
        else
            try std.fs.path.resolveAlloc(self.allocator, &.{ base_dir, dir_part });
        defer self.allocator.free(scan_dir);

        var dir = std.Io.Dir.cwd().openDir(io, scan_dir, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        var scanned: usize = 0;
        while (it.next(io) catch null) |entry| {
            scanned += 1;
            if (scanned > max_dir_scan) break;
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (leaf_part.len == 0 and entry.name.len > 0 and entry.name[0] == '.') continue;
            const fuzzy = if (leaf_part.len == 0)
                @as(i32, 0)
            else
                select_list.fuzzyMatch(leaf_part, entry.name) orelse continue;
            const prefix_boost: i32 = if (leaf_part.len > 0 and entry.name.len >= leaf_part.len and std.ascii.eqlIgnoreCase(entry.name[0..leaf_part.len], leaf_part)) 100 else 0;
            const is_dir = entry.kind == .directory;
            const label = if (is_dir)
                try std.fmt.allocPrint(self.allocator, "@{s}{s}/", .{ dir_part, entry.name })
            else
                try std.fmt.allocPrint(self.allocator, "@{s}{s}", .{ dir_part, entry.name });
            errdefer self.allocator.free(label);

            var dup = false;
            for (self.items.items) |existing| {
                if (std.mem.eql(u8, existing.label, label)) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                self.allocator.free(label);
                continue;
            }
            try self.items.append(self.allocator, .{
                .label = label,
                .score = fuzzy + prefix_boost + (if (is_dir) @as(i32, 5) else 0),
                .is_dir = is_dir,
            });
            if (self.items.items.len >= max_results) break;
        }

        std.mem.sort(Candidate, self.items.items, {}, struct {
            fn less(_: void, l: Candidate, r: Candidate) bool {
                if (l.score != r.score) return l.score > r.score;
                return std.mem.order(u8, l.label, r.label) == .lt;
            }
        }.less);
    }

    pub fn renderLinesAlloc(self: *const Popup, allocator: std.mem.Allocator, th: theme.Theme, cols_raw: usize) ![][]u8 {
        if (!self.isOpen()) return try allocator.alloc([]u8, 0);
        const max_cols = @max(@as(usize, 12), cols_raw -| 1);
        const total = self.items.items.len;
        const start = @min(self.scroll, total -| 1);
        const end = @min(total, start + max_visible);
        const count = end - start;
        const has_more = total > max_visible;
        const total_lines = count + @as(usize, if (has_more) 1 else 0);

        var out = try allocator.alloc([]u8, total_lines);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |l| allocator.free(l);
            allocator.free(out);
        }

        for (self.items.items[start..end], start..) |item, idx| {
            var raw: std.ArrayList(u8) = .empty;
            defer raw.deinit(allocator);
            const is_sel = idx == self.selected;
            if (is_sel) {
                try th.paint(&raw, allocator, theme.Theme.accent, "▸ ");
                try th.appendOpen(&raw, allocator, theme.Theme.accent);
                try raw.appendSlice(allocator, item.label);
                try th.appendClose(&raw, allocator);
            } else {
                try raw.appendSlice(allocator, "  ");
                try raw.appendSlice(allocator, item.label);
            }
            if (item.description.len > 0) {
                const lw = terminal.visibleWidth(item.label);
                const pad = if (lw < 18) 18 - lw else 2;
                try raw.appendNTimes(allocator, ' ', pad);
                try th.paint(&raw, allocator, theme.Theme.muted, item.description);
            }
            var clipped: std.ArrayList(u8) = .empty;
            errdefer clipped.deinit(allocator);
            _ = try terminal.appendTruncatedAnsi(&clipped, allocator, raw.items, max_cols, "...");
            out[built] = try clipped.toOwnedSlice(allocator);
            built += 1;
        }
        if (has_more) {
            var info_buf: [64]u8 = undefined;
            const info = try std.fmt.bufPrint(&info_buf, "  ({d}/{d} · ↑/↓ select, Tab/Enter accept, Esc close)", .{ self.selected + 1, total });
            var raw: std.ArrayList(u8) = .empty;
            defer raw.deinit(allocator);
            try th.paint(&raw, allocator, theme.Theme.muted, info);
            var clipped: std.ArrayList(u8) = .empty;
            errdefer clipped.deinit(allocator);
            _ = try terminal.appendTruncatedAnsi(&clipped, allocator, raw.items, max_cols, "...");
            out[built] = try clipped.toOwnedSlice(allocator);
            built += 1;
        }
        return out;
    }
};

test "AutocompletePopup filters /commands and @paths with fuzzy match and Up/Down/dismiss" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "alpha.txt", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "beta_note.md", .data = "b" });
    try tmp.dir.createDirPath(std.testing.io, "sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/inside.zig", .data = "c" });

    const cwd = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer a.free(cwd);

    var popup = Popup.init(a);
    defer popup.deinit();

    // `/` shows all commands + extras.
    try popup.refresh(std.testing.io, "/", 1, &.{"/skill:zig"}, cwd);
    try std.testing.expect(popup.isOpen());
    try std.testing.expect(popup.items.items.len >= 11);

    // `/h` narrows to /help and /hotkeys.
    try popup.refresh(std.testing.io, "/h", 2, &.{"/skill:zig"}, cwd);
    try std.testing.expectEqual(@as(usize, 2), popup.items.items.len);
    try std.testing.expectEqualStrings("/help", popup.selectedItem().?.label);
    popup.moveDown();
    try std.testing.expectEqualStrings("/hotkeys", popup.selectedItem().?.label);
    popup.dismiss();
    try std.testing.expect(!popup.isOpen());

    // Typing `e` changes token -> reopens narrowed to /help.
    try popup.refresh(std.testing.io, "/he", 3, &.{"/skill:zig"}, cwd);
    try std.testing.expect(popup.isOpen());
    try std.testing.expectEqual(@as(usize, 1), popup.items.items.len);
    try std.testing.expectEqualStrings("/help", popup.items.items[0].label);

    // `@` lists directory entries; `@sub/` drills into subdirectory.
    try popup.refresh(std.testing.io, "read @", 6, &.{}, cwd);
    try std.testing.expect(popup.isOpen());
    try std.testing.expectEqual(Kind.path, popup.kind);
    try std.testing.expect(popup.items.items.len == 3);

    try popup.refresh(std.testing.io, "read @sub/", 10, &.{}, cwd);
    try std.testing.expectEqual(@as(usize, 1), popup.items.items.len);
    try std.testing.expectEqualStrings("@sub/inside.zig", popup.items.items[0].label);

    const rendered = try popup.renderLinesAlloc(a, theme.Theme.init(.ansi16), 60);
    defer {
        for (rendered) |line| a.free(line);
        a.free(rendered);
    }
    try std.testing.expectEqual(@as(usize, 1), rendered.len);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0], "@sub/inside.zig") != null);
    try std.testing.expect(terminal.visibleWidth(rendered[0]) <= 60);
}
