//! Incremental, bounded SSE framing. Emitted data is borrowed until the next
//! feed call; consumers must copy any data retained after their callback.
const std = @import("std");

pub const Event = struct {
    data: []const u8,
    event: []const u8,
    id: []const u8,
};
pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Event) anyerror!void,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event_type: std.ArrayList(u8) = .empty,
    last_id: std.ArrayList(u8) = .empty,
    previous_cr: bool = false,
    first_line: bool = true,
    has_data: bool = false,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) Decoder {
        return .{ .allocator = allocator, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *Decoder) void {
        self.line.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.event_type.deinit(self.allocator);
        self.last_id.deinit(self.allocator);
        self.* = undefined;
    }

    /// max_bytes bounds each line and metadata. Assembled data uses at most
    /// max_bytes including its per-field LF separators (payload is max_bytes - 1).
    /// After an error
    /// the decoder is terminal: callers must create a new decoder for a retry.
    pub fn feed(self: *Decoder, bytes: []const u8, sink: Sink) !void {
        if (self.failed) return error.DecoderFailed;
        errdefer self.failed = true;
        for (bytes) |byte| {
            if (byte == '\n' and self.previous_cr) {
                self.previous_cr = false;
                continue;
            }
            self.previous_cr = byte == '\r';
            if (byte == '\r' or byte == '\n') {
                try self.finishLine(sink);
                self.line.clearRetainingCapacity();
            } else {
                if (self.line.items.len >= self.max_bytes) return error.SseLineTooLong;
                try self.line.append(self.allocator, byte);
            }
        }
    }

    /// SSE requires a blank line to dispatch an event. EOF does not dispatch
    /// partially received data. HTTP/provider code separately verifies finish.
    pub fn finish(self: *Decoder) !void {
        if (self.failed) return error.DecoderFailed;
        self.line.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.event_type.clearRetainingCapacity();
        self.has_data = false;
    }

    fn assign(self: *Decoder, list: *std.ArrayList(u8), value: []const u8) !void {
        if (value.len > self.max_bytes) return error.SseEventTooLong;
        list.clearRetainingCapacity();
        try list.appendSlice(self.allocator, value);
    }

    fn finishLine(self: *Decoder, sink: Sink) !void {
        var line = self.line.items;
        if (self.first_line) {
            self.first_line = false;
            if (std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
        }
        if (line.len == 0) {
            if (self.has_data) {
                // Each data field contributes a trailing LF; remove only the
                // last one, preserving empty fields and embedded line breaks.
                try sink.emit(sink.context, .{
                    .data = self.data.items[0 .. self.data.items.len - 1],
                    .event = if (self.event_type.items.len == 0) "message" else self.event_type.items,
                    .id = self.last_id.items,
                });
            }
            self.data.clearRetainingCapacity();
            self.event_type.clearRetainingCapacity();
            self.has_data = false;
            return;
        }
        if (line[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const field = line[0..colon];
        var value = if (colon < line.len) line[colon + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "data")) {
            if (self.data.items.len > self.max_bytes or value.len >= self.max_bytes - self.data.items.len)
                return error.SseEventTooLong;
            try self.data.appendSlice(self.allocator, value);
            try self.data.append(self.allocator, '\n');
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "event")) {
            try self.assign(&self.event_type, value);
        } else if (std.mem.eql(u8, field, "id") and std.mem.indexOfScalar(u8, value, 0) == null) {
            try self.assign(&self.last_id, value);
        }
        // retry and unknown fields have no meaning for this framing decoder.
        // Connection retries belong to the provider, never automatic SSE replay.
    }
};

const Capture = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    fn sink(self: *Capture) Sink {
        return .{ .context = self, .emit = emit };
    }
    fn emit(context: *anyopaque, event: Event) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        const data = try self.allocator.dupe(u8, event.data);
        errdefer self.allocator.free(data);
        const event_type = try self.allocator.dupe(u8, event.event);
        errdefer self.allocator.free(event_type);
        const id = try self.allocator.dupe(u8, event.id);
        errdefer self.allocator.free(id);
        try self.events.append(self.allocator, .{ .data = data, .event = event_type, .id = id });
    }
    fn deinit(self: *Capture) void {
        for (self.events.items) |event| {
            self.allocator.free(event.data);
            self.allocator.free(event.event);
            self.allocator.free(event.id);
        }
        self.events.deinit(self.allocator);
    }
};

test "SSE is independent of byte chunk boundaries including BOM CRLF and UTF8" {
    const input = "\xef\xbb\xbfid: turn-1\r\nevent: delta\r\ndata: 你好\r\ndata: world\r\n\r\n: heartbeat\r\ndata:[DONE]\r\n\r\n";
    // Every possible two-chunk split must produce identical events.
    for (0..input.len + 1) |split| {
        var decoder = Decoder.init(std.testing.allocator, 1024);
        defer decoder.deinit();
        var capture = Capture{ .allocator = std.testing.allocator };
        defer capture.deinit();
        try decoder.feed(input[0..split], capture.sink());
        try decoder.feed(input[split..], capture.sink());
        try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
        try std.testing.expectEqualStrings("你好\nworld", capture.events.items[0].data);
        try std.testing.expectEqualStrings("delta", capture.events.items[0].event);
        try std.testing.expectEqualStrings("turn-1", capture.events.items[1].id);
        try std.testing.expectEqualStrings("message", capture.events.items[1].event);
        try std.testing.expectEqualStrings("[DONE]", capture.events.items[1].data);
    }
}

test "SSE bytewise feed handles lone CR LF empty data and persistent id" {
    var decoder = Decoder.init(std.testing.allocator, 128);
    defer decoder.deinit();
    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();
    const input = "id: x\rdata\r\rdata:  a\nid: bad\x00id\n\nid:\ndata: last\n\n";
    for (input) |byte| try decoder.feed(&.{byte}, capture.sink());
    try std.testing.expectEqual(@as(usize, 3), capture.events.items.len);
    try std.testing.expectEqualStrings("", capture.events.items[0].data);
    try std.testing.expectEqualStrings(" a", capture.events.items[1].data);
    try std.testing.expectEqualStrings("x", capture.events.items[1].id);
    try std.testing.expectEqualStrings("", capture.events.items[2].id);
}

test "SSE discards incomplete last event at EOF" {
    var decoder = Decoder.init(std.testing.allocator, 128);
    defer decoder.deinit();
    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();
    try decoder.feed("data: partial\n", capture.sink());
    try decoder.finish();
    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
}

test "SSE bounds lines and assembled events and fails closed" {
    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var line_decoder = Decoder.init(std.testing.allocator, 8);
    defer line_decoder.deinit();
    try std.testing.expectError(error.SseLineTooLong, line_decoder.feed("123456789", capture.sink()));
    try std.testing.expectError(error.DecoderFailed, line_decoder.feed("\n", capture.sink()));
    var event_decoder = Decoder.init(std.testing.allocator, 16);
    defer event_decoder.deinit();
    try std.testing.expectError(error.SseEventTooLong, event_decoder.feed("data: 123456789\ndata: 123456789\n\n", capture.sink()));
    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
}
