//! Regular terminal UI with Zig-native raw-mode line editing, UTF-8 cursor
//! navigation, in-session history, multi-line input, and /command / @path Tab
//! completion. Preserves terminal scrollback (never enters alternate screen)
//! and restores termios attributes before every command turn or exit.
const std = @import("std");
const agent = @import("agent");

pub const max_prompt_bytes: usize = 64 * 1024;
const max_history_entries: usize = 200;

pub const Submit = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, []const u8) anyerror!void,
    session_info: ?*const fn (*anyopaque) anyerror!void = null,
    cancel: ?agent.model.Cancel = null,
    reset_cancel: ?*const fn (*anyopaque) void = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    cwd: ?[]const u8 = null,
    commands: []const []const u8 = &.{},
};

const InputQueue = struct {
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn hasBuffered(self: *const InputQueue) bool {
        return self.start < self.end;
    }

    fn readByteTimeout(self: *InputQueue, fd: std.posix.fd_t, cancel: ?agent.model.Cancel, timeout_ms: i32) !?u8 {
        if (self.start < self.end) {
            const b = self.buf[self.start];
            self.start += 1;
            return b;
        }
        if (cancel) |token| {
            if (token.isCanceled()) return error.Canceled;
        }
        var pollfds: [2]std.posix.pollfd = undefined;
        var nfds: usize = 1;
        pollfds[0] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        if (cancel) |token| {
            if (token.poll_fd) |cancel_fd| {
                pollfds[1] = .{ .fd = cancel_fd, .events = std.posix.POLL.IN, .revents = 0 };
                nfds = 2;
            }
        }
        while (true) {
            const ready = std.posix.poll(pollfds[0..nfds], timeout_ms) catch |err| switch (err) {
                else => return err,
            };
            if (cancel) |token| {
                if (token.isCanceled() or (nfds == 2 and (pollfds[1].revents & std.posix.POLL.IN) != 0)) {
                    return error.Canceled;
                }
            }
            if (ready == 0) return null;
            if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                const n = std.posix.read(fd, &self.buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        pollfds[0].revents = 0;
                        if (nfds == 2) pollfds[1].revents = 0;
                        continue;
                    },
                    else => return err,
                };
                if (n == 0) return null;
                self.start = 1;
                self.end = n;
                return self.buf[0];
            }
            pollfds[0].revents = 0;
            if (nfds == 2) pollfds[1].revents = 0;
        }
    }

    fn readByte(self: *InputQueue, fd: std.posix.fd_t, cancel: ?agent.model.Cancel) !?u8 {
        return self.readByteTimeout(fd, cancel, -1);
    }
};

const History = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *History) void {
        for (self.items.items) |entry| self.allocator.free(entry);
        self.items.deinit(self.allocator);
    }

    fn push(self: *History, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], text)) return;
        if (self.items.items.len >= max_history_entries) {
            self.allocator.free(self.items.orderedRemove(0));
        }
        try self.items.append(self.allocator, try self.allocator.dupe(u8, text));
    }
};

pub fn run(io: std.Io, submit: Submit) !void {
    const input = std.Io.File.stdin();
    const output = std.Io.File.stdout();
    if (!try input.isTty(io) or !try output.isTty(io)) return error.InteractiveTtyRequired;
    const color = try output.supportsAnsiEscapeCodes(io);
    try output.writeStreamingAll(io, if (color)
        "\x1b[1;36mzpi\x1b[0m  /help · /hotkeys · /exit · Ctrl-D exits\n"
    else
        "zpi  /help · /hotkeys · /exit · Ctrl-D exits\n");

    var queue = InputQueue{};
    var history = History{ .allocator = submit.allocator };
    defer history.deinit();

    while (true) {
        if (submit.reset_cancel) |reset| reset(submit.context);
        const prompt_prefix = if (color) "\x1b[36m>\x1b[0m " else "> ";
        try output.writeStreamingAll(io, prompt_prefix);
        const raw = readPromptLine(submit.allocator, io, input.handle, output, &queue, &history, submit, color) catch |err| switch (err) {
            error.Canceled => {
                try output.writeStreamingAll(io, "\n");
                continue;
            },
            error.StreamTooLong => {
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: prompt exceeds 64 KiB; discarded\n");
                continue;
            },
            else => return err,
        } orelse return;
        defer submit.allocator.free(raw);

        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) continue;
        try history.push(text);
        if (std.mem.eql(u8, text, "/exit") or std.mem.eql(u8, text, "/quit")) return;
        if (std.mem.eql(u8, text, "/help")) {
            try output.writeStreamingAll(io, "Enter a task to stream a response and run tools. /exit leaves the session.\nUse --session PATH to reopen; add --branch ENTRY-ID to continue from an earlier point.\nTab completes /commands and @paths; Up/Down navigates history; Alt+Enter or trailing \\ adds a newline.\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/hotkeys")) {
            try output.writeStreamingAll(io, "Keyboard shortcuts\nCtrl-C    Cancel current turn or clear prompt\nCtrl-D    Exit on empty line / delete char\nUp/Down   Navigate history or lines\nLeft/Right Move cursor (Ctrl-A/E home/end)\nCtrl-W/U/K Delete word / to start / to end\nTab       Complete /command or @path\nAlt+Enter Insert newline (or trailing \\)\n/exit     Exit (/quit)\n/help     Show help\n/session  Show current session summary\n/hotkeys  Show shortcuts\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/session")) {
            if (submit.session_info) |show| try show(submit.context);
            continue;
        }
        submit.run(submit.context, text) catch |err| {
            var msg: [256]u8 = undefined;
            const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
            try std.Io.File.stderr().writeStreamingAll(io, line);
        };
    }
}

/// Terminal-facing output escapes control sequences in untrusted content;
/// preserve newlines/tabs and UTF-8 bytes. JSON mode uses a JSON encoder instead.
pub fn writeText(io: std.Io, file: std.Io.File, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f) {
            try file.writeStreamingAll(io, text[start..i]);
            try file.writeStreamingAll(io, "?");
            start = i + 1;
        }
    }
    try file.writeStreamingAll(io, text[start..]);
}

fn terminalColumns(io: std.Io, output: std.Io.File) usize {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = io.operate(.{ .device_io_control = .{
        .file = output,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return 80;
    if (rc.device_io_control >= 0 and ws.col > 0) return ws.col;
    return 80;
}

const EditorState = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history_idx: ?usize = null,
    draft: ?[]u8 = null,
    rendered_cursor_row: usize = 0,
    last_tab_prefix: ?[]u8 = null,

    fn deinit(self: *EditorState) void {
        self.buf.deinit(self.allocator);
        if (self.draft) |d| self.allocator.free(d);
        if (self.last_tab_prefix) |p| self.allocator.free(p);
    }

    fn resetCompletionTrack(self: *EditorState) void {
        if (self.last_tab_prefix) |p| {
            self.allocator.free(p);
            self.last_tab_prefix = null;
        }
    }

    fn insertSlice(self: *EditorState, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.buf.items.len + bytes.len > max_prompt_bytes) return error.StreamTooLong;
        self.resetCompletionTrack();
        try self.buf.insertSlice(self.allocator, self.cursor, bytes);
        self.cursor += bytes.len;
    }

    fn moveLeft(self: *EditorState) void {
        self.resetCompletionTrack();
        if (self.cursor == 0) return;
        self.cursor -= 1;
        while (self.cursor > 0 and (self.buf.items[self.cursor] & 0xc0) == 0x80) : (self.cursor -= 1) {}
    }

    fn moveRight(self: *EditorState) void {
        self.resetCompletionTrack();
        if (self.cursor >= self.buf.items.len) return;
        const seq_len = std.unicode.utf8ByteSequenceLength(self.buf.items[self.cursor]) catch 1;
        self.cursor = @min(self.buf.items.len, self.cursor + seq_len);
    }

    fn moveHome(self: *EditorState) void {
        self.resetCompletionTrack();
        const line_start = if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor], '\n')) |nl| nl + 1 else 0;
        self.cursor = line_start;
    }

    fn moveEnd(self: *EditorState) void {
        self.resetCompletionTrack();
        const line_end = if (std.mem.indexOfScalarPos(u8, self.buf.items, self.cursor, '\n')) |nl| nl else self.buf.items.len;
        self.cursor = line_end;
    }

    fn moveWordLeft(self: *EditorState) void {
        self.resetCompletionTrack();
        while (self.cursor > 0 and std.ascii.isWhitespace(self.buf.items[self.cursor - 1])) : (self.cursor -= 1) {}
        while (self.cursor > 0 and !std.ascii.isWhitespace(self.buf.items[self.cursor - 1])) {
            self.moveLeft();
            if (self.cursor > 0 and std.ascii.isWhitespace(self.buf.items[self.cursor - 1])) break;
        }
    }

    fn moveWordRight(self: *EditorState) void {
        self.resetCompletionTrack();
        while (self.cursor < self.buf.items.len and std.ascii.isWhitespace(self.buf.items[self.cursor])) : (self.cursor += 1) {}
        while (self.cursor < self.buf.items.len and !std.ascii.isWhitespace(self.buf.items[self.cursor])) {
            self.moveRight();
        }
    }

    fn backspace(self: *EditorState) void {
        self.resetCompletionTrack();
        if (self.cursor == 0) return;
        const prev = self.cursor;
        self.moveLeft();
        const count = prev - self.cursor;
        self.buf.replaceRange(self.allocator, self.cursor, count, &.{}) catch unreachable;
    }

    fn deleteAtCursor(self: *EditorState) void {
        self.resetCompletionTrack();
        if (self.cursor >= self.buf.items.len) return;
        const seq_len = @min(self.buf.items.len - self.cursor, std.unicode.utf8ByteSequenceLength(self.buf.items[self.cursor]) catch 1);
        self.buf.replaceRange(self.allocator, self.cursor, seq_len, &.{}) catch unreachable;
    }

    fn killToLineStart(self: *EditorState) void {
        self.resetCompletionTrack();
        const line_start = if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor], '\n')) |nl| nl + 1 else 0;
        if (self.cursor > line_start) {
            self.buf.replaceRange(self.allocator, line_start, self.cursor - line_start, &.{}) catch unreachable;
            self.cursor = line_start;
        }
    }

    fn killToLineEnd(self: *EditorState) void {
        self.resetCompletionTrack();
        const line_end = if (std.mem.indexOfScalarPos(u8, self.buf.items, self.cursor, '\n')) |nl| nl else self.buf.items.len;
        if (line_end > self.cursor) {
            self.buf.replaceRange(self.allocator, self.cursor, line_end - self.cursor, &.{}) catch unreachable;
        }
    }

    fn killWordBack(self: *EditorState) void {
        self.resetCompletionTrack();
        const orig = self.cursor;
        while (self.cursor > 0 and std.ascii.isWhitespace(self.buf.items[self.cursor - 1])) : (self.cursor -= 1) {}
        while (self.cursor > 0 and !std.ascii.isWhitespace(self.buf.items[self.cursor - 1])) : (self.cursor -= 1) {}
        while (self.cursor > 0 and (self.buf.items[self.cursor] & 0xc0) == 0x80) : (self.cursor -= 1) {}
        if (orig > self.cursor) {
            self.buf.replaceRange(self.allocator, self.cursor, orig - self.cursor, &.{}) catch unreachable;
        }
    }

    fn moveUpLineOrHistory(self: *EditorState, history: *const History) !void {
        self.resetCompletionTrack();
        if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor], '\n')) |cur_nl| {
            const col = utf8Columns(self.buf.items[cur_nl + 1 .. self.cursor]);
            const prev_start = if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..cur_nl], '\n')) |p| p + 1 else 0;
            self.cursor = advanceByColumns(self.buf.items[prev_start..cur_nl], col) + prev_start;
            return;
        }
        if (history.items.items.len == 0) return;
        const next_idx = if (self.history_idx) |idx| (if (idx > 0) idx - 1 else return) else blk: {
            if (self.draft) |d| self.allocator.free(d);
            self.draft = try self.allocator.dupe(u8, self.buf.items);
            break :blk history.items.items.len - 1;
        };
        try self.replaceBuffer(history.items.items[next_idx]);
        self.history_idx = next_idx;
    }

    fn moveDownLineOrHistory(self: *EditorState, history: *const History) !void {
        self.resetCompletionTrack();
        if (std.mem.indexOfScalarPos(u8, self.buf.items, self.cursor, '\n')) |next_nl| {
            const line_start = if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor], '\n')) |p| p + 1 else 0;
            const col = utf8Columns(self.buf.items[line_start..self.cursor]);
            const next_end = if (std.mem.indexOfScalarPos(u8, self.buf.items, next_nl + 1, '\n')) |e| e else self.buf.items.len;
            self.cursor = advanceByColumns(self.buf.items[next_nl + 1 .. next_end], col) + next_nl + 1;
            return;
        }
        const idx = self.history_idx orelse return;
        if (idx + 1 < history.items.items.len) {
            try self.replaceBuffer(history.items.items[idx + 1]);
            self.history_idx = idx + 1;
        } else {
            const saved = self.draft orelse "";
            try self.replaceBuffer(saved);
            if (self.draft) |d| {
                self.allocator.free(d);
                self.draft = null;
            }
            self.history_idx = null;
        }
    }

    fn replaceBuffer(self: *EditorState, text: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, text);
        self.cursor = self.buf.items.len;
    }

    fn render(self: *EditorState, io: std.Io, output: std.Io.File, cols: usize, color: bool) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        if (self.rendered_cursor_row > 0) {
            try out.print(self.allocator, "\x1b[{d}A", .{self.rendered_cursor_row});
        }
        try out.appendSlice(self.allocator, "\r\x1b[J");
        try out.appendSlice(self.allocator, if (color) "\x1b[36m>\x1b[0m " else "> ");

        // Compute visual coordinates (prompt width = 2 on line 0) across newlines and soft wraps.
        const layout = computeLayout(self.buf.items, self.cursor, cols, 2);
        try appendSafeTerminalBytes(&out, self.allocator, self.buf.items);

        // If cursor is not at the end, or if final byte wrapped exactly at column boundary,
        // move from end_row/end_col back to cursor_row/cursor_col.
        const end_row = layout.end_row;
        const end_col = layout.end_col;
        if (end_row > layout.cursor_row) {
            try out.print(self.allocator, "\x1b[{d}A", .{end_row - layout.cursor_row});
        }
        if (end_col != layout.cursor_col or end_row != layout.cursor_row) {
            try out.append(self.allocator, '\r');
            if (layout.cursor_col > 0) {
                try out.print(self.allocator, "\x1b[{d}C", .{layout.cursor_col});
            }
        }
        self.rendered_cursor_row = layout.cursor_row;
        try output.writeStreamingAll(io, out.items);
    }
};

fn appendSafeTerminalBytes(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        if (byte == '\n') {
            try out.appendSlice(a, "\n  ");
        } else if ((byte < 0x20 and byte != '\t') or byte == 0x7f) {
            try out.append(a, '?');
        } else {
            try out.append(a, byte);
        }
    }
}

fn utf8Columns(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = @min(len, text.len - i);
        const cp = std.unicode.utf8Decode(text[i .. i + step]) catch 0xFFFD;
        cols += codepointWidth(cp);
        i += step;
    }
    return cols;
}

fn codepointWidth(cp: u21) usize {
    if (cp == 0) return 0;
    if ((cp >= 0x1100 and cp <= 0x115F) or
        cp == 0x2329 or cp == 0x232A or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD))
    {
        return 2;
    }
    return 1;
}

fn advanceByColumns(line: []const u8, target_cols: usize) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < line.len and cols < target_cols) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const step = @min(len, line.len - i);
        const cp = std.unicode.utf8Decode(line[i .. i + step]) catch 0xFFFD;
        const w = codepointWidth(cp);
        if (cols + w > target_cols) break;
        cols += w;
        i += step;
    }
    return i;
}

const Layout = struct {
    cursor_row: usize,
    cursor_col: usize,
    end_row: usize,
    end_col: usize,
};

fn computeLayout(text: []const u8, cursor: usize, cols_raw: usize, prompt_cols: usize) Layout {
    const cols = @max(cols_raw, 4);
    var row: usize = 0;
    var col: usize = prompt_cols;
    var cursor_row: usize = 0;
    var cursor_col: usize = prompt_cols;
    var i: usize = 0;
    while (i <= text.len) {
        if (i == cursor) {
            cursor_row = row;
            cursor_col = col;
        }
        if (i == text.len) break;
        if (text[i] == '\n') {
            row += 1;
            col = 2; // continuation indent matches "\n  "
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = @min(len, text.len - i);
        const cp = std.unicode.utf8Decode(text[i .. i + step]) catch 0xFFFD;
        const w: usize = if (text[i] == '\t') 4 else codepointWidth(cp);
        if (col + w > cols) {
            row += 1;
            col = 0;
        }
        col += w;
        if (col >= cols) {
            row += 1;
            col = 0;
        }
        i += step;
    }
    return .{ .cursor_row = cursor_row, .cursor_col = cursor_col, .end_row = row, .end_col = col };
}

const builtin_commands = [_][]const u8{ "/help", "/hotkeys", "/session", "/exit", "/quit" };

fn handleTab(editor: *EditorState, io: std.Io, output: std.Io.File, submit: Submit, cols: usize, color: bool) !bool {
    // Identify token immediately before cursor (bounded by whitespace).
    var token_start = editor.cursor;
    while (token_start > 0 and !std.ascii.isWhitespace(editor.buf.items[token_start - 1])) : (token_start -= 1) {}
    const token = editor.buf.items[token_start..editor.cursor];
    if (token.len == 0) return false;

    var matches: std.ArrayList([]u8) = .empty;
    defer {
        for (matches.items) |m| editor.allocator.free(m);
        matches.deinit(editor.allocator);
    }

    var is_command = false;
    if (token_start == 0 and token[0] == '/') {
        is_command = true;
        for (builtin_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, token)) try appendUnique(&matches, editor.allocator, cmd);
        }
        for (submit.commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, token)) try appendUnique(&matches, editor.allocator, cmd);
        }
    } else if (token[0] == '@') {
        const raw_prefix = token[1..];
        const base_dir = submit.cwd orelse ".";
        const slash_pos = std.mem.lastIndexOfScalar(u8, raw_prefix, '/');
        const dir_part = if (slash_pos) |idx| raw_prefix[0 .. idx + 1] else "";
        const leaf_part = if (slash_pos) |idx| raw_prefix[idx + 1 ..] else raw_prefix;
        const scan_dir = if (dir_part.len == 0) try editor.allocator.dupe(u8, base_dir) else try std.fs.path.resolveAlloc(editor.allocator, &.{ base_dir, dir_part });
        defer editor.allocator.free(scan_dir);

        if (std.Io.Dir.cwd().openDir(io, scan_dir, .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                if (leaf_part.len == 0 and entry.name.len > 0 and entry.name[0] == '.') continue;
                if (!std.mem.startsWith(u8, entry.name, leaf_part)) continue;
                const candidate = if (entry.kind == .directory)
                    try std.fmt.allocPrint(editor.allocator, "@{s}{s}/", .{ dir_part, entry.name })
                else
                    try std.fmt.allocPrint(editor.allocator, "@{s}{s}", .{ dir_part, entry.name });
                errdefer editor.allocator.free(candidate);
                try appendUnique(&matches, editor.allocator, candidate);
                editor.allocator.free(candidate);
                if (matches.items.len >= 64) break;
            }
        } else |_| {}
    } else return false;

    if (matches.items.len == 0) return false;
    std.mem.sort([]u8, matches.items, {}, struct {
        fn less(_: void, l: []u8, r: []u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.less);

    if (matches.items.len == 1) {
        const chosen = matches.items[0];
        const suffix = chosen[token.len..];
        if (suffix.len > 0) try editor.insertSlice(suffix);
        if (is_command and editor.cursor == editor.buf.items.len) try editor.insertSlice(" ");
        return true;
    }

    const lcp_len = commonPrefixLen(matches.items);
    if (lcp_len > token.len) {
        try editor.insertSlice(matches.items[0][token.len..lcp_len]);
        return true;
    }

    // Second Tab on the same ambiguous prefix prints candidate list below prompt.
    const same_prefix = if (editor.last_tab_prefix) |prev| std.mem.eql(u8, prev, token) else false;
    if (!same_prefix) {
        editor.resetCompletionTrack();
        editor.last_tab_prefix = try editor.allocator.dupe(u8, token);
        return false;
    }
    var list_out: std.ArrayList(u8) = .empty;
    defer list_out.deinit(editor.allocator);
    try list_out.append(editor.allocator, '\n');
    const shown = @min(matches.items.len, 24);
    for (matches.items[0..shown], 0..) |m, idx| {
        if (idx > 0) try list_out.appendSlice(editor.allocator, "  ");
        try list_out.appendSlice(editor.allocator, m);
    }
    if (matches.items.len > shown) {
        try list_out.print(editor.allocator, "  (+{d} more)", .{matches.items.len - shown});
    }
    try list_out.append(editor.allocator, '\n');
    try output.writeStreamingAll(io, list_out.items);
    editor.rendered_cursor_row = 0;
    try editor.render(io, output, cols, color);
    return false;
}

fn appendUnique(list: *std.ArrayList([]u8), a: std.mem.Allocator, text: []const u8) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, text)) return;
    }
    try list.append(a, try a.dupe(u8, text));
}

fn commonPrefixLen(items: []const []u8) usize {
    if (items.len == 0) return 0;
    var len = items[0].len;
    for (items[1..]) |item| {
        len = @min(len, item.len);
        var i: usize = 0;
        while (i < len and items[0][i] == item[i]) : (i += 1) {}
        len = i;
    }
    return len;
}

fn readPromptLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    history: *const History,
    submit: Submit,
    color: bool,
) anyerror!?[]u8 {
    if (submit.cancel) |token| {
        if (token.isCanceled()) return error.Canceled;
    }
    const orig_term = try std.posix.tcgetattr(input_fd);
    var raw_term = orig_term;
    raw_term.lflag.ICANON = false;
    raw_term.lflag.ECHO = false;
    raw_term.lflag.IEXTEN = false;
    raw_term.iflag.ICRNL = false;
    raw_term.iflag.IXON = false;
    raw_term.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw_term.cc[@backingInt(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(input_fd, .NOW, raw_term);
    defer std.posix.tcsetattr(input_fd, .NOW, orig_term) catch {};

    try output.writeStreamingAll(io, "\x1b[?2004h");
    defer output.writeStreamingAll(io, "\x1b[?2004l") catch {};

    var editor = EditorState{ .allocator = allocator };
    defer editor.deinit();

    var in_paste = false;
    var cols = terminalColumns(io, output);
    var dirty = false;

    while (true) {
        if (dirty and !queue.hasBuffered()) {
            cols = terminalColumns(io, output);
            try editor.render(io, output, cols, color);
            dirty = false;
        }
        const b_opt = try queue.readByte(input_fd, submit.cancel);
        const b = b_opt orelse {
            if (editor.buf.items.len == 0) {
                try output.writeStreamingAll(io, "\n");
                return null;
            }
            return try editor.buf.toOwnedSlice(allocator);
        };

        switch (b) {
            0x03 => return error.Canceled,
            0x04 => {
                if (editor.buf.items.len == 0) {
                    try output.writeStreamingAll(io, "\n");
                    return null;
                }
                editor.deleteAtCursor();
                dirty = true;
            },
            '\r', '\n' => {
                if (in_paste) {
                    try editor.insertSlice("\n");
                    dirty = true;
                    continue;
                }
                if (editor.cursor == editor.buf.items.len and editor.buf.items.len > 0 and editor.buf.items[editor.buf.items.len - 1] == '\\') {
                    editor.buf.items.len -= 1;
                    editor.cursor -= 1;
                    try editor.insertSlice("\n");
                    dirty = true;
                    continue;
                }
                if (dirty) {
                    cols = terminalColumns(io, output);
                    try editor.render(io, output, cols, color);
                }
                try output.writeStreamingAll(io, "\n");
                return try editor.buf.toOwnedSlice(allocator);
            },
            0x7f, 0x08 => {
                editor.backspace();
                dirty = true;
            },
            0x01 => {
                editor.moveHome();
                dirty = true;
            },
            0x05 => {
                editor.moveEnd();
                dirty = true;
            },
            0x02 => {
                editor.moveLeft();
                dirty = true;
            },
            0x06 => {
                editor.moveRight();
                dirty = true;
            },
            0x10 => {
                try editor.moveUpLineOrHistory(history);
                dirty = true;
            },
            0x0e => {
                try editor.moveDownLineOrHistory(history);
                dirty = true;
            },
            0x15 => {
                editor.killToLineStart();
                dirty = true;
            },
            0x0b => {
                editor.killToLineEnd();
                dirty = true;
            },
            0x17 => {
                editor.killWordBack();
                dirty = true;
            },
            '\t' => {
                if (!in_paste) {
                    cols = terminalColumns(io, output);
                    if (try handleTab(&editor, io, output, submit, cols, color)) dirty = true;
                } else {
                    try editor.insertSlice("\t");
                    dirty = true;
                }
            },
            0x1b => {
                const next = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse continue;
                switch (next) {
                    '\r', '\n' => {
                        try editor.insertSlice("\n");
                        dirty = true;
                    },
                    'b' => {
                        editor.moveWordLeft();
                        dirty = true;
                    },
                    'f' => {
                        editor.moveWordRight();
                        dirty = true;
                    },
                    'O' => {
                        const code = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse continue;
                        switch (code) {
                            'H' => {
                                editor.moveHome();
                                dirty = true;
                            },
                            'F' => {
                                editor.moveEnd();
                                dirty = true;
                            },
                            'A' => {
                                try editor.moveUpLineOrHistory(history);
                                dirty = true;
                            },
                            'B' => {
                                try editor.moveDownLineOrHistory(history);
                                dirty = true;
                            },
                            'C' => {
                                editor.moveRight();
                                dirty = true;
                            },
                            'D' => {
                                editor.moveLeft();
                                dirty = true;
                            },
                            else => {},
                        }
                    },
                    '[' => {
                        var seq: [32]u8 = undefined;
                        var slen: usize = 0;
                        var final_byte: ?u8 = null;
                        while (slen < seq.len) {
                            const c = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse break;
                            if (c >= 0x40 and c <= 0x7e) {
                                final_byte = c;
                                break;
                            }
                            seq[slen] = c;
                            slen += 1;
                        }
                        const params = seq[0..slen];
                        if (final_byte) |fin| switch (fin) {
                            'A' => {
                                try editor.moveUpLineOrHistory(history);
                                dirty = true;
                            },
                            'B' => {
                                try editor.moveDownLineOrHistory(history);
                                dirty = true;
                            },
                            'C' => {
                                if (std.mem.eql(u8, params, "1;5") or std.mem.eql(u8, params, "1;3")) editor.moveWordRight() else editor.moveRight();
                                dirty = true;
                            },
                            'D' => {
                                if (std.mem.eql(u8, params, "1;5") or std.mem.eql(u8, params, "1;3")) editor.moveWordLeft() else editor.moveLeft();
                                dirty = true;
                            },
                            'H' => {
                                editor.moveHome();
                                dirty = true;
                            },
                            'F' => {
                                editor.moveEnd();
                                dirty = true;
                            },
                            'u' => {
                                // Kitty CSI-u Shift+Enter -> insert newline.
                                if (std.mem.eql(u8, params, "13;2")) {
                                    try editor.insertSlice("\n");
                                    dirty = true;
                                }
                            },
                            '~' => {
                                if (std.mem.eql(u8, params, "200")) {
                                    in_paste = true;
                                } else if (std.mem.eql(u8, params, "201")) {
                                    in_paste = false;
                                } else if (std.mem.eql(u8, params, "3")) {
                                    editor.deleteAtCursor();
                                    dirty = true;
                                } else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) {
                                    editor.moveHome();
                                    dirty = true;
                                } else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) {
                                    editor.moveEnd();
                                    dirty = true;
                                }
                            },
                            else => {},
                        };
                    },
                    else => {},
                }
            },
            else => {
                if (b >= 0x20 and b < 0x7f) {
                    try editor.insertSlice(&.{b});
                    dirty = true;
                } else if (b >= 0xc2 and b <= 0xf4) {
                    const expected_len = std.unicode.utf8ByteSequenceLength(b) catch continue;
                    var utf8_buf: [4]u8 = undefined;
                    utf8_buf[0] = b;
                    var ok = true;
                    for (1..expected_len) |idx| {
                        const cb = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse {
                            ok = false;
                            break;
                        };
                        if ((cb & 0xc0) != 0x80) {
                            ok = false;
                            break;
                        }
                        utf8_buf[idx] = cb;
                    }
                    if (ok and std.unicode.utf8ValidateSlice(utf8_buf[0..expected_len])) {
                        try editor.insertSlice(utf8_buf[0..expected_len]);
                        dirty = true;
                    }
                }
            },
        }
    }
}

test "editor UTF-8 insertion cursor movement deletion and history navigation" {
    const a = std.testing.allocator;
    var history = History{ .allocator = a };
    defer history.deinit();
    try history.push("first command");
    try history.push("second");

    var editor = EditorState{ .allocator = a };
    defer editor.deinit();

    try editor.insertSlice("你好");
    try editor.insertSlice("!");
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    editor.moveLeft(); // before '!'
    editor.moveLeft(); // before '好'
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
    editor.backspace(); // removes '你'
    try std.testing.expectEqualStrings("好!", editor.buf.items);
    editor.deleteAtCursor(); // removes '好'
    try std.testing.expectEqualStrings("!", editor.buf.items);

    try editor.moveUpLineOrHistory(&history);
    try std.testing.expectEqualStrings("second", editor.buf.items);
    try editor.moveUpLineOrHistory(&history);
    try std.testing.expectEqualStrings("first command", editor.buf.items);
    try editor.moveDownLineOrHistory(&history);
    try std.testing.expectEqualStrings("second", editor.buf.items);
    try editor.moveDownLineOrHistory(&history);
    try std.testing.expectEqualStrings("!", editor.buf.items);
}

test "computeLayout tracks wide characters newlines and wrapping" {
    const l1 = computeLayout("你好\nab", 7, 10, 2);
    // "你好" takes 4 cols on row 0 (after 2-col "> "), "\n" moves to row 1 col 2, "ab" adds 2 cols -> col 4.
    try std.testing.expectEqual(@as(usize, 0), l1.cursor_row);
    try std.testing.expectEqual(@as(usize, 6), l1.cursor_col);
    try std.testing.expectEqual(@as(usize, 1), l1.end_row);
    try std.testing.expectEqual(@as(usize, 4), l1.end_col);

    const l2 = computeLayout("abcdef", 6, 6, 2);
    // 2 + 4 = 6 wraps at col 6 onto row 1, then "ef" lands at col 2.
    try std.testing.expectEqual(@as(usize, 1), l2.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), l2.cursor_col);
}
