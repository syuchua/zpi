const std = @import("std");
const model = @import("model");
const openai = @import("openai");

const Capture = struct {
    text: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    starts: usize = 0,
    fragments_before_start: usize = 0,
    fragments: std.ArrayList(u8) = .empty,
    finishes: usize = 0,
    reason: ?model.StopReason = null,
    arg: i64 = -1,
    tool_name: [32]u8 = undefined,
    tool_name_len: usize = 0,

    fn sink(self: *Capture) model.EventSink {
        return .{ .context = self, .emit = emit };
    }
    fn emit(context: *anyopaque, event: model.Event) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        switch (event) {
            .start => self.starts += 1,
            .text_delta => |text| try self.text.appendSlice(std.testing.allocator, text),
            .tool_call_end => |call| {
                self.calls += 1;
                if (call.call.name.len > self.tool_name.len) return error.NameTooLong;
                @memcpy(self.tool_name[0..call.call.name.len], call.call.name);
                self.tool_name_len = call.call.name.len;
                const n = call.call.arguments.object.get("n") orelse return error.MissingArgument;
                self.arg = switch (n) {
                    .integer => n.integer,
                    .number_string => |s| try std.fmt.parseInt(i64, s, 10),
                    else => return error.InvalidArgument,
                };
            },
            .tool_call_start => self.starts += 1,
            .tool_call_delta => |delta| {
                if (self.starts == 0) self.fragments_before_start += 1;
                try self.fragments.appendSlice(std.testing.allocator, delta.arguments_fragment);
            },
            .done => |reason| {
                self.finishes += 1;
                self.reason = reason;
            },
            else => {},
        }
    }
    fn deinit(self: *Capture) void {
        self.text.deinit(std.testing.allocator);
        self.fragments.deinit(std.testing.allocator);
    }
};

const first = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"n\\\":\"}}]},\"finish_reason\":null}]}";
const second = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"7}\"}}]},\"finish_reason\":\"tool_calls\"}]}";

test "stream decoder assembles tool arguments and preserves terminal ordering" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = openai.Decoder.init(std.testing.allocator, capture.sink());
    defer decoder.deinit();
    try decoder.feed(first);
    try decoder.feed(second);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try decoder.feed("[DONE]");
    try std.testing.expectEqualStrings("hello", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualStrings("read", capture.tool_name[0..capture.tool_name_len]);
    try std.testing.expectEqual(@as(i64, 7), capture.arg);
    try std.testing.expectEqual(model.StopReason.tool_use, capture.reason.?);
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
    try std.testing.expectEqualStrings("{\"n\":7}", capture.fragments.items);
    try std.testing.expectEqual(@as(usize, 0), capture.fragments_before_start);
    try std.testing.expectError(error.StreamAlreadyDone, decoder.feed("[DONE]"));
}

test "incomplete or malformed tool calls never become executable" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = openai.Decoder.init(std.testing.allocator, capture.sink());
    defer decoder.deinit();
    try decoder.feed(first);
    try decoder.feed("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}");
    try std.testing.expectError(error.InvalidToolArguments, decoder.feed("[DONE]"));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), capture.finishes);
}

test "request serializes text, schemas and tool result IDs" {
    var schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"object\"}", .{});
    defer schema.deinit();
    const content = [_]model.Content{.{ .text = "file" }};
    const messages = [_]model.Message{.{ .role = .tool_result, .content = &content, .tool_call_id = "id-1" }};
    const tools = [_]model.ToolDefinition{.{ .name = "read", .description = "read a file", .parameters = schema.value }};
    const body = try openai.encodeRequest(std.testing.allocator, .{ .endpoint = "http://127.0.0.1/", .model_id = "test", .api_key = "" }, &messages, &tools);
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("test", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("id-1", parsed.value.object.get("messages").?.array.items[0].object.get("tool_call_id").?.string);
    try std.testing.expect(parsed.value.object.get("stream").?.bool);
}

test "OpenAI compatibility settings select request fields and replay requirements" {
    const a = std.testing.allocator;
    const empty_args = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer empty_args.deinit();
    const history = [_]model.Message{
        .{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = empty_args.value } }} },
        .{ .role = .tool_result, .tool_call_id = "call-1", .content = &.{.{ .text = "result" }} },
    };
    const normal = try openai.encodeRequest(a, .{ .endpoint = "unused", .model_id = "fixture", .api_key = "", .compat = .{ .max_tokens_field = .max_completion_tokens } }, &history, &.{});
    defer a.free(normal);
    const normal_json = try std.json.parseFromSlice(std.json.Value, a, normal, .{});
    defer normal_json.deinit();
    try std.testing.expect(normal_json.value.object.get("max_completion_tokens") != null);
    try std.testing.expect(normal_json.value.object.get("max_tokens") == null);
    try std.testing.expect(normal_json.value.object.get("tools") == null);
    try std.testing.expect(normal_json.value.object.get("stream_options").?.object.get("include_usage").?.bool);
    try std.testing.expect(normal_json.value.object.get("store") == null);
    try std.testing.expect(normal_json.value.object.get("messages").?.array.items[0].object.get("content").? == .null);

    const no_usage = try openai.encodeRequest(a, .{ .endpoint = "unused", .model_id = "fixture", .api_key = "", .compat = .{ .supports_usage_in_streaming = false } }, &.{}, &.{});
    defer a.free(no_usage);
    const no_usage_json = try std.json.parseFromSlice(std.json.Value, a, no_usage, .{});
    defer no_usage_json.deinit();
    try std.testing.expect(no_usage_json.value.object.get("stream_options") == null);

    const compatible = try openai.encodeRequest(a, .{ .endpoint = "unused", .model_id = "fixture", .api_key = "", .compat = .{ .max_tokens_field = .max_completion_tokens, .requires_non_null_assistant_content = true, .requires_tools_with_tool_history = true } }, &history, &.{});
    defer a.free(compatible);
    const compatible_json = try std.json.parseFromSlice(std.json.Value, a, compatible, .{});
    defer compatible_json.deinit();
    const first_message = compatible_json.value.object.get("messages").?.array.items[0];
    try std.testing.expectEqualStrings("", first_message.object.get("content").?.string);
    try std.testing.expectEqual(@as(usize, 0), compatible_json.value.object.get("tools").?.array.items.len);

    const store_request = try openai.encodeRequest(a, .{
        .endpoint = "unused",
        .model_id = "fixture",
        .api_key = "",
        .compat = .{ .supports_store = true },
    }, &.{}, &.{});
    defer a.free(store_request);
    const store_json = try std.json.parseFromSlice(std.json.Value, a, store_request, .{});
    defer store_json.deinit();
    try std.testing.expect(store_json.value.object.get("store").? == .bool);
    try std.testing.expect(!store_json.value.object.get("store").?.bool);
}

test "OpenAI compatibility handles tool result names and assistant bridge requirements" {
    const a = std.testing.allocator;
    const messages = [_]model.Message{
        .{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments = .{ .object = .empty } } }} },
        .{ .role = .tool_result, .tool_call_id = "call", .tool_name = "read", .content = &.{.{ .text = "result" }} },
        .{ .role = .user, .content = &.{.{ .text = "follow-up" }} },
    };
    const config: openai.Config = .{ .endpoint = "unused", .model_id = "fixture", .api_key = "", .compat = .{ .requires_tool_result_name = true, .requires_assistant_after_tool_result = true } };
    const body = try openai.encodeRequest(a, config, &messages, &.{});
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const wire = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), wire.len);
    try std.testing.expectEqualStrings("read", wire[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("assistant", wire[2].object.get("role").?.string);
    try std.testing.expectEqualStrings("I have processed the tool results.", wire[2].object.get("content").?.string);
    try std.testing.expectEqualStrings("user", wire[3].object.get("role").?.string);

    const tool_only = [_]model.Message{messages[0]};
    const tool_body = try openai.encodeRequest(a, config, &tool_only, &.{});
    defer a.free(tool_body);
    const tool_parsed = try std.json.parseFromSlice(std.json.Value, a, tool_body, .{});
    defer tool_parsed.deinit();
    try std.testing.expectEqualStrings("", tool_parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string);
}

test "OpenAI clips output against projected system context on each request" {
    const a = std.testing.allocator;
    const old = try a.alloc(u8, 20000);
    defer a.free(old);
    @memset(old, 'x');
    const messages = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = old }} },
        .{ .role = .system, .content = &.{.{ .text = "1234567" }}, .system_prompt_replace = true },
        .{ .role = .user, .content = &.{.{ .text = "1234567" }} },
    };
    for ([_]struct { window: u32, expected: i64 }{
        .{ .window = 0, .expected = 2000 },
        .{ .window = 5000, .expected = 900 },
        .{ .window = 4096, .expected = 1 },
    }) |case| {
        const body = try openai.encodeRequest(a, .{ .endpoint = "unused", .model_id = "fixture", .api_key = "", .max_tokens = 2000, .context_window = case.window }, &messages, &.{});
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, parsed.value.object.get("max_tokens").?.integer);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("messages").?.array.items.len);
    }
}

test "multiple tool calls and multipart messages remain valid without leaks" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = openai.Decoder.init(std.testing.allocator, capture.sink());
    defer decoder.deinit();
    try decoder.feed("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"n\\\":1}\"}},{\"index\":1,\"id\":\"c2\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"n\\\":2}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try decoder.feed("[DONE]");
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    const messages = [_]model.Message{.{ .role = .user, .content = &.{ .{ .text = "a" }, .{ .text = "b" } } }};
    const body = try openai.encodeRequest(std.testing.allocator, .{ .endpoint = "http://127.0.0.1", .model_id = "fixture", .api_key = "" }, &messages, &.{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"ab\"") != null);
}

test "OpenAI stop reason mapping matches pi and unsupported reasons fail closed" {
    const cases = [_]struct { value: []const u8, expected: model.StopReason }{
        .{ .value = "stop", .expected = .stop },
        .{ .value = "end", .expected = .stop },
        .{ .value = "length", .expected = .length },
        .{ .value = "tool_calls", .expected = .tool_use },
        .{ .value = "function_call", .expected = .tool_use },
        .{ .value = "content_filter", .expected = .error_response },
        .{ .value = "network_error", .expected = .error_response },
        .{ .value = "future_reason", .expected = .error_response },
    };
    for (cases) |case| {
        var capture: Capture = .{};
        defer capture.deinit();
        var decoder = openai.Decoder.init(std.testing.allocator, capture.sink());
        defer decoder.deinit();
        // Stage an incomplete call even for failed completions. Only a valid
        // tool-use finish may publish an executable call.
        if (case.expected == .tool_use or case.expected == .error_response) try decoder.feed(first);
        const delta = if (case.expected == .tool_use)
            "{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"7}\"}}]}"
        else
            "{}";
        const terminal = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"choices\":[{{\"index\":0,\"delta\":{s},\"finish_reason\":\"{s}\"}}]}}",
            .{ delta, case.value },
        );
        defer std.testing.allocator.free(terminal);
        try decoder.feed(terminal);
        try std.testing.expectEqual(@as(usize, 0), capture.finishes);
        try decoder.feed("[DONE]");
        try std.testing.expectEqual(case.expected, capture.reason.?);
        try std.testing.expectEqual(@as(usize, 1), capture.finishes);
        try std.testing.expectEqual(@as(usize, @intFromBool(case.expected == .tool_use)), capture.calls);
    }
}

test "finish reason may be inferred only when explicitly configured" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = openai.Decoder.init(std.testing.allocator, capture.sink());
    decoder.supports_finish_reason = false;
    defer decoder.deinit();
    try decoder.feed("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}");
    try decoder.feed("[DONE]");
    try std.testing.expectEqual(model.StopReason.stop, capture.reason.?);

    var strict_capture: Capture = .{};
    defer strict_capture.deinit();
    var strict = openai.Decoder.init(std.testing.allocator, strict_capture.sink());
    defer strict.deinit();
    try strict.feed("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}");
    try std.testing.expectError(error.MissingFinishReason, strict.feed("[DONE]"));

    var calls_capture: Capture = .{};
    defer calls_capture.deinit();
    var calls = openai.Decoder.init(std.testing.allocator, calls_capture.sink());
    calls.supports_finish_reason = false;
    defer calls.deinit();
    try calls.feed(first);
    try calls.feed("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"7}\"}}]}}]}");
    try std.testing.expectEqual(@as(usize, 0), calls_capture.calls);
    try calls.feed("[DONE]");
    try std.testing.expectEqual(model.StopReason.tool_use, calls_capture.reason.?);
    try std.testing.expectEqual(@as(usize, 1), calls_capture.calls);

    var incomplete_capture: Capture = .{};
    defer incomplete_capture.deinit();
    var incomplete = openai.Decoder.init(std.testing.allocator, incomplete_capture.sink());
    incomplete.supports_finish_reason = false;
    defer incomplete.deinit();
    try incomplete.feed(first);
    try std.testing.expectError(error.InvalidToolArguments, incomplete.feed("[DONE]"));
    try std.testing.expectEqual(@as(usize, 0), incomplete_capture.calls);
    try std.testing.expectEqual(@as(usize, 0), incomplete_capture.finishes);

    var filtered_capture: Capture = .{};
    defer filtered_capture.deinit();
    var filtered = openai.Decoder.init(std.testing.allocator, filtered_capture.sink());
    filtered.supports_finish_reason = false;
    defer filtered.deinit();
    try filtered.feed(first);
    try filtered.feed("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}");
    try filtered.feed("[DONE]");
    try std.testing.expectEqual(model.StopReason.error_response, filtered_capture.reason.?);
    try std.testing.expectEqual(@as(usize, 0), filtered_capture.calls);
}

test "duplicate terminal choices and usage trailers are accepted but new data is rejected" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = openai.Decoder.init(std.testing.allocator, capture.sink());
    defer decoder.deinit();
    const terminal = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}";
    try decoder.feed(terminal);
    try decoder.feed(terminal);
    try decoder.feed("{\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}");
    try decoder.feed("[DONE]");
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
    var invalid = openai.Decoder.init(std.testing.allocator, capture.sink());
    defer invalid.deinit();
    try invalid.feed(terminal);
    try std.testing.expectError(error.DataAfterFinish, invalid.feed("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"late\"},\"finish_reason\":null}]}"));
}

const FakeServer = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    response: []const u8,
    mode: enum { ok, status_error, wrong_content_type, no_done, stall } = .ok,
    status_body: []const u8 = "fixture failure",
    status: std.http.Status = .unauthorized,
    expected_authorization: []const u8 = "Bearer test-key",
    expected_headers: []const std.http.Header = &.{},
    absent: ?[]const u8 = null,
    fn run(self: *FakeServer) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var input_buffer: [16384]u8 = undefined;
        var output_buffer: [4096]u8 = undefined;
        var input = stream.reader(self.io, &input_buffer);
        var output = stream.writer(self.io, &output_buffer);
        var server = std.http.Server.init(&input.interface, &output.interface);
        var req = try server.receiveHead();
        if (req.head.method != .POST or !std.mem.eql(u8, req.head.target, "/v1/chat/completions")) return error.UnexpectedRequest;
        var auth_count: usize = 0;
        var auth_value: ?[]const u8 = null;
        var iterator = req.iterateHeaders();
        while (iterator.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
            auth_count += 1;
            auth_value = header.value;
        }
        if (auth_count != 1 or !std.mem.eql(u8, auth_value orelse "", self.expected_authorization)) return error.InvalidAuthorization;
        for (self.expected_headers) |expected| {
            var count: usize = 0;
            iterator = req.iterateHeaders();
            while (iterator.next()) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, expected.name)) continue;
                count += 1;
                if (!std.mem.eql(u8, header.value, expected.value)) return error.WrongCustomHeader;
            }
            if (count != 1) return error.MissingOrDuplicateCustomHeader;
        }
        if (self.absent) |needle| if (std.mem.indexOf(u8, req.head_buffer, needle) != null) return error.UnexpectedHeader;
        var body_buffer: [4096]u8 = undefined;
        const body_reader = req.readerExpectNone(&body_buffer);
        const body = try body_reader.allocRemaining(std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(body);
        var request_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
        defer request_json.deinit();
        if (!request_json.value.object.get("stream").?.bool) return error.StreamNotRequested;
        switch (self.mode) {
            .status_error => return req.respond(self.status_body, .{ .status = self.status }),
            .wrong_content_type => return req.respond("{}", .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} }),
            .stall => {
                try self.io.sleep(.fromMilliseconds(30000), .awake);
                return;
            },
            else => {},
        }
        var streaming = try req.respondStreaming(&.{}, .{ .respond_options = .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
        } });
        // Every byte is its own flushed HTTP chunk: HTTP/SSE framing must not
        // assume chunk boundaries align with UTF-8, JSON tokens or lines.
        const payload = if (self.mode == .no_done) "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n" else self.response;
        for (payload) |byte| {
            try streaming.writer.writeByte(byte);
            try streaming.writer.flush();
        }
        try streaming.end();
    }
};

test "HTTP failures truncated streams and stalls return explicit errors without body capture" {
    const cases = [_]struct {
        mode: @FieldType(FakeServer, "mode"),
        expected: anyerror,
        status: ?std.http.Status = .ok,
        body: []const u8 = "",
    }{
        .{ .mode = .status_error, .expected = error.HttpRequestFailed, .status = .unauthorized, .body = "fixture failure" },
        .{ .mode = .status_error, .expected = error.HttpRequestFailed, .status = .too_many_requests, .body = "sensitive-key reflected by proxy" },
        .{ .mode = .wrong_content_type, .expected = error.InvalidContentType },
        .{ .mode = .no_done, .expected = error.TruncatedStream },
        .{ .mode = .stall, .expected = error.RequestTimeout, .status = null },
    };
    for (cases) |case| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try address.listen(std.testing.io, .{ .reuse_address = true });
        defer server.deinit(std.testing.io);
        const endpoint = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
        defer std.testing.allocator.free(endpoint);
        var fake = FakeServer{ .io = std.testing.io, .server = &server, .response = "", .mode = case.mode, .status = case.status orelse .ok, .status_body = case.body };
        var task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&fake});
        defer _ = task.cancel(std.testing.io) catch {};
        var capture: Capture = .{};
        defer capture.deinit();
        var client = openai.Client{ .io = std.testing.io, .config = .{
            .endpoint = endpoint,
            .api_key = "test-key",
            .model_id = "fixture",
            .timeout_ms = if (case.mode == .stall) 200 else 3000,
            .compat = .{ .supports_finish_reason = case.mode != .no_done },
        } };
        const messages = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
        try std.testing.expectError(case.expected, client.run(std.testing.allocator, &messages, &.{}, capture.sink()));
        try std.testing.expectEqual(case.status, client.status);
        try std.testing.expectEqual(@as(usize, 0), capture.finishes);
        if (case.mode == .stall) {
            try std.testing.expectError(error.Canceled, task.cancel(std.testing.io));
        } else {
            try task.await(std.testing.io);
        }
    }
}

test "late tool id buffers argument fragments until tool start" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = openai.Decoder.init(std.testing.allocator, capture.sink());
    defer decoder.deinit();
    try decoder.feed("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"n\\\":\"}}]},\"finish_reason\":null}]}");
    try std.testing.expectEqual(@as(usize, 0), capture.fragments.items.len);
    try decoder.feed("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"late\",\"function\":{\"arguments\":\"7}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try decoder.feed("[DONE]");
    try std.testing.expectEqual(@as(usize, 0), capture.fragments_before_start);
    try std.testing.expectEqualStrings("{\"n\":7}", capture.fragments.items);
}

test "local HTTP streaming accepts OpenAI request and emits deltas" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const endpoint = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(endpoint);
    var fake = FakeServer{ .io = std.testing.io, .server = &server, .response = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n" };
    var task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&fake});
    defer _ = task.cancel(std.testing.io) catch {};
    var capture: Capture = .{};
    defer capture.deinit();
    var client = openai.Client{ .io = std.testing.io, .config = .{ .endpoint = endpoint, .api_key = "test-key", .model_id = "fixture", .timeout_ms = 3000 } };
    const content = [_]model.Content{.{ .text = "hi" }};
    const messages = [_]model.Message{.{ .role = .user, .content = &content }};
    try client.run(std.testing.allocator, &messages, &.{}, capture.sink());
    try task.await(std.testing.io);
    try std.testing.expectEqualStrings("hello", capture.text.items);
    try std.testing.expectEqual(model.StopReason.stop, capture.reason.?);
}

test "configured OpenAI headers override authorization and are sent once" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const endpoint = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(endpoint);
    var fake = FakeServer{
        .io = std.testing.io,
        .server = &server,
        .response = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
        .expected_authorization = "Token fixture",
        .expected_headers = &.{ .{ .name = "x-fixture", .value = "enabled" }, .{ .name = "accept", .value = "application/json" } },
        .absent = "Bearer test-key",
    };
    var task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&fake});
    defer _ = task.cancel(std.testing.io) catch {};
    var capture: Capture = .{};
    defer capture.deinit();
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = "Token fixture" },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "x-fixture", .value = "enabled" },
    };
    var client = openai.Client{ .io = std.testing.io, .config = .{
        .endpoint = endpoint,
        .api_key = "test-key",
        .model_id = "fixture",
        .headers = &headers,
        .timeout_ms = 3000,
    } };
    const content = [_]model.Content{.{ .text = "hi" }};
    const messages = [_]model.Message{.{ .role = .user, .content = &content }};
    try client.run(std.testing.allocator, &messages, &.{}, capture.sink());
    try task.await(std.testing.io);
    try std.testing.expectEqualStrings("hello", capture.text.items);
    try std.testing.expectEqual(model.StopReason.stop, capture.reason.?);
}

test "OpenAI client aborts stalled stream promptly on interrupt" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const endpoint = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(endpoint);
    var fake = FakeServer{ .io = std.testing.io, .server = &server, .response = "", .mode = .stall };
    var task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&fake});
    defer _ = task.cancel(std.testing.io) catch {};
    var interrupt = try model.Interrupt.init();
    defer interrupt.deinit(std.testing.io);
    const Trigger = struct {
        target: *model.Interrupt,
        fn run(self: *@This(), io: std.Io) std.Io.Cancelable!void {
            try io.sleep(.fromMilliseconds(40), .awake);
            self.target.trigger();
        }
    };
    var trig = Trigger{ .target = &interrupt };
    var trig_task = try std.Io.concurrent(std.testing.io, Trigger.run, .{ &trig, std.testing.io });
    defer _ = trig_task.cancel(std.testing.io) catch {};
    var capture: Capture = .{};
    defer capture.deinit();
    var client = openai.Client{
        .io = std.testing.io,
        .config = .{ .endpoint = endpoint, .api_key = "test-key", .model_id = "fixture", .timeout_ms = 5000 },
        .cancel = interrupt.cancel(),
    };
    const content = [_]model.Content{.{ .text = "hi" }};
    const messages = [_]model.Message{.{ .role = .user, .content = &content }};
    try std.testing.expectError(error.Canceled, client.run(std.testing.allocator, &messages, &.{}, capture.sink()));
    try trig_task.await(std.testing.io);
    try std.testing.expect(capture.reason == null);
}

test "OpenAI Chat Completions encodes reasoning_effort only when thinking_level != off" {
    const a = std.testing.allocator;
    const msgs = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
    const off_body = try openai.encodeRequest(a, .{ .endpoint = "http://127.0.0.1/v1/chat/completions", .model_id = "m", .api_key = "" }, &msgs, &.{});
    defer a.free(off_body);
    var off_parsed = try std.json.parseFromSlice(std.json.Value, a, off_body, .{});
    defer off_parsed.deinit();
    try std.testing.expect(off_parsed.value.object.get("reasoning_effort") == null);

    const max_body = try openai.encodeRequest(a, .{ .endpoint = "http://127.0.0.1/v1/chat/completions", .model_id = "m", .api_key = "", .thinking_level = .max }, &msgs, &.{});
    defer a.free(max_body);
    var max_parsed = try std.json.parseFromSlice(std.json.Value, a, max_body, .{});
    defer max_parsed.deinit();
    try std.testing.expectEqualStrings("high", max_parsed.value.object.get("reasoning_effort").?.string);
}
