//! Anthropic Messages text/tool subset. Unsupported content fails explicitly.
const std = @import("std");
const model = @import("model");
const sse = @import("sse");
const http_headers = @import("http_headers");
const http_transport = @import("http_transport");
const context_budget = @import("context_budget");

pub const ProxyPolicy = http_transport.ProxyPolicy;
pub const Config = struct { endpoint: []const u8, model_id: []const u8, api_key: []const u8, headers: []const std.http.Header = &.{}, max_tokens: u32 = 1024, context_window: u32 = 0, timeout_ms: i64 = 60000 };
pub const Client = struct {
    io: std.Io,
    config: Config,
    environ: ?*const std.process.Environ.Map = null,
    proxy_policy: ProxyPolicy = .system,
    cancel: ?model.Cancel = null,
    timing: ?model.Timing = null,
    status: ?std.http.Status = null,
    retry_after_ms: ?u64 = null,

    pub fn provider(self: *Client) model.Provider {
        return .{ .context = self, .run_fn = runErased, .retry_info_fn = retryInfoErased };
    }
    fn runErased(context: *anyopaque, allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(context));
        return self.run(allocator, messages, tools, sink);
    }
    fn retryInfoErased(context: *anyopaque, err: anyerror) ?model.RetryHint {
        const self: *const Client = @ptrCast(@alignCast(context));
        return self.retryHint(err);
    }
    pub fn retryHint(self: *const Client, err: anyerror) model.RetryHint {
        return http_transport.retryHint(err, self.status, self.retry_after_ms);
    }
    pub fn run(self: *Client, allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition, sink: model.EventSink) !void {
        if (self.config.timeout_ms <= 0) return error.InvalidTimeout;
        if (self.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
        self.status = null;
        self.retry_after_ms = null;
        var cancel_socket: model.CancelSocket = .{};
        const Completion = union(enum) { request: anyerror!void, timer: std.Io.Cancelable!void, cancel: std.Io.Cancelable!void };
        var results: [3]Completion = undefined;
        var select = std.Io.Select(Completion).init(self.io, &results);
        defer select.cancelDiscard();
        try select.concurrent(.timer, waitTimeout, .{ self.io, self.config.timeout_ms });
        try select.concurrent(.request, request, .{ self, allocator, messages, tools, sink, &cancel_socket });
        if (self.cancel) |cancel| try select.concurrent(.cancel, waitCancel, .{ cancel, self.io });
        switch (try select.await()) {
            .request => |result| try result,
            .timer => |result| {
                cancel_socket.abort(self.io);
                try result;
                return error.RequestTimeout;
            },
            .cancel => |result| {
                cancel_socket.abort(self.io);
                try result;
                return error.Canceled;
            },
        }
    }
    fn waitTimeout(io: std.Io, milliseconds: i64) std.Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(milliseconds), .awake);
    }
    fn waitCancel(cancel: model.Cancel, io: std.Io) std.Io.Cancelable!void {
        try cancel.wait(io);
    }
    fn request(self: *Client, allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition, sink: model.EventSink, cancel_socket: *model.CancelSocket) anyerror!void {
        const uri = try std.Uri.parse(self.config.endpoint);
        if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or uri.user != null or uri.password != null) return error.InvalidEndpoint;
        if (std.mem.startsWith(u8, self.config.api_key, "sk-ant-oat")) return error.OAuthUnsupported;
        if (std.mem.indexOfAny(u8, self.config.api_key, "\r\n") != null) return error.InvalidCredential;
        try http_headers.validateAll(self.config.headers);
        const encoding_started = model.Timing.start(self.timing, self.io);
        const payload = try encodeRequest(allocator, self.config, messages, tools);
        model.Timing.finish(self.timing, self.io, encoding_started, "request_encode");
        defer allocator.free(payload);
        const accept_override = http_headers.get(self.config.headers, "accept");
        const api_key_override = http_headers.get(self.config.headers, "x-api-key");
        const version_override = http_headers.get(self.config.headers, "anthropic-version");
        const extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len + 3);
        defer allocator.free(extra_headers);
        var header_count: usize = 0;
        if (accept_override) |value| {
            extra_headers[header_count] = .{ .name = "accept", .value = value };
        } else {
            extra_headers[header_count] = .{ .name = "accept", .value = "text/event-stream" };
        }
        header_count += 1;
        if (api_key_override) |value| {
            extra_headers[header_count] = .{ .name = "x-api-key", .value = value };
        } else {
            extra_headers[header_count] = .{ .name = "x-api-key", .value = self.config.api_key };
        }
        header_count += 1;
        if (version_override) |value| {
            extra_headers[header_count] = .{ .name = "anthropic-version", .value = value };
        } else {
            extra_headers[header_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        }
        header_count += 1;
        for (self.config.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "accept") or std.ascii.eqlIgnoreCase(header.name, "x-api-key") or std.ascii.eqlIgnoreCase(header.name, "anthropic-version")) continue;
            extra_headers[header_count] = header;
            header_count += 1;
        }
        var decoder = Decoder.init(allocator, sink);
        defer decoder.deinit();
        const transport_started = model.Timing.start(self.timing, self.io);
        try http_transport.postSse(allocator, self.io, .{
            .uri = uri,
            .authorization = null,
            .extra_headers = extra_headers[0..header_count],
            .payload = payload,
            .environ = self.environ,
            .proxy_policy = self.proxy_policy,
            .cancel_socket = cancel_socket,
            .timing = self.timing,
        }, decoder.sseSink(), &decoder.done, &self.status, &self.retry_after_ms);
        model.Timing.finish(self.timing, self.io, transport_started, "http_sse_transport");
    }
};

pub fn encodeRequest(a: std.mem.Allocator, config: Config, messages: []const model.Message, tools: []const model.ToolDefinition) ![]u8 {
    if (config.max_tokens == 0) return error.InvalidTokenLimit;
    const projected = try model.projectSystemPrompt(a, messages);
    defer a.free(projected);
    try model.validateRequestImages(projected);
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(config.model_id);
    try json.objectField("max_tokens");
    try json.write(try context_budget.clampMaxTokens(a, projected, tools, config.context_window, config.max_tokens));
    try json.objectField("stream");
    try json.write(true);
    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(a);
    try json.objectField("messages");
    try json.beginArray();
    var pending_tool_uses: std.ArrayList([]const u8) = .empty;
    defer pending_tool_uses.deinit(a);
    var tool_result_count: usize = 0;
    var conversation_started = false;
    for (projected) |message| {
        if (message.role == .tool_result) {
            if (!conversation_started) return error.OrphanToolResult;
            conversation_started = true;
            if (message.tool_call_id == null) return error.MissingToolCallId;
            if (tool_result_count == 0) {
                try json.beginObject();
                try json.objectField("role");
                try json.write("user");
                try json.objectField("content");
                try json.beginArray();
            }
            try json.beginObject();
            try json.objectField("type");
            try json.write("tool_result");
            try json.objectField("tool_use_id");
            const tool_id = try checkedId(message.tool_call_id.?);
            var found = false;
            for (pending_tool_uses.items, 0..) |pending, i| if (std.mem.eql(u8, pending, tool_id)) {
                _ = pending_tool_uses.orderedRemove(i);
                found = true;
                break;
            };
            if (!found) return error.OrphanToolResult;
            try json.write(tool_id);
            try json.objectField("is_error");
            try json.write(message.is_error);
            try json.objectField("content");
            try writeTextContent(&json, message.content);
            try json.endObject();
            tool_result_count += 1;
            continue;
        }
        if (tool_result_count > 0) {
            try json.endArray();
            try json.endObject();
            tool_result_count = 0;
        }
        if (pending_tool_uses.items.len > 0) return error.MissingToolResult;
        if (message.role == .system) {
            if (conversation_started) return error.MidConversationSystemUnsupported;
            for (message.content) |part| switch (part) {
                .text => |text| {
                    if (system.items.len > 0) try system.append(a, '\n');
                    try system.appendSlice(a, text);
                },
                else => return error.UnsupportedContent,
            };
            continue;
        }
        conversation_started = true;
        if (message.role == .assistant) {
            for (message.content) |part| if (part == .tool_call) {
                if (part.tool_call.arguments != .object) return error.InvalidToolArguments;
                const tool_id = try checkedId(part.tool_call.id);
                for (pending_tool_uses.items) |prior| if (std.mem.eql(u8, prior, tool_id)) return error.DuplicateToolCallId;
                try pending_tool_uses.append(a, tool_id);
            };
        }
        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message.role == .assistant) "assistant" else "user");
        try json.objectField("content");
        try json.beginArray();
        for (message.content) |part| switch (part) {
            .text => |text| {
                try json.beginObject();
                try json.objectField("type");
                try json.write("text");
                try json.objectField("text");
                try json.write(text);
                try json.endObject();
            },
            .thinking => return error.UnsupportedThinkingReplay,
            .image => |image| {
                if (message.role != .user) return error.InvalidImageRole;
                try writeImageBlock(&json, image);
            },
            .tool_call => |call| {
                if (message.role != .assistant or call.arguments != .object) return error.InvalidToolArguments;
                try json.beginObject();
                try json.objectField("type");
                try json.write("tool_use");
                try json.objectField("id");
                try json.write(try checkedId(call.id));
                try json.objectField("name");
                try json.write(call.name);
                try json.objectField("input");
                try json.write(call.arguments);
                try json.endObject();
            },
        };
        try json.endArray();
        try json.endObject();
    }
    if (tool_result_count > 0) {
        try json.endArray();
        try json.endObject();
    }
    if (pending_tool_uses.items.len != 0) return error.MissingToolResult;
    // Close array before writing top-level fields.
    try json.endArray();
    if (system.items.len > 0) {
        try json.objectField("system");
        try json.write(system.items);
    }
    if (tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (tools) |tool| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("input_schema");
            try json.write(tool.parameters);
            try json.endObject();
        }
        try json.endArray();
    }
    try json.endObject();
    return out.toOwnedSlice();
}
fn writeImageBlock(json: *std.json.Stringify, image: model.Image) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("image");
    try json.objectField("source");
    try json.beginObject();
    try json.objectField("type");
    try json.write("base64");
    try json.objectField("media_type");
    try json.write(image.mime_type);
    try json.objectField("data");
    try image.writeBase64(json, false);
    try json.endObject();
    try json.endObject();
}

fn writeTextContent(json: *std.json.Stringify, content: []const model.Content) !void {
    try json.beginArray();
    for (content) |part| switch (part) {
        .text => |text| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("text");
            try json.objectField("text");
            try json.write(text);
            try json.endObject();
        },
        else => return error.UnsupportedContent,
    };
    try json.endArray();
}
fn checkedId(id: []const u8) ![]const u8 {
    // Reject foreign IDs rather than mapping multiple IDs onto one value.
    if (!validId(id)) return error.InvalidToolCallId;
    return id;
}
fn field(v: std.json.Value, key: []const u8) !std.json.Value {
    if (v != .object) return error.InvalidResponse;
    return v.object.get(key) orelse error.InvalidResponse;
}
fn str(v: std.json.Value) ![]const u8 {
    if (v != .string) return error.InvalidResponse;
    return v.string;
}
fn uint(v: std.json.Value) !u64 {
    return switch (v) {
        .integer => |number| if (number < 0) error.InvalidUsage else @intCast(number),
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch error.InvalidUsage,
        else => error.InvalidUsage,
    };
}
fn blockIndex(value: std.json.Value) !usize {
    const index = uint(value) catch return error.InvalidBlockIndex;
    if (index >= 256) return error.InvalidBlockIndex;
    return @intCast(index);
}
const Block = union(enum) { text, tool: struct { id: []u8, name: []u8, args: std.ArrayList(u8), initial: []u8 } };
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    sink: model.EventSink,
    blocks: std.ArrayList(?Block) = .empty,
    started: bool = false,
    done: bool = false,
    failed: bool = false,
    reason: ?model.StopReason = null,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    bytes: usize = 0,
    ended_blocks: [256]bool = @splat(false),
    pub fn init(a: std.mem.Allocator, sink: model.EventSink) Decoder {
        return .{ .allocator = a, .sink = sink };
    }
    pub fn deinit(self: *Decoder) void {
        for (self.blocks.items) |*maybe| if (maybe.*) |*b| switch (b.*) {
            .text => {},
            .tool => |*x| {
                self.allocator.free(x.id);
                self.allocator.free(x.name);
                self.allocator.free(x.initial);
                x.args.deinit(self.allocator);
            },
        };
        self.blocks.deinit(self.allocator);
    }
    pub fn sseSink(self: *Decoder) sse.Sink {
        return .{ .context = self, .emit = onSse };
    }
    fn onSse(ctx: *anyopaque, event: sse.Event) anyerror!void {
        const self: *Decoder = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, event.event, "error")) {
            self.failed = true;
            return error.ProviderError;
        }
        if (std.mem.eql(u8, event.event, "ping")) return;
        if (!std.mem.eql(u8, event.event, "message") and !knownEvent(event.event)) return;
        const event_name = if (std.mem.eql(u8, event.event, "message")) "" else event.event;
        try self.feed(event_name, event.data);
    }
    fn emit(self: *Decoder, event: model.Event) !void {
        try self.sink.emit(self.sink.context, event);
    }
    pub fn feed(self: *Decoder, event_name: []const u8, data: []const u8) !void {
        if (self.failed) return error.DecoderFailed;
        if (self.done) return error.StreamAlreadyDone;
        errdefer self.failed = true;
        if (self.bytes > 16 * 1024 * 1024 or data.len > 16 * 1024 * 1024 - self.bytes) return error.ResponseTooLarge;
        self.bytes += data.len;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .parse_numbers = false }) catch return error.InvalidResponse;
        defer parsed.deinit();
        const root = parsed.value;
        const kind = try str(try field(root, "type"));
        if (event_name.len > 0 and !std.mem.eql(u8, event_name, kind)) return error.EventTypeMismatch;
        if (std.mem.eql(u8, kind, "error")) return error.ProviderError;
        if (!self.started and !std.mem.eql(u8, kind, "message_start")) return error.MissingMessageStart;
        if (self.reason != null and !std.mem.eql(u8, kind, "message_stop")) return error.DataAfterFinish;
        if (std.mem.eql(u8, kind, "message_start")) {
            if (self.started) return error.DuplicateMessageStart;
            self.started = true;
            try self.emit(.start);
            const message = try field(root, "message");
            const usage = try field(message, "usage");
            try self.updateUsage(usage);
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            if (!self.started) return error.MissingMessageStart;
            const idx = try blockIndex(try field(root, "index"));
            while (self.blocks.items.len <= idx) try self.blocks.append(self.allocator, null);
            if (self.blocks.items[idx] != null) return error.BlockAlreadyOpen;
            const block = try field(root, "content_block");
            const block_type = try str(try field(block, "type"));
            if (std.mem.eql(u8, block_type, "text")) {
                const text = try str(try field(block, "text"));
                self.blocks.items[idx] = .text;
                if (text.len > 0) try self.emit(.{ .text_delta = text });
            } else if (std.mem.eql(u8, block_type, "thinking") or std.mem.eql(u8, block_type, "redacted_thinking")) {
                // The agent cannot yet retain signed/provider-bound reasoning.
                return error.ThinkingUnsupported;
            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                const raw_id = try str(try field(block, "id"));
                const raw_name = try str(try field(block, "name"));
                if (!validId(raw_id) or raw_name.len == 0) return error.InvalidToolCall;
                const input = try field(block, "input");
                if (input != .object) return error.InvalidToolArguments;
                const owned = blk: {
                    const id = try self.allocator.dupe(u8, raw_id);
                    errdefer self.allocator.free(id);
                    const name = try self.allocator.dupe(u8, raw_name);
                    errdefer self.allocator.free(name);
                    const initial = try std.json.Stringify.valueAlloc(self.allocator, input, .{});
                    break :blk Block{ .tool = .{ .id = id, .name = name, .args = .empty, .initial = initial } };
                };
                self.blocks.items[idx] = owned;
                try self.emit(.{ .tool_call_start = .{ .index = idx, .id = owned.tool.id, .name = owned.tool.name } });
            } else return error.UnsupportedContent;
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const idx = try blockIndex(try field(root, "index"));
            if (idx >= self.blocks.items.len or self.blocks.items[idx] == null or self.ended_blocks[idx]) return error.UnknownBlock;
            const delta = try field(root, "delta");
            const delta_type = try str(try field(delta, "type"));
            switch (self.blocks.items[idx].?) {
                .text => {
                    if (!std.mem.eql(u8, delta_type, "text_delta")) return error.InvalidBlockDelta;
                    try self.emit(.{ .text_delta = try str(try field(delta, "text")) });
                },
                .tool => |*b| {
                    if (!std.mem.eql(u8, delta_type, "input_json_delta")) return error.InvalidBlockDelta;
                    if (b.args.items.len == 0 and !std.mem.eql(u8, b.initial, "{}")) return error.ConflictingToolInput;
                    const fragment = try str(try field(delta, "partial_json"));
                    try appendBounded(self.allocator, &b.args, fragment);
                    try self.emit(.{ .tool_call_delta = .{ .index = idx, .arguments_fragment = fragment } });
                },
            }
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            const idx = try blockIndex(try field(root, "index"));
            if (idx >= self.blocks.items.len or self.blocks.items[idx] == null or self.ended_blocks[idx]) return error.UnknownBlock;
            // Keep data until message_stop so all calls are validated atomically.
            self.ended_blocks[idx] = true;
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            const delta = try field(root, "delta");
            if (delta != .object) return error.InvalidResponse;
            if (delta.object.get("stop_reason")) |stop| {
                if (stop != .null) self.reason = try parseStop(try str(stop));
            }
            if (root.object.get("usage")) |usage| try self.updateUsage(usage);
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            if (!self.started) return error.MissingMessageStart;
            const reason = self.reason orelse return error.MissingStopReason;
            if (reason == .error_response) return error.ProviderRefusal;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var calls: std.ArrayList(model.ToolCall) = .empty;
            for (self.blocks.items, 0..) |maybe, block_index| {
                if (maybe) |block| switch (block) {
                    .tool => |tool| {
                        if (!self.ended_blocks[block_index]) return error.UnclosedBlock;
                        for (calls.items) |prior| if (std.mem.eql(u8, prior.id, tool.id)) return error.DuplicateToolCallId;
                        const arguments = if (tool.args.items.len > 0) tool.args.items else tool.initial;
                        const parsed_args = std.json.parseFromSlice(std.json.Value, a, arguments, .{ .parse_numbers = false }) catch return error.InvalidToolArguments;
                        if (parsed_args.value != .object) return error.InvalidToolArguments;
                        try calls.append(a, .{ .id = tool.id, .name = tool.name, .arguments = parsed_args.value });
                    },
                    .text => if (!self.ended_blocks[block_index]) return error.UnclosedBlock,
                };
            }
            if (reason == .tool_use and calls.items.len == 0) return error.MissingToolCalls;
            if (calls.items.len > 0 and reason != .tool_use) return error.InvalidStopReason;
            var call_index: usize = 0;
            for (self.blocks.items, 0..) |maybe, block_index| {
                if (maybe) |block| if (block == .tool) {
                    try self.emit(.{ .tool_call_end = .{ .index = block_index, .call = calls.items[call_index] } });
                    call_index += 1;
                };
            }
            try self.emit(.{ .done = reason });
            self.done = true;
        } else return error.UnsupportedEvent;
    }
    fn updateUsage(self: *Decoder, value: std.json.Value) !void {
        if (value != .object) return error.InvalidUsage;
        const keys = [_][]const u8{ "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens" };
        const targets = [_]*u64{ &self.input_tokens, &self.output_tokens, &self.cache_read, &self.cache_write };
        for (keys, targets) |key, target| {
            if (value.object.get(key)) |v| if (v != .null) {
                target.* = try uint(v);
            };
        }
        try self.emit(.{ .usage = .{
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .total_tokens = self.input_tokens +| self.output_tokens +| self.cache_read +| self.cache_write,
            .cache_read_tokens = self.cache_read,
            .cache_write_tokens = self.cache_write,
        } });
    }
};
fn knownEvent(name: []const u8) bool {
    inline for (.{ "message_start", "content_block_start", "content_block_delta", "content_block_stop", "message_delta", "message_stop" }) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}
fn appendBounded(a: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8) !void {
    if (list.items.len > 1024 * 1024 or text.len > 1024 * 1024 - list.items.len) return error.ToolCallTooLarge;
    try list.appendSlice(a, text);
}
fn parseStop(stop: []const u8) !model.StopReason {
    if (std.mem.eql(u8, stop, "end_turn") or std.mem.eql(u8, stop, "stop_sequence") or std.mem.eql(u8, stop, "pause_turn")) return .stop;
    if (std.mem.eql(u8, stop, "max_tokens")) return .length;
    if (std.mem.eql(u8, stop, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, stop, "refusal") or std.mem.eql(u8, stop, "sensitive")) return .error_response;
    return error.UnsupportedStopReason;
}
