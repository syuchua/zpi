const std = @import("std");
pub const sse = @import("sse");
pub const model = @import("model");
pub const openai = @import("openai");
pub const anthropic = @import("anthropic");
pub const extensions = @import("extensions");
pub const extension_tools = @import("extension_tools");
pub const native_runtime = @import("native_runtime");
pub const native_tools = @import("native_tools");
pub const agent = @import("agent");
pub const tools = @import("tools");
pub const session = @import("session");
pub const mcp = @import("mcp");
pub const mcp_tools = @import("mcp_tools");
pub const context_budget = @import("context_budget");
pub const compaction = @import("compaction");

pub const VERSION = "0.1.0-dev";
pub const ProviderError = error{
    MissingApiKey,
    HttpRequestFailed,
    InvalidResponse,
    StreamClosed,
    UnsupportedProvider,
};

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

pub const ToolHandler = *const fn (std.mem.Allocator, []const u8) anyerror!ToolResult;
pub const RegisteredTool = struct {
    name: []const u8,
    description: []const u8,
    handler: ToolHandler,
};

pub fn validateToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '-')) return false;
    }
    return true;
}

test "tool names accept safe identifiers only" {
    try std.testing.expect(validateToolName("read_file"));
    try std.testing.expect(validateToolName("tool-2"));
    try std.testing.expect(!validateToolName(""));
    try std.testing.expect(!validateToolName("../secret"));
    try std.testing.expect(!validateToolName("bad.name"));
    var long_name: [65]u8 = undefined;
    @memset(&long_name, 'a');
    try std.testing.expect(!validateToolName(&long_name));
}
