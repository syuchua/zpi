const std = @import("std");
const model = @import("model");
const agent = @import("agent");

const Fake = struct {
    turn: usize = 0,
    fn run(context: *anyopaque, allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (tools.len != 1 or !std.mem.eql(u8, tools[0].name, "write")) return error.BadToolDefinitions;
        if (messages[messages.len - 1].role != .user and messages[messages.len - 1].role != .tool_result) return error.BadContext;
        if (self.turn == 0) {
            try sink.emit(sink.context, .start);
            const args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"out.txt\",\"text\":\"done\"}", .{});
            defer args.deinit();
            try sink.emit(sink.context, .{ .tool_call_end = .{ .index = 0, .call = .{ .id = "c1", .name = "write", .arguments = args.value } } });
            try sink.emit(sink.context, .{ .done = .tool_use });
        } else {
            try sink.emit(sink.context, .start);
            try sink.emit(sink.context, .{ .text_delta = "Finished" });
            try sink.emit(sink.context, .{ .done = .stop });
        }
        self.turn += 1;
    }
};

const WriterTool = struct {
    executed: bool = false,
    fn execute(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
        const self: *WriterTool = @ptrCast(@alignCast(context.?));
        if (ctx.on_update) |emit| try emit(ctx.update_context, .{ .text = "writing" });
        try std.testing.expectEqualStrings("out.txt", args.object.get("path").?.string);
        try std.testing.expectEqualStrings("done", args.object.get("text").?.string);
        self.executed = true;
        return .{ .text = "wrote" };
    }
};

const Events = struct {
    tool_starts: usize = 0,
    tool_ends: usize = 0,
    tool_updates: usize = 0,
    settled: usize = 0,
    fn emit(context: *anyopaque, event: agent.Event) anyerror!void {
        const self: *Events = @ptrCast(@alignCast(context));
        switch (event) {
            .tool_start => self.tool_starts += 1,
            .tool_end => self.tool_ends += 1,
            .tool_update => self.tool_updates += 1,
            .settled => self.settled += 1,
            else => {},
        }
    }
};

test "agent owns prompt, executes tools, persists results in context and settles" {
    var fake: Fake = .{};
    var writer: WriterTool = .{};
    const tools = [_]agent.Tool{.{
        .definition = .{ .name = "write", .description = "write", .parameters = .null },
        .context = &writer,
        .execute = WriterTool.execute,
    }};
    const provider = model.Provider{ .context = &fake, .run_fn = Fake.run };
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, provider, &tools, "/tmp");
    defer runtime.deinit();
    var events: Events = .{};
    try runtime.prompt("write the file", .{ .context = &events, .emit = Events.emit });
    try std.testing.expect(writer.executed);
    try std.testing.expectEqual(@as(usize, 1), events.tool_starts);
    try std.testing.expectEqual(@as(usize, 1), events.tool_ends);
    try std.testing.expectEqual(@as(usize, 1), events.tool_updates);
    try std.testing.expectEqual(@as(usize, 1), events.settled);
    try std.testing.expectEqual(@as(usize, 4), runtime.messages.items.len);
    try std.testing.expectEqualStrings("write", runtime.messages.items[1].content[0].tool_call.name);
    try std.testing.expectEqualStrings("wrote", runtime.messages.items[2].content[0].text);
    try std.testing.expectEqualStrings("Finished", runtime.messages.items[3].content[0].text);
}

test "failed provider completion does not execute partial tool calls" {
    const FailedProvider = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const model.Message, _: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
            const args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"forbidden\"}", .{});
            defer args.deinit();
            try sink.emit(sink.context, .start);
            try sink.emit(sink.context, .{ .tool_call_end = .{ .index = 0, .call = .{ .id = "failed-call", .name = "write", .arguments = args.value } } });
            try sink.emit(sink.context, .{ .done = .error_response });
        }
    };
    var executed: usize = 0;
    const Tool = struct {
        fn execute(context: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
            return .{ .text = "unexpected" };
        }
    };
    const tools = [_]agent.Tool{.{
        .definition = .{ .name = "write", .description = "fixture", .parameters = .null },
        .context = &executed,
        .execute = Tool.execute,
    }};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = undefined, .run_fn = FailedProvider.run }, &tools, "/tmp");
    defer runtime.deinit();
    var events: Events = .{};
    try std.testing.expectError(error.ProviderFailed, runtime.prompt("filtered", .{ .context = &events, .emit = Events.emit }));
    try std.testing.expectEqual(@as(usize, 0), executed);
    try std.testing.expectEqual(@as(usize, 1), runtime.messages.items.len);
    try std.testing.expectEqual(model.Role.user, runtime.messages.items[0].role);
    try std.testing.expectEqual(@as(usize, 0), events.tool_starts);
}

test "agent cancellation clears running state and permits a follow-up prompt" {
    const CancelProvider = struct {
        calls: usize = 0,
        fn run(context: *anyopaque, _: std.mem.Allocator, _: []const model.Message, _: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) return error.Canceled;
            try sink.emit(sink.context, .start);
            try sink.emit(sink.context, .{ .text_delta = "recovered" });
            try sink.emit(sink.context, .{ .done = .stop });
        }
    };
    var provider: CancelProvider = .{};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &provider, .run_fn = CancelProvider.run }, &.{}, "/tmp");
    defer runtime.deinit();
    var events: Events = .{};
    try std.testing.expectError(error.Canceled, runtime.prompt("first", .{ .context = &events, .emit = Events.emit }));
    try std.testing.expect(!runtime.running);
    try runtime.prompt("second", .{ .context = &events, .emit = Events.emit });
    try std.testing.expectEqualStrings("second", runtime.messages.items[1].content[0].text);
}

test "interrupted tool effects are reconciled without executing them again" {
    const InterruptedTool = struct {
        executions: usize = 0,
        fn execute(context: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.executions += 1;
            return error.Canceled;
        }
    };
    var fake: Fake = .{};
    var interrupted: InterruptedTool = .{};
    const tools = [_]agent.Tool{.{
        .definition = .{ .name = "write", .description = "fixture", .parameters = .null },
        .context = &interrupted,
        .execute = InterruptedTool.execute,
    }};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake, .run_fn = Fake.run }, &tools, "/tmp");
    defer runtime.deinit();
    var events: Events = .{};
    const sink = agent.Sink{ .context = &events, .emit = Events.emit };
    try std.testing.expectError(error.Canceled, runtime.prompt("perform effect", sink));
    try std.testing.expect(runtime.unresolved_tools);
    try std.testing.expectError(error.UnresolvedToolCalls, runtime.prompt("retry", sink));
    try runtime.reconcile(sink);
    try runtime.reconcile(sink);
    try std.testing.expectEqual(@as(usize, 1), interrupted.executions);
    try std.testing.expectEqual(@as(usize, 3), runtime.messages.items.len);
    const recovered = runtime.messages.items[2];
    try std.testing.expectEqual(model.Role.tool_result, recovered.role);
    try std.testing.expect(recovered.is_error);
    try std.testing.expect(std.mem.indexOf(u8, recovered.content[0].text, "outcome is unknown") != null);
    try runtime.prompt("inspect and continue", sink);
    try std.testing.expectEqual(@as(usize, 1), interrupted.executions);
    try std.testing.expectEqualStrings("Finished", runtime.messages.items[4].content[0].text);
}

test "tool update sink failure stops execution instead of becoming a successful tool result" {
    const Sink = struct {
        fn emit(_: *anyopaque, event: agent.Event) anyerror!void {
            if (event == .tool_update) return error.OutputClosed;
        }
    };
    var fake: Fake = .{};
    var writer: WriterTool = .{};
    const tools = [_]agent.Tool{.{
        .definition = .{ .name = "write", .description = "fixture", .parameters = .null },
        .context = &writer,
        .execute = WriterTool.execute,
    }};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake, .run_fn = Fake.run }, &tools, "/tmp");
    defer runtime.deinit();
    try std.testing.expectError(error.OutputClosed, runtime.prompt("fail update", .{ .context = &fake, .emit = Sink.emit }));
    try std.testing.expect(runtime.unresolved_tools);
    try std.testing.expectEqual(@as(usize, 2), runtime.messages.items.len);
    try std.testing.expect(!writer.executed);
}

test "commit failure stops the agent before a provider call or external effect" {
    const BrokenSink = struct {
        fn emit(_: *anyopaque, event: agent.Event) anyerror!void {
            if (event == .message_appended) return error.DiskFull;
        }
    };
    var fake: Fake = .{};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake, .run_fn = Fake.run }, &.{}, "/tmp");
    defer runtime.deinit();
    const sink = agent.Sink{ .context = &fake, .emit = BrokenSink.emit };
    try std.testing.expectError(error.DiskFull, runtime.prompt("first", sink));
    try std.testing.expect(runtime.commit_failed);
    try std.testing.expectEqual(@as(usize, 0), fake.turn);
    try std.testing.expectError(error.SessionCommitFailed, runtime.prompt("second", sink));
    try std.testing.expectError(error.SessionCommitFailed, runtime.reconcile(sink));
}

test "agent turn limit stops a provider that keeps asking for tools" {
    var fake: Fake = .{};
    var writer: WriterTool = .{};
    const tools = [_]agent.Tool{.{
        .definition = .{ .name = "write", .description = "fixture", .parameters = .null },
        .context = &writer,
        .execute = WriterTool.execute,
    }};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake, .run_fn = Fake.run }, &tools, "/tmp");
    defer runtime.deinit();
    runtime.max_turns = 1;
    var events: Events = .{};
    try std.testing.expectError(error.TurnLimitExceeded, runtime.prompt("bounded", .{ .context = &events, .emit = Events.emit }));
    try std.testing.expectEqual(@as(usize, 1), fake.turn);
    try std.testing.expectEqual(@as(usize, 1), events.tool_ends);
    try std.testing.expectEqual(@as(usize, 0), events.settled);
    try std.testing.expect(!runtime.unresolved_tools);
}

test "agent rejects a zero turn limit before calling the provider" {
    var fake: Fake = .{};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake, .run_fn = Fake.run }, &.{}, "/tmp");
    defer runtime.deinit();
    runtime.max_turns = 0;
    try std.testing.expectError(error.InvalidTurnLimit, runtime.prompt("x", .{ .context = undefined, .emit = Events.emit }));
}

test "agent cancellation between tools stops remaining calls and reconciles unknown outcome" {
    var interrupt = try model.Interrupt.init();
    defer interrupt.deinit(std.testing.io);
    const TwoToolProvider = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const model.Message, _: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
            const args = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
            defer args.deinit();
            try sink.emit(sink.context, .start);
            try sink.emit(sink.context, .{ .tool_call_end = .{ .index = 0, .call = .{ .id = "c1", .name = "first", .arguments = args.value } } });
            try sink.emit(sink.context, .{ .tool_call_end = .{ .index = 1, .call = .{ .id = "c2", .name = "second", .arguments = args.value } } });
            try sink.emit(sink.context, .{ .done = .tool_use });
        }
    };
    const FirstTool = struct {
        fn execute(context: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
            const target: *model.Interrupt = @ptrCast(@alignCast(context.?));
            target.trigger();
            return .{ .text = "first done" };
        }
    };
    const SecondTool = struct {
        fn execute(context: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
            const executed: *bool = @ptrCast(@alignCast(context.?));
            executed.* = true;
            return .{ .text = "second done" };
        }
    };
    var second_executed = false;
    const tools = [_]agent.Tool{
        .{ .definition = .{ .name = "first", .description = "first", .parameters = .null }, .context = &interrupt, .execute = FirstTool.execute },
        .{ .definition = .{ .name = "second", .description = "second", .parameters = .null }, .context = &second_executed, .execute = SecondTool.execute },
    };
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = undefined, .run_fn = TwoToolProvider.run }, &tools, "/tmp");
    defer runtime.deinit();
    runtime.cancel = interrupt.cancel();
    var events: Events = .{};
    const sink = agent.Sink{ .context = &events, .emit = Events.emit };
    try std.testing.expectError(error.Canceled, runtime.prompt("run batch", sink));
    try std.testing.expect(!second_executed);
    try std.testing.expect(runtime.unresolved_tools);
    try runtime.reconcile(sink);
    try std.testing.expect(!runtime.unresolved_tools);
    try std.testing.expectEqual(@as(usize, 4), runtime.messages.items.len);
    try std.testing.expectEqualStrings("c2", runtime.messages.items[3].tool_call_id.?);
    try std.testing.expect(runtime.messages.items[3].is_error);
}
