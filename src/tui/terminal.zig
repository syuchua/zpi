//! Terminal capability helpers, raw-mode termios management, UTF-8/CJK/ANSI
//! display width calculation, clipping, and escape/bracketed-paste input queue.
const std = @import("std");
const agent = @import("agent");

pub const InputQueue = struct {
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    pub fn hasBuffered(self: *const InputQueue) bool {
        return self.start < self.end;
    }

    pub fn readByteTimeout(self: *InputQueue, fd: std.posix.fd_t, cancel: ?agent.model.Cancel, timeout_ms: i32) !?u8 {
        if (cancel) |token| {
            if (token.isCanceled()) return error.Canceled;
        }
        if (self.start < self.end) {
            const b = self.buf[self.start];
            self.start += 1;
            return b;
        }
        if (self.eof) return null;
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
                if (n == 0) {
                    self.eof = true;
                    return null;
                }
                self.start = 1;
                self.end = n;
                return self.buf[0];
            }
            pollfds[0].revents = 0;
            if (nfds == 2) pollfds[1].revents = 0;
        }
    }

    pub fn readByte(self: *InputQueue, fd: std.posix.fd_t, cancel: ?agent.model.Cancel) !?u8 {
        return self.readByteTimeout(fd, cancel, -1);
    }

    pub fn readByteWithCancelAndWake(
        self: *InputQueue,
        fd: std.posix.fd_t,
        cancel: ?agent.model.Cancel,
        wake: ?agent.model.Cancel,
        timeout_ms: i32,
    ) !?u8 {
        if (cancel) |token| if (token.isCanceled()) return error.Canceled;
        if (wake) |w| if (w.isCanceled()) return null;
        if (self.start < self.end) {
            const b = self.buf[self.start];
            self.start += 1;
            return b;
        }
        if (self.eof) return null;

        var pollfds: [3]std.posix.pollfd = undefined;
        var nfds: usize = 1;
        pollfds[0] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        var cancel_idx: ?usize = null;
        if (cancel) |token| {
            if (token.poll_fd) |cancel_fd| {
                cancel_idx = nfds;
                pollfds[nfds] = .{ .fd = cancel_fd, .events = std.posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }
        var wake_idx: ?usize = null;
        if (wake) |w| {
            if (w.poll_fd) |wake_fd| {
                wake_idx = nfds;
                pollfds[nfds] = .{ .fd = wake_fd, .events = std.posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }
        while (true) {
            const ready = std.posix.poll(pollfds[0..nfds], timeout_ms) catch |err| switch (err) {
                else => return err,
            };
            if (cancel) |token| {
                if (token.isCanceled() or (cancel_idx != null and (pollfds[cancel_idx.?].revents & std.posix.POLL.IN) != 0)) {
                    return error.Canceled;
                }
            }
            if (wake) |w| {
                if (w.isCanceled() or (wake_idx != null and (pollfds[wake_idx.?].revents & std.posix.POLL.IN) != 0)) {
                    return null;
                }
            }
            if (ready == 0) return null;
            if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                const n = std.posix.read(fd, &self.buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        for (pollfds[0..nfds]) |*pfd| pfd.revents = 0;
                        continue;
                    },
                    else => return err,
                };
                if (n == 0) {
                    self.eof = true;
                    return null;
                }
                self.start = 1;
                self.end = n;
                return self.buf[0];
            }
            for (pollfds[0..nfds]) |*pfd| pfd.revents = 0;
        }
    }

    pub fn readByteWithWake(self: *InputQueue, fd: std.posix.fd_t, wake: agent.model.Cancel, timeout_ms: i32) !?u8 {
        if (wake.isCanceled()) return null;
        if (self.start < self.end) {
            const b = self.buf[self.start];
            self.start += 1;
            return b;
        }
        if (self.eof) {
            if (wake.poll_fd) |wake_fd| {
                var fds = [_]std.posix.pollfd{.{ .fd = wake_fd, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&fds, timeout_ms) catch {};
            }
            return null;
        }
        var pollfds: [2]std.posix.pollfd = undefined;
        var nfds: usize = 1;
        pollfds[0] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        if (wake.poll_fd) |wake_fd| {
            pollfds[1] = .{ .fd = wake_fd, .events = std.posix.POLL.IN, .revents = 0 };
            nfds = 2;
        }
        while (true) {
            const ready = std.posix.poll(pollfds[0..nfds], timeout_ms) catch |err| switch (err) {
                else => return err,
            };
            if (wake.isCanceled() or (nfds == 2 and (pollfds[1].revents & std.posix.POLL.IN) != 0)) {
                return null;
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
                if (n == 0) {
                    self.eof = true;
                    return null;
                }
                self.start = 1;
                self.end = n;
                return self.buf[0];
            }
            pollfds[0].revents = 0;
            if (nfds == 2) pollfds[1].revents = 0;
        }
    }
};

// Zig 0.17 exposes Linux's kernel termios layout, which is smaller than
// libc's termios. Use the matching kernel calls on Linux.
fn getTermios(fd: std.posix.fd_t) !std.posix.termios {
    if (@import("builtin").os.tag != .linux) return std.posix.tcgetattr(fd);
    const linux = std.os.linux;
    var term = std.mem.zeroes(linux.termios);
    while (true) switch (linux.errno(linux.tcgetattr(fd, &term))) {
        .SUCCESS => return term,
        .INTR => continue,
        .NOTTY => return error.NotATerminal,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

pub fn setTermiosNow(fd: std.posix.fd_t, term: std.posix.termios) !void {
    if (@import("builtin").os.tag != .linux) return std.posix.tcsetattr(fd, .NOW, term);
    const linux = std.os.linux;
    while (true) switch (linux.errno(linux.tcsetattr(fd, .NOW, &term))) {
        .SUCCESS => return,
        .INTR => continue,
        .NOTTY => return error.NotATerminal,
        .IO => return error.ProcessOrphaned,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

pub fn enterRawMode(fd: std.posix.fd_t) !std.posix.termios {
    const original = try getTermios(fd);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    try setTermiosNow(fd, raw);
    return original;
}

pub fn terminalSize(file: std.Io.File) std.posix.winsize {
    const fallback: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    var ws: std.posix.winsize = undefined;
    // Pass the writable pointer directly to libc's variadic ioctl.
    while (true) switch (std.c.errno(std.c.ioctl(file.handle, @bitCast(@as(u32, std.posix.T.IOCGWINSZ)), &ws))) {
        .SUCCESS => {
            if (ws.col == 0) ws.col = fallback.col;
            if (ws.row == 0) ws.row = fallback.row;
            return ws;
        },
        .INTR => continue,
        else => return fallback,
    };
}

pub fn terminalColumns(file: std.Io.File) usize {
    return terminalSize(file).col;
}

pub fn writeSafeText(io: std.Io, file: std.Io.File, text: []const u8) !void {
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

pub fn appendSanitizedText(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f) {
            try out.appendSlice(a, text[start..i]);
            try out.append(a, '?');
            start = i + 1;
        }
    }
    try out.appendSlice(a, text[start..]);
}

pub fn appendSafeTerminalBytes(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
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

pub fn codepointWidth(cp: u21) usize {
    if (cp == 0) return 0;
    if ((cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F))
    {
        return 0;
    }
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

pub fn utf8Columns(text: []const u8) usize {
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

/// Skip an ANSI CSI (`\x1b[...<final>`) or OSC (`\x1b]...(\x07|\x1b\\)`) escape
/// sequence starting at `text[index] == '\x1b'`, returning the next index.
pub fn skipEscapeSequence(text: []const u8, index: usize) usize {
    if (index >= text.len or text[index] != '\x1b') return index;
    if (index + 1 >= text.len) return text.len;
    const kind = text[index + 1];
    if (kind == '[') {
        var j = index + 2;
        while (j < text.len and !(text[j] >= 0x40 and text[j] <= 0x7e)) : (j += 1) {}
        return if (j < text.len) j + 1 else text.len;
    }
    if (kind == ']') {
        var j = index + 2;
        while (j < text.len) : (j += 1) {
            if (text[j] == 0x07) return j + 1;
            if (text[j] == '\x1b' and j + 1 < text.len and text[j + 1] == '\\') return j + 2;
        }
        return text.len;
    }
    return index + 2;
}

/// Terminal column width ignoring ANSI CSI/OSC escape sequences.
pub fn visibleWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            i = skipEscapeSequence(text, i);
            continue;
        }
        if (text[i] == '\r' or text[i] == '\n') {
            i += 1;
            continue;
        }
        if (text[i] == '\t') {
            cols += 4;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = @min(len, text.len - i);
        const cp = std.unicode.utf8Decode(text[i .. i + step]) catch 0xFFFD;
        if (cp >= 0x20 and cp != 0x7f) cols += codepointWidth(cp);
        i += step;
    }
    return cols;
}

pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            i = skipEscapeSequence(text, i);
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Append a single-line sanitized preview clipped to `max_cols` terminal cells.
/// Stops before CR/LF/TAB and maps control characters to `?`.
pub fn appendClippedText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max_cols: usize) !usize {
    var index: usize = 0;
    var columns: usize = 0;
    while (index < text.len and columns < max_cols) {
        if (text[index] == '\r' or text[index] == '\n' or text[index] == '\t') break;
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const step = @min(length, text.len - index);
        const decoded = std.unicode.utf8Decode(text[index .. index + step]) catch 0xfffd;
        const cp = if (decoded < 0x20 or (decoded >= 0x7f and decoded <= 0x9f)) '?' else decoded;
        const width = codepointWidth(cp);
        if (columns + width > max_cols) break;
        if (cp == '?' and decoded != '?') {
            try out.append(allocator, '?');
        } else {
            try out.appendSlice(allocator, text[index .. index + step]);
        }
        columns += width;
        index += step;
    }
    return columns;
}

/// Append ANSI-preserving text clipped to `max_cols` visible columns, appending
/// `ellipsis` when truncated and closing active SGR if any ANSI was seen.
pub fn appendTruncatedAnsi(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    max_cols: usize,
    ellipsis: []const u8,
) !usize {
    const total = visibleWidth(text);
    if (total <= max_cols) {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\x1b') {
                const next = skipEscapeSequence(text, i);
                try out.appendSlice(allocator, text[i..next]);
                i = next;
            } else if (text[i] == '\r' or text[i] == '\n') {
                break;
            } else if (text[i] == '\t') {
                try out.appendSlice(allocator, "    ");
                i += 1;
            } else if (text[i] < 0x20 or text[i] == 0x7f) {
                try out.append(allocator, '?');
                i += 1;
            } else {
                const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const step = @min(length, text.len - i);
                try out.appendSlice(allocator, text[i .. i + step]);
                i += step;
            }
        }
        return total;
    }
    const ell_cols = visibleWidth(ellipsis);
    const budget = if (max_cols > ell_cols) max_cols - ell_cols else 0;
    var cols: usize = 0;
    var i: usize = 0;
    var active_sgr = false;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            const next = skipEscapeSequence(text, i);
            const seq = text[i..next];
            try out.appendSlice(allocator, seq);
            if (seq.len >= 3 and seq[1] == '[' and seq[seq.len - 1] == 'm') {
                active_sgr = !(std.mem.eql(u8, seq, "\x1b[0m") or std.mem.eql(u8, seq, "\x1b[m"));
            }
            i = next;
            continue;
        }
        if (text[i] == '\r' or text[i] == '\n') break;
        if (text[i] == '\t') {
            if (cols + 4 > budget) break;
            try out.appendSlice(allocator, "    ");
            cols += 4;
            i += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = @min(length, text.len - i);
        const decoded = std.unicode.utf8Decode(text[i .. i + step]) catch 0xfffd;
        const cp = if (decoded < 0x20 or (decoded >= 0x7f and decoded <= 0x9f)) '?' else decoded;
        const w = codepointWidth(cp);
        if (cols + w > budget) break;
        if (cp == '?' and decoded != '?') {
            try out.append(allocator, '?');
        } else {
            try out.appendSlice(allocator, text[i .. i + step]);
        }
        cols += w;
        i += step;
    }
    if (max_cols >= ell_cols and ellipsis.len > 0) {
        try out.appendSlice(allocator, ellipsis);
        cols += ell_cols;
    }
    if (active_sgr) try out.appendSlice(allocator, "\x1b[0m");
    return cols;
}

/// Word/column-wrap a single ANSI-styled line to `max_cols` visible columns,
/// closing and re-opening active SGR sequences across line breaks.
pub fn wrapAnsiAlloc(allocator: std.mem.Allocator, text: []const u8, max_cols_raw: usize) ![]u8 {
    const max_cols = @max(1, max_cols_raw);
    if (visibleWidth(text) <= max_cols) return try allocator.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var active_sgr: std.ArrayList(u8) = .empty;
    defer active_sgr.deinit(allocator);
    var break_sgr: std.ArrayList(u8) = .empty;
    defer break_sgr.deinit(allocator);

    var line_cols: usize = 0;
    var line_start_out: usize = 0;
    var break_out_idx: ?usize = null;
    var break_in_idx: ?usize = null;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            const next = skipEscapeSequence(text, i);
            const seq = text[i..next];
            try out.appendSlice(allocator, seq);
            if (seq.len >= 3 and seq[1] == '[' and seq[seq.len - 1] == 'm') {
                if (std.mem.eql(u8, seq, "\x1b[0m") or std.mem.eql(u8, seq, "\x1b[m")) {
                    active_sgr.clearRetainingCapacity();
                } else {
                    active_sgr.clearRetainingCapacity();
                    try active_sgr.appendSlice(allocator, seq);
                }
            }
            i = next;
            continue;
        }
        if (text[i] == '\r') {
            i += 1;
            continue;
        }
        if (text[i] == '\n') {
            if (active_sgr.items.len > 0) try out.appendSlice(allocator, "\x1b[0m");
            try out.append(allocator, '\n');
            if (active_sgr.items.len > 0) try out.appendSlice(allocator, active_sgr.items);
            line_cols = 0;
            line_start_out = out.items.len;
            break_out_idx = null;
            break_in_idx = null;
            i += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = @min(length, text.len - i);
        const decoded = std.unicode.utf8Decode(text[i .. i + step]) catch 0xfffd;
        const cp = if (decoded < 0x20 or (decoded >= 0x7f and decoded <= 0x9f)) '?' else decoded;
        const w: usize = if (text[i] == '\t') 4 else codepointWidth(cp);

        if (line_cols > 0 and line_cols + w > max_cols) {
            if (break_out_idx) |bo| {
                if (bo > line_start_out and break_in_idx != null) {
                    out.items.len = bo;
                    if (break_sgr.items.len > 0) try out.appendSlice(allocator, "\x1b[0m");
                    try out.append(allocator, '\n');
                    if (break_sgr.items.len > 0) try out.appendSlice(allocator, break_sgr.items);
                    active_sgr.clearRetainingCapacity();
                    try active_sgr.appendSlice(allocator, break_sgr.items);
                    i = break_in_idx.?;
                    line_cols = 0;
                    line_start_out = out.items.len;
                    break_out_idx = null;
                    break_in_idx = null;
                    continue;
                }
            }
            if (active_sgr.items.len > 0) try out.appendSlice(allocator, "\x1b[0m");
            try out.append(allocator, '\n');
            if (active_sgr.items.len > 0) try out.appendSlice(allocator, active_sgr.items);
            line_cols = 0;
            line_start_out = out.items.len;
            break_out_idx = null;
            break_in_idx = null;
            continue;
        }

        if (text[i] == ' ' and step == 1) {
            break_out_idx = out.items.len;
            break_in_idx = i + 1;
            break_sgr.clearRetainingCapacity();
            try break_sgr.appendSlice(allocator, active_sgr.items);
        }

        if (text[i] == '\t') {
            try out.appendSlice(allocator, "    ");
        } else if (cp == '?' and decoded != '?') {
            try out.append(allocator, '?');
        } else {
            try out.appendSlice(allocator, text[i .. i + step]);
        }
        line_cols += w;
        i += step;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn advanceByColumns(line: []const u8, target_cols: usize) usize {
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

pub const Layout = struct {
    cursor_row: usize,
    cursor_col: usize,
    end_row: usize,
    end_col: usize,
};

pub fn computeLayout(text: []const u8, cursor: usize, cols_raw: usize, prompt_cols: usize) Layout {
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

pub fn pendingLineRows(line: []const u8, cols_raw: usize) usize {
    const cols = @max(cols_raw, 4);
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\x1b') {
            i = skipEscapeSequence(line, i);
            continue;
        }
        if (line[i] == '\r') {
            col = 0;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const step = @min(len, line.len - i);
        const cp = std.unicode.utf8Decode(line[i .. i + step]) catch 0xFFFD;
        const w: usize = if (line[i] == '\t') 4 else codepointWidth(cp);
        if (col + w > cols) {
            row += 1;
            col = w;
        } else {
            col += w;
        }
        i += step;
    }
    return row;
}

test "visibleWidth stripAnsi and appendTruncatedAnsi handle ANSI CJK and combining marks" {
    const a = std.testing.allocator;
    const styled = "\x1b[36mHello\x1b[0m 世界";
    try std.testing.expectEqual(@as(usize, 10), visibleWidth(styled));

    const plain = try stripAnsi(a, styled);
    defer a.free(plain);
    try std.testing.expectEqualStrings("Hello 世界", plain);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const used = try appendTruncatedAnsi(&out, a, styled, 8, "...");
    try std.testing.expectEqual(@as(usize, 8), used);
    try std.testing.expectEqualStrings("\x1b[36mHello\x1b[0m...", out.items);

    try std.testing.expectEqual(@as(usize, 1), visibleWidth("e\u{0301}"));
}

test "pendingLineRows tracks wrapped text and ignores CSI SGR sequences" {
    try std.testing.expectEqual(@as(usize, 0), pendingLineRows("0123456789", 10));
    try std.testing.expectEqual(@as(usize, 1), pendingLineRows("0123456789a", 10));
    try std.testing.expectEqual(@as(usize, 0), pendingLineRows("\x1b[2m0123456789\x1b[0m", 10));
    try std.testing.expectEqual(@as(usize, 1), pendingLineRows("\x1b[2m中文中文中文\x1b[0m", 10));
}

test "computeLayout tracks wide characters newlines and wrapping" {
    const l1 = computeLayout("你好\nab", 6, 10, 2);
    try std.testing.expectEqual(@as(usize, 0), l1.cursor_row);
    try std.testing.expectEqual(@as(usize, 6), l1.cursor_col);
    try std.testing.expectEqual(@as(usize, 1), l1.end_row);
    try std.testing.expectEqual(@as(usize, 4), l1.end_col);

    const l1_after = computeLayout("你好\nab", 7, 10, 2);
    try std.testing.expectEqual(@as(usize, 1), l1_after.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), l1_after.cursor_col);

    const l2 = computeLayout("abcdef", 6, 6, 2);
    try std.testing.expectEqual(@as(usize, 1), l2.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), l2.cursor_col);
}

test "wrapAnsiAlloc wraps on word boundaries and preserves active SGR across lines" {
    const a = std.testing.allocator;
    const wrapped = try wrapAnsiAlloc(a, "alpha \x1b[33mbeta gammas\x1b[0m", 10);
    defer a.free(wrapped);
    try std.testing.expectEqualStrings("alpha\n\x1b[33mbeta\x1b[0m\n\x1b[33mgammas\x1b[0m", wrapped);

    const cjk = try wrapAnsiAlloc(a, "中文日本語", 4);
    defer a.free(cjk);
    try std.testing.expectEqualStrings("中文\n日本\n語", cjk);
}
