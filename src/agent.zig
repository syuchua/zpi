//! Agent loop independent of terminal, HTTP and storage. Conversation data is
//! owned by this instance. Tools execute only after a successful whole response.
const std = @import("std");
pub const model = @import("model");

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    call_id: []const u8 = "",
    cancel: ?model.Cancel = null,
    update_context: ?*anyopaque = null,
    on_update: ?*const fn (?*anyopaque, ToolResult) anyerror!void = null,
};
pub const ToolResult = struct { text: []const u8, is_error: bool = false, details: ?std.json.Value = null };
pub const Tool = struct {
    definition: model.ToolDefinition,
    builtin: bool = false,
    context: ?*anyopaque = null,
    execute: *const fn (?*anyopaque, ToolContext, std.json.Value) anyerror!ToolResult,
};
pub const RetryPolicy = struct {
    enabled: bool = true,
    max_retries: u8 = 3,
    base_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 60_000,
};

pub const CompactionHook = struct {
    context: *anyopaque,
    before_turn: ?*const fn (*anyopaque) anyerror!void = null,
    recover_overflow: ?*const fn (*anyopaque) anyerror!bool = null,
};

pub const Event = union(enum) {
    provider: model.Event,
    tool_start: model.ToolCall,
    tool_update: struct { call: model.ToolCall, result: ToolResult },
    tool_end: struct { call: model.ToolCall, result: ToolResult },
    retry_scheduled: struct { attempt: u8, max_attempts: u8, delay_ms: u64, error_code: []const u8 },
    retry_finished: struct { success: bool, attempt: u8, error_code: ?[]const u8 = null },
    compacted: struct { tokens_before: u64, summary: []const u8, first_kept_id: ?[]const u8 = null, automatic: bool = false },
    /// A complete message has entered the conversation. The message is
    /// borrowed for this callback; persist or copy it synchronously.
    message_appended: model.Message,
    settled,
};
pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Event) anyerror!void,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(model.Message) = .empty,
    tools: []const Tool,
    provider: model.Provider,
    io: std.Io,
    cwd: []const u8,
    cancel: ?model.Cancel = null,
    retry: RetryPolicy = .{},
    compaction_hook: ?CompactionHook = null,
    max_turns: usize = 32,
    running: bool = false,
    /// An interrupted tool batch requires reconciliation before another prompt.
    unresolved_tools: bool = false,
    /// A sink may fail after committing data. Stop this instance rather than
    /// guessing whether durable history and in-memory state still agree.
    commit_failed: bool = false,

    /// Provider, tools and cwd are borrowed and must outlive this Agent.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, provider: model.Provider, tools: []const Tool, cwd: []const u8) Agent {
        return .{ .allocator = allocator, .arena = .init(allocator), .io = io, .provider = provider, .tools = tools, .cwd = cwd };
    }
    pub fn deinit(self: *Agent) void {
        std.debug.assert(!self.running);
        self.messages.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn append(self: *Agent, message: model.Message) !void {
        try model.validateSystemCheckpoint(message);
        const owned = try cloneMessage(self.arena.allocator(), message);
        try self.messages.append(self.allocator, owned);
    }
    /// Repair incomplete tool batches without executing them again. A crash can
    /// occur after an external effect but before its result was recorded: the
    /// outcome is unknown and must be inspected rather than replayed blindly.
    pub fn reconcile(self: *Agent, sink: Sink) !void {
        if (self.running) return error.AgentBusy;
        if (self.commit_failed) return error.SessionCommitFailed;
        var pending: std.ArrayList(model.ToolCall) = .empty;
        defer pending.deinit(self.allocator);
        for (self.messages.items) |message| {
            for (message.content) |part| switch (part) {
                .tool_call => |call| {
                    if (message.role != .assistant) return error.InvalidToolCallRole;
                    try pending.append(self.allocator, call);
                },
                else => {},
            };
            if (message.role == .tool_result) {
                const id = message.tool_call_id orelse return error.MissingToolCallId;
                var matched = false;
                for (pending.items, 0..) |call, index| {
                    if (!std.mem.eql(u8, call.id, id)) continue;
                    _ = pending.orderedRemove(index);
                    matched = true;
                    break;
                }
                if (!matched) return error.OrphanToolResult;
            }
        }
        self.unresolved_tools = pending.items.len > 0;
        for (pending.items) |call| {
            try self.append(.{
                .role = .tool_result,
                .content = &.{.{ .text = "Interrupted tool call: execution outcome is unknown. This tool was not replayed. Inspect the affected state before retrying any external effect." }},
                .tool_call_id = call.id,
                .tool_name = call.name,
                .is_error = true,
            });
            try self.notifyCommit(sink);
        }
        self.unresolved_tools = false;
    }
    pub fn prompt(self: *Agent, text: []const u8, sink: Sink) !void {
        if (self.running) return error.AgentBusy;
        if (self.max_turns == 0) return error.InvalidTurnLimit;
        if (self.commit_failed) return error.SessionCommitFailed;
        if (self.unresolved_tools) return error.UnresolvedToolCalls;
        self.running = true;
        defer self.running = false;
        try self.append(.{ .role = .user, .content = &.{.{ .text = text }} });
        try self.notifyCommit(sink);
        const definitions = try self.allocator.alloc(model.ToolDefinition, self.tools.len);
        defer self.allocator.free(definitions);
        for (self.tools, definitions) |tool, *definition| definition.* = tool.definition;
        var overflow_recovered = false;
        for (0..self.max_turns) |_| {
            if (self.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
            if (self.compaction_hook) |hook| {
                if (hook.before_turn) |prepare| try prepare(hook.context);
            }
            var turn_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer turn_arena.deinit();
            const turn_alloc = turn_arena.allocator();
            var collected = Collector{ .allocator = turn_alloc, .sink = sink };
            self.callProviderWithRetry(turn_alloc, definitions, &collected, sink) catch |err| {
                const hint = self.provider.retryHint(err);
                if (!overflow_recovered and hint != null and hint.?.context_overflow and self.compaction_hook != null and self.compaction_hook.?.recover_overflow != null) {
                    if (try self.compaction_hook.?.recover_overflow.?(self.compaction_hook.?.context)) {
                        overflow_recovered = true;
                        collected = .{ .allocator = turn_alloc, .sink = sink };
                        try self.callProviderWithRetry(turn_alloc, definitions, &collected, sink);
                    } else return err;
                } else return err;
            };
            var reason = collected.reason orelse return error.MissingProviderCompletion;
            if (reason == .length and collected.text.items.len == 0 and collected.calls.items.len == 0 and !overflow_recovered) {
                if (self.compaction_hook) |hook| {
                    if (hook.recover_overflow) |recover| {
                        if (try recover(hook.context)) {
                            overflow_recovered = true;
                            collected = .{ .allocator = turn_alloc, .sink = sink };
                            try self.callProviderWithRetry(turn_alloc, definitions, &collected, sink);
                            reason = collected.reason orelse return error.MissingProviderCompletion;
                        }
                    }
                }
            }
            if (reason == .aborted) return error.Canceled;
            if (reason == .error_response) return error.ProviderFailed;
            if (reason == .deferred) return error.DeferredResponseUnsupported;
            if (reason == .length) return error.OutputLimitExceeded;
            if (collected.calls.items.len > 0 and reason != .tool_use) return error.InvalidProviderCompletion;
            if (reason == .tool_use and collected.calls.items.len == 0) return error.MissingToolCalls;
            var content: std.ArrayList(model.Content) = .empty;
            if (collected.text.items.len > 0) try content.append(turn_alloc, .{ .text = collected.text.items });
            for (collected.calls.items) |call| try content.append(turn_alloc, .{ .tool_call = call });
            try self.append(.{ .role = .assistant, .content = content.items });
            if (reason == .tool_use) self.unresolved_tools = true;
            try self.notifyCommit(sink);
            if (reason == .stop) {
                try sink.emit(sink.context, .settled);
                return;
            }
            for (collected.calls.items) |call| {
                if (self.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
                try sink.emit(sink.context, .{ .tool_start = call });
                const result = try self.executeTool(call, turn_alloc, sink);
                try self.append(.{
                    .role = .tool_result,
                    .content = &.{.{ .text = result.text }},
                    .tool_call_id = call.id,
                    .tool_name = call.name,
                    .is_error = result.is_error,
                    .details = result.details,
                });
                try self.notifyCommit(sink);
                try sink.emit(sink.context, .{ .tool_end = .{ .call = call, .result = result } });
            }
            self.unresolved_tools = false;
        }
        return error.TurnLimitExceeded;
    }

    fn callProviderWithRetry(self: *Agent, turn_alloc: std.mem.Allocator, definitions: []const model.ToolDefinition, collected: *Collector, sink: Sink) !void {
        var attempt: u8 = 0;
        while (true) {
            if (self.cancel) |cancel| if (cancel.isCanceled()) {
                if (attempt > 0) sink.emit(sink.context, .{ .retry_finished = .{ .success = false, .attempt = attempt, .error_code = "Canceled" } }) catch {};
                return error.Canceled;
            };
            self.provider.run(self.allocator, self.messages.items, definitions, .{ .context = collected, .emit = Collector.emit }) catch |err| {
                if (err == error.Canceled or err == error.OutOfMemory) {
                    if (attempt > 0) sink.emit(sink.context, .{ .retry_finished = .{ .success = false, .attempt = attempt, .error_code = @errorName(err) } }) catch {};
                    return err;
                }
                const hint = self.provider.retryHint(err);
                const can_retry = self.retry.enabled and
                    attempt < self.retry.max_retries and
                    collected.text.items.len == 0 and
                    collected.calls.items.len == 0 and
                    (hint != null and hint.?.retryable);
                if (!can_retry) {
                    if (attempt > 0) sink.emit(sink.context, .{ .retry_finished = .{ .success = false, .attempt = attempt, .error_code = @errorName(err) } }) catch {};
                    return err;
                }
                const shift: u6 = @intCast(@min(attempt, 30));
                const exp_delay = std.math.mul(u64, self.retry.base_delay_ms, @as(u64, 1) << shift) catch self.retry.max_delay_ms;
                const delay_ms = @min(self.retry.max_delay_ms, @max(hint.?.retry_after_ms orelse 0, exp_delay));
                attempt += 1;
                try sink.emit(sink.context, .{ .retry_scheduled = .{
                    .attempt = attempt,
                    .max_attempts = self.retry.max_retries,
                    .delay_ms = delay_ms,
                    .error_code = @errorName(err),
                } });
                sleepCancellable(self.io, delay_ms, self.cancel) catch |sleep_err| {
                    sink.emit(sink.context, .{ .retry_finished = .{ .success = false, .attempt = attempt, .error_code = @errorName(sleep_err) } }) catch {};
                    return sleep_err;
                };
                collected.* = .{ .allocator = turn_alloc, .sink = sink };
                continue;
            };
            if (attempt > 0) {
                try sink.emit(sink.context, .{ .retry_finished = .{ .success = true, .attempt = attempt } });
            }
            return;
        }
    }

    fn sleepCancellable(io: std.Io, delay_ms: u64, cancel_opt: ?model.Cancel) !void {
        if (delay_ms == 0) return;
        const cancel = cancel_opt orelse {
            io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch return error.Canceled;
            return;
        };
        if (cancel.isCanceled()) return error.Canceled;
        const Completion = union(enum) { timer: std.Io.Cancelable!void, cancel: std.Io.Cancelable!void };
        var storage: [2]Completion = undefined;
        var select = std.Io.Select(Completion).init(io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.timer, waitDelay, .{ io, delay_ms });
        try select.concurrent(.cancel, waitCancel, .{ cancel, io });
        switch (try select.await()) {
            .timer => |res| try res,
            .cancel => |res| {
                try res;
                return error.Canceled;
            },
        }
    }

    fn waitDelay(io: std.Io, delay_ms: u64) std.Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
    }

    fn waitCancel(cancel: model.Cancel, io: std.Io) std.Io.Cancelable!void {
        try cancel.wait(io);
    }
    fn notifyCommit(self: *Agent, sink: Sink) !void {
        sink.emit(sink.context, .{ .message_appended = self.messages.items[self.messages.items.len - 1] }) catch |err| {
            self.commit_failed = true;
            return err;
        };
    }
    const Update = struct {
        call: model.ToolCall,
        sink: Sink,
        failure: ?anyerror = null,
        fn emit(context: ?*anyopaque, result: ToolResult) anyerror!void {
            const self: *Update = @ptrCast(@alignCast(context.?));
            self.sink.emit(self.sink.context, .{ .tool_update = .{ .call = self.call, .result = result } }) catch |err| {
                self.failure = err;
                return err;
            };
        }
    };
    fn executeTool(self: *Agent, call: model.ToolCall, allocator: std.mem.Allocator, sink: Sink) !ToolResult {
        for (self.tools) |tool| {
            if (!std.mem.eql(u8, call.name, tool.definition.name)) continue;
            var update = Update{ .call = call, .sink = sink };
            const result = tool.execute(tool.context, .{ .allocator = allocator, .io = self.io, .cwd = self.cwd, .call_id = call.id, .cancel = self.cancel, .update_context = &update, .on_update = Update.emit }, call.arguments) catch |err| {
                if (update.failure) |failure| return failure;
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                return .{ .text = try std.fmt.allocPrint(allocator, "Tool failed: {s}", .{@errorName(err)}), .is_error = true };
            };
            if (update.failure) |failure| return failure;
            return result;
        }
        return .{ .text = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{call.name}), .is_error = true };
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    text: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(model.ToolCall) = .empty,
    reason: ?model.StopReason = null,
    fn emit(context: *anyopaque, event: model.Event) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        if (self.reason != null) return error.EventAfterCompletion;
        switch (event) {
            .text_delta => |text| try self.text.appendSlice(self.allocator, text),
            .tool_call_end => |completed| {
                for (self.calls.items) |call| if (std.mem.eql(u8, call.id, completed.call.id)) return error.DuplicateToolCall;
                try self.calls.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, completed.call.id),
                    .name = try self.allocator.dupe(u8, completed.call.name),
                    .arguments = try cloneValue(self.allocator, completed.call.arguments, 0),
                });
            },
            .done => |reason| self.reason = reason,
            else => {},
        }
        try self.sink.emit(self.sink.context, .{ .provider = event });
    }
};

pub fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value, depth: usize) error{ OutOfMemory, ValueTooDeep }!std.json.Value {
    if (depth > 64) return error.ValueTooDeep;
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var result = std.json.Array.init(allocator);
            for (array.items) |item| try result.append(try cloneValue(allocator, item, depth + 1));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result: std.json.ObjectMap = .empty;
            var iter = object.iterator();
            while (iter.next()) |entry| try result.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneValue(allocator, entry.value_ptr.*, depth + 1));
            break :blk .{ .object = result };
        },
        else => value,
    };
}

pub fn cloneMessage(allocator: std.mem.Allocator, message: model.Message) !model.Message {
    const content = try allocator.alloc(model.Content, message.content.len);
    for (message.content, content) |part, *owned| owned.* = switch (part) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .thinking => |thinking| .{ .thinking = .{ .text = try allocator.dupe(u8, thinking.text), .signature = if (thinking.signature) |s| try allocator.dupe(u8, s) else null } },
        .image => |image| .{ .image = .{ .bytes = try allocator.dupe(u8, image.bytes), .mime_type = try allocator.dupe(u8, image.mime_type) } },
        .tool_call => |call| .{ .tool_call = .{ .id = try allocator.dupe(u8, call.id), .name = try allocator.dupe(u8, call.name), .arguments = try cloneValue(allocator, call.arguments, 0) } },
    };
    return .{
        .role = message.role,
        .content = content,
        .tool_call_id = if (message.tool_call_id) |id| try allocator.dupe(u8, id) else null,
        .tool_name = if (message.tool_name) |name| try allocator.dupe(u8, name) else null,
        .is_error = message.is_error,
        .details = if (message.details) |value| try cloneValue(allocator, value, 0) else null,
        .system_prompt_replace = message.system_prompt_replace,
    };
}
