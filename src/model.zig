//! Provider-neutral conversation and streaming types.
//! All slices and values are borrowed for the duration documented by the
//! caller. Persisted conversations own/copy data separately from event sinks.
const std = @import("std");

pub const Role = enum { system, user, assistant, tool_result };
pub const StopReason = enum { stop, tool_use, length, error_response, aborted, deferred };

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
};
pub const Content = union(enum) {
    text: []const u8,
    thinking: struct { text: []const u8, signature: ?[]const u8 = null },
    image: struct { bytes: []const u8, mime_type: []const u8 },
    tool_call: ToolCall,
};
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
};
pub const Message = struct {
    role: Role,
    content: []const Content,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    is_error: bool = false,
    details: ?std.json.Value = null,
    /// Zpi full system-prompt checkpoint. Provider requests fold these into a
    /// single leading system message; raw session history keeps every update.
    system_prompt_replace: bool = false,
};

pub fn validateSystemCheckpoint(message: Message) !void {
    if (!message.system_prompt_replace) return;
    if (message.role != .system) return error.InvalidSystemPromptCheckpoint;
    for (message.content) |part| if (part != .text) return error.InvalidSystemPromptCheckpoint;
}

/// Returns a caller-owned message table with borrowed payloads from messages.
/// A full system checkpoint replaces earlier system messages without dropping
/// conversation/tool history. Ordinary messages retain their relative order.
pub fn projectSystemPrompt(allocator: std.mem.Allocator, messages: []const Message) ![]Message {
    var latest: ?usize = null;
    for (messages, 0..) |message, i| {
        if (!message.system_prompt_replace) continue;
        try validateSystemCheckpoint(message);
        latest = i;
    }
    var projected: std.ArrayList(Message) = .empty;
    errdefer projected.deinit(allocator);
    if (latest) |index| {
        var leading = messages[index];
        leading.system_prompt_replace = false;
        try projected.append(allocator, leading);
        for (messages, 0..) |message, i| {
            if (message.role == .system and i <= index) continue;
            try projected.append(allocator, message);
        }
    } else try projected.appendSlice(allocator, messages);
    return projected.toOwnedSlice(allocator);
}

test "system prompt checkpoints replace only system history and preserve tool ordering" {
    const messages = [_]Message{
        .{ .role = .system, .content = &.{.{ .text = "original" }} },
        .{ .role = .user, .content = &.{.{ .text = "task" }} },
        .{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments = .{ .object = .empty } } }} },
        .{ .role = .system, .content = &.{.{ .text = "intermediate" }}, .system_prompt_replace = true },
        .{ .role = .tool_result, .content = &.{.{ .text = "result" }}, .tool_call_id = "call" },
        .{ .role = .system, .content = &.{.{ .text = "current" }}, .system_prompt_replace = true },
    };
    const projected = try projectSystemPrompt(std.testing.allocator, &messages);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqual(@as(usize, 4), projected.len);
    try std.testing.expectEqualStrings("current", projected[0].content[0].text);
    try std.testing.expect(!projected[0].system_prompt_replace);
    try std.testing.expectEqual(Role.user, projected[1].role);
    try std.testing.expectEqual(Role.assistant, projected[2].role);
    try std.testing.expectEqualStrings("call", projected[3].tool_call_id.?);
    try std.testing.expectEqualStrings("original", messages[0].content[0].text);
}

test "system projection preserves legacy messages and rejects invalid checkpoints" {
    const legacy = [_]Message{.{ .role = .system, .content = &.{.{ .text = "legacy" }} }};
    const projected = try projectSystemPrompt(std.testing.allocator, &legacy);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqualStrings("legacy", projected[0].content[0].text);
    try std.testing.expectError(error.InvalidSystemPromptCheckpoint, projectSystemPrompt(std.testing.allocator, &.{.{ .role = .user, .content = &.{}, .system_prompt_replace = true }}));
    try std.testing.expectError(error.InvalidSystemPromptCheckpoint, projectSystemPrompt(std.testing.allocator, &.{.{ .role = .system, .content = &.{.{ .image = .{ .bytes = "", .mime_type = "image/png" } }}, .system_prompt_replace = true }}));
}

/// Every slice/value in every event is borrowed for the emit callback only.
/// A sink must copy any text, tool identity or argument tree that it retains,
/// including data collected for dispatch after the provider call returns.
pub const Event = union(enum) {
    start,
    text_delta: []const u8,
    thinking_delta: []const u8,
    tool_call_start: struct { index: usize, id: []const u8, name: []const u8 },
    /// Emitted after tool_call_start; fragment is borrowed for this callback.
    tool_call_delta: struct { index: usize, arguments_fragment: []const u8 },
    /// All calls are validated before this event; data is callback-borrowed.
    /// Copy before scheduling asynchronous work or collecting for later use.
    tool_call_end: struct { index: usize, call: ToolCall },
    usage: Usage,
    done: StopReason,
};
pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Event) anyerror!void,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const CancelSocket = struct {
    mutex: std.Io.Mutex = .init,
    stream: ?std.Io.net.Stream = null,
    aborted: bool = false,

    pub fn set(self: *CancelSocket, io: std.Io, stream: std.Io.net.Stream) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.aborted) {
            stream.shutdown(io, .both) catch {};
            return;
        }
        self.stream = stream;
    }

    pub fn clear(self: *CancelSocket, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.stream = null;
    }

    pub fn abort(self: *CancelSocket, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.aborted = true;
        if (self.stream) |stream| {
            stream.shutdown(io, .both) catch {};
            self.stream = null;
        }
    }
};

pub const Cancel = struct {
    context: *anyopaque,
    is_canceled: *const fn (*anyopaque) bool,
    wait_fn: *const fn (*anyopaque, std.Io) std.Io.Cancelable!void,
    poll_fd: ?std.posix.fd_t = null,

    pub fn isCanceled(self: Cancel) bool {
        return self.is_canceled(self.context);
    }
    pub fn wait(self: Cancel, io: std.Io) std.Io.Cancelable!void {
        return self.wait_fn(self.context, io);
    }
};

/// Async-signal-safe self-pipe interrupt source. `trigger()` may be called from a
/// POSIX signal handler; `reset()` must run only when no `wait()` is active.
pub const Interrupt = struct {
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,
    canceled: std.atomic.Value(bool) = .init(false),

    pub fn init() !Interrupt {
        var fds: [2]std.posix.fd_t = undefined;
        switch (std.posix.errno(std.posix.system.pipe(&fds))) {
            .SUCCESS => {},
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        errdefer {
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
        for (fds) |fd| {
            switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)))) {
                .SUCCESS => {},
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
        const write_flags: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
        switch (std.posix.errno(std.posix.system.fcntl(fds[1], std.posix.F.SETFL, write_flags))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: *Interrupt, io: std.Io) void {
        (std.Io.File{ .handle = self.read_fd, .flags = .{ .nonblocking = false } }).close(io);
        (std.Io.File{ .handle = self.write_fd, .flags = .{ .nonblocking = false } }).close(io);
        self.* = undefined;
    }

    pub fn trigger(self: *Interrupt) void {
        self.canceled.store(true, .release);
        const byte: [1]u8 = .{1};
        _ = std.posix.system.write(self.write_fd, &byte, 1);
    }

    pub fn reset(self: *Interrupt) void {
        var pollfds = [_]std.posix.pollfd{.{ .fd = self.read_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        var scratch: [256]u8 = undefined;
        while ((std.posix.poll(&pollfds, 0) catch 0) > 0 and (pollfds[0].revents & std.posix.POLL.IN) != 0) {
            const rc = std.posix.system.read(self.read_fd, &scratch, scratch.len);
            if (std.posix.errno(rc) != .SUCCESS or rc <= 0) break;
            pollfds[0].revents = 0;
        }
        self.canceled.store(false, .release);
    }

    pub fn isCanceled(self: *const Interrupt) bool {
        return self.canceled.load(.acquire);
    }

    pub fn cancel(self: *Interrupt) Cancel {
        return .{ .context = self, .is_canceled = isCanceledErased, .wait_fn = waitErased, .poll_fd = self.read_fd };
    }

    fn isCanceledErased(context: *anyopaque) bool {
        const self: *const Interrupt = @ptrCast(@alignCast(context));
        return self.isCanceled();
    }

    fn waitErased(context: *anyopaque, io: std.Io) std.Io.Cancelable!void {
        const self: *Interrupt = @ptrCast(@alignCast(context));
        if (self.canceled.load(.acquire)) return;
        var buf: [1]u8 = undefined;
        const file: std.Io.File = .{ .handle = self.read_fd, .flags = .{ .nonblocking = false } };
        while (!self.canceled.load(.acquire)) {
            _ = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
        }
    }
};

test "interrupt trigger wakes select and reset clears state for reuse" {
    var interrupt = try Interrupt.init();
    defer interrupt.deinit(std.testing.io);
    const token = interrupt.cancel();
    try std.testing.expect(!token.isCanceled());

    const Trigger = struct {
        target: *Interrupt,
        fn run(self: *@This(), io: std.Io) std.Io.Cancelable!void {
            try io.sleep(.fromMilliseconds(20), .awake);
            self.target.trigger();
            try io.sleep(.fromSeconds(10), .awake);
        }
    };
    const Sleep = struct {
        fn run(io: std.Io) std.Io.Cancelable!void {
            try io.sleep(.fromSeconds(10), .awake);
        }
    };
    var trig = Trigger{ .target = &interrupt };
    const Completion = union(enum) { work: std.Io.Cancelable!void, cancel: std.Io.Cancelable!void, trig: std.Io.Cancelable!void };
    var storage: [3]Completion = undefined;
    var select = std.Io.Select(Completion).init(std.testing.io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.work, Sleep.run, .{std.testing.io});
    try select.concurrent(.cancel, Cancel.wait, .{ token, std.testing.io });
    try select.concurrent(.trig, Trigger.run, .{ &trig, std.testing.io });
    switch (try select.await()) {
        .cancel => |res| try res,
        else => return error.UnexpectedTestBranch,
    }
    try std.testing.expect(token.isCanceled());

    interrupt.reset();
    try std.testing.expect(!token.isCanceled());
}

/// Synchronous function delivering zero or more events into the sink. This is
/// a push stream, not a returned one-shot chunk. Implementations propagate sink
/// errors and provider errors without emitting a successful `done`.
pub const Provider = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, std.mem.Allocator, []const Message, []const ToolDefinition, EventSink) anyerror!void,

    pub fn run(self: Provider, allocator: std.mem.Allocator, messages: []const Message, tools: []const ToolDefinition, sink: EventSink) !void {
        return self.run_fn(self.context, allocator, messages, tools, sink);
    }
};
