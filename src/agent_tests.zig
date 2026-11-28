const std = @import("std");
const model = @import("model");
const agent = @import("agent");
const security = @import("security");

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

const AuthorizationCapture = struct {
    policy: security.Policy,
    calls: usize = 0,
    fn authorize(context: ?*anyopaque, tool: agent.Tool, tool_context: agent.ToolContext, _: std.json.Value, authorization: *?security.Authorization) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        const request: security.Request = .{
            .capability = tool.capability orelse return error.UnclassifiedTool,
            .source = tool.source,
            .target = .{ .kind = if (tool.capability == .filesystem_write) .path else .request, .value = if (tool.capability == .filesystem_write) tool_context.cwd else null },
        };
        const result = security.evaluate(self.policy, request);
        authorization.* = .{ .request = request, .result = result, .event_id = 1 };
        if (!result.allowed()) return error.CapabilityDenied;
    }
    fn audit(_: ?*anyopaque, _: agent.Tool, _: ?security.Authorization, _: security.Outcome) anyerror!void {
        return error.UnexpectedOperationAudit;
    }
};

test "secure policy denies a tool before its handler runs" {
    const OneCall = struct {
        calls: usize = 0,
        fn run(context: *anyopaque, allocator: std.mem.Allocator, _: []const model.Message, _: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) {
                const args = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
                defer args.deinit();
                try sink.emit(sink.context, .start);
                try sink.emit(sink.context, .{ .tool_call_end = .{ .index = 0, .call = .{ .id = "c1", .name = "write", .arguments = args.value } } });
                try sink.emit(sink.context, .{ .done = .tool_use });
            } else {
                try sink.emit(sink.context, .start);
                try sink.emit(sink.context, .{ .text_delta = "denied" });
                try sink.emit(sink.context, .{ .done = .stop });
            }
        }
    };
    var executed: usize = 0;
    const Handler = struct {
        fn run(context: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
            return .{ .text = "unexpected" };
        }
    };
    const tools = [_]agent.Tool{.{
        .definition = .{ .name = "write", .description = "write", .parameters = .null },
        .capability = .filesystem_write,
        .context = &executed,
        .execute = Handler.run,
    }};
    var auth = AuthorizationCapture{ .policy = .{ .mode = .secure } };
    var fake: OneCall = .{};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake, .run_fn = OneCall.run }, &tools, "/tmp");
    defer runtime.deinit();
    runtime.security_context = &auth;
    runtime.authorize_tool = AuthorizationCapture.authorize;
    runtime.audit_tool_outcome = AuthorizationCapture.audit;
    var events: Events = .{};
    try runtime.prompt("run write", .{ .context = &events, .emit = Events.emit });
    try std.testing.expectEqual(@as(usize, 1), auth.calls);
    try std.testing.expectEqual(@as(usize, 0), executed);
    try std.testing.expect(runtime.messages.items[2].is_error);
    try std.testing.expectEqualStrings("Capability denied by security policy.", runtime.messages.items[2].content[0].text);
    // Structured denial details expose redacted machine-readable metadata.
    const details = runtime.messages.items[2].details.?.object;
    try std.testing.expectEqualStrings("authorization_denied", details.get("type").?.string);
    try std.testing.expectEqualStrings("CapabilityDenied", details.get("code").?.string);
    try std.testing.expectEqualStrings("filesystem.write", details.get("capability").?.string);
    try std.testing.expectEqualStrings("path", details.get("targetKind").?.string);
    try std.testing.expectEqualStrings("validation", details.get("policySource").?.string);
    try std.testing.expectEqualStrings("missing-grant", details.get("reason").?.string);

    // Fail-stop mode immediately aborts the turn on the first denial.
    var auth_stop = AuthorizationCapture{ .policy = .{ .mode = .secure } };
    var fake_stop: OneCall = .{};
    var stop_runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake_stop, .run_fn = OneCall.run }, &tools, "/tmp");
    defer stop_runtime.deinit();
    stop_runtime.security_context = &auth_stop;
    stop_runtime.authorize_tool = AuthorizationCapture.authorize;
    stop_runtime.audit_tool_outcome = AuthorizationCapture.audit;
    stop_runtime.fail_stop_on_denial = true;
    var stop_events: Events = .{};
    try std.testing.expectError(error.CapabilityDenied, stop_runtime.prompt("run write", .{ .context = &stop_events, .emit = Events.emit }));
    try std.testing.expectEqual(@as(usize, 1), fake_stop.calls);
    try std.testing.expectEqual(@as(usize, 0), executed);
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

test "agent retries transient errors with backoff respects partial-output safety and cancels during sleep" {
    const RetryFake = struct {
        attempts: usize = 0,
        fail_count: usize = 2,
        emit_partial_before_fail: bool = false,
        retryable: bool = true,
        retry_after_ms: ?u64 = 15,

        fn run(context: *anyopaque, _: std.mem.Allocator, _: []const model.Message, _: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.attempts += 1;
            if (self.attempts <= self.fail_count) {
                if (self.emit_partial_before_fail) {
                    try sink.emit(sink.context, .start);
                    try sink.emit(sink.context, .{ .text_delta = "partial" });
                }
                return error.HttpRequestFailed;
            }
            try sink.emit(sink.context, .start);
            try sink.emit(sink.context, .{ .text_delta = "ok" });
            try sink.emit(sink.context, .{ .done = .stop });
        }

        fn hint(context: *anyopaque, err: anyerror) ?model.RetryHint {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (err == error.HttpRequestFailed) return .{ .retryable = self.retryable, .retry_after_ms = self.retry_after_ms };
            return null;
        }
    };
    const RetryCapture = struct {
        scheduled: usize = 0,
        finished_ok: usize = 0,
        finished_fail: usize = 0,
        last_delay: u64 = 0,

        fn emit(context: *anyopaque, event: agent.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .retry_scheduled => |r| {
                    self.scheduled += 1;
                    self.last_delay = r.delay_ms;
                },
                .retry_finished => |r| {
                    if (r.success) self.finished_ok += 1 else self.finished_fail += 1;
                },
                else => {},
            }
        }
    };

    // 1. Retries transient failures and succeeds on attempt 3.
    var fake = RetryFake{};
    var runtime = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &fake, .run_fn = RetryFake.run, .retry_info_fn = RetryFake.hint }, &.{}, "/tmp");
    defer runtime.deinit();
    runtime.retry = .{ .enabled = true, .max_retries = 3, .base_delay_ms = 5, .max_delay_ms = 100 };
    var cap = RetryCapture{};
    try runtime.prompt("retry-ok", .{ .context = &cap, .emit = RetryCapture.emit });
    try std.testing.expectEqual(@as(usize, 3), fake.attempts);
    try std.testing.expectEqual(@as(usize, 2), cap.scheduled);
    try std.testing.expectEqual(@as(usize, 1), cap.finished_ok);
    try std.testing.expectEqual(@as(u64, 15), cap.last_delay);

    // 2. Non-retryable error fails fast without sleeping.
    var non_retry = RetryFake{ .retryable = false, .fail_count = 5 };
    var rt2 = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &non_retry, .run_fn = RetryFake.run, .retry_info_fn = RetryFake.hint }, &.{}, "/tmp");
    defer rt2.deinit();
    var cap2 = RetryCapture{};
    try std.testing.expectError(error.HttpRequestFailed, rt2.prompt("fail-fast", .{ .context = &cap2, .emit = RetryCapture.emit }));
    try std.testing.expectEqual(@as(usize, 1), non_retry.attempts);
    try std.testing.expectEqual(@as(usize, 0), cap2.scheduled);

    // 3. Partial output streamed before failure is never retried (avoids duplicate tokens).
    var partial = RetryFake{ .emit_partial_before_fail = true, .fail_count = 5 };
    var rt3 = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &partial, .run_fn = RetryFake.run, .retry_info_fn = RetryFake.hint }, &.{}, "/tmp");
    defer rt3.deinit();
    var cap3 = RetryCapture{};
    try std.testing.expectError(error.HttpRequestFailed, rt3.prompt("partial-fail", .{ .context = &cap3, .emit = RetryCapture.emit }));
    try std.testing.expectEqual(@as(usize, 1), partial.attempts);
    try std.testing.expectEqual(@as(usize, 0), cap3.scheduled);

    // 4. Cancellation interrupts retry backoff immediately.
    var interrupt = try model.Interrupt.init();
    defer interrupt.deinit(std.testing.io);
    const Trigger = struct {
        target: *model.Interrupt,
        fn run(self: *@This(), io: std.Io) std.Io.Cancelable!void {
            try io.sleep(.fromMilliseconds(40), .awake);
            self.target.trigger();
        }
    };
    var trig = Trigger{ .target = &interrupt };
    var trig_task = try std.Io.concurrent(std.testing.io, Trigger.run, .{ &trig, std.testing.io });
    defer _ = trig_task.cancel(std.testing.io) catch {};
    var sleeping = RetryFake{ .fail_count = 5, .retry_after_ms = 5000 };
    var rt4 = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &sleeping, .run_fn = RetryFake.run, .retry_info_fn = RetryFake.hint }, &.{}, "/tmp");
    defer rt4.deinit();
    rt4.cancel = interrupt.cancel();
    rt4.retry = .{ .enabled = true, .max_retries = 3, .base_delay_ms = 5000, .max_delay_ms = 10_000 };
    var cap4 = RetryCapture{};
    try std.testing.expectError(error.Canceled, rt4.prompt("cancel-sleep", .{ .context = &cap4, .emit = RetryCapture.emit }));
    try trig_task.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), cap4.scheduled);
    try std.testing.expectEqual(@as(usize, 1), cap4.finished_fail);
}

test "agent mid-turn steering skips remaining tools and injects next user turn" {
    const State = struct {
        executed_first: usize = 0,
        executed_second: usize = 0,
        steering_queued: bool = false,
        provider_turns: usize = 0,
    };
    var st = State{};

    const FirstTool = struct {
        fn exec(ctx: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.executed_first += 1;
            s.steering_queued = true;
            return .{ .text = "first ok" };
        }
    };
    const SecondTool = struct {
        fn exec(ctx: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.executed_second += 1;
            return .{ .text = "second unexpected" };
        }
    };
    const SteerHook = struct {
        fn pop(ctx: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (!s.steering_queued) return null;
            s.steering_queued = false;
            return try a.dupe(u8, "steer now");
        }
    };
    const SteerProvider = struct {
        fn run(ctx: *anyopaque, a: std.mem.Allocator, messages: []const model.Message, _: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.provider_turns += 1;
            try sink.emit(sink.context, .start);
            if (s.provider_turns == 1) {
                const args = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
                defer args.deinit();
                try sink.emit(sink.context, .{ .tool_call_end = .{ .index = 0, .call = .{ .id = "t1", .name = "first", .arguments = args.value } } });
                try sink.emit(sink.context, .{ .tool_call_end = .{ .index = 1, .call = .{ .id = "t2", .name = "second", .arguments = args.value } } });
                try sink.emit(sink.context, .{ .done = .tool_use });
                return;
            }
            const last = messages[messages.len - 1];
            try std.testing.expectEqual(model.Role.user, last.role);
            try std.testing.expectEqualStrings("steer now", last.content[0].text);
            try sink.emit(sink.context, .{ .text_delta = "steered reply" });
            try sink.emit(sink.context, .{ .done = .stop });
        }
    };

    const tools = [_]agent.Tool{
        .{ .definition = .{ .name = "first", .description = "first", .parameters = .null }, .context = &st, .execute = FirstTool.exec },
        .{ .definition = .{ .name = "second", .description = "second", .parameters = .null }, .context = &st, .execute = SecondTool.exec },
    };
    var rt = agent.Agent.init(std.testing.allocator, std.testing.io, .{ .context = &st, .run_fn = SteerProvider.run }, &tools, "/tmp");
    defer rt.deinit();
    rt.steering_hook = .{ .context = &st, .pop_steering = SteerHook.pop };
    var events = Events{};
    try rt.prompt("initial", .{ .context = &events, .emit = Events.emit });

    try std.testing.expectEqual(@as(usize, 1), st.executed_first);
    try std.testing.expectEqual(@as(usize, 0), st.executed_second);
    try std.testing.expectEqual(@as(usize, 2), st.provider_turns);
    try std.testing.expectEqual(@as(usize, 1), events.settled);
    try std.testing.expect(!rt.unresolved_tools);
    try std.testing.expectEqualStrings("first ok", rt.messages.items[2].content[0].text);
    try std.testing.expect(!rt.messages.items[2].is_error);
    try std.testing.expectEqualStrings("Skipped due to queued user message.", rt.messages.items[3].content[0].text);
    try std.testing.expect(rt.messages.items[3].is_error);
    try std.testing.expectEqualStrings("steer now", rt.messages.items[4].content[0].text);
    try std.testing.expectEqualStrings("steered reply", rt.messages.items[5].content[0].text);
}
