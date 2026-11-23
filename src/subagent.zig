//! Bounded native delegation. Each worker owns its Agent, clients and arena.
//! Parent callbacks are serialized because their allocator and TUI are shared.
const std = @import("std");
const agent = @import("zpi").agent;

const max_tasks = 4;
const max_output_bytes = 8 * 1024;
const max_stream_bytes = 128 * 1024;
const max_progress_bytes = 32 * 1024;

pub const Request = struct {
    name: []const u8,
    task: []const u8,
    max_turns: usize = 16,
};

pub const Context = struct {
    parent: *anyopaque,
    run_child: *const fn (*anyopaque, agent.ToolContext, Request, agent.Sink) anyerror![]const u8,
};

pub fn definition(a: std.mem.Allocator, context: *Context) !agent.Tool {
    const schema =
        \\{"type":"object","properties":{"task":{"type":"string","description":"Self-contained task for one child"},"name":{"type":"string"},"tasks":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"object","properties":{"name":{"type":"string"},"task":{"type":"string"}},"required":["task"],"additionalProperties":false}},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":3600},"maxTurns":{"type":"integer","minimum":1,"maximum":32}},"additionalProperties":false}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, schema, .{});
    return .{
        .builtin = true,
        .context = context,
        .definition = .{
            .name = "subagent",
            .description = "Run a self-contained task, or up to 4 independent tasks concurrently, in native child agents. Children inherit current model and system instructions, start fresh conversations, and use eligible parent-enabled native tools. Working directory is shared. Provide task or tasks. Returns bounded named results and live progress. timeoutSeconds applies to the whole batch. Child conversations are in memory.",
            .parameters = parsed.value,
        },
        .execute = execute,
    };
}

const Result = struct {
    name: []const u8,
    status: enum { completed, failed } = .failed,
    text: []const u8 = "",
    error_code: ?[]const u8 = null,
    truncated: bool = false,
};

const Worker = struct {
    batch: *Batch,
    request: Request,
    cancel: *agent.model.Interrupt,
    result: Result,
    output: [max_output_bytes]u8 = undefined,
    streamed: usize = 0,

    fn run(self: *Worker) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var ctx = self.batch.ctx;
        ctx.allocator = arena.allocator();
        ctx.cancel = self.cancel.cancel();
        ctx.on_update = null;
        ctx.update_context = null;
        const text = self.batch.context.run_child(self.batch.context.parent, ctx, self.request, .{
            .context = self,
            .emit = emit,
        }) catch |err| {
            self.result.error_code = @errorName(err);
            return;
        };
        const len = clippedLength(text, self.output.len);
        @memcpy(self.output[0..len], text[0..len]);
        self.result.text = self.output[0..len];
        self.result.truncated = len < text.len;
        self.result.status = .completed;
    }

    fn emit(context: *anyopaque, event: agent.Event) anyerror!void {
        const self: *Worker = @ptrCast(@alignCast(context));
        if (self.batch.cancel.isCanceled()) return error.Canceled;
        switch (event) {
            .provider => |ev| switch (ev) {
                .text_delta => |text| {
                    if (text.len > max_stream_bytes -| self.streamed) return error.SubagentOutputTooLarge;
                    self.streamed += text.len;
                    try self.batch.progress(self.request.name, text);
                },
                else => {},
            },
            .tool_start => |call| try self.batch.progress(self.request.name, call.name),
            else => {},
        }
    }
};

const Batch = struct {
    context: *Context,
    ctx: agent.ToolContext,
    cancel: agent.model.Interrupt,
    done: agent.model.Interrupt,
    child_interrupts: []agent.model.Interrupt,
    timeout_seconds: usize,
    timed_out: bool = false,
    monitor_error: ?anyerror = null,
    progress_error: ?anyerror = null,
    progress_mutex: std.Io.Mutex = .init,
    progress_bytes: usize = 0,

    fn progress(self: *Batch, name: []const u8, text: []const u8) !void {
        const update = self.ctx.on_update orelse return;
        self.progress_mutex.lockUncancelable(self.ctx.io);
        defer self.progress_mutex.unlock(self.ctx.io);
        if (self.progress_error) |err| return err;
        const prefix_bytes = name.len + 3;
        const remaining = max_progress_bytes - self.progress_bytes;
        if (remaining <= prefix_bytes) return;
        const len = clippedLength(text, @min(1024, remaining - prefix_bytes));
        self.progress_bytes += prefix_bytes + len;
        const message = try self.ctx.allocator.print("[{s}] {s}", .{ name, text[0..len] });
        defer self.ctx.allocator.free(message);
        update(self.ctx.update_context, .{ .text = message }) catch |err| {
            self.progress_error = err;
            self.stop();
            return err;
        };
    }

    fn stop(self: *Batch) void {
        self.cancel.trigger();
        for (self.child_interrupts) |*interrupt| interrupt.trigger();
    }

    fn monitor(self: *Batch) void {
        self.watch() catch |err| {
            self.monitor_error = err;
            self.stop();
        };
    }

    fn watch(self: *Batch) !void {
        const Completion = union(enum) { done: std.Io.Cancelable!void, parent: std.Io.Cancelable!void, timer: std.Io.Cancelable!void };
        var storage: [3]Completion = undefined;
        var select = std.Io.Select(Completion).init(self.ctx.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.done, wait, .{ self.done.cancel(), self.ctx.io });
        if (self.ctx.cancel) |parent| try select.concurrent(.parent, wait, .{ parent, self.ctx.io });
        try select.concurrent(.timer, timer, .{ self.ctx.io, self.timeout_seconds });
        switch (try select.await()) {
            .done => |result| try result,
            .parent => |result| {
                try result;
                self.stop();
            },
            .timer => |result| {
                try result;
                self.timed_out = true;
                self.stop();
            },
        }
    }
};

fn wait(cancel: agent.model.Cancel, io: std.Io) std.Io.Cancelable!void {
    try cancel.wait(io);
}

fn timer(io: std.Io, seconds: usize) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(@intCast(seconds)), .awake);
}

fn execute(raw: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try keys(args, &.{ "task", "tasks", "name", "timeoutSeconds", "maxTurns" });
    const max_turns = try number(args, "maxTurns", 16, 32);
    const timeout_seconds = try number(args, "timeoutSeconds", 300, 3600);
    var requests: [max_tasks]Request = undefined;
    var count: usize = 0;
    if (args.object.get("tasks")) |tasks| {
        if (args.object.get("task") != null or args.object.get("name") != null) return error.ConflictingSubagentTasks;
        if (tasks != .array or tasks.array.items.len == 0 or tasks.array.items.len > max_tasks) return error.InvalidSubagentTasks;
        for (tasks.array.items) |item| {
            try keys(item, &.{ "name", "task" });
            requests[count] = try request(item, max_turns);
            count += 1;
        }
    } else {
        requests[0] = try request(args, max_turns);
        count = 1;
    }
    if (ctx.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
    // Each child owns a wake pipe so concurrent provider waiters cannot
    // consume another child's cancellation byte.
    var child_interrupts: [max_tasks]agent.model.Interrupt = undefined;
    var initialized: usize = 0;
    defer for (child_interrupts[0..initialized]) |*interrupt| interrupt.deinit(ctx.io);
    for (child_interrupts[0..count]) |*interrupt| {
        interrupt.* = try agent.model.Interrupt.init();
        initialized += 1;
    }
    var batch: Batch = .{
        .context = context,
        .ctx = ctx,
        .cancel = try agent.model.Interrupt.init(),
        .done = undefined,
        .child_interrupts = child_interrupts[0..count],
        .timeout_seconds = timeout_seconds,
    };
    defer batch.cancel.deinit(ctx.io);
    batch.done = try agent.model.Interrupt.init();
    defer batch.done.deinit(ctx.io);
    const watchdog = try std.Thread.spawn(.{}, Batch.monitor, .{&batch});
    var workers: [max_tasks]Worker = undefined;
    var threads: [max_tasks]std.Thread = undefined;
    var started: usize = 0;
    var joined = false;
    defer {
        if (!joined) {
            batch.stop();
            for (threads[0..started]) |thread| thread.join();
            batch.done.trigger();
            watchdog.join();
        }
    }
    for (requests[0..count], 0..) |req, i| {
        workers[i] = .{ .batch = &batch, .request = req, .cancel = &child_interrupts[i], .result = .{ .name = req.name } };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    batch.done.trigger();
    watchdog.join();
    joined = true;
    if (ctx.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
    if (batch.progress_error) |err| return err;
    if (batch.monitor_error) |err| return err;
    var results: [max_tasks]Result = undefined;
    var failed = batch.timed_out;
    for (workers[0..count], results[0..count]) |*worker, *result| {
        result.* = worker.result;
        if (batch.timed_out and result.status == .failed and result.error_code != null and std.mem.eql(u8, result.error_code.?, "Canceled")) result.error_code = "SubagentTimeout";
        failed = failed or result.status == .failed;
    }
    const text = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .results = results[0..count], .timedOut = batch.timed_out }, .{ .emit_null_optional_fields = false });
    return .{ .text = text, .is_error = failed, .details = try std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, text, .{ .allocate = .alloc_always }) };
}

fn clippedLength(text: []const u8, limit: usize) usize {
    var len = @min(text.len, limit);
    while (len > 0 and len < text.len and (text[len] & 0xc0) == 0x80) len -= 1;
    return len;
}

fn keys(value: std.json.Value, allowed: []const []const u8) !void {
    if (value != .object) return error.ExpectedObject;
    for (value.object.keys()) |key| {
        for (allowed) |known| {
            if (std.mem.eql(u8, key, known)) break;
        } else return error.UnknownArgument;
    }
}

fn request(value: std.json.Value, max_turns: usize) !Request {
    const task = value.object.get("task") orelse return error.MissingSubagentTask;
    if (task != .string or std.mem.trim(u8, task.string, " \t\r\n").len == 0 or task.string.len > 64 * 1024) return error.InvalidSubagentTask;
    if (!std.unicode.utf8ValidateSlice(task.string)) return error.InvalidSubagentTask;
    var name: []const u8 = "child";
    if (value.object.get("name")) |v| {
        if (v != .string or v.string.len == 0 or v.string.len > 80) return error.InvalidSubagentName;
        if (!std.unicode.utf8ValidateSlice(v.string)) return error.InvalidSubagentName;
        name = v.string;
    }
    return .{ .name = name, .task = task.string, .max_turns = max_turns };
}

fn number(args: std.json.Value, key: []const u8, fallback: usize, maximum: usize) !usize {
    const value = args.object.get(key) orelse return fallback;
    const num = switch (value) {
        .integer => value.integer,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidSubagentLimit,
        else => return error.InvalidSubagentLimit,
    };
    if (num <= 0 or num > maximum) return error.InvalidSubagentLimit;
    return @intCast(num);
}

test "subagent bounded requests and UTF-8 output" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"task\":\"Inspect the project\",\"maxTurns\":4}", .{});
    defer parsed.deinit();
    const req = try request(parsed.value, try number(parsed.value, "maxTurns", 16, 32));
    try std.testing.expectEqual(@as(usize, 4), req.max_turns);
    try std.testing.expectEqual(@as(usize, 1), clippedLength("a中文", 3));
}
