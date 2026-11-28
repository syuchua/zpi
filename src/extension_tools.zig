//! Tool execution adapter for the optional TypeScript host.
const std = @import("std");
const agent = @import("agent");
const extensions = @import("extensions");

pub const Entry = struct {
    host: *extensions.Host,
    name: []const u8,
    schema: std.json.Value,
    builtin: ?agent.Tool = null,
    pub fn execute(context: ?*anyopaque, ctx: agent.ToolContext, arguments: std.json.Value) anyerror!agent.ToolResult {
        const self: *Entry = @ptrCast(@alignCast(context.?));
        var gate = try self.host.request("tool_call", .{ .name = self.name, .callId = ctx.call_id, .arguments = arguments, .schema = self.schema });
        defer gate.deinit();
        const verdict = gate.value();
        if (verdict != .object) return error.InvalidExtensionGate;
        if (verdict.object.get("block")) |block| {
            if (block != .bool) return error.InvalidExtensionGate;
            if (block.bool) {
                const reason = verdict.object.get("reason") orelse .null;
                if (reason != .null and reason != .string) return error.InvalidExtensionGate;
                return .{ .text = if (reason == .string)
                    try std.fmt.allocPrint(ctx.allocator, "Tool blocked by extension: {s}", .{reason.string[0..@min(reason.string.len, 4096)]})
                else
                    try ctx.allocator.dupe(u8, "Tool blocked by extension"), .is_error = true };
            }
        }
        const input = verdict.object.get("input") orelse return error.InvalidExtensionGate;
        if (input != .object) return error.InvalidExtensionGate;
        var result: agent.ToolResult = undefined;
        if (self.builtin) |tool| {
            if (ctx.authorize_rewritten) |authorize| {
                try authorize(ctx.authorization_context, tool, ctx, input, ctx.rewritten_authorization orelse return error.InvalidSecurityPolicy);
            }
            result = tool.execute(tool.context, ctx, input) catch |err| blk: {
                if (err == error.Canceled or err == error.OutOfMemory or err == error.CapabilityDenied) return err;
                break :blk .{ .text = try std.fmt.allocPrint(ctx.allocator, "Tool failed: {s}", .{@errorName(err)}), .is_error = true };
            };
        } else {
            var executed = self.host.execute(self.name, ctx.call_id, input) catch |err| {
                // A broken transport may follow an external effect in the
                // extension. Stop the turn so reconciliation records an unknown
                // outcome; never treat it as proof that execution did nothing.
                if (err != error.ExtensionHostRejected and err != error.ExtensionToolFailed) return error.Canceled;
                return err;
            };
            defer executed.deinit();
            result = decodeResult(ctx.allocator, executed.value()) catch return error.Canceled;
        }
        var transformed = self.host.request("tool_result", .{
            .name = self.name,
            .callId = ctx.call_id,
            .arguments = input,
            .content = .{.{ .type = "text", .text = result.text }},
            .details = result.details,
            .isError = result.is_error,
        }) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.Canceled) return err;
            // Execution already completed. Keep its known result when a
            // presentation/result hook fails, rather than losing effect data.
            return result;
        };
        defer transformed.deinit();
        if (transformed.value() != .null) result = decodeResult(ctx.allocator, transformed.value()) catch |err| {
            if (err == error.OutOfMemory) return err;
            return result;
        };
        return result;
    }
};
fn decodeResult(a: std.mem.Allocator, value: std.json.Value) !agent.ToolResult {
    if (value != .object) return error.InvalidExtensionResult;
    const content = value.object.get("content") orelse return error.InvalidExtensionResult;
    if (content != .array) return error.InvalidExtensionResult;
    var text: std.ArrayList(u8) = .empty;
    for (content.array.items) |block| {
        if (block != .object) return error.InvalidExtensionResult;
        const kind = block.object.get("type") orelse return error.InvalidExtensionResult;
        const part = block.object.get("text") orelse return error.UnsupportedExtensionContent;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text") or part != .string) return error.UnsupportedExtensionContent;
        if (text.items.len + part.string.len + 1 > 50 * 1024) return error.ExtensionToolOutputTooLarge;
        if (text.items.len > 0) try text.append(a, '\n');
        try text.appendSlice(a, part.string);
    }
    const is_error: std.json.Value = value.object.get("isError") orelse .{ .bool = false };
    if (is_error != .bool) return error.InvalidExtensionResult;
    return .{ .text = try text.toOwnedSlice(a), .is_error = is_error.bool, .details = if (value.object.get("details")) |details| try agent.cloneValue(a, details, 0) else null };
}

test "extension tools receive extension capability while wrapped built-ins retain theirs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: extensions.Host = undefined;
    const builtin_tool: agent.Tool = .{
        .definition = .{ .name = "write", .description = "write", .parameters = .null },
        .capability = .filesystem_write,
        .source = .builtin_tool,
        .execute = struct {
            fn run(_: ?*anyopaque, _: agent.ToolContext, _: std.json.Value) anyerror!agent.ToolResult {
                return .{ .text = "" };
            }
        }.run,
    };
    const ready = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tools\":[{\"name\":\"remote\",\"description\":\"remote\",\"parameters\":{\"type\":\"object\"}}]}", .{});
    const tools = try combine(a, &host, ready, &.{builtin_tool});
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqual(agent.security.Capability.extension_load, tools[1].capability.?);
    try std.testing.expectEqual(agent.security.Source.typescript, tools[1].source);
    const extension_decision = agent.security.evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = tools[1].capability.? }} }, .{
        .capability = tools[1].capability.?,
        .source = tools[1].source,
        .target = .{ .kind = .plugin },
    });
    try std.testing.expect(extension_decision.allowed());
    try std.testing.expectEqual(agent.security.Capability.filesystem_write, tools[0].capability.?);
    try std.testing.expectEqual(agent.security.Source.builtin_tool, tools[0].source);
}

/// All allocated metadata/context entries live in the invocation arena.
pub fn combine(a: std.mem.Allocator, host: *extensions.Host, ready: std.json.Value, builtins: []const agent.Tool) ![]agent.Tool {
    if (ready != .object) return error.InvalidExtensionHandshake;
    const specs = ready.object.get("tools") orelse return error.InvalidExtensionHandshake;
    if (specs != .array or specs.array.items.len > 256) return error.InvalidExtensionHandshake;
    var tools: std.ArrayList(agent.Tool) = .empty;
    for (builtins) |tool| try tools.append(a, tool);
    for (specs.array.items) |spec| {
        if (spec != .object) return error.InvalidExtensionTool;
        const name = spec.object.get("name") orelse return error.InvalidExtensionTool;
        const description = spec.object.get("description") orelse return error.InvalidExtensionTool;
        const parameters = spec.object.get("parameters") orelse return error.InvalidExtensionTool;
        if (name != .string or description != .string or parameters != .object or name.string.len == 0 or name.string.len > 64) return error.InvalidExtensionTool;
        for (name.string) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return error.InvalidExtensionTool;
        const entry = try a.create(Entry);
        entry.* = .{ .host = host, .name = try a.dupe(u8, name.string), .schema = try agent.cloneValue(a, parameters, 0) };
        const tool: agent.Tool = .{ .context = entry, .execute = Entry.execute, .source = .typescript, .capability = .extension_load, .definition = .{
            .name = entry.name,
            .description = try a.dupe(u8, description.string),
            .parameters = try agent.cloneValue(a, parameters, 0),
        } };
        var replaced = false;
        for (tools.items) |*existing| if (std.mem.eql(u8, existing.definition.name, entry.name)) {
            existing.* = tool;
            replaced = true;
            break;
        };
        if (!replaced) try tools.append(a, tool);
    }
    // Every enabled built-in passes through the same gate/result hooks.
    for (tools.items) |*tool| if (tool.execute != Entry.execute) {
        const entry = try a.create(Entry);
        entry.* = .{ .host = host, .name = tool.definition.name, .schema = tool.definition.parameters, .builtin = tool.* };
        tool.context = entry;
        tool.execute = Entry.execute;
        tool.defer_authorization = true;
    };
    return tools.toOwnedSlice(a);
}
