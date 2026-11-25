//! OpenAI Responses API adapter (`openai-responses`). JSON is encoded/decoded
//! only at the network boundary. Native consumers receive borrowed typed events.
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
    max_tokens: u32 = 16384,
    /// Zero disables approximate context-window clipping.
    context_window: u32 = 0,
    thinking_level: model.ThinkingLevel = .off,
    timeout_ms: i64 = 60000,
};

pub const min_output_tokens: u32 = 16;

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
        return http_transport.retryHint(err, self.status, self.retry_after_ms);
    }

    pub fn run(self: *Client, allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
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
        if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidEndpoint;
        if (uri.user != null or uri.password != null) return error.InvalidEndpoint;
        if (std.mem.indexOfAny(u8, self.config.api_key, "\r\n") != null) return error.InvalidCredential;
        try http_headers.validateAll(self.config.headers);
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
        var decoder = Decoder.init(allocator, sink);
        defer decoder.deinit();
        try http_transport.postSse(allocator, self.io, .{
            .uri = uri,
            .authorization = if (auth_override) |value| value else if (self.config.api_key.len == 0) null else authorization,
            .extra_headers = extra_headers[0..extra_count],
            .payload = payload,
            .environ = self.environ,
            .proxy_policy = self.proxy_policy,
            .cancel_socket = cancel_socket,
        }, decoder.sseSink(), &decoder.done, &self.status, &self.retry_after_ms);
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
    try json.objectField("store");
    try json.write(false);
    try json.objectField("max_output_tokens");
    const clamped = try context_budget.clampMaxTokens(allocator, projected, tools, config.context_window, config.max_tokens);
    try json.write(@max(min_output_tokens, clamped));
    if (config.thinking_level != .off) {
        const effort = switch (config.thinking_level) {
            .off => unreachable,
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh, .max => "xhigh",
        };
        try json.objectField("reasoning");
        try json.beginObject();
        try json.objectField("effort");
        try json.write(effort);
        try json.objectField("summary");
        try json.write("auto");
        try json.endObject();
    }
    try json.objectField("input");
    try json.beginArray();

    var msg_index: usize = 0;
    for (projected) |message| {
        switch (message.role) {
            .system => {
                var text = std.ArrayList(u8).empty;
                defer text.deinit(allocator);
                for (message.content) |part| switch (part) {
                    .text => |value| try text.appendSlice(allocator, value),
                    .tool_call => return error.InvalidToolCallRole,
                    .image, .thinking => return error.UnsupportedContent,
                };
                if (text.items.len > 0) {
                    try json.beginObject();
                    try json.objectField("role");
                    try json.write("system");
                    try json.objectField("content");
                    try json.write(text.items);
                    try json.endObject();
                }
            },
            .user => {
                var text = std.ArrayList(u8).empty;
                defer text.deinit(allocator);
                for (message.content) |part| switch (part) {
                    .text => |value| try text.appendSlice(allocator, value),
                    .tool_call => return error.InvalidToolCallRole,
                    .image, .thinking => return error.UnsupportedContent,
                };
                try json.beginObject();
                try json.objectField("role");
                try json.write("user");
                try json.objectField("content");
                try json.beginArray();
                try json.beginObject();
                try json.objectField("type");
                try json.write("input_text");
                try json.objectField("text");
                try json.write(text.items);
                try json.endObject();
                try json.endArray();
                try json.endObject();
                msg_index += 1;
            },
            .assistant => {
                var text_block_index: usize = 0;
                for (message.content) |part| switch (part) {
                    .text => |value| {
                        const msg_id = if (text_block_index == 0)
                            try std.fmt.allocPrint(allocator, "msg_zpi_{d}", .{msg_index})
                        else
                            try std.fmt.allocPrint(allocator, "msg_zpi_{d}_{d}", .{ msg_index, text_block_index });
                        defer allocator.free(msg_id);
                        text_block_index += 1;
                        try json.beginObject();
                        try json.objectField("type");
                        try json.write("message");
                        try json.objectField("role");
                        try json.write("assistant");
                        try json.objectField("status");
                        try json.write("completed");
                        try json.objectField("id");
                        try json.write(msg_id);
                        try json.objectField("content");
                        try json.beginArray();
                        try json.beginObject();
                        try json.objectField("type");
                        try json.write("output_text");
                        try json.objectField("text");
                        try json.write(value);
                        try json.objectField("annotations");
                        try json.beginArray();
                        try json.endArray();
                        try json.endObject();
                        try json.endArray();
                        try json.endObject();
                    },
                    .tool_call => |call| {
                        if (call.arguments != .object) return error.InvalidToolArguments;
                        const sep = std.mem.indexOfScalar(u8, call.id, '|');
                        const call_id = if (sep) |idx| call.id[0..idx] else call.id;
                        const item_id = if (sep) |idx| call.id[idx + 1 ..] else null;
                        if (call_id.len == 0) return error.MissingToolCallId;
                        try json.beginObject();
                        try json.objectField("type");
                        try json.write("function_call");
                        if (item_id) |id_str| {
                            if (std.mem.startsWith(u8, id_str, "fc_") and id_str.len <= 64) {
                                try json.objectField("id");
                                try json.write(id_str);
                            }
                        }
                        try json.objectField("call_id");
                        try json.write(call_id);
                        try json.objectField("name");
                        try json.write(call.name);
                        try json.objectField("arguments");
                        const arguments = try std.json.Stringify.valueAlloc(allocator, call.arguments, .{});
                        defer allocator.free(arguments);
                        try json.write(arguments);
                        try json.endObject();
                    },
                    .image, .thinking => return error.UnsupportedContent,
                };
                msg_index += 1;
            },
            .tool_result => {
                const raw_id = message.tool_call_id orelse return error.MissingToolCallId;
                const sep = std.mem.indexOfScalar(u8, raw_id, '|');
                const call_id = if (sep) |idx| raw_id[0..idx] else raw_id;
                if (call_id.len == 0) return error.MissingToolCallId;
                var text = std.ArrayList(u8).empty;
                defer text.deinit(allocator);
                for (message.content) |part| switch (part) {
                    .text => |value| {
                        if (text.items.len > 0) try text.append(allocator, '\n');
                        try text.appendSlice(allocator, value);
                    },
                    .tool_call => return error.InvalidToolCallRole,
                    .image, .thinking => return error.UnsupportedContent,
                };
                const output_text = if (text.items.len == 0) "(no tool output)" else text.items;
                try json.beginObject();
                try json.objectField("type");
                try json.write("function_call_output");
                try json.objectField("call_id");
                try json.write(call_id);
                try json.objectField("output");
                try json.write(output_text);
                try json.endObject();
                msg_index += 1;
            },
        }
    }

    try json.endArray();
    if (tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (tools) |tool| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("function");
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("parameters");
            try json.write(tool.parameters);
            try json.objectField("strict");
            try json.write(false);
            try json.endObject();
        }
        try json.endArray();
    }
    try json.endObject();
    return out.toOwnedSlice();
}

const max_slots = 64;

const SlotKind = enum { empty, thinking, text, tool_call };
const Slot = struct {
    kind: SlotKind = .empty,
    call_index: usize = 0,
    streamed_chars: usize = 0,
};

const PendingCall = struct {
    combined_id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    finished: bool = false,
    emitted_arguments: usize = 0,

    fn deinit(self: *PendingCall, allocator: std.mem.Allocator) void {
        self.combined_id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    sink: model.EventSink,
    slots: [max_slots]Slot = @splat(.{}),
    calls: std.ArrayList(PendingCall) = .empty,
    started: bool = false,
    done: bool = false,
    failed: bool = false,
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
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (self.done) return;
            self.failed = true;
            return error.TruncatedStream;
        }
        if (self.done) return error.StreamAlreadyDone;
        errdefer self.failed = true;
        if (self.total_bytes > 16 * 1024 * 1024 or data.len > 16 * 1024 * 1024 - self.total_bytes) return error.ResponseTooLarge;
        self.total_bytes += data.len;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidResponse;
        const event_type = stringField(root, "type") orelse return error.InvalidResponse;

        if (std.mem.eql(u8, event_type, "error") or std.mem.eql(u8, event_type, "response.failed")) {
            return error.ProviderError;
        }
        if (!self.started) {
            try self.emit(.start);
            self.started = true;
        }

        if (std.mem.eql(u8, event_type, "response.created")) {
            return;
        } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const index = try outputIndex(root);
            const item = objectField(root, "item") orelse return error.InvalidResponse;
            try self.openSlot(index, item);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or std.mem.eql(u8, event_type, "response.reasoning_text.delta")) {
            const index = try outputIndex(root);
            const delta = stringField(root, "delta") orelse return error.InvalidResponse;
            if (self.slots[index].kind == .thinking and delta.len > 0) {
                try self.emit(.{ .thinking_delta = delta });
                self.slots[index].streamed_chars += delta.len;
            }
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            const index = try outputIndex(root);
            if (self.slots[index].kind == .thinking) {
                try self.emit(.{ .thinking_delta = "\n\n" });
                self.slots[index].streamed_chars += 2;
            }
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta") or std.mem.eql(u8, event_type, "response.refusal.delta")) {
            const index = try outputIndex(root);
            const delta = stringField(root, "delta") orelse return error.InvalidResponse;
            if (self.slots[index].kind == .text and delta.len > 0) {
                try self.emit(.{ .text_delta = delta });
                self.slots[index].streamed_chars += delta.len;
            }
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const index = try outputIndex(root);
            const delta = stringField(root, "delta") orelse return error.InvalidResponse;
            if (self.slots[index].kind != .tool_call) return;
            const call = &self.calls.items[self.slots[index].call_index];
            try appendBounded(self.allocator, &call.arguments, delta);
            if (call.arguments.items.len > call.emitted_arguments) {
                try self.emit(.{ .tool_call_delta = .{ .index = self.slots[index].call_index, .arguments_fragment = call.arguments.items[call.emitted_arguments..] } });
                call.emitted_arguments = call.arguments.items.len;
            }
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const index = try outputIndex(root);
            if (self.slots[index].kind != .tool_call) return;
            if (stringField(root, "arguments")) |final_args| {
                const call = &self.calls.items[self.slots[index].call_index];
                if (call.emitted_arguments == 0 and final_args.len > 0) {
                    try self.emit(.{ .tool_call_delta = .{ .index = self.slots[index].call_index, .arguments_fragment = final_args } });
                }
                call.arguments.clearRetainingCapacity();
                try appendBounded(self.allocator, &call.arguments, final_args);
                call.emitted_arguments = call.arguments.items.len;
            }
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const index = try outputIndex(root);
            const item = objectField(root, "item") orelse return error.InvalidResponse;
            if (self.slots[index].kind == .empty) try self.openSlot(index, item);
            switch (self.slots[index].kind) {
                .text => {
                    if (self.slots[index].streamed_chars == 0) {
                        const text = try extractMessageText(self.allocator, item);
                        defer self.allocator.free(text);
                        if (text.len > 0) try self.emit(.{ .text_delta = text });
                    }
                    self.slots[index] = .{};
                },
                .thinking => {
                    if (self.slots[index].streamed_chars == 0) {
                        const text = try extractReasoningText(self.allocator, item);
                        defer self.allocator.free(text);
                        if (text.len > 0) try self.emit(.{ .thinking_delta = text });
                    }
                    self.slots[index] = .{};
                },
                .tool_call => {
                    const call_idx = self.slots[index].call_index;
                    const call = &self.calls.items[call_idx];
                    if (stringField(item, "arguments")) |item_args| {
                        if (item_args.len > 0) {
                            if (call.emitted_arguments == 0) {
                                try self.emit(.{ .tool_call_delta = .{ .index = call_idx, .arguments_fragment = item_args } });
                            }
                            call.arguments.clearRetainingCapacity();
                            try appendBounded(self.allocator, &call.arguments, item_args);
                            call.emitted_arguments = call.arguments.items.len;
                        }
                    }
                    call.finished = true;
                    self.slots[index] = .{};
                },
                .empty => {},
            }
        } else if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) {
            const response = objectField(root, "response") orelse return error.InvalidResponse;
            if (objectField(response, "usage")) |usage| {
                const input_tokens = try tokenCount(usage, "input_tokens");
                const output_tokens = try tokenCount(usage, "output_tokens");
                const raw_total = try tokenCount(usage, "total_tokens");
                try self.emit(.{ .usage = .{
                    .input_tokens = input_tokens,
                    .output_tokens = output_tokens,
                    .total_tokens = if (raw_total > 0) raw_total else input_tokens +| output_tokens,
                } });
            }
            const status = stringField(response, "status") orelse "completed";
            const incomplete_reason = if (objectField(response, "incomplete_details")) |details| stringField(details, "reason") else null;
            var reason = try mapStopReason(status, incomplete_reason);
            if (reason == .error_response) {
                try self.emit(.{ .done = reason });
                self.done = true;
                return;
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const scratch = arena.allocator();
            var complete = try std.ArrayList(model.ToolCall).initCapacity(scratch, self.calls.items.len);
            for (self.calls.items) |call| {
                if (!call.finished or call.combined_id.items.len == 0 or call.name.items.len == 0) return error.IncompleteToolCall;
                for (complete.items) |prior| if (std.mem.eql(u8, prior.id, call.combined_id.items)) return error.DuplicateToolCallId;
                const parsed_args = std.json.parseFromSlice(std.json.Value, scratch, call.arguments.items, .{ .parse_numbers = false }) catch return error.InvalidToolArguments;
                if (parsed_args.value != .object) return error.InvalidToolArguments;
                try complete.append(scratch, .{ .id = call.combined_id.items, .name = call.name.items, .arguments = parsed_args.value });
            }
            if (complete.items.len > 0 and reason == .stop) reason = .tool_use;
            for (complete.items, 0..) |call, i| {
                try self.emit(.{ .tool_call_end = .{ .index = i, .call = call } });
            }
            try self.emit(.{ .done = reason });
            self.done = true;
        }
    }

    fn openSlot(self: *Decoder, index: usize, item: std.json.Value) !void {
        if (self.slots[index].kind != .empty) return error.InvalidResponse;
        const item_type = stringField(item, "type") orelse return error.InvalidResponse;
        if (std.mem.eql(u8, item_type, "reasoning")) {
            self.slots[index] = .{ .kind = .thinking };
        } else if (std.mem.eql(u8, item_type, "message")) {
            self.slots[index] = .{ .kind = .text };
        } else if (std.mem.eql(u8, item_type, "function_call")) {
            if (self.calls.items.len >= max_slots) return error.InvalidToolIndex;
            const call_id = stringField(item, "call_id") orelse return error.IncompleteToolCall;
            const name = stringField(item, "name") orelse return error.IncompleteToolCall;
            if (call_id.len == 0 or name.len == 0) return error.IncompleteToolCall;
            const item_id = stringField(item, "id");
            const call_index = self.calls.items.len;
            try self.calls.append(self.allocator, .{});
            const call = &self.calls.items[call_index];
            try appendBounded(self.allocator, &call.combined_id, call_id);
            if (item_id) |id_str| {
                if (id_str.len > 0) {
                    try appendBounded(self.allocator, &call.combined_id, "|");
                    try appendBounded(self.allocator, &call.combined_id, id_str);
                }
            }
            try appendBounded(self.allocator, &call.name, name);
            self.slots[index] = .{ .kind = .tool_call, .call_index = call_index };
            try self.emit(.{ .tool_call_start = .{ .index = call_index, .id = call.combined_id.items, .name = call.name.items } });
            if (stringField(item, "arguments")) |initial_args| {
                if (initial_args.len > 0) {
                    try appendBounded(self.allocator, &call.arguments, initial_args);
                    call.emitted_arguments = call.arguments.items.len;
                    try self.emit(.{ .tool_call_delta = .{ .index = call_index, .arguments_fragment = initial_args } });
                }
            }
        }
    }
};

fn outputIndex(root: std.json.Value) !usize {
    const val = root.object.get("output_index") orelse return error.InvalidResponse;
    if (val != .integer or val.integer < 0 or val.integer >= max_slots) return error.InvalidToolIndex;
    return @intCast(val.integer);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const child = value.object.get(name) orelse return null;
    return if (child == .string) child.string else null;
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const child = value.object.get(name) orelse return null;
    return if (child == .object) child else null;
}

fn extractMessageText(allocator: std.mem.Allocator, item: std.json.Value) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const content = item.object.get("content") orelse return out.toOwnedSlice(allocator);
    if (content != .array) return error.InvalidResponse;
    for (content.array.items) |part| {
        if (part != .object) return error.InvalidResponse;
        const kind = stringField(part, "type") orelse continue;
        if (std.mem.eql(u8, kind, "output_text")) {
            if (stringField(part, "text")) |t| try out.appendSlice(allocator, t);
        } else if (std.mem.eql(u8, kind, "refusal")) {
            if (stringField(part, "refusal")) |t| try out.appendSlice(allocator, t);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn extractReasoningText(allocator: std.mem.Allocator, item: std.json.Value) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for ([_][]const u8{ "summary", "content" }) |field_name| {
        if (out.items.len > 0) break;
        const arr = item.object.get(field_name) orelse continue;
        if (arr != .array) return error.InvalidResponse;
        for (arr.array.items) |part| {
            if (part != .object) return error.InvalidResponse;
            if (stringField(part, "text")) |t| {
                if (t.len > 0) {
                    if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
                    try out.appendSlice(allocator, t);
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn mapStopReason(status: []const u8, incomplete_reason: ?[]const u8) !model.StopReason {
    if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "in_progress") or std.mem.eql(u8, status, "queued")) {
        return .stop;
    }
    if (std.mem.eql(u8, status, "incomplete")) {
        if (incomplete_reason) |r| {
            if (std.mem.eql(u8, r, "max_output_tokens")) return .length;
        }
        return .error_response;
    }
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) {
        return .error_response;
    }
    return error.InvalidResponse;
}

fn appendBounded(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: []const u8) !void {
    if (list.items.len > 1024 * 1024 or value.len > 1024 * 1024 - list.items.len) return error.ToolCallTooLarge;
    try list.appendSlice(allocator, value);
}

fn tokenCount(value: std.json.Value, name: []const u8) !u64 {
    const number = value.object.get(name) orelse return 0;
    if (number != .integer or number.integer < 0) return error.InvalidUsage;
    return @intCast(number.integer);
}
