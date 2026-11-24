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
    pub const select_list = @import("tui/components/select_list.zig");
    pub const dialog = @import("tui/components/dialog.zig");
    pub const autocomplete = @import("tui/components/autocomplete.zig");
    pub const conversation_view = @import("tui/components/conversation_view.zig");
};

const DialogKind = enum { help, hotkeys };

fn eraseSubmittedPromptLine(io: std.Io, output: std.Io.File) !void {
    try output.writeStreamingAll(io, "\x1b[1A\r\x1b[J");
}

const InputQueue = terminal.InputQueue;
const mouse = @import("tui/mouse.zig");

test {
    _ = mouse;
}

fn renderFullscreenConversation(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: std.Io.File,
    view: *ConversationView,
    editor: *const EditorState,
    loader: []const u8,
    dialog: []const []const u8,
    popup: []const []const u8,
    footer: []const []const u8,
    queued: []const []const u8,
    th: theme.Theme,
) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const size = terminalSize(output);
    const rows = @max(1, @as(usize, size.row));
    const width = @as(usize, size.col) -| 1;
    const header_rows: usize = @intFromBool(rows >= 3);
    const chrome_rows = @min(footer.len, rows -| 6);
    const loader_rows: usize = @intFromBool(rows >= 5);
    const popup_rows = @min(popup.len, (rows -| (2 + header_rows + chrome_rows + loader_rows)) / 2);
    const queued_rows = @min(@min(queued.len, 4), rows -| (3 + header_rows + chrome_rows + loader_rows + popup_rows));
    const body_rows = rows -| 1 -| header_rows -| chrome_rows -| loader_rows -| popup_rows -| queued_rows;
    view.body_height = @max(1, body_rows);
    view.frame_size = size;
    // Popup rows sit directly above the editor. Mouse coordinates are 1-based.
    view.popup_row = rows - chrome_rows - popup_rows;
    view.popup_rows = popup_rows;
    try view.hit_rows.resize(allocator, rows);
    @memset(view.hit_rows.items, null);

    var frame: std.ArrayList(u8) = .empty;
    try frame.appendSlice(a, renderer.sync_begin ++ "\x1b[H\x1b[J");
    if (header_rows > 0) {
        if (!view.isFollowing()) {
            try appendFullscreenRow(&frame, a, "Browsing history · End follows latest", width);
        } else if (view.pinned_user) |pinned| {
            var header: std.ArrayList(u8) = .empty;
            if (width >= 2) try header.appendSlice(a, "> ");
            _ = try terminal.appendClippedText(&header, a, pinned, width -| 2);
            try th.appendOpen(&frame, a, theme.Theme.user_panel);
            try frame.appendSlice(a, header.items);
            try frame.appendNTimes(a, ' ', width -| terminal.visibleWidth(header.items));
            try th.appendClose(&frame, a);
            try frame.appendSlice(a, "\x1b[0m\r\n");
        } else try appendFullscreenRow(&frame, a, "Conversation · PgUp / PgDn / End", width);
    }

    var body: std.ArrayList(struct { text: []const u8, id: ?usize }) = .empty;
    if (dialog.len > 0) {
        for (dialog[0..@min(dialog.len, body_rows)]) |line| try appendFullscreenRow(&frame, a, line, width);
        try frame.appendNTimes(a, '\n', body_rows -| dialog.len);
    } else {
        // Collect from the end so wrapping a long line cannot hide the newest output.
        var id = view.pageEnd();
        var pending = view.isFollowing() and view.pending.items.len > 0;
        while (body.items.len < body_rows and (pending or id > view.first_id)) {
            const text = if (pending) view.pending.items else view.lineAt(id - 1);
            const line_id = if (pending) null else id - 1;
            if (!pending) id -= 1;
            pending = false;
            const wrapped = try terminal.wrapAnsiAlloc(a, text, @max(2, width));
            var lines = std.mem.splitBackwardsScalar(u8, wrapped, '\n');
            while (body.items.len < body_rows) try body.append(a, .{ .text = lines.next() orelse break, .id = line_id });
        }
        var index = body.items.len;
        while (index > 0) {
            index -= 1;
            const line = body.items[index];
            view.hit_rows.items[header_rows + body.items.len - 1 - index] = line.id;
            try appendFullscreenRow(&frame, a, line.text, width);
        }
        for (body.items.len..body_rows) |_| try frame.appendSlice(a, "\r\n");
    }
    if (loader_rows > 0) try appendFullscreenRow(&frame, a, loader, width);
    for (queued[0..queued_rows], 1..) |text, index| {
        var preview: std.ArrayList(u8) = .empty;
        try preview.print(a, "[queued {d}] ", .{index});
        _ = try terminal.appendClippedText(&preview, a, text, width -| preview.items.len);
        try appendFullscreenRow(&frame, a, preview.items, width);
    }
    for (popup[0..popup_rows]) |line| try appendFullscreenRow(&frame, a, line, width);
    const editor_row = rows - chrome_rows;

    const text = editor.buf.items;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..editor.cursor], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, text, editor.cursor, '\n') orelse text.len;
    const prefix_width: usize = if (width >= 3) 2 else 0;
    const cursor_budget = width -| prefix_width;
    var start = editor.cursor;
    var cursor_width: usize = 0;
    while (start > line_start) {
        var previous = start - 1;
        while (previous > line_start and text[previous] & 0xc0 == 0x80) previous -= 1;
        const char_width = terminal.visibleWidth(text[previous..start]);
        if (cursor_width + char_width > cursor_budget) break;
        start = previous;
        cursor_width += char_width;
    }
    if (prefix_width > 0) {
        if (isBangMode(text)) {
            try th.paint(&frame, a, theme.Theme.tool_ok, "! ");
        } else try th.paint(&frame, a, theme.Theme.accent, "> ");
    }
    _ = try terminal.appendClippedText(&frame, a, text[start..line_end], cursor_budget);
    for (footer[0..chrome_rows]) |line| {
        try frame.appendSlice(a, "\r\n");
        _ = try terminal.appendTruncatedAnsi(&frame, a, line, width, "");
    }
    try frame.print(a, "\x1b[{d};{d}H", .{ editor_row, 1 + prefix_width + cursor_width });
    try frame.appendSlice(a, renderer.sync_end);
    try output.writeStreamingAll(io, frame.items);
}

fn appendFullscreenRow(frame: *std.ArrayList(u8), a: std.mem.Allocator, line: []const u8, width: usize) !void {
    _ = try terminal.appendTruncatedAnsi(frame, a, line, width, "");
    try frame.appendSlice(a, "\x1b[0m\r\n");
}

fn mouseMatchesFrame(view: *const ConversationView, current: std.posix.winsize, event: mouse.Event) bool {
    return current.row == view.frame_size.row and current.col == view.frame_size.col and
        event.row <= current.row and event.col <= current.col;
}

fn scrollWithMouse(view: *ConversationView, event: mouse.Event) bool {
    switch (event.kind) {
        .wheel_up => view.scrollUp(3),
        .wheel_down => view.scrollDown(3),
        else => return false,
    }
    return true;
}

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
pub const ConversationView = components.conversation_view.ConversationView;

test {
    _ = components.conversation_view;
}
pub const writeText = terminal.writeSafeText;

pub const max_prompt_bytes: usize = 64 * 1024;
const max_history_entries: usize = 200;
const max_queued_followups: usize = 32;

fn isBangMode(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "!");
}

pub const LiveWriter = struct {
    context: *anyopaque,
    write_segment: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    write_markdown: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    set_phase: ?*const fn (*anyopaque, components.chrome.Phase, []const u8) void = null,
    write_tool_header: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,
};

pub const TreeItem = struct {
    id: []const u8,
    role: []const u8,
    preview: []const u8,
    depth: usize,
    is_user_message: bool = false,
    parent_id: ?[]const u8 = null,
    full_text: []const u8 = "",
};

pub const TreeSource = struct {
    context: *const anyopaque,
    len: usize,
    active: ?usize,
    item: *const fn (*const anyopaque, usize) TreeItem,
};

pub const ModelItem = struct {
    ref: []const u8,
    api: []const u8,
    is_active: bool = false,
};

pub const ModelSource = struct {
    context: *anyopaque,
    len: usize,
    active: ?usize,
    item: *const fn (*anyopaque, usize) ModelItem,
    deinit: *const fn (*anyopaque) void,
};

pub const SessionItem = struct {
    path: []const u8,
    label: []const u8,
    preview: []const u8,
    is_active: bool = false,
};

pub const SessionSource = struct {
    context: *anyopaque,
    len: usize,
    active: ?usize,
    item: *const fn (*anyopaque, usize) SessionItem,
    deinit: *const fn (*anyopaque) void,
};

const TreeSelection = struct {
    id: []const u8,
    summarize: bool = false,
    prefill: ?[]const u8 = null,
    branch_to_parent: bool = false,
};

pub const BgNotification = struct {
    task_name: []u8,
    status: []const u8,
    text: []u8,
    trigger: bool,
};

pub const ToolDetailItem = struct { name: []const u8, text: []const u8 };

pub const StartupInfo = struct {
    version: []const u8 = "",
    skills: []const []const u8 = &.{},
    templates: []const []const u8 = &.{},
    plugins: []const []const u8 = &.{},
    extensions: []const []const u8 = &.{},
    mcp_servers: []const []const u8 = &.{},
    tools: []const []const u8 = &.{},
};

pub const Submit = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, []const u8) anyerror!void,
    session_info: ?*const fn (*anyopaque) anyerror!void = null,
    render_initial_history: ?*const fn (*anyopaque) anyerror!bool = null,
    render_fullscreen_history: ?*const fn (*anyopaque, *ConversationView) anyerror!bool = null,
    jobs_info: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    cancel: ?agent.model.Cancel = null,
    reset_cancel: ?*const fn (*anyopaque) void = null,
    trigger_cancel: ?*const fn (*anyopaque) void = null,
    set_live_writer: ?*const fn (*anyopaque, ?LiveWriter) void = null,
    conversation_view: ?*ConversationView = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    fullscreen: bool = false,
    cwd: ?[]const u8 = null,
    commands: []const []const u8 = &.{},
    compact: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    tree: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    tree_source: ?*const fn (*anyopaque) TreeSource = null,
    switch_model: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    model_source: ?*const fn (*anyopaque) anyerror!?ModelSource = null,
    set_thinking: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    cycle_thinking: ?*const fn (*anyopaque) void = null,
    resume_session: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    session_source: ?*const fn (*anyopaque) anyerror!?SessionSource = null,
    status_info: ?*const fn (*anyopaque) components.chrome.FooterInfo = null,
    toggle_expand: ?*const fn (*anyopaque) bool = null,
    tool_details: ?*const fn (*anyopaque, std.mem.Allocator, ?[]const u8) anyerror![]ToolDetailItem = null,
    run_user_shell: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ?agent.model.Cancel) anyerror!agent.ToolResult = null,
    record_user_shell: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    push_steering: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    drain_steering: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![][]u8 = null,
    bg_wake: ?agent.model.Cancel = null,
    reset_bg_wake: ?*const fn (*anyopaque) void = null,
    pop_bg_notifications: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![]BgNotification = null,
    color_mode: ?theme.ColorMode = null,
    quiet_startup: bool = false,
    startup_info: StartupInfo = .{},
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

fn writeStartupSection(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    th: theme.Theme,
    title: []const u8,
    items: []const []const u8,
    max_cols: usize,
) !usize {
    if (items.len == 0) return 0;
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "[{s}]", .{title}) catch title;
    try th.paint(out, a, theme.Theme.accent, hdr);
    try out.append(a, '\n');

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    try joined.appendSlice(a, "  ");
    for (items, 0..) |item, idx| {
        if (idx > 0) try joined.appendSlice(a, ", ");
        try joined.appendSlice(a, item);
    }
    const wrapped = try terminal.wrapAnsiAlloc(a, joined.items, max_cols);
    defer a.free(wrapped);
    var row_count: usize = 1;
    var lines_it = std.mem.splitScalar(u8, wrapped, '\n');
    while (lines_it.next()) |line| {
        try th.paint(out, a, theme.Theme.muted, line);
        try out.append(a, '\n');
        row_count += 1;
    }
    try out.append(a, '\n');
    return row_count + 1;
}

fn renderStartupBanner(io: std.Io, output: std.Io.File, submit: Submit, th: theme.Theme) !usize {
    const a = submit.allocator;
    const sz = terminalSize(output);
    const max_cols = @max(@as(usize, 24), @as(usize, sz.col) -| 1);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var lines: usize = 0;

    try out.append(a, '\n');
    lines += 1;

    const logo = [_][]const u8{
        " ____  ____  ___",
        "|__ / |  _ \\|_ _|",
        " / /  | |_) || |",
        "/___| |  __/|___|",
        "      |_|",
    };
    const logo_width = 16;
    if (sz.col > logo_width and sz.row >= 20) {
        for (logo) |row| {
            try th.paint(&out, a, theme.Theme.accent, row);
            try out.append(a, '\n');
        }
        lines += logo.len;
    }

    try th.appendOpen(&out, a, theme.Theme.accent);
    try out.appendSlice(a, "zpi");
    try th.appendClose(&out, a);
    if (submit.startup_info.version.len > 0) {
        var ver_buf: [64]u8 = undefined;
        const ver_str = std.fmt.bufPrint(&ver_buf, " v{s}", .{submit.startup_info.version}) catch submit.startup_info.version;
        try th.paint(&out, a, theme.Theme.muted, ver_str);
    }
    try out.append(a, '\n');
    lines += 1;

    const hints = "Ctrl-C interrupt · Ctrl-D exits · / commands · @ files · Shift+Tab thinking · Ctrl-O expand · /help · /hotkeys";
    const wrapped_hints = try terminal.wrapAnsiAlloc(a, hints, max_cols);
    defer a.free(wrapped_hints);
    var hints_it = std.mem.splitScalar(u8, wrapped_hints, '\n');
    while (hints_it.next()) |hline| {
        try th.paint(&out, a, theme.Theme.muted, hline);
        try out.append(a, '\n');
        lines += 1;
    }
    try out.append(a, '\n');
    lines += 1;

    lines += try writeStartupSection(&out, a, th, "Skills", submit.startup_info.skills, max_cols);
    lines += try writeStartupSection(&out, a, th, "Prompts", submit.startup_info.templates, max_cols);
    lines += try writeStartupSection(&out, a, th, "Plugins", submit.startup_info.plugins, max_cols);
    lines += try writeStartupSection(&out, a, th, "Extensions", submit.startup_info.extensions, max_cols);
    lines += try writeStartupSection(&out, a, th, "MCP", submit.startup_info.mcp_servers, max_cols);
    lines += try writeStartupSection(&out, a, th, "Tools", submit.startup_info.tools, max_cols);

    try output.writeStreamingAll(io, out.items);
    return lines;
}

fn runLocalShell(io: std.Io, input_fd: std.posix.fd_t, queue: *InputQueue, submit: Submit, allocator: std.mem.Allocator, command: []const u8) !agent.ToolResult {
    const original = try enterRawMode(input_fd);
    defer terminal.setTermiosNow(input_fd, original) catch {};
    var done = try agent.model.Interrupt.init();
    defer done.deinit(io);
    const Worker = struct {
        submit: Submit,
        allocator: std.mem.Allocator,
        command: []const u8,
        done: *agent.model.Interrupt,
        result: anyerror!agent.ToolResult = error.Canceled,

        fn run(self: *@This()) void {
            self.result = self.submit.run_user_shell.?(self.submit.context, self.allocator, self.command, self.submit.cancel);
            self.done.trigger();
        }
    };
    var worker: Worker = .{ .submit = submit, .allocator = allocator, .command = command, .done = &done };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    errdefer {
        if (submit.trigger_cancel) |trigger| trigger(submit.context);
        thread.join();
    }
    const wake = done.cancel();
    while (!done.isCanceled()) {
        const key = try queue.readByteWithWake(input_fd, wake, 100);
        if (done.isCanceled()) break;
        if (queue.eof or key == 0x03 or key == 0x1b) {
            if (submit.trigger_cancel) |trigger| trigger(submit.context);
        }
    }
    thread.join();
    return worker.result;
}

fn showToolDetails(io: std.Io, input_fd: std.posix.fd_t, output: std.Io.File, queue: *InputQueue, submit: Submit, th: theme.Theme, items: []const ToolDetailItem) !void {
    if (items.len == 0) return output.writeStreamingAll(io, "No tool output in this conversation.\n");
    if (submit.fullscreen) try output.writeStreamingAll(io, "\x1b[H\x1b[J");
    const original = try enterRawMode(input_fd);
    defer terminal.setTermiosNow(input_fd, original) catch {};
    var viewport = renderer.MainScreenRenderer.init(submit.allocator, th.mode != .none);
    defer viewport.deinit();
    defer viewport.clearViewport(io, output) catch {};
    var scratch = std.heap.ArenaAllocator.init(submit.allocator);
    defer scratch.deinit();
    var wrapped: std.ArrayList([]const u8) = .empty;
    var width: usize = 0;
    var offset: usize = 0;
    while (true) {
        const size = terminalSize(output);
        const cols = @max(@as(usize, size.col), 4);
        if (cols != width) {
            width = cols;
            _ = scratch.reset(.retain_capacity);
            wrapped = .empty;
            const alloc = scratch.allocator();
            for (items) |item| {
                var title: std.ArrayList(u8) = .empty;
                _ = try terminal.appendClippedText(&title, alloc, item.name, cols -| 5);
                try wrapped.append(alloc, title.items);
                const safe = try terminal.safeUtf8Alloc(alloc, item.text);
                const body = try terminal.wrapAnsiAlloc(alloc, safe, cols -| 5);
                var rows = std.mem.splitScalar(u8, body, '\n');
                while (rows.next()) |row| try wrapped.append(alloc, row);
            }
        }
        const page_size = @max(@as(usize, size.row) -| 3, 1);
        const max_offset = wrapped.items.len -| page_size;
        offset = @min(offset, max_offset);
        const end = @min(offset + page_size, wrapped.items.len);
        const alloc = submit.allocator;
        var frame_arena = std.heap.ArenaAllocator.init(alloc);
        defer frame_arena.deinit();
        const frame_alloc = frame_arena.allocator();
        var page_lines: std.ArrayList([]const u8) = .empty;
        try page_lines.appendSlice(frame_alloc, wrapped.items[offset..end]);
        const title = try frame_alloc.print("Tool output {d}-{d}/{d}", .{ offset + 1, end, wrapped.items.len });
        const lines = try components.dialog.renderLinesAlloc(frame_alloc, th, .{
            .title = title,
            .lines = page_lines.items,
            .hint = "Arrows / PgUp / PgDn · Esc close",
        }, cols);
        const last = lines.len - 1;
        try viewport.renderViewport(io, output, lines, .{ .row = last, .col = terminal.visibleWidth(lines[last]) }, cols);
        const key = try queue.readByteTimeout(input_fd, submit.cancel, 100) orelse {
            if (queue.eof) return;
            continue;
        };
        switch (key) {
            'q', 0x03, '\r', '\n' => return,
            'j' => offset +|= 1,
            'k' => offset -|= 1,
            0x1b => {
                const next = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse return;
                if (next != '[' and next != 'O') continue;
                const code = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse continue;
                switch (code) {
                    'A' => offset -|= 1,
                    'B' => offset +|= 1,
                    'H' => offset = 0,
                    'F' => offset = max_offset,
                    '5', '6' => if ((try queue.readByteTimeout(input_fd, submit.cancel, 25)) == '~') {
                        if (code == '5') offset -|= page_size else offset +|= page_size;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

pub fn run(io: std.Io, options: Submit) !void {
    var submit = options;
    const input = std.Io.File.stdin();
    const output = std.Io.File.stdout();
    if (!try input.isTty(io) or !try output.isTty(io)) return error.InteractiveTtyRequired;
    const color = try output.supportsAnsiEscapeCodes(io);
    const th = theme.Theme.init(submit.color_mode orelse if (color) .ansi16 else .none);
    const use_sgr = color and th.mode != .none;
    if (submit.fullscreen and (!color or submit.set_live_writer == null)) return error.FullscreenRequiresAnsiTerminal;
    var fullscreen_view = ConversationView.init(submit.allocator);
    defer fullscreen_view.deinit();
    if (submit.fullscreen) submit.conversation_view = &fullscreen_view;
    defer if (submit.fullscreen) output.writeStreamingAll(io, "\x1b[?1049l") catch {};
    if (submit.fullscreen) try output.writeStreamingAll(io, "\x1b[?1049h");
    var header_lines: usize = 0;
    if (!submit.quiet_startup and !submit.fullscreen) {
        header_lines = try renderStartupBanner(io, output, submit, th);
    }
    const had_initial_history = if (submit.fullscreen) blk: {
        if (submit.render_fullscreen_history) |render_history| break :blk try render_history(submit.context, &fullscreen_view);
        break :blk false;
    } else if (submit.render_initial_history) |render_init| try render_init(submit.context) else false;
    if (!submit.fullscreen and !had_initial_history and !submit.quiet_startup and th.mode != .none) {
        const sz = terminalSize(output);
        const editor_chrome_rows: usize = 5;
        if (sz.row > header_lines + editor_chrome_rows) {
            const pad = @min(@as(usize, sz.row) - header_lines - editor_chrome_rows, 80);
            var pad_buf: [80]u8 = undefined;
            @memset(pad_buf[0..pad], '\n');
            try output.writeStreamingAll(io, pad_buf[0..pad]);
        }
    }

    var queue = InputQueue{};
    var history = History{ .allocator = submit.allocator };
    defer history.deinit();
    var followups: std.ArrayList([]u8) = .empty;
    defer {
        for (followups.items) |item| submit.allocator.free(item);
        followups.deinit(submit.allocator);
    }
    var bg_queue: std.ArrayList([]u8) = .empty;
    defer {
        for (bg_queue.items) |item| submit.allocator.free(item);
        bg_queue.deinit(submit.allocator);
    }
    var carried_draft: ?[]u8 = null;
    defer if (carried_draft) |draft| submit.allocator.free(draft);
    var pending_dialog: ?DialogKind = null;

    while (true) {
        if (submit.reset_cancel) |reset| reset(submit.context);
        if (followups.items.len == 0 and bg_queue.items.len == 0) {
            try collectBgNotifications(submit, io, output, &bg_queue, false);
        }
        var is_bg_wakeup = false;
        const raw = if (followups.items.len > 0) blk: {
            pending_dialog = null;
            const next = followups.orderedRemove(0);
            const echo = try components.message.formatUserEchoAlloc(submit.allocator, th, next, terminalColumns(output));
            defer submit.allocator.free(echo);
            if (submit.conversation_view) |view| {
                try view.setPinnedUser(next);
                try view.appendText(echo);
                try view.appendText("\n");
            } else {
                try output.writeStreamingAll(io, echo);
                try output.writeStreamingAll(io, "\n");
            }
            break :blk next;
        } else if (bg_queue.items.len > 0) blk: {
            pending_dialog = null;
            is_bg_wakeup = true;
            break :blk bg_queue.orderedRemove(0);
        } else blk: {
            const initial = carried_draft;
            carried_draft = null;
            defer if (initial) |draft| submit.allocator.free(draft);
            const dlg = pending_dialog;
            pending_dialog = null;
            if (dlg == null and !submit.fullscreen) {
                const prompt_prefix = if (use_sgr) "\x1b[36m>\x1b[0m " else "> ";
                try output.writeStreamingAll(io, prompt_prefix);
            }
            const res = readPromptLine(submit.allocator, io, input.handle, output, &queue, &history, submit, &bg_queue, use_sgr, color, th, initial, dlg) catch |err| switch (err) {
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
            is_bg_wakeup = res.is_bg_wakeup;
            break :blk res.text;
        };
        defer submit.allocator.free(raw);

        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) continue;
        // Bare `!` enters a visibly distinct shell-editing state; execution is
        // only triggered after the user enters a non-empty command.
        if (!is_bg_wakeup and (std.mem.eql(u8, text, "!") or std.mem.eql(u8, text, "!!"))) {
            if (carried_draft) |old| submit.allocator.free(old);
            carried_draft = try submit.allocator.dupe(u8, text);
            continue;
        }
        if (!is_bg_wakeup) {
            try history.push(text);
            if (std.mem.eql(u8, text, "/exit") or std.mem.eql(u8, text, "/quit")) return;
        }
        if (std.mem.eql(u8, text, "/details")) {
            if (submit.tool_details) |get| {
                var scratch = std.heap.ArenaAllocator.init(submit.allocator);
                defer scratch.deinit();
                const items = try get(submit.context, scratch.allocator(), null);
                if (color) try eraseSubmittedPromptLine(io, output);
                showToolDetails(io, input.handle, output, &queue, submit, th, items) catch |err| switch (err) {
                    error.Canceled => {},
                    else => return err,
                };
            } else try output.writeStreamingAll(io, "Tool details are unavailable.\n");
            continue;
        }
        if (!is_bg_wakeup and isBangMode(text) and submit.run_user_shell != null) {
            const excluded = std.mem.startsWith(u8, text, "!!");
            const prefix_len: usize = if (excluded) 2 else 1;
            const command = std.mem.trim(u8, text[prefix_len..], " \t");
            if (command.len == 0) {
                try output.writeStreamingAll(io, "Usage: !<command> runs with context; !!<command> runs without context.\n");
                continue;
            }
            var shell_prompt: std.ArrayList(u8) = .empty;
            defer shell_prompt.deinit(submit.allocator);
            try shell_prompt.appendSlice(submit.allocator, if (excluded) "!! " else "! ");
            try shell_prompt.appendSlice(submit.allocator, command);
            const panel = try components.message.formatUserEchoAlloc(submit.allocator, th, shell_prompt.items, terminalColumns(output));
            defer submit.allocator.free(panel);
            try output.writeStreamingAll(io, panel);
            try output.writeStreamingAll(io, "\n");
            var scratch = std.heap.ArenaAllocator.init(submit.allocator);
            defer scratch.deinit();
            const result = runLocalShell(io, input.handle, &queue, submit, scratch.allocator(), command) catch |err| {
                var error_buf: [160]u8 = undefined;
                const line = std.fmt.bufPrint(&error_buf, "Shell command failed: {s}\n", .{@errorName(err)}) catch "Shell command failed.\n";
                try std.Io.File.stderr().writeStreamingAll(io, line);
                continue;
            };
            const safe_output = try terminal.safeUtf8Alloc(scratch.allocator(), result.text);
            const preview = try components.tool_card.formatBodyBlockAlloc(submit.allocator, th, safe_output, 8);
            defer submit.allocator.free(preview.text);
            try output.writeStreamingAll(io, preview.text);
            if (preview.truncated) try output.writeStreamingAll(io, "│ ... (local preview truncated)\n");
            try output.writeStreamingAll(io, if (result.is_error) "[command failed]\n" else "[command complete]\n");
            if (excluded) {
                try output.writeStreamingAll(io, "[command output excluded from agent context]\n");
                continue;
            }
            const context_text = try submit.allocator.print("User ran shell command: {s}\nExit outcome and output:\n{s}", .{ command, safe_output });
            defer submit.allocator.free(context_text);
            if (submit.record_user_shell) |record| try record(submit.context, context_text);
            try output.writeStreamingAll(io, "[output added to conversation context]\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/help")) {
            if (color) {
                try eraseSubmittedPromptLine(io, output);
                pending_dialog = .help;
            } else {
                try output.writeStreamingAll(io, "Enter a task to stream a response and run tools. /exit leaves the session.\nUse --session PATH to reopen; add --branch ENTRY-ID to continue from an earlier point.\nTab completes /commands and @paths; Up/Down navigates history; Alt+Enter or trailing \\ adds a newline.\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/hotkeys")) {
            if (color) {
                try eraseSubmittedPromptLine(io, output);
                pending_dialog = .hotkeys;
            } else {
                try output.writeStreamingAll(io, "Keyboard shortcuts\nEnter     Submit prompt (or queue follow-up while busy)\nCtrl-C    Cancel current turn or clear prompt\nCtrl-D    Exit on empty line / delete char\nUp/Down   Navigate history or lines\nLeft/Right Move cursor (Ctrl-A/E home/end)\nCtrl-W/U/K Delete word / to start / to end\nTab       Complete /command or @path\nAlt+Enter Insert newline (or trailing \\)\nAlt+Up    Edit queued follow-up messages\nEsc       Clear draft while busy / cancel selector\n/model    Fuzzy model picker (or /model [provider/id] | --list)\n/thinking Show or set thinking level (/thinking [off|minimal|low|medium|high|xhigh|max])\n/tree     Branch picker (/ filter, p prefill user msg, s summarize, Enter switch)\n/compact  Summarize older context (/compact [focus])\n/exit     Exit (/quit)\n/help     Show help\n/session  Show current session summary\n/hotkeys  Show shortcuts\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/model") or std.mem.startsWith(u8, text, "/model ")) {
            const raw_arg = if (text.len > "/model".len) std.mem.trim(u8, text["/model".len..], " \t") else "";
            if (submit.switch_model) |run_switch| {
                var model_arg: ?[]u8 = null;
                defer if (model_arg) |a| submit.allocator.free(a);
                const arg = if (std.mem.eql(u8, raw_arg, "--list"))
                    ""
                else if (raw_arg.len == 0 and color and submit.model_source != null) blk: {
                    try eraseSubmittedPromptLine(io, output);
                    var src = (submit.model_source.?(submit.context) catch |err| {
                        var msg: [256]u8 = undefined;
                        const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                        try std.Io.File.stderr().writeStreamingAll(io, line);
                        continue;
                    }) orelse break :blk "";
                    defer src.deinit(src.context);
                    const picked = selectModel(submit.allocator, io, input.handle, output, &queue, submit.cancel, src, th) catch |err| switch (err) {
                        error.Canceled => {
                            queue.start = queue.end;
                            continue;
                        },
                        else => return err,
                    };
                    if (queue.eof) return;
                    const ref = picked orelse continue;
                    model_arg = try submit.allocator.dupe(u8, ref);
                    break :blk model_arg.?;
                } else raw_arg;
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
                var prefill_text: ?[]const u8 = null;
                var skip_tree_cmd = false;
                const argument = if (target.len == 0 and color and submit.tree_source != null) blk: {
                    try eraseSubmittedPromptLine(io, output);
                    const tree = submit.tree_source.?(submit.context);
                    const choice = selectTree(io, input.handle, output, &queue, submit, tree, th) catch |err| switch (err) {
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
                    if (selected.prefill) |pf| {
                        prefill_text = pf;
                        if (!selected.branch_to_parent) skip_tree_cmd = true;
                        break :blk selected.id;
                    }
                    if (!selected.summarize) break :blk selected.id;
                    summary_arg = try submit.allocator.print("--summary {s}", .{selected.id});
                    break :blk summary_arg.?;
                } else target;
                if (!skip_tree_cmd) {
                    run_tree(submit.context, argument) catch |err| {
                        var msg: [256]u8 = undefined;
                        const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                        try std.Io.File.stderr().writeStreamingAll(io, line);
                        continue;
                    };
                }
                if (prefill_text) |pf| {
                    if (carried_draft) |old| submit.allocator.free(old);
                    carried_draft = try submit.allocator.dupe(u8, pf);
                }
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
        if (std.mem.eql(u8, text, "/jobs") or std.mem.startsWith(u8, text, "/jobs ")) {
            const arg = if (text.len > "/jobs".len) std.mem.trim(u8, text["/jobs".len..], " \t") else "";
            if (submit.jobs_info) |show_jobs| {
                show_jobs(submit.context, arg) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try std.Io.File.stderr().writeStreamingAll(io, line);
                };
            } else {
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: /jobs unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/resume") or std.mem.startsWith(u8, text, "/resume ")) {
            const raw_arg = if (text.len > "/resume".len) std.mem.trim(u8, text["/resume".len..], " \t") else "";
            if (submit.resume_session) |run_resume| {
                var path_arg: ?[]u8 = null;
                defer if (path_arg) |a| submit.allocator.free(a);
                const arg = if (std.mem.eql(u8, raw_arg, "--list"))
                    ""
                else if (raw_arg.len == 0 and color and submit.session_source != null) blk: {
                    try eraseSubmittedPromptLine(io, output);
                    var src = (submit.session_source.?(submit.context) catch |err| {
                        var msg: [256]u8 = undefined;
                        const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                        try std.Io.File.stderr().writeStreamingAll(io, line);
                        continue;
                    }) orelse break :blk "";
                    defer src.deinit(src.context);
                    const picked = selectSession(submit.allocator, io, input.handle, output, &queue, submit.cancel, src, th) catch |err| switch (err) {
                        error.Canceled => {
                            queue.start = queue.end;
                            continue;
                        },
                        else => return err,
                    };
                    if (queue.eof) return;
                    const chosen_path = picked orelse continue;
                    path_arg = try submit.allocator.dupe(u8, chosen_path);
                    break :blk path_arg.?;
                } else raw_arg;
                run_resume(submit.context, arg) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try std.Io.File.stderr().writeStreamingAll(io, line);
                };
            } else {
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: /resume unavailable\n");
            }
            continue;
        }
        if (color and submit.set_live_writer != null) {
            try runTurnWithLiveEditor(io, input.handle, output, &queue, &history, submit, text, &followups, &bg_queue, &carried_draft, use_sgr, th);
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
    th: theme.Theme,
) !?TreeSelection {
    if (source.len == 0) {
        try output.writeStreamingAll(io, "No entries in session.\n");
        return null;
    }
    const Adapter = struct {
        src: TreeSource,
        fn item(ctx: *const anyopaque, idx: usize) components.select_list.Item {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            const ti = self.src.item(self.src.context, idx);
            return .{
                .id = ti.id,
                .role = ti.role,
                .preview = ti.preview,
                .search_text = ti.preview,
                .depth = ti.depth,
                .is_active = self.src.active == idx,
                .is_user_message = ti.is_user_message,
                .parent_id = ti.parent_id,
                .full_text = ti.full_text,
            };
        }
    };
    const adapter = Adapter{ .src = source };
    const picked = try components.select_list.run(
        submit.allocator,
        io,
        input_fd,
        output,
        queue,
        submit.cancel,
        .{ .context = &adapter, .len = source.len, .active = source.active, .item = Adapter.item },
        .{
            .title = "Session tree",
            .title_hint = "  / filter · p prefill",
            .mode = .tree,
            .footer_full = "Up/Down move  Enter switch  s summarize  Esc cancel",
            .footer_medium = "Up/Down Enter s=summary Esc",
            .footer_narrow = "Up/Down Enter Esc",
            .confirm_prompt = summary_confirmation,
            .max_visible = 20,
        },
        th,
    );
    const chosen = picked orelse return null;
    return switch (chosen.action) {
        .select => .{ .id = chosen.item.id },
        .summarize => .{ .id = chosen.item.id, .summarize = true },
        .prefill => .{
            .id = chosen.item.parent_id orelse chosen.item.id,
            .prefill = chosen.item.full_text,
            .branch_to_parent = chosen.item.parent_id != null,
        },
    };
}

fn selectModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    cancel: ?agent.model.Cancel,
    source: ModelSource,
    th: theme.Theme,
) !?[]const u8 {
    if (source.len == 0) {
        try output.writeStreamingAll(io, "No configured models.\n");
        return null;
    }
    const Adapter = struct {
        src: ModelSource,
        fn item(ctx: *const anyopaque, idx: usize) components.select_list.Item {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            const mi = self.src.item(self.src.context, idx);
            return .{
                .id = mi.ref,
                .role = mi.api,
                .search_text = mi.ref,
                .is_active = mi.is_active,
            };
        }
    };
    const adapter = Adapter{ .src = source };
    const picked = try components.select_list.run(
        allocator,
        io,
        input_fd,
        output,
        queue,
        cancel,
        .{ .context = &adapter, .len = source.len, .active = source.active, .item = Adapter.item },
        .{
            .title = "Models",
            .title_hint = "  type to filter",
            .mode = .direct_filter,
            .footer_full = "Type to filter  Up/Down move  Enter switch  Esc cancel",
            .footer_medium = "Filter Up/Down Enter Esc",
            .footer_narrow = "Up/Down Enter Esc",
            .max_visible = 16,
        },
        th,
    );
    const chosen = picked orelse return null;
    return chosen.item.id;
}

fn selectSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    cancel: ?agent.model.Cancel,
    source: SessionSource,
    th: theme.Theme,
) !?[]const u8 {
    if (source.len == 0) {
        try output.writeStreamingAll(io, "No matching sessions found.\n");
        return null;
    }
    const Adapter = struct {
        src: SessionSource,
        fn item(ctx: *const anyopaque, idx: usize) components.select_list.Item {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            const si = self.src.item(self.src.context, idx);
            return .{
                .id = si.label,
                .preview = si.preview,
                .search_text = si.preview,
                .is_active = si.is_active,
                .full_text = si.path,
            };
        }
    };
    const adapter = Adapter{ .src = source };
    const picked = try components.select_list.run(
        allocator,
        io,
        input_fd,
        output,
        queue,
        cancel,
        .{ .context = &adapter, .len = source.len, .active = source.active, .item = Adapter.item },
        .{
            .title = "Sessions",
            .title_hint = "  type to filter",
            .mode = .direct_filter,
            .footer_full = "Type to filter  Up/Down move  Enter resume  Esc cancel",
            .footer_medium = "Filter Up/Down Enter Esc",
            .footer_narrow = "Up/Down Enter Esc",
            .max_visible = 16,
        },
        th,
    );
    const chosen = picked orelse return null;
    return chosen.item.full_text;
}

const summary_confirmation = "Send departed branch to provider? y/n";

const EditorState = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history_idx: ?usize = null,
    draft: ?[]u8 = null,
    rendered_cursor_row: usize = 0,
    last_tab_prefix: ?[]u8 = null,
    completion_hint: ?[]u8 = null,

    fn deinit(self: *EditorState) void {
        self.buf.deinit(self.allocator);
        if (self.draft) |d| self.allocator.free(d);
        if (self.last_tab_prefix) |p| self.allocator.free(p);
        if (self.completion_hint) |h| self.allocator.free(h);
    }

    fn resetCompletionTrack(self: *EditorState) void {
        if (self.last_tab_prefix) |p| {
            self.allocator.free(p);
            self.last_tab_prefix = null;
        }
        if (self.completion_hint) |h| {
            self.allocator.free(h);
            self.completion_hint = null;
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
        const lines: []const []const u8 = if (footer_line) |fl| &.{fl} else &.{};
        return self.renderWithOverlay(io, output, cols, color, theme.Theme.init(if (color) .ansi16 else .none), &.{}, &.{}, lines, false, false);
    }

    fn appendRuleLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, th: theme.Theme, cols: usize, editing_bang: bool) !usize {
        const rule_w = @max(@as(usize, 4), cols -| 1);
        try th.appendOpen(out, allocator, if (editing_bang) theme.Theme.tool_ok else theme.Theme.border);
        var i: usize = 0;
        while (i < rule_w) : (i += 1) try out.appendSlice(allocator, "─");
        try th.appendClose(out, allocator);
        return rule_w;
    }

    fn clearAll(self: *EditorState, io: std.Io, output: std.Io.File, th: theme.Theme) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        if (th.mode != .none) try out.appendSlice(self.allocator, renderer.sync_begin);
        if (self.rendered_cursor_row > 0) {
            try out.print(self.allocator, "\x1b[{d}A", .{self.rendered_cursor_row});
        }
        try out.appendSlice(self.allocator, "\r\x1b[J");
        if (th.mode != .none) try out.appendSlice(self.allocator, renderer.sync_end);
        self.rendered_cursor_row = 0;
        try output.writeStreamingAll(io, out.items);
    }

    fn renderWithOverlay(
        self: *EditorState,
        io: std.Io,
        output: std.Io.File,
        cols: usize,
        use_sgr: bool,
        th: theme.Theme,
        dialog_lines: []const []const u8,
        popup_lines: []const []const u8,
        footer_lines: []const []const u8,
        show_rules: bool,
        shell_mode: bool,
    ) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        if (use_sgr or th.mode != .none) try out.appendSlice(self.allocator, renderer.sync_begin);
        if (self.rendered_cursor_row > 0) {
            try out.print(self.allocator, "\x1b[{d}A", .{self.rendered_cursor_row});
        }
        try out.appendSlice(self.allocator, "\r\x1b[J");

        for (dialog_lines) |dline| {
            try out.appendSlice(self.allocator, dline);
            try out.appendSlice(self.allocator, "\r\n");
        }
        var rows_above = dialog_lines.len;

        if (show_rules) {
            _ = try appendRuleLine(&out, self.allocator, th, cols, shell_mode);
            try out.appendSlice(self.allocator, "\r\n");
            rows_above += 1;
        }

        if (shell_mode) {
            try th.paint(&out, self.allocator, theme.Theme.tool_ok, "! ");
        } else {
            try out.appendSlice(self.allocator, if (use_sgr) "\x1b[36m>\x1b[0m " else "> ");
        }

        // Compute visual coordinates (prompt width = 2 on line 0) across newlines and soft wraps.
        const layout = computeLayout(self.buf.items, self.cursor, cols, 2);
        try appendSafeTerminalBytes(&out, self.allocator, self.buf.items);

        var total_end_row = layout.end_row;
        var total_end_col = layout.end_col;
        if (show_rules) {
            try out.appendSlice(self.allocator, "\r\n");
            const rule_w = try appendRuleLine(&out, self.allocator, th, cols, shell_mode);
            total_end_row += 1;
            total_end_col = rule_w;
        }
        if (popup_lines.len > 0) {
            for (popup_lines) |pl| {
                try out.appendSlice(self.allocator, "\r\n");
                try out.appendSlice(self.allocator, pl);
                total_end_row += 1;
                total_end_col = terminal.visibleWidth(pl);
            }
        } else if (self.completion_hint) |hint| {
            if (hint.len > 0) {
                try out.appendSlice(self.allocator, "\r\n");
                var styled_hint: std.ArrayList(u8) = .empty;
                defer styled_hint.deinit(self.allocator);
                try th.paint(&styled_hint, self.allocator, theme.Theme.muted, hint);
                try out.appendSlice(self.allocator, styled_hint.items);
                total_end_row += 1;
                total_end_col = terminal.visibleWidth(hint);
            }
        }
        for (footer_lines) |fl| {
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
        if (use_sgr or th.mode != .none) try out.appendSlice(self.allocator, renderer.sync_end);
        self.rendered_cursor_row = rows_above + layout.cursor_row;
        try output.writeStreamingAll(io, out.items);
    }
};

const builtin_commands = [_][]const u8{ "/help", "/hotkeys", "/session", "/resume", "/tree", "/model", "/thinking", "/compact", "/exit", "/quit" };

fn handleTab(editor: *EditorState, io: std.Io, submit: Submit, cols: usize, color: bool, allow_list: bool) !bool {
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

    // Multiple matches: insert any shared prefix and display a transient hint below the prompt.
    if (!allow_list or !color) return false;
    var list_out: std.ArrayList(u8) = .empty;
    defer list_out.deinit(editor.allocator);
    const max_cols = @max(12, cols -| 1);
    const shown = @min(matches.items.len, 12);
    for (matches.items[0..shown], 0..) |m, idx| {
        if (idx > 0) try list_out.appendSlice(editor.allocator, "  ");
        try list_out.appendSlice(editor.allocator, m);
    }
    if (matches.items.len > shown) {
        try list_out.print(editor.allocator, "  (+{d} more)", .{matches.items.len - shown});
    }
    var clipped: std.ArrayList(u8) = .empty;
    defer clipped.deinit(editor.allocator);
    _ = try terminal.appendTruncatedAnsi(&clipped, editor.allocator, list_out.items, max_cols, "...");
    if (editor.completion_hint) |old| editor.allocator.free(old);
    editor.completion_hint = try clipped.toOwnedSlice(editor.allocator);
    return true;
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

fn applyAutocomplete(
    editor: *EditorState,
    popup: *components.autocomplete.Popup,
    io: std.Io,
    submit: Submit,
    cand: components.autocomplete.Candidate,
) !void {
    editor.resetCompletionTrack();
    const start = @min(popup.token_start, editor.buf.items.len);
    const end = @min(popup.token_end, editor.buf.items.len);
    if (end < start) return;
    const label = try editor.allocator.dupe(u8, cand.label);
    defer editor.allocator.free(label);
    const is_cmd = popup.kind == .command;
    const is_dir = cand.is_dir;

    try editor.buf.replaceRange(editor.allocator, start, end - start, label);
    editor.cursor = start + label.len;
    if (is_cmd and editor.cursor == editor.buf.items.len) {
        try editor.insertSlice(" ");
        popup.clear();
    } else if (!is_cmd and is_dir) {
        try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
    } else {
        popup.clear();
    }
}

const PromptInput = struct {
    text: []u8,
    is_bg_wakeup: bool = false,
};

fn collectBgNotifications(
    submit: Submit,
    io: std.Io,
    output: std.Io.File,
    bg_queue: *std.ArrayList([]u8),
    silent: bool,
) !void {
    if (submit.reset_bg_wake) |reset| reset(submit.context);
    const pop_fn = submit.pop_bg_notifications orelse return;
    const notes = try pop_fn(submit.context, submit.allocator);
    defer {
        for (notes) |n| {
            submit.allocator.free(n.task_name);
            submit.allocator.free(n.text);
        }
        submit.allocator.free(notes);
    }
    for (notes) |n| {
        if (!silent) {
            var line_buf: [256]u8 = undefined;
            const notice = std.fmt.bufPrint(&line_buf, "[bg {s}: {s}]\n", .{ n.status, n.task_name }) catch "[bg task updated]\n";
            output.writeStreamingAll(io, notice) catch {};
        }
        if (n.trigger) {
            try bg_queue.append(submit.allocator, try submit.allocator.dupe(u8, n.text));
        }
    }
}

fn readPromptLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    history: *const History,
    submit: Submit,
    bg_queue: *std.ArrayList([]u8),
    use_sgr: bool,
    term_ansi: bool,
    th: theme.Theme,
    initial: ?[]const u8,
    initial_dialog: ?DialogKind,
) anyerror!?PromptInput {
    if (submit.cancel) |token| {
        if (token.isCanceled()) return error.Canceled;
    }
    const orig_term = try enterRawMode(input_fd);
    defer terminal.setTermiosNow(input_fd, orig_term) catch {};

    defer output.writeStreamingAll(io, if (submit.fullscreen) mouse.disable ++ "\x1b[?2004l" else "\x1b[?2004l") catch {};
    try output.writeStreamingAll(io, if (submit.fullscreen) "\x1b[?2004h" ++ mouse.enable else "\x1b[?2004h");

    var editor = EditorState{ .allocator = allocator };
    defer editor.deinit();
    var popup = components.autocomplete.Popup.init(allocator);
    defer popup.deinit();

    const has_footer = th.mode != .none and submit.status_info != null;
    var dialog = initial_dialog;
    var dialog_on_screen = false;
    var in_paste = false;
    var cols = terminalColumns(output);
    var last_size = terminalSize(output);
    var dirty = has_footer or dialog != null or submit.fullscreen;
    if (initial) |text| {
        if (text.len > 0) {
            try editor.insertSlice(text);
            dirty = true;
        }
    }

    while (true) {
        if ((dirty and !queue.hasBuffered()) or (dialog != null and !dialog_on_screen)) {
            cols = terminalColumns(output);
            if (th.mode != .none and !in_paste) {
                try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
            } else {
                popup.clear();
            }

            const popup_lines: [][]u8 = if (popup.isOpen())
                try popup.renderLinesAlloc(allocator, th, cols)
            else
                &.{};
            defer {
                for (popup_lines) |pl| allocator.free(pl);
                if (popup_lines.len > 0) allocator.free(popup_lines);
            }
            const popup_slices = try allocator.alloc([]const u8, popup_lines.len);
            defer allocator.free(popup_slices);
            for (popup_lines, popup_slices) |pl, *s| s.* = pl;

            var footer_buf: ?[2][]u8 = null;
            if (has_footer) {
                var info = submit.status_info.?(submit.context);
                info.queued_count = 0;
                footer_buf = try components.chrome.Footer.renderLinesAlloc(allocator, th, info, @max(1, cols -| 1));
            }
            defer if (footer_buf) |fb| {
                allocator.free(fb[0]);
                allocator.free(fb[1]);
            };
            const footer_slices: []const []const u8 = if (footer_buf) |*fb| fb else &.{};

            const dialog_lines: [][]u8 = if (dialog) |dk| blk: {
                const spec: components.dialog.DialogSpec = switch (dk) {
                    .help => .{ .title = "Help", .lines = &components.dialog.help_lines },
                    .hotkeys => .{ .title = "Keyboard shortcuts", .lines = &components.dialog.hotkeys_lines },
                };
                break :blk try components.dialog.renderLinesAlloc(allocator, th, spec, cols);
            } else &.{};
            defer {
                for (dialog_lines) |dl| allocator.free(dl);
                if (dialog_lines.len > 0) allocator.free(dialog_lines);
            }
            const dialog_slices = try allocator.alloc([]const u8, dialog_lines.len);
            defer allocator.free(dialog_slices);
            for (dialog_lines, dialog_slices) |dl, *s| s.* = dl;

            if (submit.fullscreen and submit.conversation_view != null) {
                try renderFullscreenConversation(allocator, io, output, submit.conversation_view.?, &editor, "", dialog_slices, popup_slices, footer_slices, &.{}, th);
            } else {
                try editor.renderWithOverlay(io, output, cols, use_sgr, th, dialog_slices, popup_slices, footer_slices, th.mode != .none, isBangMode(editor.buf.items));
            }
            dialog_on_screen = dialog_slices.len > 0;
            dirty = false;
        }
        const b_opt = try queue.readByteWithCancelAndWake(input_fd, submit.cancel, submit.bg_wake, if (submit.fullscreen) 100 else -1);
        const b = b_opt orelse {
            if (!queue.eof) {
                if (submit.fullscreen) {
                    const new_size = terminalSize(output);
                    if (new_size.row != last_size.row or new_size.col != last_size.col) {
                        last_size = new_size;
                        dirty = true;
                    }
                    const bg_ready = if (submit.bg_wake) |wake| wake.isCanceled() else false;
                    if (!bg_ready) continue;
                }
                try collectBgNotifications(submit, io, output, bg_queue, true);
                if (bg_queue.items.len > 0 and editor.buf.items.len == 0 and dialog == null and !popup.isOpen()) {
                    try editor.clearAll(io, output, th);
                    try output.writeStreamingAll(io, "[bg task completed]\n");
                    return .{ .text = bg_queue.orderedRemove(0), .is_bg_wakeup = true };
                }
                dirty = true;
                continue;
            }
            popup.clear();
            if (dialog_on_screen or editor.completion_hint != null or th.mode != .none) {
                editor.resetCompletionTrack();
                editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, &.{}, false, isBangMode(editor.buf.items)) catch {};
                dialog_on_screen = false;
            }
            if (editor.buf.items.len == 0) {
                try output.writeStreamingAll(io, "\n");
                return null;
            }
            return .{ .text = try editor.buf.toOwnedSlice(allocator) };
        };

        if (dialog != null) {
            dialog = null;
            dirty = true;
            if (b == 0x03) continue;
            if ((b == '\r' or b == '\n' or b == 'q' or b == 'Q' or b == '?') and editor.buf.items.len == 0) continue;
            if (b == 0x1b) {
                const next = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse continue;
                if (next == 0x1b) continue;
                if (queue.start > 0) queue.start -= 1;
            }
        }

        switch (b) {
            0x03 => {
                popup.clear();
                if (dialog_on_screen or editor.completion_hint != null or th.mode != .none) {
                    editor.resetCompletionTrack();
                    editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, &.{}, false, false) catch {};
                    dialog_on_screen = false;
                }
                return error.Canceled;
            },
            0x04 => {
                if (editor.buf.items.len == 0) {
                    popup.clear();
                    if (dialog_on_screen or editor.completion_hint != null or th.mode != .none) {
                        editor.resetCompletionTrack();
                        editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, &.{}, false, isBangMode(editor.buf.items)) catch {};
                        dialog_on_screen = false;
                    }
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
                if (th.mode != .none and dirty) {
                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                }
                if (popup.isOpen() and popup.kind == .command and editor.cursor == editor.buf.items.len) {
                    if (popup.selectedItem()) |candidate| {
                        const execute = components.autocomplete.isBuiltin(candidate.label) or std.mem.eql(u8, candidate.label, editor.buf.items);
                        try applyAutocomplete(&editor, &popup, io, submit, candidate);
                        dirty = true;
                        if (!execute) continue;
                    }
                }
                if (popup.isOpen() and popup.user_navigated and popup.kind == .path) {
                    if (popup.selectedItem()) |candidate| {
                        try applyAutocomplete(&editor, &popup, io, submit, candidate);
                        dirty = true;
                        continue;
                    }
                }
                if (editor.cursor == editor.buf.items.len and editor.buf.items.len > 0 and editor.buf.items[editor.buf.items.len - 1] == '\\') {
                    editor.buf.items.len -= 1;
                    editor.cursor -= 1;
                    try editor.insertSlice("\n");
                    dirty = true;
                    continue;
                }
                const submitted = std.mem.trim(u8, editor.buf.items, " \t\r\n");
                if ((use_sgr or submit.fullscreen) and submitted.len > 0 and submitted[0] != '/' and !isBangMode(submitted)) {
                    if (!submit.fullscreen) try editor.clearAll(io, output, th);
                    const echo = try components.message.formatUserEchoAlloc(allocator, th, submitted, terminalColumns(output));
                    defer allocator.free(echo);
                    if (submit.conversation_view) |view| {
                        try view.setPinnedUser(submitted);
                        try view.appendText(echo);
                        try view.appendText("\n");
                    } else {
                        try output.writeStreamingAll(io, echo);
                        try output.writeStreamingAll(io, "\n");
                    }
                    return .{ .text = try editor.buf.toOwnedSlice(allocator) };
                }
                const had_hint = editor.completion_hint != null or popup.isOpen();
                popup.clear();
                editor.resetCompletionTrack();
                if (dirty or had_hint or has_footer or th.mode != .none) {
                    cols = terminalColumns(output);
                    try editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, &.{}, false, isBangMode(editor.buf.items));
                }
                try output.writeStreamingAll(io, "\n");
                return .{ .text = try editor.buf.toOwnedSlice(allocator) };
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
                if (th.mode != .none and !in_paste and dirty) {
                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                }
                if (popup.isOpen()) {
                    popup.moveUp();
                } else {
                    try editor.moveUpLineOrHistory(history);
                }
                dirty = true;
            },
            0x0e => {
                if (th.mode != .none and !in_paste and dirty) {
                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                }
                if (popup.isOpen()) {
                    popup.moveDown();
                } else {
                    try editor.moveDownLineOrHistory(history);
                }
                dirty = true;
            },
            0x0f => {
                if (submit.toggle_expand) |toggle| {
                    _ = toggle(submit.context);
                    dirty = true;
                }
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
                    cols = terminalColumns(output);
                    if (th.mode == .none) {
                        if (try handleTab(&editor, io, submit, cols, term_ansi, false)) dirty = true;
                    } else {
                        try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                        if (popup.items.items.len > 0) {
                            popup.dismissed = false;
                            if (popup.user_navigated or popup.items.items.len == 1) {
                                if (popup.selectedItem()) |cand| {
                                    try applyAutocomplete(&editor, &popup, io, submit, cand);
                                    dirty = true;
                                }
                            } else {
                                const lcp_len = popup.commonPrefixLen();
                                const tok_len = popup.token_end - popup.token_start;
                                if (lcp_len > tok_len) {
                                    const start = @min(popup.token_start, editor.buf.items.len);
                                    const end = @min(popup.token_end, editor.buf.items.len);
                                    const lcp = try editor.allocator.dupe(u8, popup.items.items[0].label[0..lcp_len]);
                                    defer editor.allocator.free(lcp);
                                    try editor.buf.replaceRange(editor.allocator, start, end - start, lcp);
                                    editor.cursor = start + lcp.len;
                                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                                    dirty = true;
                                } else {
                                    popup.moveDown();
                                    dirty = true;
                                }
                            }
                        }
                    }
                } else {
                    try editor.insertSlice("\t");
                    dirty = true;
                }
            },
            0x1b => {
                const next = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse {
                    if (th.mode != .none and !in_paste and dirty) {
                        try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                    }
                    if (popup.isOpen()) {
                        popup.dismiss();
                        dirty = true;
                    } else if (editor.completion_hint != null) {
                        editor.resetCompletionTrack();
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
                                if (th.mode != .none and !in_paste and dirty) {
                                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                                }
                                if (popup.isOpen()) {
                                    popup.moveUp();
                                } else {
                                    try editor.moveUpLineOrHistory(history);
                                }
                                dirty = true;
                            },
                            'B' => {
                                if (th.mode != .none and !in_paste and dirty) {
                                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                                }
                                if (popup.isOpen()) {
                                    popup.moveDown();
                                } else {
                                    try editor.moveDownLineOrHistory(history);
                                }
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
                        if (!in_paste) if (submit.conversation_view) |view| if (final_byte) |fin| {
                            if (mouse.Event.parse(fin, params)) |event| {
                                if (!dirty and mouseMatchesFrame(view, terminalSize(output), event)) {
                                    if (!scrollWithMouse(view, event) and event.kind == .left) {
                                        const index = event.row -| view.popup_row;
                                        if (event.row >= view.popup_row and index < view.popup_rows and popup.isOpen() and popup.kind == .command) {
                                            const item = popup.scroll + index;
                                            if (index < components.autocomplete.Popup.max_visible and item < popup.items.items.len) {
                                                try applyAutocomplete(&editor, &popup, io, submit, popup.items.items[item]);
                                            }
                                        } else if (view.toolAtRow(event.row)) |id| {
                                            if (submit.tool_details) |get| {
                                                var arena = std.heap.ArenaAllocator.init(allocator);
                                                defer arena.deinit();
                                                const items = try get(submit.context, arena.allocator(), id);
                                                if (items.len > 0) {
                                                    try output.writeStreamingAll(io, mouse.disable);
                                                    defer output.writeStreamingAll(io, mouse.enable) catch {};
                                                    showToolDetails(io, input_fd, output, queue, submit, th, items) catch |err| switch (err) {
                                                        error.Canceled => {},
                                                        else => return err,
                                                    };
                                                }
                                            }
                                        }
                                    }
                                }
                                dirty = true;
                                continue;
                            }
                            if (view.handleScrollKey(fin, params)) {
                                dirty = true;
                                continue;
                            }
                        };
                        if (final_byte) |fin| switch (fin) {
                            'A' => {
                                if (th.mode != .none and !in_paste and dirty) {
                                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                                }
                                if (popup.isOpen()) {
                                    popup.moveUp();
                                } else {
                                    try editor.moveUpLineOrHistory(history);
                                }
                                dirty = true;
                            },
                            'B' => {
                                if (th.mode != .none and !in_paste and dirty) {
                                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                                }
                                if (popup.isOpen()) {
                                    popup.moveDown();
                                } else {
                                    try editor.moveDownLineOrHistory(history);
                                }
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
                            'Z' => {
                                if (submit.cycle_thinking) |cycle| {
                                    cycle(submit.context);
                                    dirty = true;
                                }
                            },
                            'u' => {
                                // Kitty CSI-u Shift+Enter -> insert newline; Shift+Tab -> cycle thinking.
                                if (std.mem.eql(u8, params, "13;2")) {
                                    try editor.insertSlice("\n");
                                    dirty = true;
                                } else if (std.mem.eql(u8, params, "9;2")) {
                                    if (submit.cycle_thinking) |cycle| {
                                        cycle(submit.context);
                                        dirty = true;
                                    }
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
    _ = components.select_list;
    _ = components.dialog;
    _ = components.autocomplete;
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
    conversation_view: ?*ConversationView = null,
    md: components.markdown.MarkdownStyler = .{},
    loader: components.chrome.Loader = .{},
    mutex: std.Io.Mutex = .init,
    pending_line: std.ArrayList(u8) = .empty,
    overlay_bytes: std.ArrayList(u8) = .empty,
    overlay_cursor_row: usize = 0,
    overlay_cols: usize = 80,
    overlay_active: bool = false,

    const max_pending_line_bytes: usize = 4096;

    fn init(allocator: std.mem.Allocator, io: std.Io, output: std.Io.File, color: bool, th: theme.Theme, conversation_view: ?*ConversationView) LiveScreen {
        return .{ .allocator = allocator, .io = io, .output = output, .color = color, .th = th, .conversation_view = conversation_view };
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
            .write_tool_header = if (self.conversation_view != null) writeToolHeaderErased else null,
        };
    }

    fn writeSegmentErased(context: *anyopaque, prefix: []const u8, safe: []const u8, suffix: []const u8) anyerror!void {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        return self.writeSegment(prefix, safe, suffix);
    }

    fn writeToolHeaderErased(context: *anyopaque, header: []const u8, id: []const u8) anyerror!void {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.conversation_view.?.appendToolHeader(header, id);
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

    fn handleScrollKey(self: *LiveScreen, final: u8, params: []const u8) bool {
        const view = self.conversation_view orelse return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (mouse.Event.parse(final, params)) |event| {
            if (mouseMatchesFrame(view, terminalSize(self.output), event)) _ = scrollWithMouse(view, event);
            return true;
        }
        return view.handleScrollKey(final, params);
    }

    fn writeSegment(self: *LiveScreen, prefix: []const u8, safe: []const u8, suffix: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.conversation_view) |view| {
            try view.appendText(prefix);
            const clean = try terminal.safeUtf8Alloc(self.allocator, safe);
            defer self.allocator.free(clean);
            try view.appendText(clean);
            try view.appendText(suffix);
            return;
        }

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);
        if (self.color) try frame.appendSlice(self.allocator, renderer.sync_begin);
        const body_start = frame.items.len;

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

        if (frame.items.len > body_start) {
            if (self.color) try frame.appendSlice(self.allocator, renderer.sync_end);
            try self.output.writeStreamingAll(self.io, frame.items);
        }
    }

    fn writeMarkdown(self: *LiveScreen, delta: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.conversation_view) |view| {
            const clean = try terminal.safeUtf8Alloc(self.allocator, delta);
            defer self.allocator.free(clean);
            var rest = clean;
            while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                try view.appendText(rest[0..nl]);
                if (!view.pending_clipped) {
                    const styled = try self.md.styleLine(self.allocator, self.th, view.pending.items);
                    defer self.allocator.free(styled);
                    view.pending.clearRetainingCapacity();
                    try view.appendText(styled);
                }
                try view.flush();
                rest = rest[nl + 1 ..];
            }
            try view.appendText(rest);
            return;
        }

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);
        if (self.color) try frame.appendSlice(self.allocator, renderer.sync_begin);
        const body_start = frame.items.len;

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

            const wrap_cols = @max(16, self.overlay_cols -| 1);
            const needs_style = self.th.mode != .none and (self.md.in_code_fence or components.markdown.MarkdownStyler.hasSyntax(full_line.items));
            const needs_wrap = self.color and terminal.visibleWidth(full_line.items) > wrap_cols;
            if (needs_style or needs_wrap) {
                const styled = try self.md.styleWrappedLineAlloc(self.allocator, self.th, full_line.items, wrap_cols);
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

        if (frame.items.len > body_start) {
            if (self.color) try frame.appendSlice(self.allocator, renderer.sync_end);
            try self.output.writeStreamingAll(self.io, frame.items);
        }
    }

    fn loaderTickAndRender(
        self: *LiveScreen,
        editor: *const EditorState,
        followups: []const []const u8,
        submit: Submit,
        cols: usize,
        delta_ms: u64,
    ) !void {
        var loader_line: ?[]u8 = null;
        defer if (loader_line) |line| self.allocator.free(line);
        var footer_lines: ?[2][]u8 = null;
        defer if (footer_lines) |lines| {
            for (lines) |line| self.allocator.free(line);
        };
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (delta_ms > 0) self.loader.tick(delta_ms);
            if (self.th.mode != .none) {
                const max_cols = @max(1, cols -| 1);
                loader_line = try self.loader.renderLineAlloc(self.allocator, self.th, max_cols);
            }
        }
        if (self.th.mode != .none) {
            if (submit.status_info) |get_info| {
                var info = get_info(submit.context);
                info.queued_count = followups.len;
                footer_lines = try components.chrome.Footer.renderLinesAlloc(self.allocator, self.th, info, @max(1, cols -| 1));
            }
        }
        if (self.conversation_view) |view| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try renderFullscreenConversation(self.allocator, self.io, self.output, view, editor, loader_line orelse "", &.{}, &.{}, if (footer_lines) |*lines| lines else &.{}, followups, self.th);
            return;
        }
        const rendered = try renderLiveOverlayFrameWithChrome(
            self.allocator,
            editor,
            followups,
            cols,
            self.color,
            self.th,
            loader_line,
            if (footer_lines) |*lines| lines else &.{},
        );
        defer self.allocator.free(rendered.bytes);
        try self.updateOverlay(rendered.bytes, rendered.cursor_row, cols);
    }

    fn updateOverlay(self: *LiveScreen, new_bytes: []const u8, new_cursor_row: usize, cols: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.overlay_active and cols == self.overlay_cols and new_cursor_row == self.overlay_cursor_row and std.mem.eql(u8, self.overlay_bytes.items, new_bytes)) {
            return;
        }

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);
        if (self.color) try frame.appendSlice(self.allocator, renderer.sync_begin);

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

        if (frame.items.len > 0) {
            if (self.color) try frame.appendSlice(self.allocator, renderer.sync_end);
            try self.output.writeStreamingAll(self.io, frame.items);
        }
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
    return renderLiveOverlayFrameWithChrome(allocator, editor, followups, cols_raw, color, theme.Theme.init(if (color) .ansi16 else .none), null, &.{});
}

fn renderLiveOverlayFrameWithChrome(
    allocator: std.mem.Allocator,
    editor: *const EditorState,
    followups: []const []const u8,
    cols_raw: usize,
    color: bool,
    th: theme.Theme,
    loader_line: ?[]const u8,
    footer_lines: []const []const u8,
) !LiveOverlayFrame {
    const show_editor = loader_line != null or editor.buf.items.len > 0;
    if (followups.len == 0 and !show_editor) {
        return .{ .bytes = try allocator.alloc(u8, 0), .cursor_row = 0 };
    }
    const cols = @max(cols_raw, 4);
    const max_preview_cols = @max(1, cols -| 1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rows_above: usize = 0;
    if (loader_line) |line| {
        try out.appendSlice(allocator, line);
        try out.appendSlice(allocator, "\r\n");
        rows_above += 1;
    }
    if (followups.len > 0) {
        const shown = @min(followups.len, 4);
        for (followups[0..shown], 1..) |item, idx| {
            var label_buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "[queued {d}] ", .{idx});
            if (color) try out.appendSlice(allocator, "\x1b[2m");
            const used = try appendTreeText(&out, allocator, label, max_preview_cols);
            _ = try appendTreeText(&out, allocator, item, max_preview_cols -| used);
            if (color) try out.appendSlice(allocator, "\x1b[0m");
            try out.appendSlice(allocator, "\r\n");
            rows_above += 1;
        }
        if (followups.len > shown) {
            var more_buf: [48]u8 = undefined;
            const more = try std.fmt.bufPrint(&more_buf, "  (+{d} more queued)", .{followups.len - shown});
            if (color) try out.appendSlice(allocator, "\x1b[2m");
            _ = try appendTreeText(&out, allocator, more, max_preview_cols);
            if (color) try out.appendSlice(allocator, "\x1b[0m");
            try out.appendSlice(allocator, "\r\n");
            rows_above += 1;
        }
        if (editor.buf.items.len == 0) {
            if (color) try out.appendSlice(allocator, "\x1b[2m");
            _ = try appendTreeText(&out, allocator, "  Alt+Up edit queued", max_preview_cols);
            if (color) try out.appendSlice(allocator, "\x1b[0m");
            if (!show_editor) return .{ .bytes = try out.toOwnedSlice(allocator), .cursor_row = rows_above };
            try out.appendSlice(allocator, "\r\n");
            rows_above += 1;
        }
    }

    if (show_editor) {
        const shell_mode = isBangMode(editor.buf.items);
        if (th.mode != .none) {
            _ = try EditorState.appendRuleLine(&out, allocator, th, cols, shell_mode);
            try out.appendSlice(allocator, "\r\n");
            rows_above += 1;
        }
        if (shell_mode) {
            try th.paint(&out, allocator, theme.Theme.tool_ok, "! ");
        } else {
            try out.appendSlice(allocator, if (color) "\x1b[36m>\x1b[0m " else "> ");
        }
        const layout = computeLayout(editor.buf.items, editor.cursor, cols, 2);
        try appendSafeTerminalBytes(&out, allocator, editor.buf.items);
        var bottom_row = layout.end_row;
        var bottom_col = layout.end_col;
        if (th.mode != .none) {
            try out.appendSlice(allocator, "\r\n");
            bottom_col = try EditorState.appendRuleLine(&out, allocator, th, cols, shell_mode);
            bottom_row += 1;
        }
        for (footer_lines) |line| {
            if (line.len == 0) continue;
            try out.appendSlice(allocator, "\r\n");
            try out.appendSlice(allocator, line);
            bottom_row += 1;
            bottom_col = terminal.visibleWidth(line);
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
    bg_queue: *std.ArrayList([]u8),
    carried_draft: *?[]u8,
    use_sgr: bool,
    th: theme.Theme,
) !void {
    const orig_term = try enterRawMode(input_fd);
    defer terminal.setTermiosNow(input_fd, orig_term) catch {};

    defer output.writeStreamingAll(io, if (submit.fullscreen) mouse.disable ++ "\x1b[?2004l" else "\x1b[?2004l") catch {};
    try output.writeStreamingAll(io, if (submit.fullscreen) "\x1b[?2004h" ++ mouse.enable else "\x1b[?2004h");

    var done = try agent.model.Interrupt.init();
    defer done.deinit(io);

    var cols = terminalColumns(output);
    var last_size = terminalSize(output);
    var screen = LiveScreen.init(submit.allocator, io, output, use_sgr, th, submit.conversation_view);
    screen.overlay_cols = cols;
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
    errdefer screen.clearOverlay() catch {};
    try screen.loaderTickAndRender(&editor, followups.items, submit, cols, 0);
    var worker = WorkerState{ .submit = submit, .text = text, .done = &done };
    var thread = try std.Thread.spawn(.{}, WorkerState.run, .{&worker});
    var joined = false;
    errdefer if (!joined) {
        if (submit.trigger_cancel) |trig| trig(submit.context);
        thread.join();
    };

    var in_paste = false;
    var dirty = false;
    const wake = done.cancel();
    var last_tick_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();

    while (true) {
        if (done.isCanceled()) break;
        const current_size = terminalSize(output);
        const current_cols = @as(usize, current_size.col);
        if ((dirty or current_cols != cols or current_size.row != last_size.row) and !queue.hasBuffered()) {
            cols = current_cols;
            last_size = current_size;
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
                cols = terminalColumns(output);
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
            0x0f => {
                if (submit.toggle_expand) |toggle| {
                    _ = toggle(submit.context);
                    dirty = true;
                }
            },
            0x13 => {
                const trimmed = std.mem.trim(u8, editor.buf.items, " \t\r\n");
                if (trimmed.len > 0) {
                    if (submit.push_steering) |steer| {
                        try history.push(trimmed);
                        try steer(submit.context, trimmed);
                        try editor.replaceBuffer("");
                        editor.history_idx = null;
                        if (editor.draft) |d| {
                            submit.allocator.free(d);
                            editor.draft = null;
                        }
                        dirty = true;
                    }
                }
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
                    cols = terminalColumns(output);
                    if (try handleTab(&editor, io, submit, cols, use_sgr, false)) dirty = true;
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
                    } else if (submit.trigger_cancel) |trigger| {
                        trigger(submit.context);
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
                        if (!in_paste) if (final_byte) |fin| {
                            if (screen.handleScrollKey(fin, params)) {
                                dirty = true;
                                continue;
                            }
                        };
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

    if (submit.drain_steering) |drain| {
        const leftover = drain(submit.context, submit.allocator) catch &.{};
        if (leftover.len > 0) {
            errdefer {
                for (leftover) |item| submit.allocator.free(item);
                submit.allocator.free(leftover);
            }
            try followups.insertSlice(submit.allocator, 0, leftover);
            submit.allocator.free(leftover);
        }
    }

    if (worker.err) |err| {
        var msg: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
        try std.Io.File.stderr().writeStreamingAll(io, line);
        carried_draft.* = try buildCarriedDraft(submit.allocator, followups, editor.buf.items);
    } else {
        try collectBgNotifications(submit, io, output, bg_queue, false);
        if (editor.buf.items.len > 0) {
            carried_draft.* = try submit.allocator.dupe(u8, editor.buf.items);
        }
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

    const with_rules = try renderLiveOverlayFrame(a, &editor, &.{}, 20, true);
    defer a.free(with_rules.bytes);
    try std.testing.expect(std.mem.indexOf(u8, with_rules.bytes, "───────────────────") != null);
    try std.testing.expectEqual(@as(usize, 2), with_rules.cursor_row);

    try editor.replaceBuffer("");
    const loader = "Working...";
    const status = [_][]const u8{ "cwd/status", "provider/model" };
    const busy = try renderLiveOverlayFrameWithChrome(a, &editor, &.{}, 20, true, theme.Theme.init(.ansi16), loader, &status);
    defer a.free(busy.bytes);
    try std.testing.expect(std.mem.indexOf(u8, busy.bytes, "Working...\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, busy.bytes, "\x1b[36m>\x1b[0m ") != null);
    try std.testing.expect(std.mem.indexOf(u8, busy.bytes, "cwd/status\r\nprovider/model") != null);
    try std.testing.expectEqual(@as(usize, 2), busy.cursor_row);
    try std.testing.expect(std.mem.endsWith(u8, busy.bytes, "\x1b[3A\r\x1b[2C"));
}
