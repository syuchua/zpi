//! OpenAI-compatible Chat Completions adapter. JSON is encoded/decoded only
//! at the network boundary. Native consumers receive borrowed typed events.
const std = @import("std");
const model = @import("model");
const sse = @import("sse");
const http_headers = @import("http_headers");
const context_budget = @import("context_budget");

pub const ProxyPolicy = enum { system, none };

pub const Config = struct {
    endpoint: []const u8,
    model_id: []const u8,
    api_key: []const u8,
    headers: []const std.http.Header = &.{},
    max_tokens: u32 = 1024,
    /// Zero disables approximate context-window clipping.
    context_window: u32 = 0,
    compat: Compat = .{},
    timeout_ms: i64 = 60000,
};

pub const Compat = struct {
    pub const MaxTokensField = enum { max_tokens, max_completion_tokens };
    max_tokens_field: MaxTokensField = .max_tokens,
    requires_non_null_assistant_content: bool = false,
    requires_tools_with_tool_history: bool = false,
    requires_tool_result_name: bool = false,
    requires_assistant_after_tool_result: bool = false,
    supports_usage_in_streaming: bool = true,
    supports_finish_reason: bool = true,
    supports_store: bool = false,
};

pub const Client = struct {
    io: std.Io,
    config: Config,
    environ: ?*const std.process.Environ.Map = null,
    proxy_policy: ProxyPolicy = .system,
    cancel: ?model.Cancel = null,
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
        return switch (err) {
            error.HttpRequestFailed => if (self.status) |st| blk: {
                if (st == .payload_too_large) break :blk .{ .retryable = false, .context_overflow = true };
                if (http_headers.isRetryableHttpStatus(st)) break :blk .{ .retryable = true, .retry_after_ms = self.retry_after_ms };
                break :blk .{ .retryable = false };
            } else .{ .retryable = false },
            error.RequestTimeout,
            error.TruncatedStream,
            error.ResponseReadFailed,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.NetworkUnreachable,
            error.HostUnreachable,
            error.TemporaryNameServerFailure,
            => .{ .retryable = true },
            else => .{ .retryable = false },
        };
    }

    pub fn run(self: *Client, allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
        if (self.config.timeout_ms <= 0) return error.InvalidTimeout;
        if (self.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
        self.status = null;
        self.retry_after_ms = null;
        var cancel_socket: model.CancelSocket = .{};
        // Join all tasks before returning so no borrowed state survives timeout or cancel.
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
        if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidEndpoint;
        if (uri.user != null or uri.password != null) return error.InvalidEndpoint;
        if (std.mem.indexOfAny(u8, self.config.api_key, "\r\n") != null) return error.InvalidCredential;
        try http_headers.validateAll(self.config.headers);
        var http: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer http.deinit();
        var proxy_arena = std.heap.ArenaAllocator.init(allocator);
        defer proxy_arena.deinit();
        if (self.proxy_policy == .system) {
            if (self.environ) |env| try http.initDefaultProxies(proxy_arena.allocator(), env);
        }
        // Zig 0.17's CONNECT path returns the proxy-protocol connection without
        // wrapping the tunnel in origin TLS. Refuse before opening a connection
        // or sending credentials. Direct mode is an explicit caller decision.
        if (std.mem.eql(u8, uri.scheme, "https") and http.https_proxy != null)
            return error.HttpsProxyUnsupported;
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.api_key});
        defer allocator.free(authorization);
        const auth_override = http_headers.get(self.config.headers, "authorization");
        const extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len + 1);
        defer allocator.free(extra_headers);
        var extra_count: usize = 0;
        if (http_headers.get(self.config.headers, "accept") == null) {
            extra_headers[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
            extra_count += 1;
        }
        for (self.config.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
            extra_headers[extra_count] = header;
            extra_count += 1;
        }
        const payload = try encodeRequest(allocator, self.config, messages, tools);
        defer allocator.free(payload);
        var req = try http.request(.POST, uri, .{
            // Inspect redirect status without following it or draining its body.
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .authorization = if (auth_override) |value| .{ .override = value } else if (self.config.api_key.len == 0) .omit else .{ .override = authorization },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = extra_headers[0..extra_count],
        });
        defer req.deinit();
        if (req.connection) |conn| cancel_socket.set(self.io, conn.stream_reader.stream);
        defer cancel_socket.clear(self.io);
        try req.sendBodyComplete(payload);
        var response = try req.receiveHead(&.{});
        self.status = response.head.status;
        if (response.head.status != .ok) {
            self.retry_after_ms = http_headers.parseRetryAfterMs(response.head);
            return error.HttpRequestFailed;
        }
        if (response.head.content_encoding != .identity) return error.UnsupportedContentEncoding;
        const content_type = response.head.content_type orelse return error.InvalidContentType;
        const delimiter = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..delimiter], " \t"), "text/event-stream")) return error.InvalidContentType;
        var decoder = Decoder.init(allocator, sink);
        decoder.supports_finish_reason = self.config.compat.supports_finish_reason;
        defer decoder.deinit();
        var framing = sse.Decoder.init(allocator, 1024 * 1024);
        defer framing.deinit();
        var transfer_buffer: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var chunk: [8192]u8 = undefined;
        while (!decoder.done) {
            // Draining the Reader's internal buffer can avoid an extra socket
            // read before exposing already-arrived SSE bytes.
            const buffered = reader.buffered();
            if (buffered.len > 0) {
                try framing.feed(buffered, decoder.sseSink());
                reader.toss(buffered.len);
                continue;
            }
            // readVec returns available bytes; readSliceShort would wait for a
            // whole buffer and delay small streaming deltas until EOF.
            var vectors = [_][]u8{&chunk};
            const count = reader.readVec(&vectors) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ResponseReadFailed,
            };
            if (count > 0) try framing.feed(chunk[0..count], decoder.sseSink());
        }
        try framing.finish();
        if (!decoder.done) return error.TruncatedStream;
        // [DONE] terminates the application stream. Do not wait for an idle
        // keep-alive server to close the connection; req.deinit closes this
        // non-reusable request. Bytes after DONE in the same SSE batch still
        // fail through the terminal decoder.
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, config: Config, messages: []const model.Message, tools: []const model.ToolDefinition) ![]u8 {
    const projected = try model.projectSystemPrompt(allocator, messages);
    defer allocator.free(projected);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(config.model_id);
    try json.objectField("stream");
    try json.write(true);
    if (config.compat.supports_store) {
        try json.objectField("store");
        try json.write(false);
    }
    if (config.compat.supports_usage_in_streaming) {
        try json.objectField("stream_options");
        try json.beginObject();
        try json.objectField("include_usage");
        try json.write(true);
        try json.endObject();
    }
    try json.objectField(@tagName(config.compat.max_tokens_field));
    try json.write(try context_budget.clampMaxTokens(allocator, projected, tools, config.context_window, config.max_tokens));
    try json.objectField("messages");
    try json.beginArray();
    var previous_role: ?model.Role = null;
    for (projected) |message| {
        if (config.compat.requires_assistant_after_tool_result and previous_role == .tool_result and message.role == .user) {
            try writeAssistantBridge(&json);
        }
        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message.role == .tool_result) "tool" else @tagName(message.role));
        if (message.role == .tool_result) {
            try json.objectField("tool_call_id");
            try json.write(message.tool_call_id orelse return error.MissingToolCallId);
            if (config.compat.requires_tool_result_name) {
                if (message.tool_name) |name| {
                    try json.objectField("name");
                    try json.write(name);
                }
            }
        }
        var text = std.ArrayList(u8).empty;
        defer text.deinit(allocator);
        var calls = std.ArrayList(model.ToolCall).empty;
        defer calls.deinit(allocator);
        for (message.content) |content| switch (content) {
            .text => |part| try text.appendSlice(allocator, part),
            .tool_call => |call| {
                if (message.role != .assistant) return error.InvalidToolCallRole;
                try calls.append(allocator, call);
            },
            // Later adapters may handle these blocks. Never silently drop them.
            .image, .thinking => return error.UnsupportedContent,
        };
        try json.objectField("content");
        if (calls.items.len > 0 and text.items.len == 0 and !config.compat.requires_non_null_assistant_content and !config.compat.requires_assistant_after_tool_result) try json.write(null) else try json.write(text.items);
        if (calls.items.len > 0) {
            try json.objectField("tool_calls");
            try json.beginArray();
            for (calls.items) |call| {
                if (call.arguments != .object) return error.InvalidToolArguments;
                try json.beginObject();
                try json.objectField("id");
                try json.write(call.id);
                try json.objectField("type");
                try json.write("function");
                try json.objectField("function");
                try json.beginObject();
                try json.objectField("name");
                try json.write(call.name);
                try json.objectField("arguments");
                const arguments = try std.json.Stringify.valueAlloc(allocator, call.arguments, .{});
                defer allocator.free(arguments);
                try json.write(arguments);
                try json.endObject();
                try json.endObject();
            }
            try json.endArray();
        }
        try json.endObject();
        previous_role = message.role;
    }
    try json.endArray();
    if (tools.len > 0 or (config.compat.requires_tools_with_tool_history and hasToolHistory(projected))) {
        try json.objectField("tools");
        try json.beginArray();
        for (tools) |tool| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("function");
            try json.objectField("function");
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("parameters");
            try json.write(tool.parameters);
            try json.endObject();
            try json.endObject();
        }
        try json.endArray();
    }
    try json.endObject();
    return out.toOwnedSlice();
}

fn writeAssistantBridge(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("role");
    try json.write("assistant");
    try json.objectField("content");
    try json.write("I have processed the tool results.");
    try json.endObject();
}

const PendingCall = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    started: bool = false,
    emitted_arguments: usize = 0,
    fn deinit(self: *PendingCall, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    sink: model.EventSink,
    calls: std.ArrayList(PendingCall) = .empty,
    started: bool = false,
    done: bool = false,
    failed: bool = false,
    finish_reason: ?model.StopReason = null,
    supports_finish_reason: bool = true,
    total_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, sink: model.EventSink) Decoder {
        return .{ .allocator = allocator, .sink = sink };
    }
    pub fn deinit(self: *Decoder) void {
        for (self.calls.items) |*call| call.deinit(self.allocator);
        self.calls.deinit(self.allocator);
    }
    pub fn sseSink(self: *Decoder) sse.Sink {
        return .{ .context = self, .emit = onSse };
    }
    fn onSse(context: *anyopaque, event: sse.Event) anyerror!void {
        const self: *Decoder = @ptrCast(@alignCast(context));
        try self.feed(event.data);
    }
    fn emit(self: *Decoder, event: model.Event) !void {
        try self.sink.emit(self.sink.context, event);
    }
    pub fn feed(self: *Decoder, data: []const u8) !void {
        if (self.failed) return error.DecoderFailed;
        if (self.done) return error.StreamAlreadyDone;
        errdefer self.failed = true;
        if (self.total_bytes > 16 * 1024 * 1024 or data.len > 16 * 1024 * 1024 - self.total_bytes) return error.ResponseTooLarge;
        self.total_bytes += data.len;
        if (std.mem.eql(u8, data, "[DONE]")) {
            const reason: model.StopReason = self.finish_reason orelse reason: {
                if (self.supports_finish_reason) return error.MissingFinishReason;
                // An explicit [DONE] still gates inference. EOF never reaches this path.
                break :reason if (self.calls.items.len > 0) .tool_use else .stop;
            };
            if (!self.started) return error.EmptyResponse;
            if (reason == .error_response) {
                // A failed response can contain partial calls. End the stream
                // without exposing them for dispatch.
                try self.emit(.{ .done = reason });
                self.done = true;
                return;
            }
            if (self.calls.items.len > 0 and reason != .tool_use) return error.IncompleteToolResponse;
            // Validate ALL calls before exposing any as executable. A malformed
            // later call must not permit partial execution of the first call.
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var complete = try std.ArrayList(model.ToolCall).initCapacity(allocator, self.calls.items.len);
            for (self.calls.items) |call| {
                if (call.id.items.len == 0 or call.name.items.len == 0) return error.IncompleteToolCall;
                for (complete.items) |prior| if (std.mem.eql(u8, prior.id, call.id.items)) return error.DuplicateToolCallId;
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments.items, .{ .parse_numbers = false }) catch return error.InvalidToolArguments;
                if (parsed.value != .object) return error.InvalidToolArguments;
                try complete.append(allocator, .{ .id = call.id.items, .name = call.name.items, .arguments = parsed.value });
            }
            if (reason == .tool_use and complete.items.len == 0) return error.IncompleteToolCall;
            for (complete.items, 0..) |call, index| try self.emit(.{ .tool_call_end = .{ .index = index, .call = call } });
            try self.emit(.{ .done = reason });
            self.done = true;
            return;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidResponse;
        if (root.object.get("error") != null) return error.ProviderError;
        if (!self.started) {
            try self.emit(.start);
            self.started = true;
        }
        if (root.object.get("usage")) |usage| {
            if (usage == .object) try self.emit(.{ .usage = .{
                .input_tokens = try tokenCount(usage, "prompt_tokens"),
                .output_tokens = try tokenCount(usage, "completion_tokens"),
                .total_tokens = try tokenCount(usage, "total_tokens"),
            } });
        }
        const choices = root.object.get("choices") orelse {
            if (root.object.get("usage") != null) return;
            return error.InvalidResponse;
        };
        if (choices != .array or choices.array.items.len > 1) return error.InvalidResponse;
        for (choices.array.items) |choice| {
            if (choice != .object) return error.InvalidResponse;
            const index = choice.object.get("index") orelse return error.InvalidResponse;
            if (index != .integer or index.integer != 0) return error.InvalidResponse;
            const delta = choice.object.get("delta") orelse return error.InvalidResponse;
            if (delta != .object) return error.InvalidResponse;
            if (self.finish_reason != null) {
                // Usage trailers may arrive after the terminal choice. Never
                // let those accounting-only chunks mutate conversational state.
                if (choice.object.get("finish_reason")) |finish| {
                    if (finish != .null and (finish != .string or parseFinish(finish.string) != self.finish_reason.?)) return error.DataAfterFinish;
                }
                for ([_][]const u8{ "content", "reasoning_content", "tool_calls" }) |key| {
                    if (delta.object.get(key)) |v| {
                        if (v != .null) return error.DataAfterFinish;
                    }
                }
                continue;
            }
            if (delta.object.get("content")) |content| {
                if (content == .string) try self.emit(.{ .text_delta = content.string }) else if (content != .null) return error.InvalidResponse;
            }
            if (delta.object.get("reasoning_content")) |thinking| {
                if (thinking == .string) try self.emit(.{ .thinking_delta = thinking.string }) else if (thinking != .null) return error.InvalidResponse;
            }
            if (delta.object.get("tool_calls")) |calls| {
                if (calls != .array) return error.InvalidResponse;
                for (calls.array.items) |fragment| try self.appendCall(fragment);
            }
            if (choice.object.get("finish_reason")) |finish| {
                if (finish == .null) continue;
                if (finish != .string) return error.InvalidResponse;
                self.finish_reason = parseFinish(finish.string);
            }
        }
    }
    fn appendCall(self: *Decoder, value: std.json.Value) !void {
        if (value != .object) return error.InvalidResponse;
        const index_value = value.object.get("index") orelse return error.InvalidResponse;
        if (index_value != .integer or index_value.integer < 0 or index_value.integer >= 64) return error.InvalidToolIndex;
        const index: usize = @intCast(index_value.integer);
        while (self.calls.items.len <= index) try self.calls.append(self.allocator, .{});
        const call = &self.calls.items[index];
        if (value.object.get("type")) |kind| {
            if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return error.UnsupportedToolType;
        }
        if (value.object.get("id")) |id| {
            if (id != .string) return error.InvalidResponse;
            try appendBounded(self.allocator, &call.id, id.string);
        }
        if (value.object.get("function")) |function| {
            if (function != .object) return error.InvalidResponse;
            if (function.object.get("name")) |name| {
                if (name != .string) return error.InvalidResponse;
                try appendBounded(self.allocator, &call.name, name.string);
            }
            if (function.object.get("arguments")) |arguments| {
                if (arguments != .string) return error.InvalidResponse;
                try appendBounded(self.allocator, &call.arguments, arguments.string);
            }
        }
        if (!call.started and call.id.items.len > 0 and call.name.items.len > 0) {
            try self.emit(.{ .tool_call_start = .{ .index = index, .id = call.id.items, .name = call.name.items } });
            call.started = true;
        }
        if (call.started and call.arguments.items.len > call.emitted_arguments) {
            try self.emit(.{ .tool_call_delta = .{ .index = index, .arguments_fragment = call.arguments.items[call.emitted_arguments..] } });
            call.emitted_arguments = call.arguments.items.len;
        }
    }
};

fn appendBounded(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: []const u8) !void {
    if (list.items.len > 1024 * 1024 or value.len > 1024 * 1024 - list.items.len) return error.ToolCallTooLarge;
    try list.appendSlice(allocator, value);
}
fn hasToolHistory(messages: []const model.Message) bool {
    for (messages) |message| {
        if (message.role == .tool_result) return true;
        for (message.content) |part| if (part == .tool_call) return true;
    }
    return false;
}

fn parseFinish(value: []const u8) model.StopReason {
    if (std.mem.eql(u8, value, "stop") or std.mem.eql(u8, value, "end")) return .stop;
    if (std.mem.eql(u8, value, "tool_calls") or std.mem.eql(u8, value, "function_call")) return .tool_use;
    if (std.mem.eql(u8, value, "length")) return .length;
    // Provider failures such as content_filter and network_error, and unknown
    // reasons, all map to a failed completion.
    return .error_response;
}
fn tokenCount(value: std.json.Value, name: []const u8) !u64 {
    const number = value.object.get(name) orelse return 0;
    if (number != .integer or number.integer < 0) return error.InvalidUsage;
    return @intCast(number.integer);
}
