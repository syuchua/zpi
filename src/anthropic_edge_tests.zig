const std = @import("std");
const anthropic = @import("anthropic");
const model = @import("model");
const sse = @import("sse");
const a = std.testing.allocator;
const start = "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}";
const Capture = struct {
    calls: usize = 0,
    ended_index: ?usize = null,
    argument: ?std.json.Value = null,
    done: bool = false,
    fail: bool = false,
    fn sink(self: *Capture) model.EventSink {
        return .{ .context = self, .emit = emit };
    }
    fn emit(ctx: *anyopaque, event: model.Event) !void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.FixtureSinkFailure;
        switch (event) {
            .tool_call_end => |call| {
                self.calls += 1;
                self.ended_index = call.index;
                // Verify exact numeric lexemes during their borrowed lifetime.
                const n = call.call.arguments.object.get("n") orelse return;
                try std.testing.expectEqualStrings("9007199254740993", n.number_string);
            },
            .done => self.done = true,
            else => {},
        }
    }
};
fn feed(d: *anthropic.Decoder, data: []const u8) !void {
    try d.feed("", data);
}
test "Anthropic initial tool input and zero-argument calls preserve block indexes and exact numbers" {
    for ([_][]const u8{ "{}", "{\"n\":9007199254740993}" }) |input| {
        var capture: Capture = .{};
        var d = anthropic.Decoder.init(a, capture.sink());
        defer d.deinit();
        try feed(&d, start);
        const begin = try std.fmt.allocPrint(a, "{{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"ls\",\"input\":{s}}}}}", .{input});
        defer a.free(begin);
        try feed(&d, begin);
        try feed(&d, "{\"type\":\"content_block_stop\",\"index\":2}");
        try feed(&d, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}");
        try feed(&d, "{\"type\":\"message_stop\"}");
        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expectEqual(@as(usize, 2), capture.ended_index.?);
        try std.testing.expect(capture.done);
    }
}
test "Anthropic malformed protocol and refusal never finish successfully" {
    const cases = [_]struct { events: []const []const u8, expected: anyerror }{
        .{ .events = &.{"{\"type\":\"message_stop\"}"}, .expected = error.MissingMessageStart },
        .{ .events = &.{ start, "{\"type\":\"message_delta\",\"delta\":null}" }, .expected = error.InvalidResponse },
        .{ .events = &.{ start, "{\"type\":\"message_stop\"}" }, .expected = error.MissingStopReason },
        .{ .events = &.{ start, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}", "{\"type\":\"message_stop\"}" }, .expected = error.ProviderRefusal },
        .{ .events = &.{ start, "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"x\"}}", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}", "{\"type\":\"message_stop\"}" }, .expected = error.UnclosedBlock },
    };
    for (cases) |case| {
        var capture: Capture = .{};
        var d = anthropic.Decoder.init(a, capture.sink());
        defer d.deinit();
        for (case.events[0 .. case.events.len - 1]) |event| try feed(&d, event);
        try std.testing.expectError(case.expected, feed(&d, case.events[case.events.len - 1]));
        try std.testing.expect(!capture.done);
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
        try std.testing.expectError(error.DecoderFailed, feed(&d, start));
    }
}
test "Anthropic propagates sink failures and ignores unknown SSE extensions" {
    var capture: Capture = .{ .fail = true };
    var d = anthropic.Decoder.init(a, capture.sink());
    defer d.deinit();
    try std.testing.expectError(error.FixtureSinkFailure, feed(&d, start));
    try std.testing.expectError(error.DecoderFailed, feed(&d, start));
    capture.fail = false;
    var other = anthropic.Decoder.init(a, capture.sink());
    defer other.deinit();
    var framing = sse.Decoder.init(a, 4096);
    defer framing.deinit();
    try framing.feed("event: ping\ndata: {}\n\nevent: future_event\ndata: not-json\n\nevent: message_start\ndata: " ++ start ++ "\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\nevent: future_event\ndata: not-json\n\n", other.sseSink());
    try std.testing.expect(capture.done);
}
test "Anthropic request rejects missing or intervening tool results and signed replay" {
    const config: anthropic.Config = .{ .endpoint = "unused", .api_key = "", .model_id = "fixture" };
    const call: model.Message = .{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments = .{ .object = .empty } } }} };
    const user: model.Message = .{ .role = .user, .content = &.{.{ .text = "intervening" }} };
    const result: model.Message = .{ .role = .tool_result, .tool_call_id = "call", .content = &.{.{ .text = "result" }} };
    try std.testing.expectError(error.MissingToolResult, anthropic.encodeRequest(a, config, &.{call}, &.{}));
    try std.testing.expectError(error.MissingToolResult, anthropic.encodeRequest(a, config, &.{ call, user, result }, &.{}));
    try std.testing.expectError(error.OrphanToolResult, anthropic.encodeRequest(a, config, &.{result}, &.{}));
    try std.testing.expectError(error.UnsupportedThinkingReplay, anthropic.encodeRequest(a, config, &.{.{ .role = .assistant, .content = &.{.{ .thinking = .{ .text = "reason", .signature = "signature" } }} }}, &.{}));
}
