//! Agent adapter for explicitly loaded trusted native tools. Metadata is copied
//! into the invocation arena. Modules and retained operations outlive the agent.
const std = @import("std");
const agent = @import("agent");
const runtime = @import("native_runtime");
const json = @import("native_json");

pub const Entry = struct {
    module: *runtime.Module,
    index: u32,
    timeout_ms: u32 = 30000,
    drain_ms: u32 = 1000,
    poll_interval_ms: u32 = 10,
    unavailable: bool = false,
    retained_operation: ?*runtime.Operation = null,

    /// Retry cooperative cleanup without executing the tool again. The module
    /// stays pinned until this confirms a terminal state and destroys the handle.
    pub fn drainRetained(self: *Entry, io: std.Io) !void {
        const operation = self.retained_operation orelse return;
        if (!operation.terminal) self.drain(io, operation);
        try operation.destroy();
        std.heap.page_allocator.destroy(operation);
        self.retained_operation = null;
        self.unavailable = false;
    }

    pub fn execute(context: ?*anyopaque, ctx: agent.ToolContext, arguments: std.json.Value) anyerror!agent.ToolResult {
        const self: *Entry = @ptrCast(@alignCast(context.?));
        if (self.unavailable) return error.Canceled;
        if (arguments != .object) return error.ExpectedObject;
        // The plugin must copy all borrowed inputs it needs before start returns.
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const input = try json.fromJson(arena.allocator(), arguments, .{});
        // An undrained operation is intentionally retained past the turn arena.
        const operation = try std.heap.page_allocator.create(runtime.Operation);
        operation.* = self.module.start(self.index, .{
            .call_id = runtime.span(ctx.call_id),
            .cwd = runtime.span(ctx.cwd),
            .arguments = input,
        }) catch |err| {
            std.heap.page_allocator.destroy(operation);
            return err;
        };
        defer {
            if (!operation.terminal) self.drain(ctx.io, operation);
            if (operation.destroy()) |_| {
                std.heap.page_allocator.destroy(operation);
            } else |_| {
                // Retain the handle and module to process exit. Never unload
                // code or free a handle on an unconfirmed cancellation.
                self.unavailable = true;
                self.retained_operation = operation;
            }
        }
        const started = std.Io.Timestamp.now(ctx.io, .awake);
        var updates: usize = 0;
        var update_bytes: usize = 0;
        while (true) {
            if (ctx.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
            if (started.untilNow(ctx.io, .awake).toMilliseconds() >= self.timeout_ms) return error.Canceled;
            var output = operation.poll() catch return error.Canceled;
            defer output.release();
            switch (output.state) {
                runtime.pending => {},
                runtime.progress => {
                    updates += 1;
                    if (updates > 1024) return error.Canceled;
                    // Updates are callback-borrowed. Reclaim each conversion
                    // independently of the agent's longer-lived turn arena.
                    var update_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer update_arena.deinit();
                    const update = decode(update_arena.allocator(), output.owned.value, false) catch return error.Canceled;
                    update_bytes += update.text.len;
                    if (update_bytes > 1024 * 1024) return error.Canceled;
                    if (ctx.on_update) |emit| emit(ctx.update_context, update) catch return error.Canceled;
                },
                runtime.complete, runtime.failed => return decode(ctx.allocator, output.owned.value, output.state == runtime.failed),
                runtime.canceled => return error.Canceled,
                else => unreachable,
            }
            output.release();
            if (ctx.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
            try ctx.io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake);
        }
    }
    fn drain(self: *Entry, io: std.Io, operation: *runtime.Operation) void {
        operation.cancel() catch return;
        const started = std.Io.Timestamp.now(io, .awake);
        // Cleanup must still run if the calling task was canceled.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        while (started.untilNow(io, .awake).toMilliseconds() < self.drain_ms) {
            var output = operation.poll() catch return;
            output.release();
            if (operation.terminal) return;
            io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake) catch return;
        }
    }
};
fn decode(a: std.mem.Allocator, value: @import("native_plugin").Value, failed: bool) !agent.ToolResult {
    const converted = try json.toJson(a, value, .{ .max_bytes = 50 * 1024 });
    const text = if (converted == .string) converted.string else try std.json.Stringify.valueAlloc(a, converted, .{});
    if (text.len > 50 * 1024) return error.NativeToolOutputTooLarge;
    return .{ .text = text, .is_error = failed, .details = converted };
}

/// Duplicate tool names are rejected before any model request. This adapter
/// intentionally adds tools; replacement policies remain a separate feature.
pub fn combine(a: std.mem.Allocator, module: *runtime.Module, existing: []const agent.Tool) ![]agent.Tool {
    var tools: std.ArrayList(agent.Tool) = .empty;
    try tools.appendSlice(a, existing);
    const count = try module.toolCount();
    for (0..count) |index| {
        const spec = try module.toolAt(@intCast(index));
        const name = try runtime.spanText(spec.name, 64);
        for (tools.items) |tool| if (std.mem.eql(u8, tool.definition.name, name)) return error.DuplicateNativeTool;
        const entry = try a.create(Entry);
        entry.* = .{ .module = module, .index = @intCast(index) };
        try tools.append(a, .{
            .context = entry,
            .execute = Entry.execute,
            .definition = .{
                .name = try a.dupe(u8, name),
                .description = try a.dupe(u8, try runtime.spanText(spec.description, 16384)),
                .parameters = try json.toJson(a, spec.parameters, .{}),
            },
        });
    }
    return tools.toOwnedSlice(a);
}
