//! Regular terminal UI. The terminal owns scrollback and canonical line editing;
//! this MVP never enters an alternate screen or leaves terminal attributes changed.
const std = @import("std");
const agent = @import("agent");

pub const Submit = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, []const u8) anyerror!void,
    session_info: ?*const fn (*anyopaque) anyerror!void = null,
    cancel: ?agent.model.Cancel = null,
    reset_cancel: ?*const fn (*anyopaque) void = null,
};

pub fn run(io: std.Io, submit: Submit) !void {
    const input = std.Io.File.stdin();
    const output = std.Io.File.stdout();
    if (!try input.isTty(io) or !try output.isTty(io)) return error.InteractiveTtyRequired;
    const color = try output.supportsAnsiEscapeCodes(io);
    try output.writeStreamingAll(io, if (color)
        "\x1b[1;36mzpi\x1b[0m  /help · /exit · Ctrl-D exits\n"
    else
        "zpi  /help · /exit · Ctrl-D exits\n");
    var buffer: [64 * 1024]u8 = undefined;
    var reader = input.readerStreaming(io, &buffer);
    while (true) {
        if (submit.reset_cancel) |reset| reset(submit.context);
        try output.writeStreamingAll(io, if (color) "\x1b[36m>\x1b[0m " else "> ");
        const raw = readPromptLine(io, input.handle, &reader, submit.cancel) catch |err| switch (err) {
            error.Canceled => {
                reader.err = null;
                reader.interface.seek = 0;
                reader.interface.end = 0;
                try output.writeStreamingAll(io, "\n");
                continue;
            },
            error.StreamTooLong => {
                // Drain the offending line without retaining an unbounded paste.
                _ = reader.interface.discardDelimiterInclusive('\n') catch |drain_err| switch (drain_err) {
                    error.EndOfStream => return,
                    else => return drain_err,
                };
                try std.Io.File.stderr().writeStreamingAll(io, "zpi: prompt exceeds 64 KiB; discarded\n");
                continue;
            },
            else => return err,
        } orelse return;
        const text = std.mem.trim(u8, raw, " \t\r");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "/exit") or std.mem.eql(u8, text, "/quit")) return;
        if (std.mem.eql(u8, text, "/help")) {
            try output.writeStreamingAll(io, "Enter a task to stream a response and run tools. /exit leaves the session.\nUse --session PATH to reopen; add --branch ENTRY-ID to continue from an earlier point.\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/hotkeys")) {
            try output.writeStreamingAll(io, "Keyboard shortcuts\nCtrl-C  Cancel current turn\nCtrl-D  Exit\n/exit   Exit\n/quit   Exit\n/help   Show help\n/session Show current session summary\n/hotkeys Show shortcuts\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/session")) {
            if (submit.session_info) |show| try show(submit.context);
            continue;
        }
        // The read buffer stays untouched while submit executes. A caller that
        // queues work must copy this borrowed input before returning.
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

fn readPromptLine(io: std.Io, input_fd: std.posix.fd_t, reader: *std.Io.File.Reader, cancel: ?agent.model.Cancel) anyerror!?[]const u8 {
    const token = cancel orelse return reader.interface.takeDelimiter('\n');
    if (token.isCanceled()) return error.Canceled;
    if (token.poll_fd) |cancel_fd| {
        if (std.mem.indexOfScalar(u8, reader.interface.buffered(), '\n') == null) {
            var pollfds = [_]std.posix.pollfd{
                .{ .fd = input_fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = cancel_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            while (true) {
                _ = std.posix.poll(&pollfds, -1) catch |err| switch (err) {
                    else => return err,
                };
                if (token.isCanceled() or (pollfds[1].revents & std.posix.POLL.IN) != 0) return error.Canceled;
                if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) break;
                pollfds[0].revents = 0;
                pollfds[1].revents = 0;
            }
        }
        return reader.interface.takeDelimiter('\n');
    }
    const Completion = union(enum) { line: anyerror!?[]const u8, cancel: std.Io.Cancelable!void };
    var storage: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.line, takeLine, .{reader});
    try select.concurrent(.cancel, waitCancel, .{ token, io });
    return switch (try select.await()) {
        .line => |res| res,
        .cancel => |res| blk: {
            try res;
            break :blk error.Canceled;
        },
    };
}
fn takeLine(reader: *std.Io.File.Reader) anyerror!?[]const u8 {
    return reader.interface.takeDelimiter('\n');
}
fn waitCancel(cancel: agent.model.Cancel, io: std.Io) std.Io.Cancelable!void {
    try cancel.wait(io);
}
