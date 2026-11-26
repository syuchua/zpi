const std = @import("std");
const model = @import("model");
const openai_responses = @import("openai_responses");

const Capture = struct {
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    fragments: std.ArrayList(u8) = .empty,
    last_id: std.ArrayList(u8) = .empty,
    last_name: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    starts: usize = 0,
    tool_starts: usize = 0,
    finishes: usize = 0,
    reason: ?model.StopReason = null,
    usage: ?model.Usage = null,
    arg_n: i64 = -1,

    fn sink(self: *Capture) model.EventSink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, event: model.Event) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        switch (event) {
            .start => self.starts += 1,
            .text_delta => |t| try self.text.appendSlice(std.testing.allocator, t),
            .thinking_delta => |t| try self.thinking.appendSlice(std.testing.allocator, t),
            .tool_call_start => |tc| {
                self.tool_starts += 1;
                self.last_id.clearRetainingCapacity();
                try self.last_id.appendSlice(std.testing.allocator, tc.id);
                self.last_name.clearRetainingCapacity();
                try self.last_name.appendSlice(std.testing.allocator, tc.name);
            },
            .tool_call_delta => |d| try self.fragments.appendSlice(std.testing.allocator, d.arguments_fragment),
            .tool_call_end => |tc| {
                self.calls += 1;
                if (tc.call.arguments.object.get("n")) |n| {
                    self.arg_n = switch (n) {
                        .integer => n.integer,
                        .number_string => |s| try std.fmt.parseInt(i64, s, 10),
                        else => return error.InvalidArgument,
                    };
                }
            },
            .usage => |u| self.usage = u,
            .done => |r| {
                self.finishes += 1;
                self.reason = r;
            },
        }
    }

    fn deinit(self: *Capture) void {
        self.text.deinit(std.testing.allocator);
        self.thinking.deinit(std.testing.allocator);
        self.fragments.deinit(std.testing.allocator);
        self.last_id.deinit(std.testing.allocator);
        self.last_name.deinit(std.testing.allocator);
    }
};

test "responses request encodes system prompt, assistant items, function calls, and tool outputs" {
    const a = std.testing.allocator;
    var schema = try std.json.parseFromSlice(std.json.Value, a, "{\"type\":\"object\"}", .{});
    defer schema.deinit();
    var call_args = try std.json.parseFromSlice(std.json.Value, a, "{\"path\":\"README.md\"}", .{});
    defer call_args.deinit();

    const messages = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "old sys" }} },
        .{ .role = .user, .content = &.{.{ .text = "check file" }} },
        .{ .role = .system, .content = &.{.{ .text = "new sys" }}, .system_prompt_replace = true },
        .{ .role = .assistant, .content = &.{
            .{ .text = "Reading now" },
            .{ .tool_call = .{ .id = "call_1|fc_abc", .name = "read", .arguments = call_args.value } },
            .{ .tool_call = .{ .id = "call_2|foreign_id", .name = "read", .arguments = call_args.value } },
        } },
        .{ .role = .tool_result, .tool_call_id = "call_1|fc_abc", .content = &.{.{ .text = "file body" }} },
        .{ .role = .tool_result, .tool_call_id = "call_2|foreign_id", .content = &.{} },
    };
    const tools = [_]model.ToolDefinition{.{ .name = "read", .description = "Read file", .parameters = schema.value }};
    const body = try openai_responses.encodeRequest(a, .{
        .endpoint = "http://127.0.0.1/v1/responses",
        .model_id = "gpt-5-codex",
        .api_key = "k",
        .max_tokens = 8,
    }, &messages, &tools);
    defer a.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gpt-5-codex", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool);
    try std.testing.expect(!root.get("store").?.bool);
    try std.testing.expectEqual(@as(i64, 16), root.get("max_output_tokens").?.integer);

    const input = root.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 7), input.len);
    try std.testing.expectEqualStrings("system", input[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("new sys", input[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("user", input[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("input_text", input[1].object.get("content").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("message", input[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("Reading now", input[2].object.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("function_call", input[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("fc_abc", input[3].object.get("id").?.string);
    try std.testing.expectEqualStrings("call_1", input[3].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("function_call", input[4].object.get("type").?.string);
    try std.testing.expect(input[4].object.get("id") == null);
    try std.testing.expectEqualStrings("call_2", input[4].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("function_call_output", input[5].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[5].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("file body", input[5].object.get("output").?.string);
    try std.testing.expectEqualStrings("(no tool output)", input[6].object.get("output").?.string);

    const req_tools = root.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), req_tools.len);
    try std.testing.expectEqualStrings("function", req_tools[0].object.get("type").?.string);
    try std.testing.expect(!req_tools[0].object.get("strict").?.bool);
}

test "Responses request encodes a user image as input_image data URL" {
    const a = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\nfixture";
    const messages = [_]model.Message{.{ .role = .user, .content = &.{ .{ .text = "describe" }, .{ .image = .{ .bytes = png, .mime_type = "image/png" } } } }};
    const body = try openai_responses.encodeRequest(a, .{ .endpoint = "unused", .model_id = "fixture", .api_key = "" }, &messages, &.{});
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("input").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("input_text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("input_image", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("auto", content[1].object.get("detail").?.string);
}

test "responses request rejects unsupported thinking content and missing tool_call_id" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidImageSize, openai_responses.encodeRequest(a, .{ .endpoint = "http://127.0.0.1/", .model_id = "m", .api_key = "" }, &.{
        .{ .role = .user, .content = &.{.{ .image = .{ .bytes = "", .mime_type = "image/png" } }} },
    }, &.{}));
    try std.testing.expectError(error.UnsupportedContent, openai_responses.encodeRequest(a, .{ .endpoint = "http://127.0.0.1/", .model_id = "m", .api_key = "" }, &.{
        .{ .role = .assistant, .content = &.{.{ .thinking = .{ .text = "hmm" } }} },
    }, &.{}));
    try std.testing.expectError(error.MissingToolCallId, openai_responses.encodeRequest(a, .{ .endpoint = "http://127.0.0.1/", .model_id = "m", .api_key = "" }, &.{
        .{ .role = .tool_result, .content = &.{.{ .text = "x" }} },
    }, &.{}));
}

test "responses decoder streams thinking, text, function_call deltas, usage, and validates before tool_call_end" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = openai_responses.Decoder.init(std.testing.allocator, capture.sink());
    defer decoder.deinit();

    const events = [_][]const u8{
        "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}",
        "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\"}}",
        "{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"delta\":\"plan\"}",
        "{\"type\":\"response.reasoning_summary_part.done\",\"output_index\":0}",
        "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\"}}",
        "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}",
        "{\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"hello \"}",
        "{\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"world\"}",
        "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello world\"}]}}",
        "{\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{\\\"n\\\":\"}}",
        "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"delta\":\"7}\"}",
        "{\"type\":\"response.function_call_arguments.done\",\"output_index\":2,\"arguments\":\"{\\\"n\\\":7}\"}",
        "{\"type\":\"response.output_item.done\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{\\\"n\\\":7}\"}}",
    };
    for (events) |ev| try decoder.feed(ev);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try decoder.feed("{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}");
    // Trailing [DONE] from compatible proxies after response.completed is tolerated cleanly.
    try decoder.feed("[DONE]");

    try std.testing.expectEqualStrings("plan\n\n", capture.thinking.items);
    try std.testing.expectEqualStrings("hello world", capture.text.items);
    try std.testing.expectEqualStrings("call_1|fc_1", capture.last_id.items);
    try std.testing.expectEqualStrings("read", capture.last_name.items);
    try std.testing.expectEqualStrings("{\"n\":7}", capture.fragments.items);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(i64, 7), capture.arg_n);
    try std.testing.expectEqual(@as(u64, 15), capture.usage.?.total_tokens);
    try std.testing.expectEqual(model.StopReason.tool_use, capture.reason.?);
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
}

test "responses decoder rejects unfinished or malformed tool calls and maps incomplete max_output_tokens" {
    {
        var capture: Capture = .{};
        defer capture.deinit();
        var decoder = openai_responses.Decoder.init(std.testing.allocator, capture.sink());
        defer decoder.deinit();
        try decoder.feed("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{\\\"n\\\":1}\"}}");
        try std.testing.expectError(error.IncompleteToolCall, decoder.feed("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}"));
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
    }
    {
        var capture: Capture = .{};
        defer capture.deinit();
        var decoder = openai_responses.Decoder.init(std.testing.allocator, capture.sink());
        defer decoder.deinit();
        try decoder.feed("{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{bad\"}}");
        try std.testing.expectError(error.InvalidToolArguments, decoder.feed("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}"));
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
    }
    {
        var capture: Capture = .{};
        defer capture.deinit();
        var decoder = openai_responses.Decoder.init(std.testing.allocator, capture.sink());
        defer decoder.deinit();
        try decoder.feed("{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}");
        try std.testing.expectEqual(model.StopReason.length, capture.reason.?);
    }
    {
        var capture: Capture = .{};
        defer capture.deinit();
        var decoder = openai_responses.Decoder.init(std.testing.allocator, capture.sink());
        defer decoder.deinit();
        try std.testing.expectError(error.TruncatedStream, decoder.feed("[DONE]"));
    }
    {
        var capture: Capture = .{};
        defer capture.deinit();
        var decoder = openai_responses.Decoder.init(std.testing.allocator, capture.sink());
        defer decoder.deinit();
        try decoder.feed("{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{\\\"n\\\":1}\"}}");
        try decoder.feed("{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"}}}");
        try std.testing.expectEqual(model.StopReason.error_response, capture.reason.?);
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
    }
}

const FakeServer = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    mode: enum { ok, retry_429, stall } = .ok,
    response_body: []const u8 = "",
    expected_auth: ?[]const u8 = null,

    fn run(self: *FakeServer) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var input_buffer: [16384]u8 = undefined;
        var output_buffer: [4096]u8 = undefined;
        var input = stream.reader(self.io, &input_buffer);
        var output = stream.writer(self.io, &output_buffer);
        var http_server = std.http.Server.init(&input.interface, &output.interface);
        var req = try http_server.receiveHead();
        if (req.head.method != .POST or !std.mem.eql(u8, req.head.target, "/v1/responses")) return error.UnexpectedRequest;
        if (self.expected_auth) |expected| {
            var auth_value: ?[]const u8 = null;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth_value = h.value;
            }
            if (!std.mem.eql(u8, auth_value orelse "", expected)) return error.InvalidAuthorization;
        }
        var body_buffer: [4096]u8 = undefined;
        const body_reader = req.readerExpectNone(&body_buffer);
        const body = try body_reader.allocRemaining(std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(body);

        switch (self.mode) {
            .retry_429 => return req.respond("", .{
                .status = .too_many_requests,
                .extra_headers = &.{.{ .name = "retry-after", .value = "2" }},
            }),
            .stall => {
                try self.io.sleep(.fromMilliseconds(30000), .awake);
                return;
            },
            .ok => {
                var streaming = try req.respondStreaming(&.{}, .{ .respond_options = .{
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
                } });
                for (self.response_body) |byte| {
                    try streaming.writer.writeByte(byte);
                    try streaming.writer.flush();
                }
                try streaming.end();
            },
        }
    }
};

test "responses client streams SSE over HTTP, parses retry hints, and cancels stalled stream" {
    const sse_body =
        "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
        "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"ok\"}\n\n" ++
        "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}\n\n" ++
        "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1,\"total_tokens\":4}}}\n\n";

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const endpoint = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/responses", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(endpoint);

    var fake = FakeServer{ .io = std.testing.io, .server = &server, .response_body = sse_body, .expected_auth = "Bearer secret-k" };
    var task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&fake});
    defer _ = task.cancel(std.testing.io) catch {};
    var capture: Capture = .{};
    defer capture.deinit();
    var client = openai_responses.Client{ .io = std.testing.io, .config = .{ .endpoint = endpoint, .api_key = "secret-k", .model_id = "gpt-5", .timeout_ms = 3000 } };
    try client.run(std.testing.allocator, &.{.{ .role = .user, .content = &.{.{ .text = "hi" }} }}, &.{}, capture.sink());
    try task.await(std.testing.io);
    try std.testing.expectEqualStrings("ok", capture.text.items);
    try std.testing.expectEqual(model.StopReason.stop, capture.reason.?);

    var retry_fake = FakeServer{ .io = std.testing.io, .server = &server, .mode = .retry_429 };
    var retry_task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&retry_fake});
    defer _ = retry_task.cancel(std.testing.io) catch {};
    var retry_cap: Capture = .{};
    defer retry_cap.deinit();
    try std.testing.expectError(error.HttpRequestFailed, client.run(std.testing.allocator, &.{.{ .role = .user, .content = &.{.{ .text = "hi" }} }}, &.{}, retry_cap.sink()));
    try retry_task.await(std.testing.io);
    const hint = client.retryHint(error.HttpRequestFailed);
    try std.testing.expect(hint.retryable);
    try std.testing.expectEqual(@as(?u64, 2000), hint.retry_after_ms);

    var stall_fake = FakeServer{ .io = std.testing.io, .server = &server, .mode = .stall };
    var stall_task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&stall_fake});
    defer _ = stall_task.cancel(std.testing.io) catch {};
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
    var stall_client = openai_responses.Client{ .io = std.testing.io, .config = .{ .endpoint = endpoint, .api_key = "secret-k", .model_id = "gpt-5", .timeout_ms = 5000 }, .cancel = interrupt.cancel() };
    var stall_cap: Capture = .{};
    defer stall_cap.deinit();
    try std.testing.expectError(error.Canceled, stall_client.run(std.testing.allocator, &.{.{ .role = .user, .content = &.{.{ .text = "hi" }} }}, &.{}, stall_cap.sink()));
    try std.testing.expectError(error.Canceled, stall_task.cancel(std.testing.io));
    try trig_task.await(std.testing.io);
}

test "responses request encodes reasoning effort and summary when thinking_level != off" {
    const a = std.testing.allocator;
    const msgs = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
    const off_body = try openai_responses.encodeRequest(a, .{ .endpoint = "http://127.0.0.1/v1/responses", .model_id = "gpt-5", .api_key = "" }, &msgs, &.{});
    defer a.free(off_body);
    var off_parsed = try std.json.parseFromSlice(std.json.Value, a, off_body, .{});
    defer off_parsed.deinit();
    try std.testing.expect(off_parsed.value.object.get("reasoning") == null);

    const xhigh_body = try openai_responses.encodeRequest(a, .{ .endpoint = "http://127.0.0.1/v1/responses", .model_id = "gpt-5", .api_key = "", .thinking_level = .max }, &msgs, &.{});
    defer a.free(xhigh_body);
    var xhigh_parsed = try std.json.parseFromSlice(std.json.Value, a, xhigh_body, .{});
    defer xhigh_parsed.deinit();
    const reasoning = xhigh_parsed.value.object.get("reasoning").?.object;
    try std.testing.expectEqualStrings("xhigh", reasoning.get("effort").?.string);
    try std.testing.expectEqualStrings("auto", reasoning.get("summary").?.string);
}
