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
};

const DialogKind = enum { help, hotkeys };

fn eraseSubmittedPromptLine(io: std.Io, output: std.Io.File) !void {
    try output.writeStreamingAll(io, "\x1b[1A\r\x1b[J");
}

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
    model_source: ?*const fn (*anyopaque) anyerror!?ModelSource = null,
    set_thinking: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    cycle_thinking: ?*const fn (*anyopaque) void = null,
    resume_session: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    session_source: ?*const fn (*anyopaque) anyerror!?SessionSource = null,
    status_info: ?*const fn (*anyopaque) components.chrome.FooterInfo = null,
    toggle_expand: ?*const fn (*anyopaque) bool = null,
    push_steering: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    drain_steering: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![][]u8 = null,
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
    var pending_dialog: ?DialogKind = null;

    while (true) {
        if (submit.reset_cancel) |reset| reset(submit.context);
        const raw = if (followups.items.len > 0) blk: {
            pending_dialog = null;
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
            const dlg = pending_dialog;
            pending_dialog = null;
            if (dlg == null) {
                const prompt_prefix = if (use_sgr) "\x1b[36m>\x1b[0m " else "> ";
                try output.writeStreamingAll(io, prompt_prefix);
            }
            break :blk readPromptLine(submit.allocator, io, input.handle, output, &queue, &history, submit, use_sgr, color, th, initial, dlg) catch |err| switch (err) {
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
        return self.renderWithOverlay(io, output, cols, color, theme.Theme.init(if (color) .ansi16 else .none), &.{}, lines, false);
    }

    fn appendRuleLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, th: theme.Theme, cols: usize) !usize {
        const rule_w = @max(@as(usize, 4), cols -| 1);
        try th.appendOpen(out, allocator, theme.Theme.border);
        var i: usize = 0;
        while (i < rule_w) : (i += 1) try out.appendSlice(allocator, "─");
        try th.appendClose(out, allocator);
        return rule_w;
    }

    fn renderWithOverlay(
        self: *EditorState,
        io: std.Io,
        output: std.Io.File,
        cols: usize,
        use_sgr: bool,
        th: theme.Theme,
        dialog_lines: []const []const u8,
        footer_lines: []const []const u8,
        show_rules: bool,
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
            _ = try appendRuleLine(&out, self.allocator, th, cols);
            try out.appendSlice(self.allocator, "\r\n");
            rows_above += 1;
        }

        try out.appendSlice(self.allocator, if (use_sgr) "\x1b[36m>\x1b[0m " else "> ");

        // Compute visual coordinates (prompt width = 2 on line 0) across newlines and soft wraps.
        const layout = computeLayout(self.buf.items, self.cursor, cols, 2);
        try appendSafeTerminalBytes(&out, self.allocator, self.buf.items);

        var total_end_row = layout.end_row;
        var total_end_col = layout.end_col;
        if (show_rules) {
            try out.appendSlice(self.allocator, "\r\n");
            const rule_w = try appendRuleLine(&out, self.allocator, th, cols);
            total_end_row += 1;
            total_end_col = rule_w;
        }
        if (self.completion_hint) |hint| {
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

fn readPromptLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_fd: std.posix.fd_t,
    output: std.Io.File,
    queue: *InputQueue,
    history: *const History,
    submit: Submit,
    use_sgr: bool,
    term_ansi: bool,
    th: theme.Theme,
    initial: ?[]const u8,
    initial_dialog: ?DialogKind,
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
    var dialog = initial_dialog;
    var dialog_on_screen = false;
    var in_paste = false;
    var cols = terminalColumns(io, output);
    var dirty = has_footer or dialog != null;
    if (initial) |text| {
        if (text.len > 0) {
            try editor.insertSlice(text);
            dirty = true;
        }
    }

    while (true) {
        if ((dirty and !queue.hasBuffered()) or (dialog != null and !dialog_on_screen)) {
            cols = terminalColumns(io, output);
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

            try editor.renderWithOverlay(io, output, cols, use_sgr, th, dialog_slices, footer_slices, th.mode != .none);
            dialog_on_screen = dialog_slices.len > 0;
            dirty = false;
        }
        const b_opt = try queue.readByte(input_fd, submit.cancel);
        const b = b_opt orelse {
            if (dialog_on_screen or editor.completion_hint != null or th.mode != .none) {
                editor.resetCompletionTrack();
                editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, false) catch {};
                dialog_on_screen = false;
            }
            if (editor.buf.items.len == 0) {
                try output.writeStreamingAll(io, "\n");
                return null;
            }
            return try editor.buf.toOwnedSlice(allocator);
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
                if (dialog_on_screen or editor.completion_hint != null or th.mode != .none) {
                    editor.resetCompletionTrack();
                    editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, false) catch {};
                    dialog_on_screen = false;
                }
                return error.Canceled;
            },
            0x04 => {
                if (editor.buf.items.len == 0) {
                    if (dialog_on_screen or editor.completion_hint != null or th.mode != .none) {
                        editor.resetCompletionTrack();
                        editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, false) catch {};
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
                if (editor.cursor == editor.buf.items.len and editor.buf.items.len > 0 and editor.buf.items[editor.buf.items.len - 1] == '\\') {
                    editor.buf.items.len -= 1;
                    editor.cursor -= 1;
                    try editor.insertSlice("\n");
                    dirty = true;
                    continue;
                }
                const had_hint = editor.completion_hint != null;
                editor.resetCompletionTrack();
                if (dirty or had_hint or has_footer or th.mode != .none) {
                    cols = terminalColumns(io, output);
                    try editor.renderWithOverlay(io, output, cols, use_sgr, th, &.{}, &.{}, false);
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
                    cols = terminalColumns(io, output);
                    if (try handleTab(&editor, io, submit, cols, term_ansi, true)) dirty = true;
                } else {
                    try editor.insertSlice("\t");
                    dirty = true;
                }
            },
            0x1b => {
                const next = try queue.readByteTimeout(input_fd, submit.cancel, 25) orelse {
                    if (editor.completion_hint != null) {
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
                    const footer_lines = try components.chrome.Footer.renderLinesAlloc(self.allocator, self.th, info, max_cols);
                    defer {
                        self.allocator.free(footer_lines[0]);
                        self.allocator.free(footer_lines[1]);
                    }
                    status_buf = try std.fmt.allocPrint(self.allocator, "{s}\r\n{s}\r\n{s}", .{ loader_line, footer_lines[0], footer_lines[1] });
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
        const rule_w = @max(@as(usize, 4), cols -| 1);
        if (color) {
            try out.appendSlice(allocator, "\x1b[2m");
            var ri: usize = 0;
            while (ri < rule_w) : (ri += 1) try out.appendSlice(allocator, "─");
            try out.appendSlice(allocator, "\x1b[0m\r\n");
            rows_above += 1;
        }
        try out.appendSlice(allocator, if (color) "\x1b[36m>\x1b[0m " else "> ");
        const layout = computeLayout(editor.buf.items, editor.cursor, cols, 2);
        try appendSafeTerminalBytes(&out, allocator, editor.buf.items);
        var bottom_row = layout.end_row;
        var bottom_col = layout.end_col;
        if (color) {
            try out.appendSlice(allocator, "\r\n\x1b[2m");
            var ri: usize = 0;
            while (ri < rule_w) : (ri += 1) try out.appendSlice(allocator, "─");
            try out.appendSlice(allocator, "\x1b[0m");
            bottom_row += 1;
            bottom_col = rule_w;
        }
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

    var cols = terminalColumns(io, output);
    var screen = LiveScreen.init(submit.allocator, io, output, color, th);
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
    var worker = WorkerState{ .submit = submit, .text = text, .done = &done };
    var thread = try std.Thread.spawn(.{}, WorkerState.run, .{&worker});
    var joined = false;
    errdefer if (!joined) {
        if (submit.trigger_cancel) |trig| trig(submit.context);
        thread.join();
    };

    var in_paste = false;
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
                    cols = terminalColumns(io, output);
                    if (try handleTab(&editor, io, submit, cols, color, false)) dirty = true;
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

    const with_rules = try renderLiveOverlayFrame(a, &editor, &.{}, 20, true);
    defer a.free(with_rules.bytes);
    try std.testing.expect(std.mem.indexOf(u8, with_rules.bytes, "───────────────────") != null);
    try std.testing.expectEqual(@as(usize, 2), with_rules.cursor_row);
}
