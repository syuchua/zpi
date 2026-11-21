//! Adapt initialized MCP stdio clients into ordinary agent tool definitions.
const std = @import("std");
const agent = @import("agent");
const mcp = @import("mcp");

pub const Entry = struct {
    client: *mcp.Client,
    remote_name: []const u8,

    pub fn execute(context: ?*anyopaque, ctx: agent.ToolContext, arguments: std.json.Value) anyerror!agent.ToolResult {
        const self: *Entry = @ptrCast(@alignCast(context.?));
        var reply = self.client.callTool(self.remote_name, arguments) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.InvalidMcpToolArguments or err == error.McpRequestTooLarge or err == error.McpNotReady) return err;
            // A transport or RPC error does not establish whether the tool ran.
            return error.Canceled;
        };
        defer reply.deinit();
        const result = reply.result();
        if (result != .object) return error.InvalidMcpToolResult;
        const content = field(result, "content");
        if (content != .array or content.array.items.len > 256) return error.Canceled;
        var text: std.ArrayList(u8) = .empty;
        for (content.array.items) |block| {
            if (block != .object) return error.Canceled;
            const kind = field(block, "type");
            if (kind != .string) return error.Canceled;
            if (std.mem.eql(u8, kind.string, "text")) {
                const part = field(block, "text");
                if (part != .string) return error.Canceled;
                if (text.items.len + part.string.len + @intFromBool(text.items.len > 0) > 50 * 1024) return error.McpToolOutputTooLarge;
                if (text.items.len > 0) try text.append(ctx.allocator, '\n');
                try text.appendSlice(ctx.allocator, part.string);
            } else return error.UnsupportedMcpToolContent;
        }
        const failure = field(result, "isError");
        if (failure != .null and failure != .bool) return error.Canceled;
        return .{ .text = if (text.items.len > 0) try text.toOwnedSlice(ctx.allocator) else try ctx.allocator.dupe(u8, "(no text content)"), .is_error = failure == .bool and failure.bool };
    }
};

/// Metadata and dispatch entries are owned by the invocation arena.
pub fn combine(a: std.mem.Allocator, client: *mcp.Client, server: []const u8, definitions: []const agent.Tool, listing: std.json.Value) ![]const agent.Tool {
    if (!mcp.validToolName(server)) return error.InvalidMcpServerName;
    const tools = field(listing, "tools");
    if (tools != .array) return error.InvalidMcpTools;
    if (listing != .object or listing.object.contains("nextCursor")) return error.UnsupportedMcpPagination;
    if (tools.array.items.len == 0) return definitions;
    if (tools.array.items.len > 128) return error.TooManyMcpTools;
    var result: std.ArrayList(agent.Tool) = .empty;
    errdefer result.deinit(a);
    try result.appendSlice(a, definitions);
    for (tools.array.items) |remote| {
        const name_value = field(remote, "name");
        const description_value = field(remote, "description");
        const schema = field(remote, "inputSchema");
        if (name_value != .string or !mcp.validToolName(name_value.string) or schema != .object) return error.InvalidMcpTools;
        if (description_value != .null and (description_value != .string or description_value.string.len > 4096)) return error.InvalidMcpTools;
        const object_type = field(schema, "type");
        if (object_type != .string or !std.mem.eql(u8, object_type.string, "object")) return error.InvalidMcpTools;
        var function_name: std.ArrayList(u8) = .empty;
        try function_name.appendSlice(a, "mcp__");
        for (server) |c| try function_name.append(a, if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
        try function_name.appendSlice(a, "__");
        for (name_value.string) |c| try function_name.append(a, if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
        if (function_name.items.len > 64) return error.McpToolNameTooLong;
        const function_name_owned = try function_name.toOwnedSlice(a);
        for (result.items) |existing| if (std.mem.eql(u8, existing.definition.name, function_name_owned)) return error.McpToolNameCollision;
        const entry = try a.create(Entry);
        entry.* = .{ .client = client, .remote_name = try a.dupe(u8, name_value.string) };
        try result.append(a, .{ .context = entry, .execute = Entry.execute, .definition = .{
            .name = function_name_owned,
            .description = if (description_value == .string) try a.dupe(u8, description_value.string) else "MCP tool",
            .parameters = try agent.cloneValue(a, schema, 0),
        } });
    }
    return result.toOwnedSlice(a);
}

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}

test "MCP adapter rejects normalized name collisions and paginated listings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var client: mcp.Client = undefined;
    const collision = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"tools":[{"name":"echo-text","inputSchema":{"type":"object"}},{"name":"echo_text","inputSchema":{"type":"object"}}]}
    , .{});
    try std.testing.expectError(error.McpToolNameCollision, combine(a, &client, "demo", &.{}, collision));
    const page = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tools\":[],\"nextCursor\":\"more\"}", .{});
    try std.testing.expectError(error.UnsupportedMcpPagination, combine(a, &client, "demo", &.{}, page));
    try std.testing.expectError(error.InvalidMcpTools, combine(a, &client, "demo", &.{}, .null));
}
