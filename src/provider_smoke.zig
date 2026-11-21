//! Explicit, opt-in network smoke using local pi model configuration.
//! Only synthetic prompts leave the machine; credentials never enter output.
const std = @import("std");
const zpi = @import("zpi");

const Output = struct {
    bytes: usize = 0,
    deltas: usize = 0,
    done: bool = false,
    fn emit(context: *anyopaque, event: zpi.model.Event) !void {
        const self: *Output = @ptrCast(@alignCast(context));
        switch (event) {
            .text_delta => |text| {
                self.bytes += text.len;
                self.deltas += 1;
            },
            .done => |reason| {
                if (reason != .stop) return error.UnexpectedFinishReason;
                self.done = true;
            },
            .tool_call_end => return error.UnexpectedToolCall,
            else => {},
        }
    }
};

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidModelsConfig;
    return value.object.get(name) orelse error.MissingConfigField;
}
fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidModelsConfig;
    return value.string;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len > 2) return error.ExpectedOptionalModelId;
    const chosen = if (args.len == 2) args[1] else "MiniCPM5-2B";
    const user_dir = init.environ_map.get("HOME") orelse return error.MissingHome;
    const path = try std.fs.path.join(allocator, &.{ user_dir, ".pi", "agent", "models.json" });
    const config_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(4 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{});
    const provider = try field(try field(parsed.value, "providers"), "amd-radeon");
    const api = try string(try field(provider, "api"));
    if (!std.mem.eql(u8, api, "openai-completions")) return error.UnsupportedApi;
    const models = try field(provider, "models");
    if (models != .array) return error.InvalidModelsConfig;
    var found = false;
    for (models.array.items) |entry| {
        if (std.mem.eql(u8, try string(try field(entry, "id")), chosen)) found = true;
    }
    if (!found) return error.ModelNotConfigured;
    const base = try string(try field(provider, "baseUrl"));
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{std.mem.trimEnd(u8, base, "/")});
    const configured_key = try string(try field(provider, "apiKey"));
    // Never execute configuration commands in a smoke test. Support literal
    // keys or a simple $NAME reference, explicitly rejecting command syntax.
    if (std.mem.startsWith(u8, configured_key, "!")) return error.CommandCredentialUnsupported;
    const key = if (std.mem.startsWith(u8, configured_key, "$"))
        init.environ_map.get(configured_key[1..]) orelse return error.MissingCredentialEnvironment
    else
        configured_key;
    var client = zpi.openai.Client{ .io = init.io, .config = .{
        .endpoint = endpoint,
        .model_id = chosen,
        .api_key = key,
        .max_tokens = 64,
        .timeout_ms = 45000,
    }, .environ = init.environ_map, .proxy_policy = .none };
    const messages = [_]zpi.model.Message{.{ .role = .user, .content = &.{.{ .text = "Reply briefly with the word READY. This is a connectivity test." }} }};
    var output: Output = .{};
    client.run(init.gpa, &messages, &.{}, .{ .context = &output, .emit = Output.emit }) catch |err| {
        // Print error identifiers/status only: raw server payloads can echo keys.
        std.debug.print("provider smoke failed: {s}; HTTP={?}\n", .{ @errorName(err), client.status });
        std.process.exit(1);
    };
    if (!output.done or output.bytes == 0) return error.EmptyResponse;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("provider=amd-radeon model={s} HTTP=200 text_bytes={d} deltas={d} finish=stop\n", .{ chosen, output.bytes, output.deltas });
    try writer.interface.flush();
}
