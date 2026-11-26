const std = @import("std");
const model = @import("model");
const anthropic = @import("anthropic");
const sse = @import("sse");
const a = std.testing.allocator;
const Capture = struct {
    text: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    starts: usize = 0,
    done: ?model.StopReason = null,
    usage: model.Usage = .{},
    fn sink(self: *Capture) model.EventSink {
        return .{ .context = self, .emit = emit };
    }
    fn emit(ctx: *anyopaque, event: model.Event) !void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        switch (event) {
            .text_delta => |t| try self.text.appendSlice(a, t),
            .tool_call_start => self.starts += 1,
            .tool_call_end => |t| {
                try std.testing.expect(t.call.arguments == .object);
                self.calls += 1;
            },
            .done => |r| self.done = r,
            .usage => |u| self.usage = u,
            else => {},
        }
    }
    fn deinit(self: *Capture) void {
        self.text.deinit(a);
    }
};
const start = "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":0,\"cache_read_input_tokens\":7}}}";
fn feed(decoder: *anthropic.Decoder, data: []const u8) !void {
    try decoder.feed("", data);
}
fn tool(decoder: *anthropic.Decoder, index: usize, id: []const u8, arguments: []const u8) !void {
    const begin = try std.fmt.allocPrint(a, "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"read\",\"input\":{{}}}}}}", .{ index, id });
    defer a.free(begin);
    try feed(decoder, begin);
    const quoted = try std.json.Stringify.valueAlloc(a, arguments, .{});
    defer a.free(quoted);
    const delta = try std.fmt.allocPrint(a, "{{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}", .{ index, quoted });
    defer a.free(delta);
    try feed(decoder, delta);
    const end = try std.fmt.allocPrint(a, "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{index});
    defer a.free(end);
    try feed(decoder, end);
}
test "Anthropic assembles calls only after all blocks validate and merges cache usage" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = anthropic.Decoder.init(a, capture.sink());
    defer decoder.deinit();
    try feed(&decoder, start);
    try feed(&decoder, "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Hello\"}}");
    try feed(&decoder, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}");
    try feed(&decoder, "{\"type\":\"content_block_stop\",\"index\":0}");
    try tool(&decoder, 1, "call_1", "{\"path\":\"a\"}");
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try feed(&decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2,\"input_tokens\":null}}");
    try feed(&decoder, "{\"type\":\"message_stop\"}");
    try std.testing.expectEqualStrings("Hello world", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(model.StopReason.tool_use, capture.done.?);
    try std.testing.expectEqual(@as(u64, 12), capture.usage.total_tokens);
}
test "Anthropic malformed later tool and duplicate IDs expose no executable calls" {
    for ([_]bool{ false, true }) |duplicate| {
        var capture: Capture = .{};
        defer capture.deinit();
        var decoder = anthropic.Decoder.init(a, capture.sink());
        defer decoder.deinit();
        try feed(&decoder, start);
        try tool(&decoder, 0, "call_1", "{}");
        try tool(&decoder, 1, if (duplicate) "call_1" else "call_2", if (duplicate) "{}" else "{broken");
        try feed(&decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}");
        if (duplicate) try std.testing.expectError(error.DuplicateToolCallId, feed(&decoder, "{\"type\":\"message_stop\"}")) else try std.testing.expectError(error.InvalidToolArguments, feed(&decoder, "{\"type\":\"message_stop\"}"));
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
        try std.testing.expect(capture.done == null);
    }
}
test "Anthropic rejects unsupported thinking and closed block deltas" {
    var capture: Capture = .{};
    defer capture.deinit();
    var decoder = anthropic.Decoder.init(a, capture.sink());
    defer decoder.deinit();
    try feed(&decoder, start);
    try std.testing.expectError(error.ThinkingUnsupported, feed(&decoder, "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"x\"}}"));
    try std.testing.expectError(error.DecoderFailed, feed(&decoder, start));
    var other = anthropic.Decoder.init(a, capture.sink());
    defer other.deinit();
    try feed(&other, start);
    try tool(&other, 0, "call", "{}");
    try std.testing.expectError(error.UnknownBlock, feed(&other, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}"));
}
test "Anthropic encodes user image blocks and validates detected MIME type" {
    const allocator = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\nfixture";
    const messages = [_]model.Message{.{ .role = .user, .content = &.{ .{ .text = "describe" }, .{ .image = .{ .bytes = png, .mime_type = "image/png" } } } }};
    const body = try anthropic.encodeRequest(allocator, .{ .endpoint = "unused", .api_key = "", .model_id = "fixture" }, &messages, &.{});
    defer allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("image", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("image/png", content[1].object.get("source").?.object.get("media_type").?.string);
    const invalid = [_]model.Message{.{ .role = .user, .content = &.{.{ .image = .{ .bytes = "bad", .mime_type = "image/png" } }} }};
    try std.testing.expectError(error.UnsupportedImageType, anthropic.encodeRequest(allocator, .{ .endpoint = "unused", .api_key = "", .model_id = "fixture" }, &invalid, &.{}));
}
test "Anthropic request lifts leading system and groups consecutive tool results" {
    const messages = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "instructions" }} },
        .{ .role = .user, .content = &.{.{ .text = "hello" }} },
        .{ .role = .assistant, .content = &.{
            .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = .{ .object = .empty } } },
            .{ .tool_call = .{ .id = "call_2", .name = "read", .arguments = .{ .object = .empty } } },
        } },
        .{ .role = .tool_result, .tool_call_id = "call_1", .content = &.{ .{ .text = "a" }, .{ .text = "b" } } },
        .{ .role = .tool_result, .tool_call_id = "call_2", .is_error = true, .content = &.{.{ .text = "failed" }} },
    };
    const body = try anthropic.encodeRequest(a, .{ .endpoint = "unused", .api_key = "", .model_id = "fixture" }, &messages, &.{});
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("instructions", parsed.value.object.get("system").?.string);
    const wire = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), wire.len);
    try std.testing.expectEqualStrings("user", wire[2].object.get("role").?.string);
    const results = wire[2].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[1].object.get("is_error").?.bool);
    try std.testing.expectEqual(@as(usize, 2), results[0].object.get("content").?.array.items.len);
    const bad = [_]model.Message{.{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "bad/id", .name = "read", .arguments = .{ .object = .empty } } }} }};
    try std.testing.expectError(error.InvalidToolCallId, anthropic.encodeRequest(a, .{ .endpoint = "unused", .api_key = "", .model_id = "fixture" }, &bad, &.{}));
}
test "Anthropic clips output from the projected context and leaves defaults unchanged" {
    const messages = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "1234567" }}, .system_prompt_replace = true },
        .{ .role = .user, .content = &.{.{ .text = "1234567" }} },
    };
    for ([_]struct { window: u32, expected: i64 }{
        .{ .window = 0, .expected = 2000 },
        .{ .window = 5000, .expected = 900 },
        .{ .window = 4096, .expected = 1 },
    }) |case| {
        const body = try anthropic.encodeRequest(a, .{ .endpoint = "unused", .model_id = "fixture", .api_key = "", .max_tokens = 2000, .context_window = case.window }, &messages, &.{});
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, parsed.value.object.get("max_tokens").?.integer);
        try std.testing.expectEqualStrings("1234567", parsed.value.object.get("system").?.string);
    }
}

const FakeServer = struct {
    server: *std.Io.net.Server,
    mode: enum { ok, unauthorized, truncated, stall, provider_error } = .ok,
    expected_api_key: []const u8 = "fixture-key",
    expected_version: []const u8 = "2023-06-01",
    expected_headers: []const std.http.Header = &.{},
    absent: ?[]const u8 = null,
    fn run(self: *FakeServer) !void {
        const stream = try self.server.accept(std.testing.io);
        defer stream.close(std.testing.io);
        var ib: [16384]u8 = undefined;
        var ob: [4096]u8 = undefined;
        var input = stream.reader(std.testing.io, &ib);
        var output = stream.writer(std.testing.io, &ob);
        var server = std.http.Server.init(&input.interface, &output.interface);
        var req = try server.receiveHead();
        if (!std.mem.eql(u8, req.head.target, "/v1/messages")) return error.WrongPath;
        const defaults = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.expected_api_key },
            .{ .name = "anthropic-version", .value = self.expected_version },
        };
        for ([_][]const std.http.Header{ &defaults, self.expected_headers }) |expected_headers| {
            for (expected_headers) |expected| {
                var count: usize = 0;
                var iterator = req.iterateHeaders();
                while (iterator.next()) |header| {
                    if (!std.ascii.eqlIgnoreCase(header.name, expected.name)) continue;
                    count += 1;
                    if (!std.mem.eql(u8, header.value, expected.value)) return error.WrongCustomHeader;
                }
                if (count != 1) return error.MissingOrDuplicateCustomHeader;
            }
        }
        if (self.absent) |needle| if (std.mem.indexOf(u8, req.head_buffer, needle) != null) return error.UnexpectedHeader;
        var bb: [4096]u8 = undefined;
        const body = try req.readerExpectNone(&bb).allocRemaining(a, .limited(1024 * 1024));
        defer a.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        if (!parsed.value.object.get("stream").?.bool) return error.WrongBody;
        if (self.mode == .unauthorized) return req.respond("fixture", .{ .status = .unauthorized });
        if (self.mode == .stall) {
            try std.testing.io.sleep(.fromSeconds(30), .awake);
            return;
        }
        var streaming = try req.respondStreaming(&.{}, .{ .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} } });
        const payload = "event: message_start\ndata: " ++ start ++ "\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"hello\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n";
        for (payload) |byte| {
            try streaming.writer.writeByte(byte);
            try streaming.writer.flush();
        }
        if (self.mode == .provider_error) try streaming.writer.writeAll("event: error\ndata: {\"type\":\"error\"}\n\n") else if (self.mode != .truncated) try streaming.writer.writeAll("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n");
        try streaming.end();
    }
};
test "Anthropic HTTP headers streaming truncation provider errors and timeout" {
    for ([_]@FieldType(FakeServer, "mode"){ .ok, .unauthorized, .truncated, .stall, .provider_error }) |mode| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try address.listen(std.testing.io, .{ .reuse_address = true });
        defer server.deinit(std.testing.io);
        const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/messages", .{server.socket.address.getPort()});
        defer a.free(endpoint);
        var fake = FakeServer{ .server = &server, .mode = mode };
        var task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&fake});
        defer _ = task.cancel(std.testing.io) catch {};
        var capture: Capture = .{};
        defer capture.deinit();
        var client = anthropic.Client{ .io = std.testing.io, .config = .{ .endpoint = endpoint, .api_key = "fixture-key", .model_id = "fixture", .timeout_ms = if (mode == .stall) 150 else 3000 } };
        const messages = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
        const result = client.run(a, &messages, &.{}, capture.sink());
        switch (mode) {
            .ok => {
                try result;
                try std.testing.expectEqualStrings("hello", capture.text.items);
                try std.testing.expectEqual(model.StopReason.stop, capture.done.?);
            },
            .unauthorized => try std.testing.expectError(error.HttpRequestFailed, result),
            .truncated => try std.testing.expectError(error.TruncatedStream, result),
            .stall => try std.testing.expectError(error.RequestTimeout, result),
            .provider_error => try std.testing.expectError(error.ProviderError, result),
        }
        if (mode == .stall) {
            _ = task.cancel(std.testing.io) catch {};
        } else try task.await(std.testing.io);
        if (mode != .ok) try std.testing.expect(capture.done == null);
    }
}

test "configured Anthropic headers override defaults without duplicates" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/messages", .{server.socket.address.getPort()});
    defer a.free(endpoint);
    var fake = FakeServer{
        .server = &server,
        .expected_api_key = "custom-key",
        .expected_version = "2024-01-01",
        .expected_headers = &.{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "x-fixture", .value = "enabled" },
        },
        .absent = "fixture-key",
    };
    var task = try std.Io.concurrent(std.testing.io, FakeServer.run, .{&fake});
    defer _ = task.cancel(std.testing.io) catch {};
    var capture: Capture = .{};
    defer capture.deinit();
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "X-Api-Key", .value = "custom-key" },
        .{ .name = "Anthropic-Version", .value = "2024-01-01" },
        .{ .name = "x-fixture", .value = "enabled" },
    };
    var client = anthropic.Client{ .io = std.testing.io, .config = .{
        .endpoint = endpoint,
        .api_key = "fixture-key",
        .model_id = "fixture",
        .headers = &headers,
        .timeout_ms = 3000,
    } };
    const messages = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
    try client.run(a, &messages, &.{}, capture.sink());
    try task.await(std.testing.io);
    try std.testing.expectEqualStrings("hello", capture.text.items);
    try std.testing.expectEqual(model.StopReason.stop, capture.done.?);
}

test "Anthropic client aborts stalled stream promptly on interrupt" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/messages", .{server.socket.address.getPort()});
    defer a.free(endpoint);
    var fake = FakeServer{ .server = &server, .mode = .stall };
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
    var client = anthropic.Client{
        .io = std.testing.io,
        .config = .{ .endpoint = endpoint, .api_key = "fixture-key", .model_id = "fixture", .timeout_ms = 5000 },
        .cancel = interrupt.cancel(),
    };
    const messages = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
    try std.testing.expectError(error.Canceled, client.run(a, &messages, &.{}, capture.sink()));
    try trig_task.await(std.testing.io);
    try std.testing.expect(capture.done == null);
}
