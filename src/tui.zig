//! Regular terminal UI with Zig-native raw-mode line editing, UTF-8 cursor
//! navigation, in-session history, multi-line input, and /command / @path Tab
//! completion. Preserves terminal scrollback (never enters alternate screen)
//! and restores termios attributes before every command turn or exit.
const std = @import("std");
const agent = @import("agent");
pub const terminal = @import("tui/terminal.zig");
pub const theme = @import("tui/theme.zig");
pub const renderer = @import("tui/renderer.zig");
pub const components = struct {
    pub const markdown = @import("tui/components/markdown.zig");
    pub const message = @import("tui/components/message.zig");
    pub const tool_card = @import("tui/components/tool_card.zig");
    pub const chrome = @import("tui/components/chrome.zig");
};

const InputQueue = terminal.InputQueue;
const enterRawMode = terminal.enterRawMode;
const terminalSize = terminal.terminalSize;
const terminalColumns = terminal.terminalColumns;
const appendSafeTerminalBytes = terminal.appendSafeTerminalBytes;
const utf8Columns = terminal.utf8Columns;
const codepointWidth = terminal.codepointWidth;
const advanceByColumns = terminal.advanceByColumns;
const computeLayout = terminal.computeLayout;
const pendingLineRows = terminal.pendingLineRows;
const appendSanitizedText = terminal.appendSanitizedText;
const appendTreeText = terminal.appendClippedText;
pub const writeText = terminal.writeSafeText;

pub const max_prompt_bytes: usize = 64 * 1024;
const max_history_entries: usize = 200;
const max_queued_followups: usize = 32;

pub const LiveWriter = struct {
    context: *anyopaque,
    write_segment: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    write_markdown: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    set_phase: ?*const fn (*anyopaque, components.chrome.Phase, []const u8) void = null,
};

pub const TreeItem = struct {
    id: []const u8,
    role: []const u8,
    preview: []const u8,
    depth: usize,
};

pub const TreeSource = struct {
    context: *const anyopaque,
    len: usize,
    active: ?usize,
    item: *const fn (*const anyopaque, usize) TreeItem,
};

const TreeSelection = struct {
    id: []const u8,
    summarize: bool = false,
};

pub const Submit = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, []const u8) anyerror!void,
    session_info: ?*const fn (*anyopaque) anyerror!void = null,
    cancel: ?agent.model.Cancel = null,
    reset_cancel: ?*const fn (*anyopaque) void = null,
    trigger_cancel: ?*const fn (*anyopaque) void = null,
    set_live_writer: ?*const fn (*anyopaque, ?LiveWriter) void = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    cwd: ?[]const u8 = null,
    commands: []const []const u8 = &.{},
    compact: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    tree: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    tree_source: ?*const fn (*anyopaque) TreeSource = null,
    switch_model: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    set_thinking: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    status_info: ?*const fn (*anyopaque) components.chrome.FooterInfo = null,
    color_mode: ?theme.ColorMode = null,
    quiet_startup: bool = false,
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
    const th = theme.Theme.init(submit.color_mode orelse if (color) .ansi16 else .none);
    const use_sgr = color and th.mode != .none;
    if (!submit.quiet_startup) {
        try output.writeStreamingAll(io, if (use_sgr)
            "\x1b[1;36mzpi\x1b[0m  /help · /hotkeys · /exit · Ctrl-D exits\n"
        else
            "zpi  /help · /hotkeys · /exit · Ctrl-D exits\n");
    }

    var queue = InputQueue{};
    var history = History{ .allocator = submit.allocator };
    defer history.deinit();
    var followups: std.ArrayList([]u8) = .empty;
    defer {
        for (followups.items) |item| submit.allocator.free(item);
        followups.deinit(submit.allocator);
    }
    var carried_draft: ?[]u8 = null;
    defer if (carried_draft) |draft| submit.allocator.free(draft);

    while (true) {
        if (submit.reset_cancel) |reset| reset(submit.context);
        const raw = if (followups.items.len > 0) blk: {
            const next = followups.orderedRemove(0);
            const echo = try components.message.formatUserEchoAlloc(submit.allocator, th, next);
            defer submit.allocator.free(echo);
            try output.writeStreamingAll(io, echo);
            try output.writeStreamingAll(io, "\n");
            break :blk next;
        } else blk: {
            const initial = carried_draft;
            carried_draft = null;
            defer if (initial) |draft| submit.allocator.free(draft);
            const prompt_prefix = if (use_sgr) "\x1b[36m>\x1b[0m " else "> ";
            try output.writeStreamingAll(io, prompt_prefix);
            break :blk readPromptLine(submit.allocator, io, input.handle, output, &queue, &history, submit, use_sgr, th, initial) catch |err| switch (err) {
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
        };
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
            try output.writeStreamingAll(io, "Keyboard shortcuts\nEnter     Submit prompt (or queue follow-up while busy)\nCtrl-C    Cancel current turn or clear prompt\nCtrl-D    Exit on empty line / delete char\nUp/Down   Navigate history or lines\nLeft/Right Move cursor (Ctrl-A/E home/end)\nCtrl-W/U/K Delete word / to start / to end\nTab       Complete /command or @path\nAlt+Enter Insert newline (or trailing \\)\nAlt+Up    Edit queued follow-up messages\nEsc       Clear draft while busy / cancel /tree picker\n/model    List or switch model (/model [provider/id])\n/thinking Show or set thinking level (/thinking [off|minimal|low|medium|high|xhigh|max])\n/tree     Pick a branch (Up/Down, Enter, Esc); /tree --list prints IDs\n/compact  Summarize older context (/compact [focus])\n/exit     Exit (/quit)\n/help     Show help\n/session  Show current session summary\n/hotkeys  Show shortcuts\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/model") or std.mem.startsWith(u8, text, "/model ")) {
            const arg = if (text.len > "/model".len) std.mem.trim(u8, text["/model".len..], " \t") else "";
            if (submit.switch_model) |run_switch| {
                run_switch(submit.context, arg) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try std.Io.File.stderr().writeStreamingAll(io, line);
                };
            } else {
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: /model unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/thinking") or std.mem.startsWith(u8, text, "/thinking ")) {
            const arg = if (text.len > "/thinking".len) std.mem.trim(u8, text["/thinking".len..], " \t") else "";
            if (submit.set_thinking) |run_thinking| {
                run_thinking(submit.context, arg) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try std.Io.File.stderr().writeStreamingAll(io, line);
                };
            } else {
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: /thinking unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/tree") or std.mem.startsWith(u8, text, "/tree ")) {
            const target = if (text.len > "/tree".len) std.mem.trim(u8, text["/tree".len..], " \t") else "";
            if (submit.tree) |run_tree| {
                var summary_arg: ?[]u8 = null;
                defer if (summary_arg) |arg| submit.allocator.free(arg);
                const argument = if (target.len == 0 and color and submit.tree_source != null) blk: {
                    const tree = submit.tree_source.?(submit.context);
                    const choice = selectTree(io, input.handle, output, &queue, submit, tree) catch |err| switch (err) {
                        error.Canceled => {
                            queue.start = queue.end;
                            const prev_draft = carried_draft;
                            carried_draft = null;
                            defer if (prev_draft) |d| submit.allocator.free(d);
                            carried_draft = try buildCarriedDraft(submit.allocator, &followups, prev_draft orelse "");
                            continue;
                        },
                        else => return err,
                    };
                    if (queue.eof) return;
                    const selected = choice orelse continue;
                    if (!selected.summarize) break :blk selected.id;
                    summary_arg = try submit.allocator.print("--summary {s}", .{selected.id});
                    break :blk summary_arg.?;
                } else target;
                run_tree(submit.context, argument) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try std.Io.File.stderr().writeStreamingAll(io, line);
                };
            } else {
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: /tree unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/compact") or std.mem.startsWith(u8, text, "/compact ")) {
            const focus = if (text.len > "/compact".len) std.mem.trim(u8, text["/compact".len..], " \t") else "";
            if (submit.compact) |run_compact| {
                run_compact(submit.context, focus) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try std.Io.File.stderr().writeStreamingAll(io, line);
                };
            } else {
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: compaction unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/session")) {
            if (submit.session_info) |show| try show(submit.context);
            continue;
        }
        if (color and submit.set_live_writer != null) {
            try runTurnWithLiveEditor(io, input.handle, output, &queue, &history, submit, text, &followups, &carried_draft, use_sgr, th);
        } else {
            submit.run(submit.context, text) catch |err| {
                var msg: [256]u8 = undefined;
                const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                try std.Io.File.stderr().writeStreamingAll(io, line);
            };
        }
    }
}

fn selectTree(
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    submit: Submit,
    source: TreeSource,
) !?TreeSelection {
    if (source.len == 0) {
        try output.writeStreamingAll(io, "No entries in session.\n");
        return null;
    }

    const original = try enterRawMode(input_fd);
    defer std.posix.tcsetattr(input_fd, .NOW, original) catch {};
    try output.writeStreamingAll(io, "\x1b[?2004h");
    defer output.writeStreamingAll(io, "\x1b[?2004l\r\n") catch {};

    var selected = source.active orelse source.len - 1;
    var first: usize = 0;
    var previous_rows: usize = 0;
    var previous_size: ?std.posix.winsize = null;
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(submit.allocator);
    var dirty = true;
    var in_paste = false;
    var confirm_summary = false;
    while (true) {
        const size = terminalSize(io, output);
        const can_confirm = size.row >= 2 and size.col > summary_confirmation.len;
        if (confirm_summary and !can_confirm) {
            confirm_summary = false;
            dirty = true;
        }
        const chrome: usize = @as(usize, @intFromBool(size.row >= 3)) + @intFromBool(size.row >= 2);
        const visible = @max(1, @min(20, @as(usize, size.row) -| chrome));
        if (selected < first) first = selected;
        if (selected >= first + visible) first = selected - visible + 1;
        first = @min(first, source.len -| visible);
        const resized = if (previous_size) |old| old.col != size.col or old.row != size.row else false;
        if (dirty or resized) {
            // A resize can reflow an old frame. Start a fresh one so redraws
            // never rely on the old cursor position after a resize.
            if (resized) try output.writeStreamingAll(io, "\r\n");
            const end = @min(source.len, first + visible);
            frame.clearRetainingCapacity();
            try renderTree(&frame, submit.allocator, source, selected, .{ first, end }, size, if (resized) 0 else previous_rows, confirm_summary);
            try output.writeStreamingAll(io, frame.items);
            previous_rows = end - first + chrome - 1;
            previous_size = size;
            dirty = false;
        }

        const key = (try queue.readByteTimeout(input_fd, submit.cancel, 100)) orelse {
            if (queue.eof) return null;
            continue;
        };
        if (key == 0x1b) {
            const next = (try queue.readByteTimeout(input_fd, submit.cancel, 35)) orelse {
                if (!in_paste) return null;
                continue;
            };
            if (next != '[' and next != 'O') {
                if (in_paste) continue;
                // A key typed immediately after Escape belongs to the prompt.
                queue.start -= 1;
                return null;
            }
            var params: [32]u8 = undefined;
            var count: usize = 0;
            const final_byte: ?u8 = while (true) {
                const byte = (try queue.readByteTimeout(input_fd, submit.cancel, 35)) orelse break null;
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
            const previous = selected;
            switch (final) {
                'A' => selected -|= 1,
                'B' => selected = @min(selected + 1, source.len - 1),
                'H' => selected = 0,
                'F' => selected = source.len - 1,
                '~' => {
                    if (std.mem.eql(u8, prefix, "5")) selected -|= visible;
                    if (std.mem.eql(u8, prefix, "6")) selected = @min(selected + visible, source.len - 1);
                    if (std.mem.eql(u8, prefix, "1") or std.mem.eql(u8, prefix, "7")) selected = 0;
                    if (std.mem.eql(u8, prefix, "4") or std.mem.eql(u8, prefix, "8")) selected = source.len - 1;
                },
                else => {},
            }
            dirty = selected != previous;
        } else if (key == 0x03) {
            return error.Canceled;
        } else if (!in_paste) {
            switch (key) {
                0x04 => return null,
                '\r', '\n' => {
                    if (!confirm_summary) return .{ .id = source.item(source.context, selected).id };
                },
                's', 'S' => {
                    if (!confirm_summary and can_confirm and source.active != selected) {
                        confirm_summary = true;
                        dirty = true;
                    }
                },
                'n', 'N' => {
                    if (confirm_summary) {
                        confirm_summary = false;
                        dirty = true;
                    }
                },
                'y', 'Y' => {
                    if (confirm_summary) {
                        const current_size = terminalSize(io, output);
                        if (current_size.row >= 2 and current_size.col > summary_confirmation.len)
                            return .{ .id = source.item(source.context, selected).id, .summarize = true };
                    }
                },
                else => {},
            }
        }
    }
}

const summary_confirmation = "Send departed branch to provider? y/n";

fn renderTree(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    source: TreeSource,
    selected: usize,
    range: struct { usize, usize },
    size: std.posix.winsize,
    previous_rows: usize,
    confirm_summary: bool,
) !void {
    // Leave room at the right edge to avoid wrapping clipped previews.
    const width = @max(1, @as(usize, size.col) -| 1);
    if (previous_rows > 0) try out.print(allocator, "\x1b[{d}A", .{previous_rows});
    try out.appendSlice(allocator, "\r\x1b[J");
    if (size.row >= 3) {
        _ = try appendTreeText(out, allocator, "Session tree", width);
        try out.appendSlice(allocator, "\r\n");
    }

    for (range[0]..range[1]) |index| {
        if (index > range[0]) try out.appendSlice(allocator, "\r\n");
        const item = source.item(source.context, index);
        if (index == selected) try out.appendSlice(allocator, "\x1b[7m");
        const marker: u8 = if (index == selected) '>' else ' ';
        const active: u8 = if (source.active == index) '*' else ' ';
        var remaining = width;
        remaining -= try appendTreeText(out, allocator, &.{ marker, active, ' ' }, remaining);
        const indent_len: usize = if (item.depth > 4) 8 else item.depth * 2;
        const indent = "        "[0..indent_len];
        const visible_indent = indent[0..@min(indent.len, remaining)];
        try out.appendSlice(allocator, visible_indent);
        remaining -= visible_indent.len;
        remaining -= try appendTreeText(out, allocator, item.id, remaining);
        remaining -= try appendTreeText(out, allocator, " ", remaining);
        remaining -= try appendTreeText(out, allocator, item.role, remaining);
        remaining -= try appendTreeText(out, allocator, "  ", remaining);
        _ = try appendTreeText(out, allocator, item.preview, remaining);
        if (index == selected) try out.appendSlice(allocator, "\x1b[0m");
    }
    if (size.row >= 2) {
        try out.appendSlice(allocator, "\r\n");
        if (confirm_summary) {
            _ = try appendTreeText(out, allocator, summary_confirmation, width);
        } else {
            const full = "Up/Down move  Enter switch  s summarize  Esc cancel";
            const shortcuts = if (width >= full.len) full else if (width >= summary_confirmation.len) "Up/Down Enter s=summary Esc" else "Up/Down Enter Esc";
            _ = try appendTreeText(out, allocator, shortcuts, width);
        }
    }
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
        return self.renderWithFooter(io, output, cols, color, null);
    }

    fn renderWithFooter(self: *EditorState, io: std.Io, output: std.Io.File, cols: usize, color: bool, footer_line: ?[]const u8) !void {
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

        var total_end_row = layout.end_row;
        var total_end_col = layout.end_col;
        if (footer_line) |fl| {
            if (fl.len > 0) {
                try out.appendSlice(self.allocator, "\r\n");
                try out.appendSlice(self.allocator, fl);
                total_end_row += 1;
                total_end_col = terminal.visibleWidth(fl);
            }
        }

        // Move from bottom rendered row back to cursor_row/cursor_col.
        if (total_end_row > layout.cursor_row) {
            try out.print(self.allocator, "\x1b[{d}A", .{total_end_row - layout.cursor_row});
        }
        if (total_end_col != layout.cursor_col or total_end_row != layout.cursor_row) {
            try out.append(self.allocator, '\r');
            if (layout.cursor_col > 0) {
                try out.print(self.allocator, "\x1b[{d}C", .{layout.cursor_col});
            }
        }
        self.rendered_cursor_row = layout.cursor_row;
        try output.writeStreamingAll(io, out.items);
    }

    fn clearFooterOnly(self: *EditorState, io: std.Io, output: std.Io.File, cols: usize) !void {
        const layout = computeLayout(self.buf.items, self.cursor, cols, 2);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        if (layout.end_row > layout.cursor_row) {
            try out.print(self.allocator, "\x1b[{d}B", .{layout.end_row - layout.cursor_row});
        }
        try out.appendSlice(self.allocator, "\r\n\x1b[J");
        try out.print(self.allocator, "\x1b[1A\r", .{});
        if (layout.end_col > 0) try out.print(self.allocator, "\x1b[{d}C", .{layout.end_col});
        try output.writeStreamingAll(io, out.items);
    }
};

const builtin_commands = [_][]const u8{ "/help", "/hotkeys", "/session", "/tree", "/model", "/thinking", "/compact", "/exit", "/quit" };

fn handleTab(editor: *EditorState, io: std.Io, output: std.Io.File, submit: Submit, cols: usize, color: bool, allow_list: bool) !bool {
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
    if (!allow_list) return false;
    const same_prefix = if (editor.last_tab_prefix) |prev| std.mem.eql(u8, prev, token) else false;
    if (!same_prefix) {
        editor.resetCompletionTrack();
        editor.last_tab_prefix = try editor.allocator.dupe(u8, token);
        return false;
    }
    var list_out: std.ArrayList(u8) = .empty;
    defer list_out.deinit(editor.allocator);
    const shown = @min(matches.items.len, 24);
    for (matches.items[0..shown], 0..) |m, idx| {
        if (idx > 0) try list_out.appendSlice(editor.allocator, "  ");
        try list_out.appendSlice(editor.allocator, m);
    }
    if (matches.items.len > shown) {
        try list_out.print(editor.allocator, "  (+{d} more)", .{matches.items.len - shown});
    }
    try list_out.append(editor.allocator, '\n');
    if (color and submit.status_info != null) {
        try editor.clearFooterOnly(io, output, cols);
    }
    try output.writeStreamingAll(io, "\n");
    try output.writeStreamingAll(io, list_out.items);
    editor.rendered_cursor_row = 0;
    const footer_line = if (color and submit.status_info != null) blk: {
        var info = submit.status_info.?(submit.context);
        info.queued_count = 0;
        break :blk try components.chrome.Footer.renderLineAlloc(editor.allocator, theme.Theme.init(submit.color_mode orelse .ansi16), info, @max(1, cols -| 1));
    } else null;
    defer if (footer_line) |fl| editor.allocator.free(fl);
    try editor.renderWithFooter(io, output, cols, color, footer_line);
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
    th: theme.Theme,
    initial: ?[]const u8,
) anyerror!?[]u8 {
    if (submit.cancel) |token| {
        if (token.isCanceled()) return error.Canceled;
    }
    const orig_term = try enterRawMode(input_fd);
    defer std.posix.tcsetattr(input_fd, .NOW, orig_term) catch {};

    try output.writeStreamingAll(io, "\x1b[?2004h");
    defer output.writeStreamingAll(io, "\x1b[?2004l") catch {};

    var editor = EditorState{ .allocator = allocator };
    defer editor.deinit();

    const has_footer = th.mode != .none and submit.status_info != null;
    var in_paste = false;
    var cols = terminalColumns(io, output);
    var dirty = has_footer;
    if (initial) |text| {
        if (text.len > 0) {
            try editor.insertSlice(text);
            dirty = true;
        }
    }

    while (true) {
        if (dirty and !queue.hasBuffered()) {
            cols = terminalColumns(io, output);
            const footer_line = if (has_footer) blk: {
                var info = submit.status_info.?(submit.context);
                info.queued_count = 0;
                break :blk try components.chrome.Footer.renderLineAlloc(allocator, th, info, @max(1, cols -| 1));
            } else null;
            defer if (footer_line) |fl| allocator.free(fl);
            try editor.renderWithFooter(io, output, cols, color, footer_line);
            dirty = false;
        }
        const b_opt = try queue.readByte(input_fd, submit.cancel);
        const b = b_opt orelse {
            if (has_footer) editor.clearFooterOnly(io, output, cols) catch {};
            if (editor.buf.items.len == 0) {
                try output.writeStreamingAll(io, "\n");
                return null;
            }
            return try editor.buf.toOwnedSlice(allocator);
        };

        switch (b) {
            0x03 => {
                if (has_footer) editor.clearFooterOnly(io, output, cols) catch {};
                return error.Canceled;
            },
            0x04 => {
                if (editor.buf.items.len == 0) {
                    if (has_footer) editor.clearFooterOnly(io, output, cols) catch {};
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
                    try editor.renderWithFooter(io, output, cols, color, null);
                } else if (has_footer) {
                    try editor.clearFooterOnly(io, output, cols);
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
                    if (try handleTab(&editor, io, output, submit, cols, color, true)) dirty = true;
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

test {
    _ = terminal;
    _ = theme;
    _ = renderer;
    _ = components.markdown;
    _ = components.message;
    _ = components.tool_card;
    _ = components.chrome;
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

const LiveScreen = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    output: std.Io.File,
    color: bool,
    th: theme.Theme,
    md: components.markdown.MarkdownStyler = .{},
    loader: components.chrome.Loader = .{},
    mutex: std.Io.Mutex = .init,
    pending_line: std.ArrayList(u8) = .empty,
    overlay_bytes: std.ArrayList(u8) = .empty,
    overlay_cursor_row: usize = 0,
    overlay_cols: usize = 80,
    overlay_active: bool = false,

    const max_pending_line_bytes: usize = 4096;

    fn init(allocator: std.mem.Allocator, io: std.Io, output: std.Io.File, color: bool, th: theme.Theme) LiveScreen {
        return .{ .allocator = allocator, .io = io, .output = output, .color = color, .th = th };
    }

    fn deinit(self: *LiveScreen) void {
        self.pending_line.deinit(self.allocator);
        self.overlay_bytes.deinit(self.allocator);
    }

    fn writer(self: *LiveScreen) LiveWriter {
        return .{
            .context = self,
            .write_segment = writeSegmentErased,
            .write_markdown = writeMarkdownErased,
            .set_phase = setPhaseErased,
        };
    }

    fn writeSegmentErased(context: *anyopaque, prefix: []const u8, safe: []const u8, suffix: []const u8) anyerror!void {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        return self.writeSegment(prefix, safe, suffix);
    }

    fn writeMarkdownErased(context: *anyopaque, delta: []const u8) anyerror!void {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        return self.writeMarkdown(delta);
    }

    fn setPhaseErased(context: *anyopaque, phase: components.chrome.Phase, detail: []const u8) void {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.loader.setPhase(phase, detail);
    }

    fn writeSegment(self: *LiveScreen, prefix: []const u8, safe: []const u8, suffix: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);

        if (self.overlay_active) {
            const p_rows = if (self.pending_line.items.len > 0) pendingLineRows(self.pending_line.items, self.overlay_cols) else 0;
            const move_up = self.overlay_cursor_row + (if (self.pending_line.items.len > 0) 1 + p_rows else 0);
            if (move_up > 0) try frame.print(self.allocator, "\x1b[{d}A", .{move_up});
            try frame.appendSlice(self.allocator, "\r\x1b[J");
            if (self.pending_line.items.len > 0) try frame.appendSlice(self.allocator, self.pending_line.items);
            self.overlay_active = false;
        }

        const chunk_start = frame.items.len;
        if (prefix.len > 0) try frame.appendSlice(self.allocator, prefix);
        if (safe.len > 0) try appendSanitizedText(&frame, self.allocator, safe);
        if (suffix.len > 0) try frame.appendSlice(self.allocator, suffix);
        try updatePendingLine(&self.pending_line, self.allocator, frame.items[chunk_start..]);

        if (self.overlay_bytes.items.len > 0) {
            if (self.pending_line.items.len > 0) try frame.appendSlice(self.allocator, "\r\n");
            try frame.appendSlice(self.allocator, self.overlay_bytes.items);
            self.overlay_active = true;
        }

        if (frame.items.len > 0) try self.output.writeStreamingAll(self.io, frame.items);
    }

    fn writeMarkdown(self: *LiveScreen, delta: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);

        if (self.overlay_active) {
            const p_rows = if (self.pending_line.items.len > 0) pendingLineRows(self.pending_line.items, self.overlay_cols) else 0;
            const move_up = self.overlay_cursor_row + (if (self.pending_line.items.len > 0) 1 + p_rows else 0);
            if (move_up > 0) try frame.print(self.allocator, "\x1b[{d}A", .{move_up});
            try frame.appendSlice(self.allocator, "\r\x1b[J");
            if (self.pending_line.items.len > 0) try frame.appendSlice(self.allocator, self.pending_line.items);
            self.overlay_active = false;
        }

        var rest = delta;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const seg = rest[0..nl];
            const had_pending = self.pending_line.items.len > 0;
            var full_line: std.ArrayList(u8) = .empty;
            defer full_line.deinit(self.allocator);
            if (had_pending) try full_line.appendSlice(self.allocator, self.pending_line.items);
            try full_line.appendSlice(self.allocator, seg);

            if (self.th.mode != .none and (self.md.in_code_fence or components.markdown.MarkdownStyler.hasSyntax(full_line.items))) {
                const styled = try self.md.styleLine(self.allocator, self.th, full_line.items);
                defer self.allocator.free(styled);
                if (had_pending) {
                    const p_rows = pendingLineRows(self.pending_line.items, self.overlay_cols);
                    if (p_rows > 0) try frame.print(self.allocator, "\x1b[{d}A", .{p_rows});
                    try frame.appendSlice(self.allocator, "\r\x1b[J");
                }
                try frame.appendSlice(self.allocator, styled);
                try frame.append(self.allocator, '\n');
            } else {
                if (seg.len > 0) try appendSanitizedText(&frame, self.allocator, seg);
                try frame.append(self.allocator, '\n');
            }
            self.pending_line.clearRetainingCapacity();
            rest = rest[nl + 1 ..];
        }

        if (rest.len > 0) {
            const chunk_start = frame.items.len;
            try appendSanitizedText(&frame, self.allocator, rest);
            try updatePendingLine(&self.pending_line, self.allocator, frame.items[chunk_start..]);
        }

        if (self.overlay_bytes.items.len > 0) {
            if (self.pending_line.items.len > 0) try frame.appendSlice(self.allocator, "\r\n");
            try frame.appendSlice(self.allocator, self.overlay_bytes.items);
            self.overlay_active = true;
        }

        if (frame.items.len > 0) try self.output.writeStreamingAll(self.io, frame.items);
    }

    fn loaderTickAndRender(
        self: *LiveScreen,
        editor: *const EditorState,
        followups: []const []const u8,
        submit: Submit,
        cols: usize,
        delta_ms: u64,
    ) !void {
        var status_buf: ?[]u8 = null;
        defer if (status_buf) |s| self.allocator.free(s);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (delta_ms > 0) self.loader.tick(delta_ms);
            if (self.th.mode != .none) {
                const max_cols = @max(1, cols -| 1);
                const loader_line = try self.loader.renderLineAlloc(self.allocator, self.th, max_cols);
                defer self.allocator.free(loader_line);
                if (submit.status_info) |get_info| {
                    var info = get_info(submit.context);
                    info.queued_count = followups.len;
                    const footer_line = try components.chrome.Footer.renderLineAlloc(self.allocator, self.th, info, max_cols);
                    defer self.allocator.free(footer_line);
                    status_buf = try std.fmt.allocPrint(self.allocator, "{s}\r\n{s}", .{ loader_line, footer_line });
                } else {
                    status_buf = try self.allocator.dupe(u8, loader_line);
                }
            }
        }
        const rendered = try renderLiveOverlayFrameWithChrome(
            self.allocator,
            editor,
            followups,
            cols,
            self.color,
            status_buf,
        );
        defer self.allocator.free(rendered.bytes);
        try self.updateOverlay(rendered.bytes, rendered.cursor_row, cols);
    }

    fn updateOverlay(self: *LiveScreen, new_bytes: []const u8, new_cursor_row: usize, cols: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);

        if (self.overlay_active) {
            if (new_bytes.len == 0) {
                const p_rows = if (self.pending_line.items.len > 0) pendingLineRows(self.pending_line.items, self.overlay_cols) else 0;
                const move_up = self.overlay_cursor_row + (if (self.pending_line.items.len > 0) 1 + p_rows else 0);
                if (move_up > 0) try frame.print(self.allocator, "\x1b[{d}A", .{move_up});
                try frame.appendSlice(self.allocator, "\r\x1b[J");
                if (self.pending_line.items.len > 0) try frame.appendSlice(self.allocator, self.pending_line.items);
                self.overlay_active = false;
            } else if (cols != self.overlay_cols) {
                try frame.appendSlice(self.allocator, "\r\n");
                self.pending_line.clearRetainingCapacity();
                try frame.appendSlice(self.allocator, new_bytes);
                self.overlay_active = true;
            } else {
                if (self.overlay_cursor_row > 0) try frame.print(self.allocator, "\x1b[{d}A", .{self.overlay_cursor_row});
                try frame.appendSlice(self.allocator, "\r\x1b[J");
                try frame.appendSlice(self.allocator, new_bytes);
                self.overlay_active = true;
            }
        } else if (new_bytes.len > 0) {
            if (self.pending_line.items.len > 0) try frame.appendSlice(self.allocator, "\r\n");
            try frame.appendSlice(self.allocator, new_bytes);
            self.overlay_active = true;
        }

        self.overlay_bytes.clearRetainingCapacity();
        try self.overlay_bytes.appendSlice(self.allocator, new_bytes);
        self.overlay_cursor_row = new_cursor_row;
        self.overlay_cols = cols;

        if (frame.items.len > 0) try self.output.writeStreamingAll(self.io, frame.items);
    }

    fn clearOverlay(self: *LiveScreen) !void {
        try self.updateOverlay(&.{}, 0, self.overlay_cols);
    }
};

fn updatePendingLine(pending: *std.ArrayList(u8), a: std.mem.Allocator, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    if (std.mem.lastIndexOfScalar(u8, chunk, '\n')) |nl| {
        pending.clearRetainingCapacity();
        const tail = chunk[nl + 1 ..];
        if (tail.len <= LiveScreen.max_pending_line_bytes) try pending.appendSlice(a, tail);
        return;
    }
    if (pending.items.len + chunk.len > LiveScreen.max_pending_line_bytes) {
        pending.clearRetainingCapacity();
        return;
    }
    try pending.appendSlice(a, chunk);
}

const LiveOverlayFrame = struct { bytes: []u8, cursor_row: usize };

fn renderLiveOverlayFrame(
    allocator: std.mem.Allocator,
    editor: *const EditorState,
    followups: []const []const u8,
    cols_raw: usize,
    color: bool,
) !LiveOverlayFrame {
    return renderLiveOverlayFrameWithChrome(allocator, editor, followups, cols_raw, color, null);
}

fn renderLiveOverlayFrameWithChrome(
    allocator: std.mem.Allocator,
    editor: *const EditorState,
    followups: []const []const u8,
    cols_raw: usize,
    color: bool,
    chrome_block: ?[]const u8,
) !LiveOverlayFrame {
    if (followups.len == 0 and editor.buf.items.len == 0 and (chrome_block == null or chrome_block.?.len == 0)) {
        return .{ .bytes = try allocator.alloc(u8, 0), .cursor_row = 0 };
    }
    const cols = @max(cols_raw, 4);
    const max_preview_cols = @max(1, cols -| 1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rows_above: usize = 0;
    if (followups.len > 0) {
        const shown = @min(followups.len, 4);
        for (followups[0..shown], 1..) |item, idx| {
            var label_buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "[queued {d}] ", .{idx});
            if (color) try out.appendSlice(allocator, "\x1b[2m");
            const used = try appendTreeText(&out, allocator, label, max_preview_cols);
            _ = try appendTreeText(&out, allocator, item, max_preview_cols -| used);
            if (color) try out.appendSlice(allocator, "\x1b[0m");
            if (idx < shown or followups.len > shown or editor.buf.items.len > 0) {
                try out.appendSlice(allocator, "\r\n");
                rows_above += 1;
            }
        }
        if (followups.len > shown) {
            var more_buf: [48]u8 = undefined;
            const more = try std.fmt.bufPrint(&more_buf, "  (+{d} more queued)", .{followups.len - shown});
            if (color) try out.appendSlice(allocator, "\x1b[2m");
            _ = try appendTreeText(&out, allocator, more, max_preview_cols);
            if (color) try out.appendSlice(allocator, "\x1b[0m");
            if (editor.buf.items.len > 0) {
                try out.appendSlice(allocator, "\r\n");
                rows_above += 1;
            }
        }
        if (editor.buf.items.len == 0) {
            try out.appendSlice(allocator, "\r\n");
            rows_above += 1;
            if (color) try out.appendSlice(allocator, "\x1b[2m");
            _ = try appendTreeText(&out, allocator, "  Alt+Up edit queued", max_preview_cols);
            if (color) try out.appendSlice(allocator, "\x1b[0m");
            if (chrome_block) |cb| {
                if (cb.len > 0) {
                    try out.appendSlice(allocator, "\r\n");
                    rows_above += 1;
                    try out.appendSlice(allocator, cb);
                    rows_above += std.mem.count(u8, cb, "\n");
                }
            }
            return .{ .bytes = try out.toOwnedSlice(allocator), .cursor_row = rows_above };
        }
    }

    if (editor.buf.items.len > 0) {
        try out.appendSlice(allocator, if (color) "\x1b[36m>\x1b[0m " else "> ");
        const layout = computeLayout(editor.buf.items, editor.cursor, cols, 2);
        try appendSafeTerminalBytes(&out, allocator, editor.buf.items);
        var bottom_row = layout.end_row;
        var bottom_col = layout.end_col;
        if (chrome_block) |cb| {
            if (cb.len > 0) {
                try out.appendSlice(allocator, "\r\n");
                try out.appendSlice(allocator, cb);
                bottom_row += 1 + std.mem.count(u8, cb, "\n");
                const last_nl = std.mem.lastIndexOfScalar(u8, cb, '\n');
                const last_line = if (last_nl) |idx| cb[idx + 1 ..] else cb;
                bottom_col = terminal.visibleWidth(last_line);
            }
        }
        if (bottom_row > layout.cursor_row) {
            try out.print(allocator, "\x1b[{d}A", .{bottom_row - layout.cursor_row});
        }
        if (bottom_col != layout.cursor_col or bottom_row != layout.cursor_row) {
            try out.append(allocator, '\r');
            if (layout.cursor_col > 0) try out.print(allocator, "\x1b[{d}C", .{layout.cursor_col});
        }
        return .{ .bytes = try out.toOwnedSlice(allocator), .cursor_row = rows_above + layout.cursor_row };
    }

    if (chrome_block) |cb| {
        if (cb.len > 0) {
            try out.appendSlice(allocator, cb);
            return .{ .bytes = try out.toOwnedSlice(allocator), .cursor_row = std.mem.count(u8, cb, "\n") };
        }
    }
    return .{ .bytes = try out.toOwnedSlice(allocator), .cursor_row = 0 };
}

fn restoreFollowupsToEditor(editor: *EditorState, followups: *std.ArrayList([]u8), allocator: std.mem.Allocator) !void {
    if (followups.items.len == 0) return;
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);
    for (followups.items, 0..) |item, i| {
        if (i > 0) try combined.appendSlice(allocator, "\n\n");
        try combined.appendSlice(allocator, item);
    }
    if (editor.buf.items.len > 0) {
        try combined.appendSlice(allocator, "\n\n");
        try combined.appendSlice(allocator, editor.buf.items);
    }
    if (combined.items.len > max_prompt_bytes) return error.StreamTooLong;
    try editor.replaceBuffer(combined.items);
    for (followups.items) |item| allocator.free(item);
    followups.clearRetainingCapacity();
}

fn buildCarriedDraft(allocator: std.mem.Allocator, followups: *std.ArrayList([]u8), draft: []const u8) !?[]u8 {
    if (followups.items.len == 0 and draft.len == 0) return null;
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);
    for (followups.items, 0..) |item, i| {
        if (i > 0) try combined.appendSlice(allocator, "\n\n");
        try combined.appendSlice(allocator, item);
    }
    if (draft.len > 0) {
        if (combined.items.len > 0) try combined.appendSlice(allocator, "\n\n");
        try combined.appendSlice(allocator, draft);
    }
    for (followups.items) |item| allocator.free(item);
    followups.clearRetainingCapacity();
    if (combined.items.len == 0) return null;
    if (combined.items.len > max_prompt_bytes) combined.items.len = max_prompt_bytes;
    return try combined.toOwnedSlice(allocator);
}

fn runTurnWithLiveEditor(
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    history: *History,
    submit: Submit,
    text: []const u8,
    followups: *std.ArrayList([]u8),
    carried_draft: *?[]u8,
    color: bool,
    th: theme.Theme,
) !void {
    const orig_term = try enterRawMode(input_fd);
    defer std.posix.tcsetattr(input_fd, .NOW, orig_term) catch {};

    try output.writeStreamingAll(io, "\x1b[?2004h");
    defer output.writeStreamingAll(io, "\x1b[?2004l") catch {};

    var done = try agent.model.Interrupt.init();
    defer done.deinit(io);

    var screen = LiveScreen.init(submit.allocator, io, output, color, th);
    defer screen.deinit();

    submit.set_live_writer.?(submit.context, screen.writer());
    defer submit.set_live_writer.?(submit.context, null);

    var editor = EditorState{ .allocator = submit.allocator };
    defer editor.deinit();
    if (carried_draft.*) |draft| {
        if (draft.len > 0) try editor.insertSlice(draft);
        submit.allocator.free(draft);
        carried_draft.* = null;
    }

    const WorkerState = struct {
        submit: Submit,
        text: []const u8,
        done: *agent.model.Interrupt,
        err: ?anyerror = null,
        fn run(state: *@This()) void {
            state.submit.run(state.submit.context, state.text) catch |e| {
                state.err = e;
            };
            state.done.trigger();
        }
    };
    var worker = WorkerState{ .submit = submit, .text = text, .done = &done };
    var thread = try std.Thread.spawn(.{}, WorkerState.run, .{&worker});
    var joined = false;
    errdefer if (!joined) {
        if (submit.trigger_cancel) |trig| trig(submit.context);
        thread.join();
    };

    var in_paste = false;
    var cols = terminalColumns(io, output);
    var dirty = followups.items.len > 0 or editor.buf.items.len > 0;
    const wake = done.cancel();
    var last_tick_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();

    while (true) {
        if (done.isCanceled()) break;
        const current_cols = terminalColumns(io, output);
        if ((dirty or current_cols != cols) and !queue.hasBuffered()) {
            cols = current_cols;
            try screen.loaderTickAndRender(&editor, followups.items, submit, cols, 0);
            dirty = false;
        }
        const b_opt = try queue.readByteWithWake(input_fd, wake, 120);
        if (done.isCanceled()) break;
        const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (b_opt == null) {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), now_ms - last_tick_ms));
            if (elapsed >= 120 and !queue.hasBuffered()) {
                last_tick_ms = now_ms;
                cols = terminalColumns(io, output);
                try screen.loaderTickAndRender(&editor, followups.items, submit, cols, elapsed);
            }
            continue;
        }
        const b = b_opt.?;

        switch (b) {
            0x03 => {
                if (submit.trigger_cancel) |trig| trig(submit.context);
            },
            0x04 => {
                if (editor.buf.items.len > 0) {
                    editor.deleteAtCursor();
                    dirty = true;
                }
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
                const trimmed = std.mem.trim(u8, editor.buf.items, " \t\r\n");
                if (trimmed.len > 0 and followups.items.len < max_queued_followups) {
                    try history.push(trimmed);
                    try followups.append(submit.allocator, try submit.allocator.dupe(u8, trimmed));
                    try editor.replaceBuffer("");
                    editor.history_idx = null;
                    if (editor.draft) |d| {
                        submit.allocator.free(d);
                        editor.draft = null;
                    }
                    dirty = true;
                } else if (trimmed.len == 0 and editor.buf.items.len > 0) {
                    try editor.replaceBuffer("");
                    dirty = true;
                }
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
                    if (try handleTab(&editor, io, output, submit, cols, color, false)) dirty = true;
                } else {
                    try editor.insertSlice("\t");
                    dirty = true;
                }
            },
            0x1b => {
                const next = try queue.readByteWithWake(input_fd, wake, 25) orelse {
                    if (done.isCanceled()) break;
                    if (editor.buf.items.len > 0) {
                        try editor.replaceBuffer("");
                        editor.history_idx = null;
                        dirty = true;
                    }
                    continue;
                };
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
                    0x1b => {
                        const third = try queue.readByteWithWake(input_fd, wake, 25) orelse continue;
                        if (third == '[' or third == 'O') {
                            const fourth = try queue.readByteWithWake(input_fd, wake, 25) orelse continue;
                            if (fourth == 'A') {
                                restoreFollowupsToEditor(&editor, followups, submit.allocator) catch {};
                                dirty = true;
                            }
                        }
                    },
                    'O' => {
                        const code = try queue.readByteWithWake(input_fd, wake, 25) orelse continue;
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
                            const c = try queue.readByteWithWake(input_fd, wake, 25) orelse break;
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
                                if (std.mem.eql(u8, params, "1;3")) {
                                    restoreFollowupsToEditor(&editor, followups, submit.allocator) catch {};
                                } else {
                                    try editor.moveUpLineOrHistory(history);
                                }
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
                    editor.insertSlice(&.{b}) catch {};
                    dirty = true;
                } else if (b >= 0xc2 and b <= 0xf4) {
                    const expected_len = std.unicode.utf8ByteSequenceLength(b) catch continue;
                    var utf8_buf: [4]u8 = undefined;
                    utf8_buf[0] = b;
                    var ok = true;
                    for (1..expected_len) |idx| {
                        const cb = try queue.readByteWithWake(input_fd, wake, 25) orelse {
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
                        editor.insertSlice(utf8_buf[0..expected_len]) catch {};
                        dirty = true;
                    }
                }
            },
        }
    }

    thread.join();
    joined = true;
    try screen.clearOverlay();

    if (worker.err) |err| {
        var msg: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
        try std.Io.File.stderr().writeStreamingAll(io, line);
        carried_draft.* = try buildCarriedDraft(submit.allocator, followups, editor.buf.items);
    } else if (editor.buf.items.len > 0) {
        carried_draft.* = try submit.allocator.dupe(u8, editor.buf.items);
    }
}

test "pendingLineRows tracks wrapped text and ignores CSI SGR sequences" {
    try std.testing.expectEqual(@as(usize, 0), pendingLineRows("0123456789", 10));
    try std.testing.expectEqual(@as(usize, 1), pendingLineRows("0123456789a", 10));
    try std.testing.expectEqual(@as(usize, 0), pendingLineRows("\x1b[2m0123456789\x1b[0m", 10));
    try std.testing.expectEqual(@as(usize, 1), pendingLineRows("\x1b[2m中文中文中文\x1b[0m", 10));
}

test "restoreFollowupsToEditor and buildCarriedDraft preserve queued items and draft" {
    const a = std.testing.allocator;
    var followups: std.ArrayList([]u8) = .empty;
    defer {
        for (followups.items) |item| a.free(item);
        followups.deinit(a);
    }
    try followups.append(a, try a.dupe(u8, "first"));
    try followups.append(a, try a.dupe(u8, "second"));

    var editor = EditorState{ .allocator = a };
    defer editor.deinit();
    try editor.insertSlice("draft");

    try restoreFollowupsToEditor(&editor, &followups, a);
    try std.testing.expectEqual(@as(usize, 0), followups.items.len);
    try std.testing.expectEqualStrings("first\n\nsecond\n\ndraft", editor.buf.items);

    try followups.append(a, try a.dupe(u8, "queued"));
    const carried = (try buildCarriedDraft(a, &followups, "wip")).?;
    defer a.free(carried);
    try std.testing.expectEqual(@as(usize, 0), followups.items.len);
    try std.testing.expectEqualStrings("queued\n\nwip", carried);
}

test "renderLiveOverlayFrame clips queued previews and tracks multiline draft cursor" {
    const a = std.testing.allocator;
    var editor = EditorState{ .allocator = a };
    defer editor.deinit();

    const empty = try renderLiveOverlayFrame(a, &editor, &.{}, 80, false);
    defer a.free(empty.bytes);
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);

    const queued = [_][]const u8{
        "first 中文日本語",
        "second",
        "third",
        "fourth",
        "fifth",
    };
    const q_only = try renderLiveOverlayFrame(a, &editor, &queued, 24, false);
    defer a.free(q_only.bytes);
    try std.testing.expect(std.mem.indexOf(u8, q_only.bytes, "[queued 1] first 中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, q_only.bytes, "(+1 more queued)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q_only.bytes, "Alt+Up edit queued") != null);
    try std.testing.expectEqual(@as(usize, 5), q_only.cursor_row);

    try editor.insertSlice("line1\nline2");
    editor.moveLeft();
    const with_draft = try renderLiveOverlayFrame(a, &editor, &queued, 40, false);
    defer a.free(with_draft.bytes);
    try std.testing.expect(std.mem.indexOf(u8, with_draft.bytes, "> line1\n  line2") != null);
    try std.testing.expectEqual(@as(usize, 6), with_draft.cursor_row);
}
