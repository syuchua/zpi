const std = @import("std");
const runtime = @import("native_runtime");
const native = @import("native_plugin");
const fixture = @import("native_fixture");
const native_tools = @import("native_tools");
const agent = @import("agent");

fn openFixture() !runtime.Module {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const selected = std.process.Environ.getPosix(std.testing.environ, "ZPI_NATIVE_FIXTURE") orelse fixture.path;
    const path = try std.fs.path.resolveAlloc(std.testing.allocator, &.{ cwd, selected });
    defer std.testing.allocator.free(path);
    return runtime.Module.open(path);
}

test "native plugin copies callback inputs and pins module until output and operation release" {
    var module = try openFixture();
    defer module.close() catch @panic("fixture left live work");
    const tool = try module.toolAt(0);
    try std.testing.expectEqualStrings("echo_native", try runtime.spanText(tool.name, 64));
    try std.testing.expectEqual(@as(u32, 1), try module.toolCount());
    var id = [_]u8{ 'c', 'a', 'l', 'l' };
    var operation = try module.start(0, .{
        .call_id = runtime.span(&id),
        .cwd = runtime.span("/tmp"),
        .arguments = .{ .tag = @backingInt(native.Tag.object), .flags = 0, .payload = .{ .object = .{ .ptr = null, .len = 0 } } },
    });
    @memset(&id, 'x');
    try std.testing.expectError(error.PluginBusy, module.close());
    try std.testing.expectError(error.PluginBusy, operation.destroy());
    var update = try operation.poll();
    try std.testing.expectEqual(runtime.progress, update.state);
    try std.testing.expectError(error.InvalidPluginOperationState, operation.poll());
    update.release();
    update.release();
    var result = try operation.poll();
    try std.testing.expectEqual(runtime.complete, result.state);
    try std.testing.expectEqualStrings("call", try runtime.spanText(result.owned.value.payload.span, 64));
    try std.testing.expectError(error.PluginBusy, module.close());
    try std.testing.expectError(error.PluginBusy, operation.destroy());
    result.release();
    try operation.destroy();
    try operation.destroy();
    try module.close();
    try std.testing.expectError(error.PluginClosed, module.toolCount());
}

test "native plugin cancellation is idempotent and still requires terminal poll and destruction" {
    var module = try openFixture();
    defer module.close() catch @panic("fixture left live work");
    var operation = try module.start(0, .{
        .call_id = runtime.span("cancel"),
        .cwd = runtime.span("/tmp"),
        .arguments = .{ .tag = @backingInt(native.Tag.null), .flags = 0, .payload = .{ .signed_integer = 0 } },
    });
    try operation.cancel();
    try operation.cancel();
    try std.testing.expectError(error.PluginBusy, operation.destroy());
    var result = try operation.poll();
    try std.testing.expectEqual(runtime.canceled, result.state);
    result.release();
    try operation.destroy();
}

test "native pending failed and malformed terminal results preserve cleanup" {
    var module = try openFixture();
    defer module.close() catch @panic("fixture left live work");
    for ([_][]const u8{ "pending", "fail", "malformed" }) |id| {
        var operation = try module.start(0, .{
            .call_id = runtime.span(id),
            .cwd = runtime.span("/tmp"),
            .arguments = .{ .tag = @backingInt(native.Tag.null), .flags = 0, .payload = .{ .signed_integer = 0 } },
        });
        var first = try operation.poll();
        try std.testing.expectEqual(if (std.mem.eql(u8, id, "pending")) runtime.pending else runtime.progress, first.state);
        first.release();
        if (std.mem.eql(u8, id, "malformed")) {
            try std.testing.expectError(error.InvalidValueTag, operation.poll());
            try std.testing.expect(operation.terminal);
            try std.testing.expectEqual(@as(usize, 0), module.live_outputs);
        } else {
            var result = try operation.poll();
            try std.testing.expectEqual(if (std.mem.eql(u8, id, "fail")) runtime.failed else runtime.complete, result.state);
            result.release();
        }
        try operation.destroy();
    }
    // Fixture shutdown rejects unreleased producer allocations, so this proves
    // that the malformed terminal graph was released on its validation error.
    try module.close();
}

test "native agent adapter copies results emits progress and rejects duplicate names" {
    var module = try openFixture();
    defer module.close() catch @panic("adapter left live work");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try native_tools.combine(a, &module, &.{});
    try std.testing.expectEqual(agent.security.Capability.native_plugin_load, tools[0].capability.?);
    try std.testing.expectEqual(agent.security.Source.native_plugin, tools[0].source);
    const decision = agent.security.evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = .native_plugin_load }} }, .{
        .capability = tools[0].capability.?,
        .source = tools[0].source,
        .target = .{ .kind = .plugin },
    });
    try std.testing.expect(decision.allowed());
    try std.testing.expectError(error.DuplicateNativeTool, native_tools.combine(a, &module, tools));
    const Updates = struct {
        count: usize = 0,
        fn emit(context: ?*anyopaque, _: agent.ToolResult) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
        }
    };
    var updates: Updates = .{};
    const ctx: agent.ToolContext = .{ .allocator = a, .io = std.testing.io, .cwd = "/tmp", .call_id = "adapter-call", .on_update = Updates.emit, .update_context = &updates };
    const result = try tools[0].execute(tools[0].context, ctx, .{ .object = .empty });
    try std.testing.expectEqualStrings("adapter-call", result.text);
    try std.testing.expectEqualStrings("adapter-call", result.details.?.string);
    try std.testing.expectEqual(@as(usize, 1), updates.count);
    try std.testing.expectEqual(@as(usize, 0), module.live_operations);
    try std.testing.expectEqual(@as(usize, 0), module.live_outputs);
    var failed_ctx = ctx;
    failed_ctx.call_id = "fail";
    const failed_result = try tools[0].execute(tools[0].context, failed_ctx, .{ .object = .empty });
    try std.testing.expect(failed_result.is_error);
    const BrokenUpdates = struct {
        fn emit(_: ?*anyopaque, _: agent.ToolResult) anyerror!void {
            return error.BrokenPipe;
        }
    };
    var broken_ctx = ctx;
    broken_ctx.on_update = BrokenUpdates.emit;
    try std.testing.expectError(error.Canceled, tools[0].execute(tools[0].context, broken_ctx, .{ .object = .empty }));
    try std.testing.expectEqual(@as(usize, 0), module.live_operations);
    try std.testing.expectEqual(@as(usize, 0), module.live_outputs);
    // Malformed terminal data is an interrupted call and is never replayed.
    failed_ctx.call_id = "malformed";
    try std.testing.expectError(error.Canceled, tools[0].execute(tools[0].context, failed_ctx, .{ .object = .empty }));
    try module.close();
    // The tool result was copied before producer release and library unload.
    try std.testing.expectEqualStrings("adapter-call", result.text);
}

test "native adapter deadline cancels and drains before freeing the operation" {
    var module = try openFixture();
    defer module.close() catch @panic("deadline left live work");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry: native_tools.Entry = .{ .module = &module, .index = 0, .timeout_ms = 20, .poll_interval_ms = 5 };
    try std.testing.expectError(error.Canceled, native_tools.Entry.execute(&entry, .{ .allocator = a, .io = std.testing.io, .cwd = "/tmp", .call_id = "stall" }, .{ .object = .empty }));
    try std.testing.expect(!entry.unavailable);
    try std.testing.expect(entry.retained_operation == null);
    try std.testing.expectEqual(@as(usize, 0), module.live_operations);
    try std.testing.expectEqual(@as(usize, 0), module.live_outputs);
}

test "an undrained native operation remains pinned and can be drained explicitly later" {
    var module = try openFixture();
    defer module.close() catch @panic("retained operation still live");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry: native_tools.Entry = .{ .module = &module, .index = 0, .timeout_ms = 20, .drain_ms = 0 };
    try std.testing.expectError(error.Canceled, native_tools.Entry.execute(&entry, .{ .allocator = a, .io = std.testing.io, .cwd = "/tmp", .call_id = "stall" }, .{ .object = .empty }));
    try std.testing.expect(entry.unavailable);
    try std.testing.expect(entry.retained_operation != null);
    try std.testing.expectEqual(@as(usize, 1), module.live_operations);
    try std.testing.expectError(error.PluginBusy, module.close());
    try std.testing.expectError(error.Canceled, native_tools.Entry.execute(&entry, .{ .allocator = a, .io = std.testing.io, .cwd = "/tmp", .call_id = "must-not-run" }, .{ .object = .empty }));
    // The fixture only models a pending operation as terminal after cancellation.
    entry.drain_ms = 100;
    try entry.drainRetained(std.testing.io);
    try std.testing.expect(!entry.unavailable);
    try std.testing.expect(entry.retained_operation == null);
    try std.testing.expectEqual(@as(usize, 0), module.live_operations);
    try module.close();
}

test "native descriptor negotiation checks required prefix before callbacks and permits optional tails" {
    var module = try openFixture();
    defer module.close() catch @panic("fixture left live work");
    var table = module.table.*;
    table.abi_major = 99;
    try std.testing.expectError(error.PluginAbiMajorMismatch, runtime.validateTable(&table, 3));
    table = module.table.*;
    table.struct_size = runtime.required_size - 1;
    try std.testing.expectError(error.PluginTableTooShort, runtime.validateTable(&table, 3));
    table = module.table.*;
    table.required_capabilities = 128;
    try std.testing.expectError(error.PluginRequiredCapabilities, runtime.validateTable(&table, 3));
    table = module.table.*;
    table.poll = null;
    try std.testing.expectError(error.PluginMissingCallback, runtime.validateTable(&table, 3));
    table = module.table.*;
    table.struct_size = runtime.required_size;
    table.name = .{ .ptr = null, .len = 999999 };
    try runtime.validateTable(&table, 3);
    table.struct_size = @sizeOf(runtime.Table) + 128;
    table.abi_minor = 10;
    try runtime.validateTable(&table, 3);
}
