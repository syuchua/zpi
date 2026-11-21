//! Independently compiled Zig implementation of the provisional C ABI.
const std = @import("std");
const runtime = @import("native_runtime");
const native = @import("native_plugin");
const a = std.heap.c_allocator;
const Instance = struct { live: usize = 0, outputs: usize = 0 };
const Operation = struct { id: []u8, polls: usize = 0, canceled: bool = false };
const Result = struct { owner: *Instance, text: []u8 };

fn create(host: *const runtime.HostTable, out: *?*anyopaque) callconv(.c) i32 {
    if (host.abi_major != native.abi_major or host.struct_size < @sizeOf(runtime.HostTable)) return 1;
    const instance = a.create(Instance) catch return 2;
    instance.* = .{};
    out.* = instance;
    return 0;
}
fn shutdown(context: ?*anyopaque) callconv(.c) i32 {
    const instance: *Instance = @ptrCast(@alignCast(context.?));
    if (instance.live != 0 or instance.outputs != 0) return 1;
    a.destroy(instance);
    return 0;
}
fn toolCount(_: ?*anyopaque) callconv(.c) u32 {
    return 1;
}
const schema_entries = [_]native.Entry{
    .{ .key = runtime.span("type"), .value = .{ .tag = @backingInt(native.Tag.string), .flags = 0, .payload = .{ .span = runtime.span("object") } } },
    .{ .key = runtime.span("additionalProperties"), .value = .{ .tag = @backingInt(native.Tag.boolean), .flags = 0, .payload = .{ .boolean = 1 } } },
};
fn toolAt(_: ?*anyopaque, index: u32, out: *runtime.Tool) callconv(.c) i32 {
    if (index != 0) return 1;
    out.* = .{
        .name = runtime.span("echo_native"),
        .description = runtime.span("Return the received call id"),
        .parameters = .{ .tag = @backingInt(native.Tag.object), .flags = 0, .payload = .{ .object = .{ .ptr = &schema_entries, .len = schema_entries.len } } },
    };
    return 0;
}
fn start(context: ?*anyopaque, index: u32, call: *const runtime.Call, out: *?*anyopaque) callconv(.c) i32 {
    if (index != 0) return 1;
    const id = runtime.spanText(call.call_id, 4096) catch return 1;
    const operation = a.create(Operation) catch return 2;
    const copy = a.dupe(u8, id) catch {
        a.destroy(operation);
        return 2;
    };
    operation.* = .{ .id = copy };
    const instance: *Instance = @ptrCast(@alignCast(context.?));
    instance.live += 1;
    out.* = operation;
    return 0;
}
fn release(context: ?*anyopaque) callconv(.c) void {
    const result: *Result = @ptrCast(@alignCast(context.?));
    result.owner.outputs -= 1;
    a.free(result.text);
    a.destroy(result);
}
fn poll(context: ?*anyopaque, handle: ?*anyopaque, out: *runtime.Poll) callconv(.c) i32 {
    const operation: *Operation = @ptrCast(@alignCast(handle.?));
    out.* = std.mem.zeroes(runtime.Poll);
    if (operation.canceled) {
        out.state = runtime.canceled;
        return 0;
    }
    if (std.mem.eql(u8, operation.id, "stall")) {
        out.state = runtime.pending;
        return 0;
    }
    if (operation.polls == 0) {
        operation.polls += 1;
        out.state = if (std.mem.eql(u8, operation.id, "pending")) runtime.pending else runtime.progress;
        return 0;
    }
    const result = a.create(Result) catch return 2;
    const text = a.dupe(u8, operation.id) catch {
        a.destroy(result);
        return 2;
    };
    const instance: *Instance = @ptrCast(@alignCast(context.?));
    result.* = .{ .owner = instance, .text = text };
    instance.outputs += 1;
    out.state = if (std.mem.eql(u8, operation.id, "fail")) runtime.failed else runtime.complete;
    out.output = .{
        .value = .{ .tag = if (std.mem.eql(u8, operation.id, "malformed")) 999 else @backingInt(native.Tag.string), .flags = 0, .payload = .{ .span = runtime.span(text) } },
        .context = result,
        .release = release,
    };
    return 0;
}
fn cancel(_: ?*anyopaque, handle: ?*anyopaque) callconv(.c) i32 {
    const operation: *Operation = @ptrCast(@alignCast(handle.?));
    operation.canceled = true;
    return 0;
}
fn destroy(context: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(context.?));
    const operation: *Operation = @ptrCast(@alignCast(handle.?));
    a.free(operation.id);
    a.destroy(operation);
    instance.live -= 1;
}
const descriptor: runtime.Table = .{
    .abi_major = native.abi_major,
    .abi_minor = native.abi_minor,
    .struct_size = @sizeOf(runtime.Table),
    .reserved = 0,
    .required_capabilities = runtime.cap_values | runtime.cap_tools,
    .create = create,
    .shutdown = shutdown,
    .tool_count = toolCount,
    .tool_at = toolAt,
    .start = start,
    .poll = poll,
    .cancel = cancel,
    .destroy = destroy,
    .name = runtime.span("zig-fixture"),
};
export fn zpi_plugin_descriptor_v1() ?*const runtime.Header {
    return @ptrCast(&descriptor);
}
