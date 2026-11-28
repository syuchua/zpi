//! Native Google Gemini `streamGenerateContent?alt=sse` provider client.
//! Uses `x-goog-api-key` header (never URL query parameters) and the shared
//! HTTP/HTTPS SSE transport with system proxy support.
const std = @import("std");
const model = @import("model");
const sse = @import("sse");
const http_headers = @import("http_headers");
const http_transport = @import("http_transport");
const context_budget = @import("context_budget");

pub const ProxyPolicy = http_transport.ProxyPolicy;

pub const Config = struct {
    endpoint: []const u8,
    model_id: []const u8,
    api_key: []const u8,
    headers: []const std.http.Header = &.{},
    max_tokens: u32 = 8192,
    context_window: u32 = 0,
    thinking_level: model.ThinkingLevel = .off,
    timeout_ms: i64 = 60000,
};

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
        if (std.mem.indexOfAny(u8, self.config.api_key, "\r\n") != null) return error.InvalidCredential;
        try http_headers.validateAll(self.config.headers);

        const encoding_started = model.Timing.start(self.timing, self.io);
        const payload = try encodeRequest(allocator, self.config, messages, tools);
        model.Timing.finish(self.timing, self.io, encoding_started, "request_encode");
        defer allocator.free(payload);

        const accept_override = http_headers.get(self.config.headers, "accept");
        const key_override = http_headers.get(self.config.headers, "x-goog-api-key");
        const extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len + 2);
        defer allocator.free(extra_headers);
        var header_count: usize = 0;

        extra_headers[header_count] = .{ .name = "accept", .value = accept_override orelse "text/event-stream" };
        header_count += 1;
        if (key_override) |value| {
            extra_headers[header_count] = .{ .name = "x-goog-api-key", .value = value };
            header_count += 1;
        } else if (self.config.api_key.len > 0) {
            extra_headers[header_count] = .{ .name = "x-goog-api-key", .value = self.config.api_key };
            header_count += 1;
        }
        for (self.config.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "accept") or std.ascii.eqlIgnoreCase(header.name, "x-goog-api-key")) continue;
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

const PendingCall = struct {
    id: []const u8,
    name: []const u8,
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

    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(a);

    try json.objectField("contents");
    try json.beginArray();

    var pending_calls: std.ArrayList(PendingCall) = .empty;
    defer pending_calls.deinit(a);
    var tool_result_count: usize = 0;
    var conversation_started = false;

    for (projected) |message| {
        if (message.role == .tool_result) {
            if (!conversation_started) return error.OrphanToolResult;
            const raw_id = message.tool_call_id orelse return error.MissingToolCallId;
            if (raw_id.len == 0) return error.InvalidToolCallId;

            var matched_name: ?[]const u8 = null;
            for (pending_calls.items, 0..) |pending, idx| {
                if (std.mem.eql(u8, pending.id, raw_id)) {
                    matched_name = pending.name;
                    _ = pending_calls.orderedRemove(idx);
                    break;
                }
            }
            const tool_name = matched_name orelse message.tool_name orelse return error.OrphanToolResult;
            if (tool_name.len == 0) return error.InvalidToolCall;

            if (tool_result_count == 0) {
                try json.beginObject();
                try json.objectField("role");
                try json.write("user");
                try json.objectField("parts");
                try json.beginArray();
            }

            try json.beginObject();
            try json.objectField("functionResponse");
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool_name);
            try json.objectField("response");
            try json.beginObject();
            try json.objectField(if (message.is_error) "error" else "result");
            const joined = try collectText(a, message.content);
            defer a.free(joined);
            try json.write(joined);
            try json.endObject();
            try json.endObject();
            try json.endObject();

            tool_result_count += 1;
            continue;
        }

        if (tool_result_count > 0) {
            try json.endArray();
            try json.endObject();
            tool_result_count = 0;
        }
        if (pending_calls.items.len > 0) return error.MissingToolResult;

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
                if (part.tool_call.id.len == 0 or part.tool_call.name.len == 0) return error.InvalidToolCall;
                for (pending_calls.items) |prior| if (std.mem.eql(u8, prior.id, part.tool_call.id)) return error.DuplicateToolCallId;
                try pending_calls.append(a, .{ .id = part.tool_call.id, .name = part.tool_call.name });
            };
        }

        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message.role == .assistant) "model" else "user");
        try json.objectField("parts");
        try json.beginArray();
        var emitted_parts: usize = 0;
        for (message.content) |part| switch (part) {
            .text => |text| {
                try json.beginObject();
                try json.objectField("text");
                try json.write(text);
                try json.endObject();
                emitted_parts += 1;
            },
            .thinking => {
                // Gemini does not require replaying unsigned reasoning text across turns.
            },
            .image => |image| {
                if (message.role != .user) return error.InvalidImageRole;
                try json.beginObject();
                try json.objectField("inlineData");
                try json.beginObject();
                try json.objectField("mimeType");
                try json.write(image.mime_type);
                try json.objectField("data");
                try image.writeBase64(&json, false);
                try json.endObject();
                try json.endObject();
                emitted_parts += 1;
            },
            .tool_call => |call| {
                if (message.role != .assistant or call.arguments != .object) return error.InvalidToolArguments;
                try json.beginObject();
                try json.objectField("functionCall");
                try json.beginObject();
                try json.objectField("name");
                try json.write(call.name);
                try json.objectField("args");
                try json.write(call.arguments);
                try json.endObject();
                try json.endObject();
                emitted_parts += 1;
            },
        };
        if (emitted_parts == 0) {
            try json.beginObject();
            try json.objectField("text");
            try json.write("");
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }

    if (tool_result_count > 0) {
        try json.endArray();
        try json.endObject();
    }
    if (pending_calls.items.len != 0) return error.MissingToolResult;
    try json.endArray();

    if (system.items.len > 0) {
        try json.objectField("systemInstruction");
        try json.beginObject();
        try json.objectField("parts");
        try json.beginArray();
        try json.beginObject();
        try json.objectField("text");
        try json.write(system.items);
        try json.endObject();
        try json.endArray();
        try json.endObject();
    }

    if (tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        try json.beginObject();
        try json.objectField("functionDeclarations");
        try json.beginArray();
        for (tools) |tool| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("parameters");
            try writeSanitizedSchema(&json, tool.parameters);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
        try json.endArray();
    }

    const clamped_max = try context_budget.clampMaxTokens(a, projected, tools, config.context_window, config.max_tokens);
    try json.objectField("generationConfig");
    try json.beginObject();
    try json.objectField("maxOutputTokens");
    try json.write(clamped_max);
    if (thinkingBudget(config.thinking_level)) |budget| {
        try json.objectField("thinkingConfig");
        try json.beginObject();
        try json.objectField("includeThoughts");
        try json.write(true);
        try json.objectField("thinkingBudget");
        try json.write(budget);
        try json.endObject();
    }
    try json.endObject();

    try json.endObject();
    return out.toOwnedSlice();
}

fn thinkingBudget(level: model.ThinkingLevel) ?u32 {
    return switch (level) {
        .off => null,
        .minimal => 1024,
        .low => 2048,
        .medium => 8192,
        .high => 16384,
        .xhigh => 24576,
        .max => 32768,
    };
}

/// Gemini's OpenAPI schema subset rejects `additionalProperties` and `$schema`.
/// Strip unsupported keys recursively while preserving object/array/property structure.
fn writeSanitizedSchema(json: *std.json.Stringify, value: std.json.Value) !void {
    switch (value) {
        .object => |obj| {
            try json.beginObject();
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "additionalProperties") or
                    std.mem.eql(u8, key, "$schema") or
                    std.mem.eql(u8, key, "oneOf") or
                    std.mem.eql(u8, key, "anyOf"))
                {
                    continue;
                }
                try json.objectField(key);
                try writeSanitizedSchema(json, entry.value_ptr.*);
            }
            try json.endObject();
        },
        .array => |arr| {
            try json.beginArray();
            for (arr.items) |item| try writeSanitizedSchema(json, item);
            try json.endArray();
        },
        else => try json.write(value),
    }
}

fn collectText(a: std.mem.Allocator, content: []const model.Content) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (content) |part| switch (part) {
        .text => |text| try out.appendSlice(a, text),
        else => return error.UnsupportedContent,
    };
    return out.toOwnedSlice(a);
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    sink: model.EventSink,
    started: bool = false,
    done: bool = false,
    failed: bool = false,
    saw_tool_call: bool = false,
    call_counter: usize = 0,
    bytes: usize = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    has_usage: bool = false,

    pub fn init(a: std.mem.Allocator, sink: model.EventSink) Decoder {
        return .{ .allocator = a, .sink = sink };
    }

    pub fn deinit(_: *Decoder) void {}

    pub fn sseSink(self: *Decoder) sse.Sink {
        return .{ .context = self, .emit = onSse };
    }

    fn onSse(ctx: *anyopaque, event: sse.Event) anyerror!void {
        const self: *Decoder = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, event.event, "error")) {
            self.failed = true;
            return error.ProviderError;
        }
        const trimmed = std.mem.trim(u8, event.data, " \t\r\n");
        if (trimmed.len == 0) return;
        try self.feed(trimmed);
    }

    fn emit(self: *Decoder, event: model.Event) !void {
        try self.sink.emit(self.sink.context, event);
    }

    pub fn feed(self: *Decoder, data: []const u8) !void {
        if (self.failed) return error.DecoderFailed;
        if (self.done) return error.StreamAlreadyDone;
        errdefer self.failed = true;
        if (self.bytes > 16 * 1024 * 1024 or data.len > 16 * 1024 * 1024 - self.bytes) return error.ResponseTooLarge;
        self.bytes += data.len;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .parse_numbers = false }) catch return error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;

        if (root.get("error") != null) return error.ProviderError;

        if (!self.started) {
            self.started = true;
            try self.emit(.start);
        }

        if (root.get("usageMetadata")) |usage_val| {
            try self.updateUsage(usage_val);
        }

        if (root.get("promptFeedback")) |fb| {
            if (fb == .object) {
                if (fb.object.get("blockReason")) |br| {
                    if (br == .string and br.string.len > 0) {
                        if (self.has_usage) try self.emitUsage();
                        self.done = true;
                        try self.emit(.{ .done = .error_response });
                        return;
                    }
                }
            }
        }

        var finish_reason: ?[]const u8 = null;
        if (root.get("candidates")) |cands_val| {
            if (cands_val != .array) return error.InvalidResponse;
            if (cands_val.array.items.len > 0) {
                const cand = cands_val.array.items[0];
                if (cand != .object) return error.InvalidResponse;
                if (cand.object.get("content")) |content_val| {
                    if (content_val != .object) return error.InvalidResponse;
                    if (content_val.object.get("parts")) |parts_val| {
                        if (parts_val != .array) return error.InvalidResponse;
                        for (parts_val.array.items) |part| {
                            if (part != .object) return error.InvalidResponse;
                            const is_thought = if (part.object.get("thought")) |t| (t == .bool and t.bool) else false;
                            if (part.object.get("text")) |text_val| {
                                if (text_val != .string) return error.InvalidResponse;
                                if (text_val.string.len > 0) {
                                    if (is_thought) {
                                        try self.emit(.{ .thinking_delta = text_val.string });
                                    } else {
                                        try self.emit(.{ .text_delta = text_val.string });
                                    }
                                }
                            }
                            if (part.object.get("functionCall")) |fc_val| {
                                if (fc_val != .object) return error.InvalidToolCall;
                                const name_val = fc_val.object.get("name") orelse return error.InvalidToolCall;
                                if (name_val != .string or name_val.string.len == 0) return error.InvalidToolCall;
                                const args_val: std.json.Value = if (fc_val.object.get("args")) |av| blk: {
                                    if (av != .object) return error.InvalidToolArguments;
                                    break :blk av;
                                } else .{ .object = .empty };

                                const idx = self.call_counter;
                                self.call_counter += 1;
                                var id_buf: [64]u8 = undefined;
                                const call_id: []const u8 = if (fc_val.object.get("id")) |id_v| blk: {
                                    if (id_v == .string and id_v.string.len > 0) break :blk id_v.string;
                                    break :blk try std.fmt.bufPrint(&id_buf, "gemini_call_{d}", .{self.call_counter});
                                } else try std.fmt.bufPrint(&id_buf, "gemini_call_{d}", .{self.call_counter});

                                self.saw_tool_call = true;
                                try self.emit(.{ .tool_call_start = .{
                                    .index = idx,
                                    .id = call_id,
                                    .name = name_val.string,
                                } });
                                try self.emit(.{ .tool_call_end = .{
                                    .index = idx,
                                    .call = .{
                                        .id = call_id,
                                        .name = name_val.string,
                                        .arguments = args_val,
                                    },
                                } });
                            }
                        }
                    }
                }
                if (cand.object.get("finishReason")) |fr_val| {
                    if (fr_val == .string and fr_val.string.len > 0) {
                        finish_reason = fr_val.string;
                    }
                }
            }
        }

        if (finish_reason) |reason| {
            if (self.has_usage) try self.emitUsage();
            const stop = mapFinishReason(reason, self.saw_tool_call);
            self.done = true;
            try self.emit(.{ .done = stop });
        }
    }

    fn updateUsage(self: *Decoder, value: std.json.Value) !void {
        if (value != .object) return error.InvalidUsage;
        if (value.object.get("promptTokenCount")) |v| {
            self.input_tokens = try uint(v);
            self.has_usage = true;
        }
        var out_tokens: u64 = 0;
        var got_out = false;
        if (value.object.get("candidatesTokenCount")) |v| {
            out_tokens += try uint(v);
            got_out = true;
        }
        if (value.object.get("thoughtsTokenCount")) |v| {
            out_tokens += try uint(v);
            got_out = true;
        }
        if (got_out) {
            self.output_tokens = out_tokens;
            self.has_usage = true;
        }
        if (value.object.get("totalTokenCount")) |v| {
            self.total_tokens = try uint(v);
            self.has_usage = true;
        }
        if (value.object.get("cachedContentTokenCount")) |v| {
            self.cache_read_tokens = try uint(v);
            self.has_usage = true;
        }
    }

    fn emitUsage(self: *Decoder) !void {
        const total = if (self.total_tokens > 0) self.total_tokens else self.input_tokens + self.output_tokens;
        try self.emit(.{ .usage = .{
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .total_tokens = total,
            .cache_read_tokens = self.cache_read_tokens,
        } });
    }
};

fn mapFinishReason(reason: []const u8, saw_tool_call: bool) model.StopReason {
    if (std.mem.eql(u8, reason, "STOP")) return if (saw_tool_call) .tool_use else .stop;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, reason, "FINISH_REASON_UNSPECIFIED")) return if (saw_tool_call) .tool_use else .stop;
    return .error_response;
}

fn uint(v: std.json.Value) !u64 {
    return switch (v) {
        .integer => |number| if (number < 0) error.InvalidUsage else @intCast(number),
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch error.InvalidUsage,
        else => error.InvalidUsage,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Capture = struct {
    allocator: std.mem.Allocator,
    started: usize = 0,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(OwnedCall) = .empty,
    usage: ?model.Usage = null,
    done: ?model.StopReason = null,

    const OwnedCall = struct { id: []u8, name: []u8, args_json: []u8 };

    fn deinit(self: *Capture) void {
        self.text.deinit(self.allocator);
        self.thinking.deinit(self.allocator);
        for (self.tool_calls.items) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.args_json);
        }
        self.tool_calls.deinit(self.allocator);
    }

    fn sink(self: *Capture) model.EventSink {
        return .{ .context = self, .emit = onEvent };
    }

    fn onEvent(ctx: *anyopaque, event: model.Event) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        switch (event) {
            .start => self.started += 1,
            .text_delta => |d| try self.text.appendSlice(self.allocator, d),
            .thinking_delta => |d| try self.thinking.appendSlice(self.allocator, d),
            .tool_call_end => |tc| {
                const id = try self.allocator.dupe(u8, tc.call.id);
                errdefer self.allocator.free(id);
                const name = try self.allocator.dupe(u8, tc.call.name);
                errdefer self.allocator.free(name);
                const args_json = try std.json.Stringify.valueAlloc(self.allocator, tc.call.arguments, .{});
                try self.tool_calls.append(self.allocator, .{ .id = id, .name = name, .args_json = args_json });
            },
            .usage => |u| self.usage = u,
            .done => |r| self.done = r,
            else => {},
        }
    }
};

test "gemini encodeRequest formats system, multi-turn tool calls, images, thinking, and strips additionalProperties" {
    const a = std.testing.allocator;
    var schema = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}",
        .{},
    );
    defer schema.deinit();
    var call_args = try std.json.parseFromSlice(std.json.Value, a, "{\"path\":\"README.md\"}", .{});
    defer call_args.deinit();

    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 0 };
    const messages = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "You are concise." }} },
        .{ .role = .user, .content = &.{ .{ .text = "Inspect" }, .{ .image = .{ .bytes = &png, .mime_type = "image/png" } } } },
        .{ .role = .assistant, .content = &.{
            .{ .thinking = .{ .text = "private thought" } },
            .{ .tool_call = .{ .id = "gemini_call_1", .name = "read", .arguments = call_args.value } },
        } },
        .{ .role = .tool_result, .tool_call_id = "gemini_call_1", .content = &.{.{ .text = "hello file" }} },
    };
    const tools = [_]model.ToolDefinition{.{
        .name = "read",
        .description = "Read file",
        .parameters = schema.value,
    }};

    const payload = try encodeRequest(a, .{
        .endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
        .model_id = "gemini-2.5-flash",
        .api_key = "test-key",
        .max_tokens = 2048,
        .thinking_level = .low,
    }, &messages, &tools);
    defer a.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"inlineData\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"functionCall\":{\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"functionResponse\":{\"name\":\"read\",\"response\":{\"result\":\"hello file\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"thinkingBudget\":2048") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "additionalProperties") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "private thought") == null);
}

test "gemini Decoder parses text, thought, functionCall, cached usage, and finishReason" {
    const a = std.testing.allocator;
    var cap = Capture{ .allocator = a };
    defer cap.deinit();
    var dec = Decoder.init(a, cap.sink());
    defer dec.deinit();

    try dec.feed("{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"ponder\",\"thought\":true},{\"text\":\"Hello \"}]}}]}");
    try dec.feed("{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"world\"},{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a.txt\"}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":100,\"candidatesTokenCount\":25,\"thoughtsTokenCount\":15,\"totalTokenCount\":140,\"cachedContentTokenCount\":60}}");

    try std.testing.expect(dec.done);
    try std.testing.expectEqual(@as(usize, 1), cap.started);
    try std.testing.expectEqualStrings("ponder", cap.thinking.items);
    try std.testing.expectEqualStrings("Hello world", cap.text.items);
    try std.testing.expectEqual(@as(usize, 1), cap.tool_calls.items.len);
    try std.testing.expectEqualStrings("gemini_call_1", cap.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read", cap.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", cap.tool_calls.items[0].args_json);
    try std.testing.expectEqual(model.StopReason.tool_use, cap.done.?);
    try std.testing.expectEqual(@as(u64, 100), cap.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 40), cap.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u64, 140), cap.usage.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 60), cap.usage.?.cache_read_tokens);
}

test "gemini Client streams SSE over loopback HTTP and sends x-goog-api-key header" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const ServerCtx = struct {
        srv: *std.Io.net.Server,
        io: std.Io,
        saw_key: bool = false,
        fn run(self: *@This()) void {
            var stream = self.srv.accept(self.io) catch return;
            defer stream.close(self.io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &rbuf);
            var writer = stream.writer(self.io, &wbuf);
            var http_srv = std.http.Server.init(&reader.interface, &writer.interface);
            var req = http_srv.receiveHead() catch return;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "x-goog-api-key") and std.mem.eql(u8, h.value, "gem-secret-123")) {
                    self.saw_key = true;
                }
            }
            const body =
                "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hi from \"}]}}]}\n\n" ++
                "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Gemini!\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":12,\"candidatesTokenCount\":5,\"totalTokenCount\":17}}\n\n";
            req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            }) catch {};
        }
    };
    var sctx = ServerCtx{ .srv = &server, .io = io };
    var task = try std.Io.concurrent(io, ServerCtx.run, .{&sctx});
    defer task.cancel(io);

    const endpoint = try a.print("http://127.0.0.1:{d}/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse", .{port});
    defer a.free(endpoint);

    var client = Client{
        .io = io,
        .config = .{
            .endpoint = endpoint,
            .model_id = "gemini-2.5-flash",
            .api_key = "gem-secret-123",
            .timeout_ms = 5000,
        },
        .proxy_policy = .none,
    };
    var cap = Capture{ .allocator = a };
    defer cap.deinit();
    const msgs = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "hello" }} }};
    try client.run(a, &msgs, &.{}, cap.sink());
    task.await(io);

    try std.testing.expect(sctx.saw_key);
    try std.testing.expectEqualStrings("Hi from Gemini!", cap.text.items);
    try std.testing.expectEqual(model.StopReason.stop, cap.done.?);
    try std.testing.expectEqual(@as(u64, 17), cap.usage.?.total_tokens);
}
