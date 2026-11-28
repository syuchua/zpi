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
    pub const text_selection = @import("tui/text_selection.zig");
    pub const markdown = @import("tui/components/markdown.zig");
    pub const message = @import("tui/components/message.zig");
    pub const tool_card = @import("tui/components/tool_card.zig");
    pub const chrome = @import("tui/components/chrome.zig");
    pub const select_list = @import("tui/components/select_list.zig");
    pub const dialog = @import("tui/components/dialog.zig");
    pub const autocomplete = @import("tui/components/autocomplete.zig");
    pub const search = @import("tui/components/search.zig");
    pub const conversation_view = @import("tui/components/conversation_view.zig");
};

const DialogKind = enum { help, hotkeys };

/// Terminal output for the prompt loop. In fullscreen mode every direct write
/// invalidates the retained row diff first, because the renderer can no longer
/// assume the screen still matches its last painted frame.
const ScreenIo = struct {
    io: std.Io,
    file: std.Io.File,
    painter: ?*renderer.FullscreenRenderer = null,

    fn invalidate(self: ScreenIo) void {
        if (self.painter) |painter| painter.invalidate();
    }

    fn write(self: ScreenIo, bytes: []const u8) !void {
        self.invalidate();
        try self.file.writeStreamingAll(self.io, bytes);
    }

    fn eraseSubmittedPromptLine(self: ScreenIo) !void {
        if (self.painter != null) return;
        try self.write("\x1b[1A\r\x1b[J");
    }

    fn writeStderr(self: ScreenIo, bytes: []const u8) !void {
        self.invalidate();
        try std.Io.File.stderr().writeStreamingAll(self.io, bytes);
    }
};

const InputQueue = terminal.InputQueue;
const mouse = @import("tui/mouse.zig");

fn writeTuiError(io: std.Io, text: []const u8, colored: bool) !void {
    const stderr = std.Io.File.stderr();
    if (colored and (stderr.isTty(io) catch false)) {
        var styled: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&styled, "\x1b[31m{s}\x1b[0m\n", .{text});
        try stderr.writeStreamingAll(io, line);
    } else {
        try stderr.writeStreamingAll(io, text);
        try stderr.writeStreamingAll(io, "\n");
    }
}

fn writeConversationText(io: std.Io, output: std.Io.File, view: ?*ConversationView, text: []const u8) !void {
    if (view) |conversation| return conversation.appendText(text);
    try output.writeStreamingAll(io, text);
}

fn reportTurnError(io: std.Io, view: ?*ConversationView, colored: bool, err: anyerror) !void {
    if (view) |conversation| {
        try conversation.appendText("\n");
        if (colored) try conversation.appendText("\x1b[31m");
        try conversation.appendText("zpi: ");
        try conversation.appendText(@errorName(err));
        if (colored) try conversation.appendText("\x1b[0m");
        try conversation.appendText("\n");
        return;
    }
    var line: [128]u8 = undefined;
    try writeTuiError(io, try std.fmt.bufPrint(&line, "zpi: {s}", .{@errorName(err)}), colored);
}

test {
    _ = mouse;
    _ = components.text_selection;
}

fn renderFullscreenConversation(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: std.Io.File,
    painter: *renderer.FullscreenRenderer,
    view: *ConversationView,
    editor: *const EditorState,
    loader: []const u8,
    dialog: []const []const u8,
    popup: []const []const u8,
    footer: []const []const u8,
    queued: []const []const u8,
    th: theme.Theme,
    search_line: ?[]const u8,
    search_query: ?[]const u8,
) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const size = terminalSize(output);
    const rows = @max(1, @as(usize, size.row));
    const width = @as(usize, size.col) -| 1;
    const pinned_user = view.pinnedUserForPage();
    const header_rows: usize = if (rows >= 6 and pinned_user != null) 3 else @intFromBool(rows >= 3);
    // Reserve the editor and a transcript row before budgeting optional chrome.
    const chrome_budget = rows -| (header_rows + 2);
    // Search and Jump to latest share a row below the transcript.
    const search_rows: usize = @intFromBool(search_line != null and chrome_budget > 0 and width > 0 and dialog.len == 0);
    const jump_latest_rows: usize = @intFromBool(search_rows == 0 and !view.isFollowing() and chrome_budget > 0 and popup.len == 0 and width > 0 and dialog.len == 0);
    if (size.row != view.frame_size.row or size.col != view.frame_size.col) view.clearCopiedNotice();
    if (view.copy_notice_until_ms != null) _ = view.expireCopiedNotice(std.Io.Timestamp.now(io, .awake).toMilliseconds());
    const reserved_below_body = jump_latest_rows + search_rows;
    const chrome_available = chrome_budget - reserved_below_body;
    // Keep room for the transcript and scrolling controls on short terminals.
    const footer_limit: usize = if (rows < 12) 2 else 4;
    const chrome_rows = @min(footer.len, @min(chrome_available, footer_limit));
    const loader_rows: usize = @intFromBool(rows >= 5 and chrome_available > chrome_rows);
    const extra_rows = chrome_available - chrome_rows - loader_rows;
    const rule_rows: usize = @intFromBool(rows >= 12 and width >= 4 and extra_rows > 0);
    const notice_label = "Copied";
    const show_notice = view.copy_notice_until_ms != null and width >= notice_label.len and dialog.len == 0;
    const notice_on_footer = show_notice and chrome_rows >= 3;
    const notice_on_rule = show_notice and !notice_on_footer and rule_rows > 0;
    const popup_budget = extra_rows - rule_rows;
    const popup_rows = @min(popup.len, popup_budget / 2);
    const queued_rows = @min(@min(queued.len, 4), popup_budget - popup_rows);
    const body_rows = rows -| (1 + header_rows + chrome_rows + loader_rows + popup_rows + queued_rows + rule_rows + reserved_below_body);
    view.body_height = @max(1, body_rows);
    view.pinned_hit_row = if (pinned_user) |user| user.row else null;
    view.pinned_header_rows = if (dialog.len == 0 and width > 0 and pinned_user != null) header_rows else 0;
    view.jump_latest_row = if (dialog.len == 0 and jump_latest_rows > 0 and width > 0) header_rows + body_rows + 1 else 0;
    try view.layoutTools(width);
    // Popup rows sit above the editor and its optional separator. Mouse rows are 1-based.
    view.popup_row = rows - chrome_rows - popup_rows - rule_rows;
    view.popup_rows = popup_rows;
    const hit_rows = try a.alloc(?components.text_selection.Row, rows);
    @memset(hit_rows, null);

    // Retained rows: one clipped row per terminal row. Blank rows are empty so an
    // unchanged blank line costs nothing to repaint.
    var rows_out: std.ArrayList([]const u8) = .empty;
    try rows_out.ensureTotalCapacity(a, rows);
    if (header_rows > 0) {
        if (pinned_user) |pinned| {
            var header: std.ArrayList(u8) = .empty;
            if (width >= 2) try header.appendSlice(a, "> ");
            _ = try terminal.appendClippedText(&header, a, pinned.text, width -| 2);
            if (header_rows == 3) try appendPinnedUserRow(&rows_out, a, th, "", width);
            try appendPinnedUserRow(&rows_out, a, th, header.items, width);
            if (header_rows == 3) try appendPinnedUserRow(&rows_out, a, th, "", width);
        } else try appendFullscreenRow(&rows_out, a, "Conversation · PgUp / PgDn / End", width);
    }

    var body: std.ArrayList(struct {
        text: []const u8,
        hit: components.text_selection.Row,
        kind: ?ConversationView.ToolRowKind,
    }) = .empty;
    if (dialog.len > 0) {
        // A dialog taller than the body is clipped; the padding range must use
        // the clamped count or it would underflow/overflow the row budget.
        const shown_dialog_rows = @min(dialog.len, body_rows);
        for (dialog[0..shown_dialog_rows]) |line| try appendFullscreenRow(&rows_out, a, line, width);
        for (shown_dialog_rows..body_rows) |_| try rows_out.append(a, "");
    } else {
        // Collect from the end so wrapping a long line cannot hide the newest output.
        var id = view.pageEnd();
        var pending = view.isFollowing() and view.pending.items.len > 0;
        while (body.items.len < body_rows and (pending or id > view.first_id)) {
            const line_id = if (pending) null else blk: {
                id -= 1;
                break :blk id;
            };
            pending = false;
            const text = if (line_id) |line| view.lineAt(line) orelse continue else view.pending.items;
            const tool_kind = if (line_id) |line| view.toolRowKind(line) else null;
            const row_limit = if (line_id) |line| view.toolBodyRowLimit(line) else null;
            const wrap_width = if (row_limit != null) ConversationView.toolBodyWidth(width) else @max(1, width);
            var wrapped = try terminal.wrapAnsiAlloc(a, text, wrap_width);
            if (row_limit) |limit| {
                if (limit != std.math.maxInt(usize)) {
                    var prefix = std.mem.splitScalar(u8, wrapped, '\n');
                    for (0..limit) |_| _ = prefix.next();
                    if (prefix.index) |next| wrapped = wrapped[0 .. next - 1];
                }
            }
            var lines = std.mem.splitBackwardsScalar(u8, wrapped, '\n');
            const tool_gutter = row_limit != null and width >= 3;
            var wrap_from_end: usize = 0;
            while (body.items.len < body_rows) : (wrap_from_end += 1) {
                const wrapped_line = lines.next() orelse break;
                var rendered = if (tool_gutter) blk: {
                    var tool_line: std.ArrayList(u8) = .empty;
                    try th.paint(&tool_line, a, theme.Theme.border, "│ ");
                    try tool_line.appendSlice(a, wrapped_line);
                    break :blk tool_line.items;
                } else wrapped_line;
                if (search_query) |query| if (query.len > 0 and line_id != null) {
                    if (view.search_hit_row == line_id.?) rendered = try components.search.highlightAlloc(a, th, rendered, query);
                };
                try body.append(a, .{
                    .text = rendered,
                    .hit = .{
                        .id = line_id,
                        .wrap_from_end = wrap_from_end,
                        .prefix = if (tool_gutter) 2 else 0,
                        .selectable = tool_kind != .hint,
                    },
                    .kind = tool_kind,
                });
            }
        }
        var index = body.items.len;
        while (index > 0) {
            index -= 1;
            var line = body.items[index];
            const row = rows_out.items.len;
            if (line.kind) |kind| {
                line.hit.width = try appendToolPanelRow(&rows_out, a, th, line.text, width, kind);
            } else {
                try appendFullscreenRow(&rows_out, a, line.text, width);
                line.hit.width = terminal.visibleWidth(rows_out.items[row]);
            }
            line.hit.fingerprint = std.hash.Wyhash.hash(0, rows_out.items[row]);
            hit_rows[row] = line.hit;
        }
        for (body.items.len..body_rows) |_| try rows_out.append(a, "");
    }
    if (view.mouse_gesture) |gesture| {
        if (size.row != view.frame_size.row or size.col != view.frame_size.col or
            !components.text_selection.Gesture.sameRows(view.hit_rows.items, hit_rows))
        {
            view.mouse_gesture = null;
        } else if (gesture.range()) |selection| {
            for (selection.first.row..selection.last.row + 1) |row| {
                const hit = hit_rows[row - 1] orelse continue;
                if (selection.columns(row, hit)) |cols| {
                    rows_out.items[row - 1] = try components.text_selection.highlightAlloc(a, rows_out.items[row - 1], cols);
                }
            }
        }
    }
    if (search_rows > 0) try appendFullscreenRow(&rows_out, a, search_line.?, width);
    if (search_rows == 0 and jump_latest_rows > 0 and width > 0) {
        var button: std.ArrayList(u8) = .empty;
        try th.paint(&button, a, theme.Theme.accent, "[↓ Jump to latest (End)]");
        try appendFullscreenRow(&rows_out, a, button.items, width);
    }
    if (loader_rows > 0) try appendFullscreenRow(&rows_out, a, loader, width);
    for (queued[0..queued_rows], 1..) |text, index| {
        var preview: std.ArrayList(u8) = .empty;
        try preview.print(a, "[queued {d}] ", .{index});
        _ = try terminal.appendClippedText(&preview, a, text, width -| preview.items.len);
        try appendFullscreenRow(&rows_out, a, preview.items, width);
    }
    for (popup[0..popup_rows]) |line| try appendFullscreenRow(&rows_out, a, line, width);
    if (rule_rows > 0) {
        var rule: std.ArrayList(u8) = .empty;
        _ = try EditorState.appendRuleLine(&rule, a, th, size.col, isBangMode(editor.buf.items));
        try rows_out.append(a, if (notice_on_rule) try copiedNoticeRow(a, th, rule.items, width, notice_label) else rule.items);
    }
    const editor_row = rows_out.items.len;

    const text = editor.buf.items;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..editor.cursor], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, text, editor.cursor, '\n') orelse text.len;
    const prefix_width: usize = if (width >= 3) 2 else 0;
    // Short screens can lack both rules. Leave enough room for the prompt,
    // the cursor, and the notice on the existing editor row.
    const notice_on_editor = show_notice and !notice_on_footer and !notice_on_rule and width >= prefix_width + notice_label.len + 2;
    const editor_width = if (notice_on_editor) width - notice_label.len - 1 else width;
    const cursor_budget = editor_width - prefix_width;
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
    var editor_line: std.ArrayList(u8) = .empty;
    if (prefix_width > 0) {
        if (isBangMode(text)) {
            try th.paint(&editor_line, a, theme.Theme.tool_ok, "! ");
        } else try th.paint(&editor_line, a, theme.Theme.accent, "> ");
    }
    _ = try terminal.appendClippedText(&editor_line, a, text[start..line_end], cursor_budget);
    try rows_out.append(a, if (notice_on_editor) try copiedNoticeRow(a, th, editor_line.items, width, notice_label) else editor_line.items);
    if (footer.len > 0) {
        const indices: []const usize = switch (chrome_rows) {
            4 => &.{ 0, 1, 2, 3 },
            3 => &.{ 1, 2, 3 },
            2 => &.{ 1, 2 },
            1 => &.{2},
            else => &.{},
        };
        for (indices) |index| {
            if (notice_on_footer and index == 3) {
                try rows_out.append(a, try copiedNoticeRow(a, th, footer[index], width, notice_label));
            } else try appendFullscreenRow(&rows_out, a, footer[index], width);
        }
    }
    // Diff against the retained frame so steady streaming only repaints edited
    // rows; the cursor is left on the editor row.
    try view.hit_rows.ensureTotalCapacity(view.allocator, hit_rows.len);
    try painter.render(io, output, rows_out.items, .{ .row = editor_row, .col = prefix_width + cursor_width }, size.col);
    view.hit_rows.clearRetainingCapacity();
    view.hit_rows.appendSliceAssumeCapacity(hit_rows);
    view.frame_size = size;
}

fn copiedNoticeRow(a: std.mem.Allocator, th: theme.Theme, base: []const u8, width: usize, label: []const u8) ![]const u8 {
    var row: std.ArrayList(u8) = .empty;
    const label_col = width - label.len;
    const used = try terminal.appendTruncatedAnsi(&row, a, base, label_col -| 1, "");
    try row.appendNTimes(a, ' ', label_col - used);
    try th.paint(&row, a, theme.Theme.tool_output, label);
    return row.items;
}

fn appendPinnedUserRow(rows_out: *std.ArrayList([]const u8), a: std.mem.Allocator, th: theme.Theme, text: []const u8, width: usize) !void {
    var row: std.ArrayList(u8) = .empty;
    try th.appendOpen(&row, a, theme.Theme.user_panel);
    try row.appendSlice(a, text);
    try row.appendNTimes(a, ' ', width -| terminal.visibleWidth(text));
    try th.appendClose(&row, a);
    try rows_out.append(a, row.items);
}

fn appendFullscreenRow(rows_out: *std.ArrayList([]const u8), a: std.mem.Allocator, line: []const u8, width: usize) !void {
    var row: std.ArrayList(u8) = .empty;
    _ = try terminal.appendTruncatedAnsi(&row, a, line, width, "");
    try rows_out.append(a, row.items);
}

fn appendToolPanelRow(rows_out: *std.ArrayList([]const u8), a: std.mem.Allocator, th: theme.Theme, text: []const u8, width: usize, kind: ConversationView.ToolRowKind) !usize {
    var clipped: std.ArrayList(u8) = .empty;
    defer clipped.deinit(a);
    _ = try terminal.appendTruncatedAnsi(&clipped, a, text, width, "");
    var row: std.ArrayList(u8) = .empty;
    try th.appendOpen(&row, a, theme.Theme.tool_panel);
    if (kind == .hint) try th.appendOpen(&row, a, theme.Theme.tool_hint);
    if (kind == .output_title) try th.appendOpen(&row, a, theme.Theme.tool_output);
    var pos: usize = 0;
    while (pos < clipped.items.len) {
        if (clipped.items[pos] == '\x1b') {
            const end = terminal.skipEscapeSequence(clipped.items, pos);
            const seq = clipped.items[pos..end];
            try row.appendSlice(a, seq);
            if (std.mem.eql(u8, seq, "\x1b[0m") or std.mem.eql(u8, seq, "\x1b[m")) try th.appendOpen(&row, a, theme.Theme.tool_panel);
            pos = end;
        } else {
            try row.append(a, clipped.items[pos]);
            pos += 1;
        }
    }
    const content_width = terminal.visibleWidth(clipped.items);
    try row.appendNTimes(a, ' ', width -| content_width);
    try th.appendClose(&row, a);
    try rows_out.append(a, row.items);
    return content_width;
}

fn mouseMatchesFrame(view: *const ConversationView, current: std.posix.winsize, event: mouse.Event) bool {
    return current.row == view.frame_size.row and current.col == view.frame_size.col and
        event.row <= current.row and event.col <= current.col;
}

const TranscriptMouse = union(enum) { other, handled, copy: []u8 };

/// Handle selection against the last painted frame. Return owned bytes so the
/// caller can invoke the clipboard helper outside the live screen mutex.
fn handleTranscriptMouse(view: *ConversationView, painter: *renderer.FullscreenRenderer, size: std.posix.winsize, event: mouse.Event, allocator: std.mem.Allocator) !TranscriptMouse {
    if (painter.paintedRows() != view.hit_rows.items.len or painter.needsFullPaint() or !mouseMatchesFrame(view, size, event)) {
        view.mouse_gesture = null;
        return .handled;
    }
    const point: components.text_selection.Point = .{ .row = event.row, .col = event.col };
    switch (event.kind) {
        .left => {
            view.clearCopiedNotice();
            if (event.row == 0 or event.row > view.hit_rows.items.len) return .other;
            view.mouse_gesture = null;
            const hit = view.hit_rows.items[event.row - 1] orelse return .other;
            const on_text = hit.selectable and event.col > hit.prefix and event.col <= hit.width;
            if (!on_text and view.toolAtRow(event.row) == null) return .other;
            view.mouse_gesture = .{ .anchor = point, .focus = point, .selectable = on_text };
        },
        .left_motion => {
            if (view.mouse_gesture) |*gesture| {
                gesture.move(point);
            } else return .other;
        },
        .left_release => {
            var gesture = view.mouse_gesture orelse return .handled;
            view.mouse_gesture = null;
            gesture.move(point);
            if (!gesture.moved) {
                if (view.toolAtRow(event.row)) |id| try view.toggleToolExpanded(id);
            } else if (gesture.range()) |selection| {
                if (try selection.copyAlloc(allocator, view.hit_rows.items, painter.rows.items)) |text| return .{ .copy = text };
            }
        },
        .wheel_up, .wheel_down => {
            view.mouse_gesture = null;
            return .other;
        },
        .ignored => {},
    }
    return .handled;
}

fn copyTextSelection(submit: Submit, screen: ScreenIo, text: []u8) !bool {
    defer submit.allocator.free(text);
    const copy = submit.copy_selection orelse {
        try screen.writeStderr("zpi: clipboard is unavailable\n");
        return false;
    };
    copy(submit.context, text) catch |err| {
        try screen.writeStderr(switch (err) {
            error.ClipboardUnavailable => "zpi: clipboard unavailable. Check pbcopy (macOS) or wl-copy / xclip (Linux).\n",
            error.ClipboardTimeout => "zpi: clipboard helper timed out\n",
            error.InvalidClipboardPayload => "zpi: selected text is too large or is not valid UTF-8\n",
            else => "zpi: failed to copy selection to clipboard\n",
        });
        return false;
    };
    return true;
}

/// Return whether canceling a gesture requires repainting its highlight.
fn cancelTranscriptGesture(view: ?*ConversationView) bool {
    const conversation = view orelse return false;
    if (conversation.mouse_gesture == null) return false;
    conversation.clearMouseGesture();
    return true;
}

fn navigateWithMouse(view: *ConversationView, event: mouse.Event) bool {
    switch (event.kind) {
        .wheel_up => view.scrollUp(3),
        .wheel_down => view.scrollDown(3),
        .left_motion, .left_release => return false,
        .left => {
            if (view.jump_latest_row > 0 and event.row == view.jump_latest_row) {
                view.followLatest();
            } else if (view.pinned_header_rows > 0 and event.row <= view.pinned_header_rows) {
                view.jumpToUserRow(view.pinned_hit_row orelse return false);
            } else return false;
        },
        .ignored => return false,
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
    write_tool_text: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,
    write_tool_body: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,
    approve_once: ?*const fn (*anyopaque, agent.security.Request, ?agent.model.Cancel) anyerror!agent.security.ApprovalOutcome = null,
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
    new_session: ?*const fn (*anyopaque) anyerror!void = null,
    session_info: ?*const fn (*anyopaque) anyerror!void = null,
    cost_info: ?*const fn (*anyopaque) anyerror!void = null,
    context_info: ?*const fn (*anyopaque) anyerror!void = null,
    copy_last_reply: ?*const fn (*anyopaque) anyerror!void = null,
    copy_selection: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
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
    render_saved_session_on_exit: ?*const fn (*anyopaque) anyerror!void = null,
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
    tool_outputs_expanded: bool = false,
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

fn copyLastReply(submit: Submit, screen: ScreenIo) !void {
    const copy_reply = submit.copy_last_reply orelse return screen.writeStderr("zpi: clipboard is unavailable\n");
    copy_reply(submit.context) catch |err| return screen.writeStderr(switch (err) {
        error.NoAssistantReply => "zpi: no assistant reply to copy yet\n",
        error.ClipboardUnavailable => "zpi: clipboard unavailable. Check pbcopy (macOS) or install wl-copy / xclip and check your display session (Linux).\n",
        error.ClipboardTimeout => "zpi: clipboard helper timed out. Check your display session and try again.\n",
        error.InvalidClipboardPayload => "zpi: reply is too large or is not valid UTF-8\n",
        else => "zpi: copy failed. Check your clipboard helper and display session.\n",
    });
    try screen.writeStderr("Copied last assistant reply to clipboard.\n");
}

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

fn renderStartupBanner(io: std.Io, output: std.Io.File, submit: Submit, th: theme.Theme, view: ?*ConversationView) !usize {
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

    if (view) |conversation| {
        try conversation.appendText(out.items);
    } else {
        try output.writeStreamingAll(io, out.items);
    }
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

pub fn run(io: std.Io, options: Submit) !void {
    var submit = options;
    const input = std.Io.File.stdin();
    const output = std.Io.File.stdout();
    if (!try input.isTty(io) or !try output.isTty(io)) return error.InteractiveTtyRequired;
    const color = try output.supportsAnsiEscapeCodes(io);
    const th = theme.Theme.init(submit.color_mode orelse if (color) .ansi16 else .none);
    const use_sgr = color and th.mode != .none;
    if (!color or submit.set_live_writer == null) submit.fullscreen = false;
    var fullscreen_view = ConversationView.init(submit.allocator);
    defer fullscreen_view.deinit();
    if (submit.fullscreen) submit.conversation_view = &fullscreen_view;
    var alternate_screen = false;
    defer if (alternate_screen) output.writeStreamingAll(io, mouse.disable ++ "\x1b[?2004l\x1b[?1049l") catch {};
    var painter = renderer.FullscreenRenderer.init(submit.allocator, use_sgr);
    defer painter.deinit();
    if (submit.fullscreen) {
        fullscreen_view.tools_expanded = submit.tool_outputs_expanded;
        alternate_screen = true;
        try output.writeStreamingAll(io, "\x1b[?1049h");
    }
    // In fullscreen the retained row diff owns stdout. Every direct terminal
    // write below goes through `tc` so it invalidates the retained frame first.
    const tc = ScreenIo{ .io = io, .file = output, .painter = if (submit.fullscreen) &painter else null };
    var header_lines: usize = 0;
    if (!submit.quiet_startup and !submit.fullscreen) {
        header_lines = try renderStartupBanner(io, output, submit, th, null);
    }
    const had_initial_history = if (submit.fullscreen) blk: {
        if (submit.render_fullscreen_history) |render_history| break :blk try render_history(submit.context, &fullscreen_view);
        break :blk false;
    } else if (submit.render_initial_history) |render_init| try render_init(submit.context) else false;
    if (submit.fullscreen and !submit.quiet_startup) {
        // Include startup information in the first viewport even when restored history fills it.
        _ = try renderStartupBanner(io, output, submit, th, &fullscreen_view);
    }
    if (!submit.fullscreen and !had_initial_history and !submit.quiet_startup and th.mode != .none) {
        const sz = terminalSize(output);
        const editor_chrome_rows: usize = 6;
        if (sz.row > header_lines + editor_chrome_rows) {
            const pad = @min(@as(usize, sz.row) - header_lines - editor_chrome_rows, 80);
            var pad_buf: [80]u8 = undefined;
            @memset(pad_buf[0..pad], '\n');
            try tc.write(pad_buf[0..pad]);
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
    // `/search` arms the next prompt read to start in transcript search mode.
    var pending_search = false;

    while (true) {
        if (submit.reset_cancel) |reset| reset(submit.context);
        if (followups.items.len == 0 and bg_queue.items.len == 0) {
            try collectBgNotifications(submit, io, tc.file, &bg_queue, false);
        }
        var is_bg_wakeup = false;
        const raw = if (followups.items.len > 0) blk: {
            pending_dialog = null;
            const next = followups.orderedRemove(0);
            const echo = try components.message.formatUserEchoAlloc(submit.allocator, th, next, terminalColumns(tc.file));
            defer submit.allocator.free(echo);
            if (submit.conversation_view) |view| {
                try view.appendUserMessage(next, echo, if (th.mode == .none or terminalColumns(tc.file) < 5) 0 else 1);
                try view.appendText("\n");
            } else {
                try tc.write(echo);
                try tc.write("\n");
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
                try tc.write(prompt_prefix);
            }
            const start_search = pending_search;
            pending_search = false;
            const res = readPromptLine(submit.allocator, io, input.handle, tc.file, &queue, &history, submit, &bg_queue, use_sgr, color, th, initial, dlg, tc.painter, start_search) catch |err| switch (err) {
                error.Canceled => {
                    try tc.write("\n");
                    continue;
                },
                error.StreamTooLong => {
                    try tc.writeStderr("zpi: prompt exceeds 64 KiB; discarded\n");
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
            if (std.mem.eql(u8, text, "/new")) {
                try tc.eraseSubmittedPromptLine();
                if (submit.new_session) |new_session| {
                    new_session(submit.context) catch |err| try reportTurnError(io, submit.conversation_view, use_sgr, err);
                } else try tc.writeStderr("zpi: /new unavailable\n");
                continue;
            }
            if (std.mem.eql(u8, text, "/exit") or std.mem.eql(u8, text, "/quit")) {
                const saved_output = alternate_screen and submit.render_saved_session_on_exit != null;
                if (saved_output) {
                    try tc.write(mouse.disable ++ "\x1b[?2004l\x1b[?1049l");
                    alternate_screen = false;
                }
                if (submit.render_saved_session_on_exit) |render| try render(submit.context);
                return;
            }
            try history.push(text);
        }
        if (!is_bg_wakeup and isBangMode(text) and submit.run_user_shell != null) {
            const excluded = std.mem.startsWith(u8, text, "!!");
            const prefix_len: usize = if (excluded) 2 else 1;
            const command = std.mem.trim(u8, text[prefix_len..], " \t");
            if (command.len == 0) {
                try tc.write("Usage: !<command> runs with context; !!<command> runs without context.\n");
                continue;
            }
            var shell_prompt: std.ArrayList(u8) = .empty;
            defer shell_prompt.deinit(submit.allocator);
            try shell_prompt.appendSlice(submit.allocator, if (excluded) "!! " else "! ");
            try shell_prompt.appendSlice(submit.allocator, command);
            const panel = try components.message.formatUserEchoAlloc(submit.allocator, th, shell_prompt.items, terminalColumns(tc.file));
            defer submit.allocator.free(panel);
            const view = submit.conversation_view;
            if (view) |conversation| {
                try conversation.appendUserMessage(shell_prompt.items, panel, if (th.mode == .none or terminalColumns(tc.file) < 5) 0 else 1);
            } else try writeConversationText(tc.io, tc.file, view, panel);
            try writeConversationText(tc.io, tc.file, view, "\n");
            var scratch = std.heap.ArenaAllocator.init(submit.allocator);
            defer scratch.deinit();
            const result = runLocalShell(io, input.handle, &queue, submit, scratch.allocator(), command) catch |err| {
                var error_buf: [160]u8 = undefined;
                const line = std.fmt.bufPrint(&error_buf, "Shell command failed: {s}\n", .{@errorName(err)}) catch "Shell command failed.\n";
                try writeConversationText(io, .stderr(), view, line);
                continue;
            };
            const safe_output = try terminal.safeUtf8Alloc(scratch.allocator(), result.text);
            const preview = try components.tool_card.formatBodyPreviewAlloc(submit.allocator, th, safe_output, ConversationView.compact_tool_rows, terminalColumns(tc.file));
            defer submit.allocator.free(preview.text);
            try writeConversationText(tc.io, tc.file, view, preview.text);
            if (preview.truncated) try writeConversationText(tc.io, tc.file, view, "│ ... (local preview truncated)\n");
            try writeConversationText(tc.io, tc.file, view, if (result.is_error) "[command failed]\n" else "[command complete]\n");
            if (excluded) {
                try writeConversationText(tc.io, tc.file, view, "[command output excluded from agent context]\n");
                continue;
            }
            const context_text = try submit.allocator.print("User ran shell command: {s}\nExit outcome and output:\n{s}", .{ command, safe_output });
            defer submit.allocator.free(context_text);
            if (submit.record_user_shell) |record| try record(submit.context, context_text);
            try writeConversationText(tc.io, tc.file, view, "[output added to conversation context]\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/search")) {
            if (!submit.fullscreen or submit.conversation_view == null) {
                try output.writeStreamingAll(io, "/search needs the fullscreen interface (--tui-mode fullscreen).\n");
                continue;
            }
            try tc.eraseSubmittedPromptLine();
            pending_search = true;
            continue;
        }
        if (std.mem.eql(u8, text, "/help")) {
            if (color) {
                try tc.eraseSubmittedPromptLine();
                pending_dialog = .help;
            } else {
                try tc.write("Enter a task to stream a response and run tools. /exit leaves the session.\nUse --session PATH to reopen; add --branch ENTRY-ID to continue from an earlier point.\nTab completes /commands and @paths; Up/Down navigates history; Alt+Enter or trailing \\ adds a newline.\nFullscreen: Ctrl-F or Esc on an empty prompt searches the transcript (/search).\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/hotkeys")) {
            if (color) {
                try tc.eraseSubmittedPromptLine();
                pending_dialog = .hotkeys;
            } else {
                try tc.write("Keyboard shortcuts\nEnter     Submit prompt (or queue follow-up while busy)\nCtrl-C    Cancel current turn or clear prompt\nCtrl-D    Exit on empty line / delete char\nUp/Down   Navigate history or lines\nLeft/Right Move cursor (Ctrl-A/E home/end)\nCtrl-W/U/K Delete word / to start / to end\nTab       Complete /command or @path\nAlt+Enter Insert newline (or trailing \\)\nAlt+Up    Edit queued follow-up messages\nCtrl-F    Search transcript (/search, or Esc on an empty prompt)\nCtrl-P/N  Previous/next user message (Alt+Up/Alt+Down)\nEsc       Clear draft while busy / cancel selector / open search when empty\n/model    Fuzzy model picker (or /model [provider/id] | --list)\n/thinking Show or set thinking level (/thinking [off|minimal|low|medium|high|xhigh|max])\n/tree     Branch picker (/ filter, p prefill user msg, s summarize, Enter switch)\n/new      Start a fresh session\n/compact  Summarize older context (/compact [focus])\n/exit     Exit (/quit)\n/help     Show help\n/search   Search the fullscreen transcript (Ctrl-F)\n/session  Show current session summary\n/hotkeys  Show shortcuts\n");
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
                    tc.invalidate();
                    try tc.eraseSubmittedPromptLine();
                    var src = (submit.model_source.?(submit.context) catch |err| {
                        var msg: [256]u8 = undefined;
                        const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                        try tc.writeStderr(line);
                        continue;
                    }) orelse break :blk "";
                    defer src.deinit(src.context);
                    const picked = selectModel(submit.allocator, io, input.handle, tc.file, &queue, submit.cancel, src, th) catch |err| switch (err) {
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
                    try tc.writeStderr(line);
                };
            } else {
                try tc.writeStderr("zpi: /model unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/thinking") or std.mem.startsWith(u8, text, "/thinking ")) {
            const arg = if (text.len > "/thinking".len) std.mem.trim(u8, text["/thinking".len..], " \t") else "";
            if (submit.set_thinking) |run_thinking| {
                run_thinking(submit.context, arg) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try tc.writeStderr(line);
                };
            } else {
                try tc.writeStderr("zpi: /thinking unavailable\n");
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
                    tc.invalidate();
                    try tc.eraseSubmittedPromptLine();
                    const tree = submit.tree_source.?(submit.context);
                    const choice = selectTree(io, input.handle, tc.file, &queue, submit, tree, th) catch |err| switch (err) {
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
                        try tc.writeStderr(line);
                        continue;
                    };
                }
                if (prefill_text) |pf| {
                    if (carried_draft) |old| submit.allocator.free(old);
                    carried_draft = try submit.allocator.dupe(u8, pf);
                }
            } else {
                try tc.writeStderr("zpi: /tree unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/compact") or std.mem.startsWith(u8, text, "/compact ")) {
            const focus = if (text.len > "/compact".len) std.mem.trim(u8, text["/compact".len..], " \t") else "";
            if (submit.compact) |run_compact| {
                if (color and submit.set_live_writer != null) {
                    try runTurnWithLiveEditor(io, input.handle, tc.file, &queue, &history, submit, run_compact, focus, .compacting, &followups, &bg_queue, &carried_draft, use_sgr, th, tc.painter);
                    continue;
                }
                run_compact(submit.context, focus) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try tc.writeStderr(line);
                };
            } else {
                try tc.writeStderr("zpi: compaction unavailable\n");
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/copy")) {
            try copyLastReply(submit, tc);
            continue;
        }
        if (std.mem.eql(u8, text, "/session")) {
            if (submit.session_info) |show| {
                tc.invalidate();
                try show(submit.context);
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/cost")) {
            if (submit.cost_info) |show| {
                tc.invalidate();
                try show(submit.context);
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/context")) {
            if (submit.context_info) |show| {
                tc.invalidate();
                try show(submit.context);
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/jobs") or std.mem.startsWith(u8, text, "/jobs ")) {
            const arg = if (text.len > "/jobs".len) std.mem.trim(u8, text["/jobs".len..], " \t") else "";
            if (submit.jobs_info) |show_jobs| {
                tc.invalidate();
                show_jobs(submit.context, arg) catch |err| {
                    var msg: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                    try tc.writeStderr(line);
                };
            } else {
                try tc.writeStderr("zpi: /jobs unavailable\n");
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
                    tc.invalidate();
                    try tc.eraseSubmittedPromptLine();
                    var src = (submit.session_source.?(submit.context) catch |err| {
                        var msg: [256]u8 = undefined;
                        const line = try std.fmt.bufPrint(&msg, "zpi: {s}\n", .{@errorName(err)});
                        try tc.writeStderr(line);
                        continue;
                    }) orelse break :blk "";
                    defer src.deinit(src.context);
                    const picked = selectSession(submit.allocator, io, input.handle, tc.file, &queue, submit.cancel, src, th) catch |err| switch (err) {
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
                    try tc.writeStderr(line);
                };
            } else {
                try tc.writeStderr("zpi: /resume unavailable\n");
            }
            continue;
        }
        if (color and submit.set_live_writer != null) {
            try runTurnWithLiveEditor(io, input.handle, tc.file, &queue, &history, submit, submit.run, text, .streaming, &followups, &bg_queue, &carried_draft, use_sgr, th, tc.painter);
        } else {
            submit.run(submit.context, text) catch |err| try reportTurnError(io, submit.conversation_view, use_sgr, err);
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
        if (show_rules and footer_lines.len != 4) {
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

const builtin_commands = [_][]const u8{ "/help", "/hotkeys", "/search", "/copy", "/session", "/cost", "/context", "/new", "/resume", "/tree", "/model", "/thinking", "/compact", "/exit", "/quit" };

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

/// Fullscreen-only prompt navigation: walk marked user messages backward or
/// forward without touching the draft, queue, steering or active turn.
fn navigatePromptHistory(view: *ConversationView, forward: bool) bool {
    return if (forward) view.jumpToNextUserMessage() else view.jumpToPreviousUserMessage();
}

/// Prompt navigation only takes over an empty, unmodified draft so typed text,
/// shell mode and completion hints keep their normal editing keys.
fn promptHistoryIdle(editor: *const EditorState) bool {
    return editor.buf.items.len == 0 and editor.completion_hint == null and editor.history_idx == null;
}

const SearchKeyResult = enum { none, refresh, cancel, submit };

/// Capture the current page so Esc can restore exactly the same viewport, then
/// return to the live tail so the first match search starts from new output too.
fn beginSearch(state: *components.search.SearchState, view: *ConversationView, popup: *components.autocomplete.Popup) !void {
    state.clear();
    state.capturePage(view);
    view.search_hit_row = null;
    popup.clear();
}

fn searchRefresh(state: *components.search.SearchState, view: *ConversationView) !void {
    try view.collectMatches(state.query.items, &state.matches);
    if (state.matches.items.len == 0) {
        state.cursor = 0;
        view.search_hit_row = null;
        return;
    }
    // Keep the previous focused row when it is still a match.
    if (view.search_hit_row) |hit| {
        for (state.matches.items, 0..) |row, index| {
            if (row == hit) {
                state.cursor = index;
                _ = view.jumpToSearchRow(row);
                return;
            }
        }
    }
    state.cursor = state.matches.items.len - 1;
    _ = view.jumpToSearchRow(state.matches.items[state.cursor]);
}

/// Focus the next (delta > 0) or previous match, wrapping at both ends.
fn searchStep(state: *components.search.SearchState, view: *ConversationView, forward: bool) void {
    const total = state.matches.items.len;
    if (total == 0) return;
    state.cursor = if (forward) (state.cursor + 1) % total else if (state.cursor == 0) total - 1 else state.cursor - 1;
    if (!view.jumpToSearchRow(state.matches.items[state.cursor])) {
        // The focused row was evicted between frames; rebuild from scratch.
        view.collectMatches(state.query.items, &state.matches) catch return;
        if (state.matches.items.len == 0) return;
        if (state.cursor >= state.matches.items.len) state.cursor = state.matches.items.len - 1;
        _ = view.jumpToSearchRow(state.matches.items[state.cursor]);
    }
}

/// Bounded incremental search input. Returns the loop action so the caller can
/// restore the viewport and exit search mode.
fn handleSearchKey(
    state: *components.search.SearchState,
    view: *ConversationView,
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    submit: Submit,
    first: u8,
    painter: *renderer.FullscreenRenderer,
) !SearchKeyResult {
    var bytes: [4]u8 = undefined;
    var len: usize = 1;
    bytes[0] = first;
    switch (first) {
        0x03 => return .cancel,
        0x07 => return .cancel,
        '\r', '\n' => return .submit,
        0x7f, 0x08 => {
            if (state.popByte()) try searchRefresh(state, view);
            return .refresh;
        },
        0x0e => { // Ctrl-N and Down: next match
            searchStep(state, view, true);
            return .refresh;
        },
        0x10 => { // Ctrl-P and Up: previous match
            searchStep(state, view, false);
            return .refresh;
        },
        0x1b => {},
        else => {},
    }
    if (first == 0x1b) {
        const next = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse return .cancel;
        if (next != '[') view.clearMouseGesture();
        switch (next) {
            // Esc Esc also cancels; the first Esc already restored the page.
            '\x1b' => return .cancel,
            'A' => {
                searchStep(state, view, false);
                return .refresh;
            },
            'B' => {
                searchStep(state, view, true);
                return .refresh;
            },
            'O' => {
                const code = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse return .none;
                switch (code) {
                    'A' => searchStep(state, view, false),
                    'B' => searchStep(state, view, true),
                    else => return .none,
                }
                return .refresh;
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
                if (final_byte) |fin| {
                    if (mouse.Event.parse(fin, seq[0..slen])) |event| {
                        switch (try handleTranscriptMouse(view, painter, terminalSize(output), event, submit.allocator)) {
                            .other => _ = navigateWithMouse(view, event),
                            .handled => {},
                            .copy => |text| if (try copyTextSelection(submit, .{ .io = io, .file = output, .painter = painter }, text)) view.showCopiedNotice(std.Io.Timestamp.now(io, .awake).toMilliseconds()),
                        }
                        return .refresh;
                    }
                    switch (fin) {
                        'A' => searchStep(state, view, false),
                        'B' => searchStep(state, view, true),
                        else => {},
                    }
                }
                view.clearMouseGesture();
                return .refresh;
            },
            // Alt+<printable> and Alt+Enter are not part of the query.
            else => return .none,
        }
    }
    if (first >= 0x20 and first < 0x7f) {
        if (!state.pushByte(first)) return .none;
    } else if (first >= 0xc2 and first <= 0xf4) {
        const expected_len = std.unicode.utf8ByteSequenceLength(first) catch return .none;
        for (1..expected_len) |idx| {
            const follow = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse return .none;
            if ((follow & 0xc0) != 0x80) return .none;
            bytes[idx] = follow;
        }
        len = expected_len;
        if (!std.unicode.utf8ValidateSlice(bytes[0..len])) return .none;
        if (!state.pushSlice(bytes[0..len])) return .none;
    } else return .none;
    try searchRefresh(state, view);
    return .refresh;
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
        if (!silent or submit.conversation_view != null) {
            var line_buf: [256]u8 = undefined;
            const notice = std.fmt.bufPrint(&line_buf, "[bg {s}: {s}]\n", .{ n.status, n.task_name }) catch "[bg task updated]\n";
            const safe = try terminal.safeUtf8Alloc(submit.allocator, notice);
            defer submit.allocator.free(safe);
            try writeConversationText(io, output, submit.conversation_view, safe);
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
    painter: ?*renderer.FullscreenRenderer,
    start_search: bool,
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
    var search = components.search.SearchState.init(allocator);
    defer search.deinit();
    var search_active = false;
    defer if (submit.conversation_view) |view| {
        view.mouse_gesture = null;
    };

    const has_footer = (submit.fullscreen or th.mode != .none) and submit.status_info != null;
    var dialog = initial_dialog;
    var dialog_on_screen = false;
    var in_paste = false;
    var skip_popup_refresh = false;
    var cols = terminalColumns(output);
    var last_size = terminalSize(output);
    var dirty = has_footer or dialog != null or submit.fullscreen;
    if (initial) |text| {
        if (text.len > 0) {
            try editor.insertSlice(text);
            dirty = true;
        }
    }
    // `/search` enters search on the next prompt read without redrawing first.
    if (start_search and submit.fullscreen and submit.conversation_view != null and editor.buf.items.len == 0 and dialog == null) {
        try beginSearch(&search, submit.conversation_view.?, &popup);
        popup.clear();
        search_active = true;
        dirty = true;
    }

    while (true) {
        if ((dirty and !queue.hasBuffered()) or (dialog != null and !dialog_on_screen)) {
            cols = terminalColumns(output);
            if (th.mode != .none and !in_paste) {
                if (!skip_popup_refresh) try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
            } else {
                popup.clear();
            }
            skip_popup_refresh = false;

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

            var footer_buf: ?[4][]u8 = null;
            if (has_footer) {
                var info = submit.status_info.?(submit.context);
                info.queued_count = 0;
                footer_buf = try components.chrome.Footer.renderFramedLinesAlloc(allocator, th, info, @max(1, cols -| 1), null);
            }
            defer if (footer_buf) |fb| {
                for (fb) |line| allocator.free(line);
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
                const search_line: ?[]u8 = if (search_active) try components.search.promptLineAlloc(allocator, th, &search, cols) else null;
                defer if (search_line) |line| allocator.free(line);
                try renderFullscreenConversation(allocator, io, output, painter.?, submit.conversation_view.?, &editor, "", dialog_slices, popup_slices, footer_slices, &.{}, th, search_line, if (search_active and search.query.items.len > 0) search.query.items else null);
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
                        _ = cancelTranscriptGesture(submit.conversation_view);
                        dirty = true;
                    }
                    const bg_ready = if (submit.bg_wake) |wake| wake.isCanceled() else false;
                    if (submit.conversation_view) |view| {
                        if (view.expireCopiedNotice(std.Io.Timestamp.now(io, .awake).toMilliseconds())) dirty = true;
                    }
                    if (!bg_ready) continue;
                }
                try collectBgNotifications(submit, io, output, bg_queue, true);
                if (bg_queue.items.len > 0 and editor.buf.items.len == 0 and dialog == null and !popup.isOpen()) {
                    if (!submit.fullscreen) try editor.clearAll(io, output, th);
                    try writeConversationText(io, output, submit.conversation_view, "[bg task completed]\n");
                    return .{ .text = bg_queue.orderedRemove(0), .is_bg_wakeup = true };
                }
                dirty = true;
                continue;
            }
            popup.clear();
            if (!submit.fullscreen and (dialog_on_screen or editor.completion_hint != null or th.mode != .none)) {
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

        if (b != 0x1b) dirty = cancelTranscriptGesture(submit.conversation_view) or dirty;
        skip_popup_refresh = false;
        if (search_active) {
            const result = try handleSearchKey(
                &search,
                submit.conversation_view orelse return error.SearchRequiresFullscreen,
                io,
                input_fd,
                output,
                @constCast(queue),
                submit,
                b,
                painter.?,
            );
            switch (result) {
                .cancel => {
                    submit.conversation_view.?.mouse_gesture = null;
                    search.restorePage(submit.conversation_view.?);
                    search.clear();
                    search_active = false;
                },
                .submit => {
                    // Keep the focused match and query visible, but return to
                    // the normal editor so the draft can be submitted.
                    if (search.count() == 0) search.restorePage(submit.conversation_view.?);
                    search_active = false;
                },
                .refresh, .none => {},
            }
            dirty = true;
            continue;
        }
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
                if (!submit.fullscreen and (dialog_on_screen or editor.completion_hint != null or th.mode != .none)) {
                    editor.resetCompletionTrack();
                    editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, &.{}, false, false) catch {};
                    dialog_on_screen = false;
                }
                return error.Canceled;
            },
            0x04 => {
                if (editor.buf.items.len == 0) {
                    popup.clear();
                    if (!submit.fullscreen and (dialog_on_screen or editor.completion_hint != null or th.mode != .none)) {
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
                        try view.appendUserMessage(submitted, echo, if (th.mode == .none or terminalColumns(output) < 5) 0 else 1);
                        try view.appendText("\n");
                    } else {
                        try output.writeStreamingAll(io, echo);
                        try output.writeStreamingAll(io, "\n");
                    }
                    return .{ .text = try editor.buf.toOwnedSlice(allocator) };
                }
                // The retained renderer owns the fullscreen editor and its footer.
                if (submit.fullscreen) return .{ .text = try editor.buf.toOwnedSlice(allocator) };
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
            0x18 => {
                if (!in_paste) {
                    try copyLastReply(submit, .{ .io = io, .file = output, .painter = painter });
                    dirty = true;
                }
            },
            0x06 => {
                if (submit.fullscreen and submit.conversation_view != null and !in_paste and
                    editor.buf.items.len == 0 and dialog == null and !popup.isOpen() and !search_active)
                {
                    try beginSearch(&search, submit.conversation_view.?, &popup);
                    popup.clear();
                    search_active = true;
                    dirty = true;
                    continue;
                }
                editor.moveRight();
                dirty = true;
            },
            0x10 => {
                if (th.mode != .none and !in_paste and dirty) {
                    try popup.refresh(io, editor.buf.items, editor.cursor, submit.commands, submit.cwd);
                }
                if (popup.isOpen()) {
                    popup.moveUp();
                } else if (submit.fullscreen and promptHistoryIdle(&editor) and if (submit.conversation_view) |view| navigatePromptHistory(view, false) else false) {
                    // Ctrl-P on an empty prompt jumps to the previous user message.
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
                } else if (submit.fullscreen and promptHistoryIdle(&editor) and if (submit.conversation_view) |view| navigatePromptHistory(view, true) else false) {
                    // Ctrl-N on an empty prompt jumps to the next user message.
                } else {
                    try editor.moveDownLineOrHistory(history);
                }
                dirty = true;
            },
            0x0f => {
                if (submit.toggle_expand) |toggle| {
                    const expanded = toggle(submit.context);
                    if (submit.conversation_view) |view| view.setToolsExpanded(expanded);
                    skip_popup_refresh = !dirty;
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
                    dirty = cancelTranscriptGesture(submit.conversation_view) or dirty;
                    // Esc opens search on an empty prompt. A draft, dialog,
                    // popup or completion hint keeps its usual Escape behavior.
                    if (submit.fullscreen and submit.conversation_view != null and !in_paste and
                        editor.buf.items.len == 0 and dialog == null and !popup.isOpen() and
                        editor.completion_hint == null)
                    {
                        try beginSearch(&search, submit.conversation_view.?, &popup);
                        popup.clear();
                        search_active = true;
                        dirty = true;
                        continue;
                    }
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
                if (next != '[') dirty = cancelTranscriptGesture(submit.conversation_view) or dirty;
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
                                switch (try handleTranscriptMouse(view, painter.?, terminalSize(output), event, submit.allocator)) {
                                    .handled => {},
                                    .copy => |text| if (try copyTextSelection(submit, .{ .io = io, .file = output, .painter = painter }, text)) view.showCopiedNotice(std.Io.Timestamp.now(io, .awake).toMilliseconds()),
                                    .other => if (!navigateWithMouse(view, event) and event.kind == .left and !dirty) {
                                        const index = event.row -| view.popup_row;
                                        if (event.row >= view.popup_row and index < view.popup_rows and popup.isOpen() and popup.kind == .command) {
                                            const item = popup.scroll + index;
                                            if (index < components.autocomplete.Popup.max_visible and item < popup.items.items.len) {
                                                try applyAutocomplete(&editor, &popup, io, submit, popup.items.items[item]);
                                            }
                                        }
                                    },
                                }
                                dirty = true;
                                continue;
                            }
                            if (view.handleScrollKey(fin, params)) {
                                dirty = true;
                                continue;
                            }
                        };
                        dirty = cancelTranscriptGesture(submit.conversation_view) or dirty;
                        if (final_byte) |fin| switch (fin) {
                            'A' => {
                                // Alt+Up (CSI 1;3A / 1;5A) walks earlier user
                                // messages; plain Up keeps history/line editing.
                                if (submit.fullscreen and promptHistoryIdle(&editor) and th.mode != .none and
                                    submit.conversation_view != null and !popup.isOpen() and
                                    (std.mem.eql(u8, params, "1;3") or std.mem.eql(u8, params, "1;5")) and
                                    navigatePromptHistory(submit.conversation_view.?, false))
                                {
                                    dirty = true;
                                    continue;
                                }
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
                                if (submit.fullscreen and promptHistoryIdle(&editor) and th.mode != .none and
                                    submit.conversation_view != null and !popup.isOpen() and
                                    (std.mem.eql(u8, params, "1;3") or std.mem.eql(u8, params, "1;5")) and
                                    navigatePromptHistory(submit.conversation_view.?, true))
                                {
                                    dirty = true;
                                    continue;
                                }
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
    painter: ?*renderer.FullscreenRenderer = null,
    md: components.markdown.MarkdownStyler = .{},
    loader: components.chrome.Loader = .{},
    mutex: std.Io.Mutex = .init,
    pending_line: std.ArrayList(u8) = .empty,
    overlay_bytes: std.ArrayList(u8) = .empty,
    overlay_cursor_row: usize = 0,
    overlay_cols: usize = 80,
    overlay_active: bool = false,
    event_wake: ?*agent.model.Interrupt = null,
    authorization_condition: std.Io.Condition = .init,
    authorization_waiting: bool = false,
    authorization_visible: bool = false,
    authorization_decision: ?bool = null,
    authorization_label: std.ArrayList(u8) = .empty,
    started_ms: i64 = 0,

    fn elapsedMs(self: *const LiveScreen) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        return @intCast(@max(0, now - self.started_ms));
    }

    // Called with the screen mutex held, including when the consumer resets it.
    fn notifyLocked(self: *LiveScreen) void {
        if (self.event_wake) |wake| if (!wake.isCanceled()) wake.trigger();
    }

    const max_pending_line_bytes: usize = 4096;

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        output: std.Io.File,
        color: bool,
        th: theme.Theme,
        conversation_view: ?*ConversationView,
        painter: ?*renderer.FullscreenRenderer,
    ) LiveScreen {
        return .{
            .allocator = allocator,
            .io = io,
            .output = output,
            .color = color,
            .th = th,
            .conversation_view = conversation_view,
            .painter = painter,
        };
    }

    fn deinit(self: *LiveScreen) void {
        self.pending_line.deinit(self.allocator);
        self.overlay_bytes.deinit(self.allocator);
        self.authorization_label.deinit(self.allocator);
    }

    fn writer(self: *LiveScreen) LiveWriter {
        return .{
            .context = self,
            .write_segment = writeSegmentErased,
            .write_markdown = writeMarkdownErased,
            .set_phase = setPhaseErased,
            .write_tool_text = if (self.conversation_view != null) writeToolTextErased else null,
            .write_tool_body = if (self.conversation_view != null) writeToolBodyErased else null,
            .approve_once = approveOnceErased,
        };
    }

    fn approveOnceErased(context: *anyopaque, request: agent.security.Request, cancel: ?agent.model.Cancel) anyerror!agent.security.ApprovalOutcome {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        return self.approveOnce(request, cancel);
    }

    fn approveOnce(self: *LiveScreen, request: agent.security.Request, cancel: ?agent.model.Cancel) !agent.security.ApprovalOutcome {
        const target = request.target.value orelse @tagName(request.target.kind);
        if (target.len > 4096) return .denied;
        for (target) |byte| if (byte < 0x20 or byte > 0x7e) return .denied;
        const token = cancel orelse return .unavailable;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.authorization_waiting or token.isCanceled()) return .denied;
        try self.authorization_label.print(self.allocator, "{s}  {s}", .{ request.capability.name(), target });
        self.authorization_waiting = true;
        defer {
            self.authorization_decision = null;
            self.authorization_waiting = false;
            self.authorization_visible = false;
            self.authorization_label.clearRetainingCapacity();
            self.notifyLocked();
        }
        self.notifyLocked();
        while (self.authorization_decision == null and !token.isCanceled()) {
            self.authorization_condition.waitTimeout(self.io, &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return .denied,
            };
        }
        if (token.isCanceled()) return .denied;
        return if (self.authorization_decision orelse false) .approved else .denied;
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
        if (self.loader.setPhase(phase, detail, self.elapsedMs())) self.notifyLocked();
    }

    fn handleScrollKey(self: *LiveScreen, final: u8, params: []const u8, submit: Submit) !bool {
        const view = self.conversation_view orelse return false;
        const selected_text: ?[]u8 = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const event = mouse.Event.parse(final, params) orelse {
                view.clearMouseGesture();
                return view.handleScrollKey(final, params);
            };
            switch (try handleTranscriptMouse(view, self.painter.?, terminalSize(self.output), event, submit.allocator)) {
                .other => _ = navigateWithMouse(view, event),
                .handled => {},
                .copy => |text| break :blk text,
            }
            break :blk null;
        };
        if (selected_text) |text| {
            if (try copyTextSelection(submit, .{ .io = self.io, .file = self.output, .painter = self.painter }, text)) {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                view.showCopiedNotice(std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
                self.notifyLocked();
            }
        }
        return true;
    }

    fn writeSegment(self: *LiveScreen, prefix: []const u8, safe: []const u8, suffix: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.conversation_view) |view| {
            // Tool text never writes to the terminal directly in fullscreen; the
            // next retained-row paint shows it.
            try view.appendText(prefix);
            const clean = try terminal.safeUtf8Alloc(self.allocator, safe);
            defer self.allocator.free(clean);
            try view.appendText(clean);
            try view.appendText(suffix);
            self.notifyLocked();
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
            self.notifyLocked();
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

    fn renderLive(
        self: *LiveScreen,
        editor: *const EditorState,
        followups: []const []const u8,
        submit: Submit,
        cols: usize,
    ) !void {
        const max_cols = @max(1, cols -| 1);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.event_wake) |wake| if (wake.isCanceled()) wake.reset();
        var activity = self.loader;
        activity.elapsed_ms = self.elapsedMs();
        const loader_line = try activity.renderLineAlloc(self.allocator, self.th, max_cols);
        defer self.allocator.free(loader_line);

        self.authorization_visible = false;
        if (self.authorization_waiting and self.authorization_decision == null) {
            const label = self.authorization_label.items;
            const question = "Allow once? [y/N]";
            const size = terminalSize(self.output);
            const max_label_lines: usize = if (size.row >= 9) @min(@as(usize, 6), size.row - 6) else 0;
            var wrapped: std.ArrayList([]const u8) = .empty;
            defer wrapped.deinit(self.allocator);
            try wrapped.append(self.allocator, question);
            var fits = question.len <= max_cols and max_label_lines > 0;
            if (fits) {
                var offset: usize = 0;
                while (offset < label.len) {
                    if (wrapped.items.len - 1 >= max_label_lines) {
                        fits = false;
                        break;
                    }
                    const end = @min(label.len, offset + max_cols);
                    try wrapped.append(self.allocator, label[offset..end]);
                    offset = end;
                }
            }
            const lines: []const []const u8 = if (fits) wrapped.items else &.{"Resize to review, or press n to deny"};
            if (self.conversation_view) |view| {
                try renderFullscreenConversation(self.allocator, self.io, self.output, self.painter.?, view, editor, "", lines, &.{}, &.{}, &.{}, self.th, null, null);
            } else {
                const frame = try std.mem.join(self.allocator, "\r\n", lines);
                defer self.allocator.free(frame);
                try self.updateOverlayLocked(frame, lines.len - 1, cols);
            }
            self.authorization_visible = fits;
            return;
        }

        var footer_lines: ?[4][]u8 = null;
        defer if (footer_lines) |lines| {
            for (lines) |line| self.allocator.free(line);
        };
        if (self.conversation_view != null or self.th.mode != .none) {
            if (submit.status_info) |get_info| {
                var info = get_info(submit.context);
                info.queued_count = followups.len;
                footer_lines = try components.chrome.Footer.renderFramedLinesAlloc(self.allocator, self.th, info, max_cols, activity);
            }
        }
        if (self.conversation_view) |view| {
            try renderFullscreenConversation(self.allocator, self.io, self.output, self.painter.?, view, editor, loader_line, &.{}, &.{}, if (footer_lines) |*lines| lines else &.{}, followups, self.th, null, null);
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
        try self.updateOverlayLocked(rendered.bytes, rendered.cursor_row, cols);
    }

    fn updateOverlay(self: *LiveScreen, new_bytes: []const u8, new_cursor_row: usize, cols: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.updateOverlayLocked(new_bytes, new_cursor_row, cols);
    }

    fn updateOverlayLocked(self: *LiveScreen, new_bytes: []const u8, new_cursor_row: usize, cols: usize) !void {
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

    fn writeToolTextErased(context: *anyopaque, text: []const u8, id: []const u8) anyerror!void {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.conversation_view.?.appendToolText(text, id);
        self.notifyLocked();
    }

    fn writeToolBodyErased(context: *anyopaque, text: []const u8, id: []const u8) anyerror!void {
        const self: *LiveScreen = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.conversation_view.?.appendToolBody(text, id);
        self.notifyLocked();
    }

    fn setToolsExpanded(self: *LiveScreen, expanded: bool) void {
        const view = self.conversation_view orelse return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        view.setToolsExpanded(expanded);
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
        if (th.mode != .none and footer_lines.len != 4) {
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
    run_worker: *const fn (*anyopaque, []const u8) anyerror!void,
    text: []const u8,
    initial_phase: components.chrome.Phase,
    followups: *std.ArrayList([]u8),
    bg_queue: *std.ArrayList([]u8),
    carried_draft: *?[]u8,
    use_sgr: bool,
    th: theme.Theme,
    painter: ?*renderer.FullscreenRenderer,
) !void {
    const orig_term = try enterRawMode(input_fd);
    defer terminal.setTermiosNow(input_fd, orig_term) catch {};

    if (painter) |p| p.invalidate();
    defer output.writeStreamingAll(io, if (submit.fullscreen) mouse.disable ++ "\x1b[?2004l" else "\x1b[?2004l") catch {};
    try output.writeStreamingAll(io, if (submit.fullscreen) "\x1b[?2004h" ++ mouse.enable else "\x1b[?2004h");

    var done = try agent.model.Interrupt.init();
    defer done.deinit(io);

    var cols = terminalColumns(output);
    var last_size = terminalSize(output);
    var screen = LiveScreen.init(submit.allocator, io, output, use_sgr, th, submit.conversation_view, painter);
    defer if (submit.conversation_view) |view| {
        view.mouse_gesture = null;
    };
    var event_wake = try agent.model.Interrupt.init();
    defer event_wake.deinit(io);
    screen.event_wake = &event_wake;
    screen.started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    screen.loader.phase = initial_phase;
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
        context: *anyopaque,
        callback: *const fn (*anyopaque, []const u8) anyerror!void,
        text: []const u8,
        done: *agent.model.Interrupt,
        err: ?anyerror = null,
        fn run(state: *@This()) void {
            state.callback(state.context, state.text) catch |e| {
                state.err = e;
            };
            state.done.trigger();
        }
    };
    errdefer screen.clearOverlay() catch {};
    try screen.renderLive(&editor, followups.items, submit, cols);
    var worker = WorkerState{ .context = submit.context, .callback = run_worker, .text = text, .done = &done };
    var thread = try std.Thread.spawn(.{}, WorkerState.run, .{&worker});
    var joined = false;
    errdefer if (!joined) {
        if (submit.trigger_cancel) |trig| trig(submit.context);
        thread.join();
    };

    var in_paste = false;
    var dirty = false;
    const wake = done.cancel();
    const update_interval_ms = 16;
    const animation_interval_ms = components.chrome.Loader.frame_ms;
    var last_paint_ms = screen.elapsedMs();

    while (!done.isCanceled()) {
        const now = screen.elapsedMs();
        const notice_expired = if (submit.conversation_view) |view| blk: {
            screen.mutex.lockUncancelable(io);
            defer screen.mutex.unlock(io);
            break :blk view.expireCopiedNotice(std.Io.Timestamp.now(io, .awake).toMilliseconds());
        } else false;
        const update_pending = event_wake.isCanceled();
        const animation_deadline = (now / animation_interval_ms + 1) * animation_interval_ms;
        const update_deadline = last_paint_ms + update_interval_ms;
        const buffered = queue.hasBuffered();
        if (!buffered) {
            const current_size = terminalSize(output);
            const resized = !std.meta.eql(current_size, last_size);
            const animate = now / animation_interval_ms != last_paint_ms / animation_interval_ms;
            if (dirty or resized or animate or notice_expired or (update_pending and now >= update_deadline)) {
                cols = current_size.col;
                last_size = current_size;
                try screen.renderLive(&editor, followups.items, submit, cols);
                last_paint_ms = now;
                dirty = false;
                continue;
            }
        }
        // Leave throttled updates latched until paint. Exclude their pipe from
        // the wait so keystrokes and completion can still interrupt the delay.
        const deadline = if (update_pending) @min(update_deadline, animation_deadline) else animation_deadline;
        const update_wake = if (update_pending or buffered) null else event_wake.cancel();
        if (queue.eof) {
            if (submit.trigger_cancel) |trigger| trigger(submit.context);
            _ = try queue.readByteWithWake(input_fd, wake, @intCast(deadline -| now));
            continue;
        }
        const b = (queue.readByteWithCancelAndWake(input_fd, wake, update_wake, @intCast(deadline -| now)) catch |err| switch (err) {
            error.Canceled => break,
            else => return err,
        }) orelse continue;
        if (done.isCanceled()) break;
        const approval_pending = blk: {
            screen.mutex.lockUncancelable(io);
            defer screen.mutex.unlock(io);
            if (!screen.authorization_waiting) break :blk false;
            if (screen.authorization_decision == null and !in_paste) {
                switch (b) {
                    'y', 'Y' => if (screen.authorization_visible) {
                        screen.authorization_decision = true;
                    },
                    'n', 'N', '\r', '\n' => screen.authorization_decision = false,
                    else => {},
                }
                if (screen.authorization_decision != null) {
                    dirty = true;
                    screen.authorization_condition.signal(io);
                }
            }
            break :blk true;
        };
        // Escape sequences still go through the normal parser so bracketed paste
        // stays tracked. Printable bytes never reach the editor during approval.
        if (approval_pending and b != 0x1b and b != 0x03) continue;
        if (b != 0x1b) if (submit.conversation_view) |view| view.clearMouseGesture();
        if (submit.conversation_view) |view| view.clearCopiedNotice();

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
                    screen.setToolsExpanded(toggle(submit.context));
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
                    if (submit.conversation_view) |view| view.clearMouseGesture();
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
                if (next != '[' and next != 'O') if (submit.conversation_view) |view| view.clearMouseGesture();
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
                        if (submit.conversation_view) |view| view.mouse_gesture = null;
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
                        if (submit.conversation_view) |view| view.mouse_gesture = null;
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
                            if (try screen.handleScrollKey(fin, params, submit)) {
                                dirty = true;
                                continue;
                            }
                        };
                        if (submit.conversation_view) |view| view.clearMouseGesture();
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
        try reportTurnError(io, submit.conversation_view, use_sgr, err);
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

    const plain = try renderLiveOverlayFrameWithChrome(a, &editor, &.{}, 20, false, theme.Theme.init(.none), loader, &.{});
    defer a.free(plain.bytes);
    try std.testing.expectEqualStrings("Working...\r\n> ", plain.bytes);
    try std.testing.expectEqual(@as(usize, 1), plain.cursor_row);
}
