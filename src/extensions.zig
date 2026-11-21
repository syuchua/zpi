//! Experimental client for the user-selected, version-pinned Node pi SDK host.
//! This protocol is a Zpi JSONL boundary, not a pi protocol or security sandbox.
const std = @import("std");
const model = @import("model");

pub const max_line_bytes = 1024 * 1024;
pub const Config = struct {
    node_exe: []const u8 = "node",
    host_script: []const u8,
    sdk_directory: []const u8,
    cwd: []const u8,
    timeout_ms: u32 = 30000,
};
pub const Response = struct {
    parsed: std.json.Parsed(std.json.Value),
    pub fn value(self: Response) std.json.Value {
        const root = self.parsed.value;
        return if (root == .object) root.object.get("result") orelse .null else .null;
    }
    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
    }
};
pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    child: std.process.Child,
    pending: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,
    busy: bool = false,
    failed: bool = false,
    closed: bool = false,
    remote_rejected: bool = false,
    cancel: ?model.Cancel = null,
    event_context: ?*anyopaque = null,
    on_event: ?*const fn (?*anyopaque, std.json.Value) anyerror!void = null,

    /// Paths are explicit and absolute. Config strings must outlive Host.
    pub fn start(a: std.mem.Allocator, io: std.Io, config: Config) !Host {
        if (config.timeout_ms == 0 or config.timeout_ms > 300000 or !std.fs.path.isAbsolute(config.host_script) or !std.fs.path.isAbsolute(config.sdk_directory) or !std.fs.path.isAbsolute(config.cwd)) return error.InvalidExtensionConfig;
        const child = try std.process.spawn(io, .{
            .argv = &.{ config.node_exe, config.host_script, config.sdk_directory },
            .cwd = .{ .path = config.cwd },
            .pgid = 0,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{ .allocator = a, .io = io, .config = config, .child = child };
    }
    pub fn deinit(self: *Host) void {
        self.terminate();
        self.pending.deinit(self.allocator);
    }
    fn terminate(self: *Host) void {
        if (self.child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
        self.child.kill(self.io);
        self.closed = true;
    }
    pub fn load(self: *Host, paths: []const []const u8) !Response {
        if (paths.len == 0 or paths.len > 64) return error.InvalidExtensionPaths;
        var response = try self.request("load", .{ .cwd = self.config.cwd, .paths = paths });
        errdefer {
            response.deinit();
            self.failed = true;
            self.terminate();
        }
        const value = response.value();
        if (value != .object) return error.InvalidExtensionHandshake;
        const protocol = value.object.get("protocol") orelse return error.InvalidExtensionHandshake;
        const version = value.object.get("protocolVersion") orelse return error.InvalidExtensionHandshake;
        const sdk_version = value.object.get("version") orelse return error.InvalidExtensionHandshake;
        const tools = value.object.get("tools") orelse return error.InvalidExtensionHandshake;
        const valid_sdk = sdk_version == .string and (std.mem.eql(u8, sdk_version.string, "1.5.2") or std.mem.eql(u8, sdk_version.string, "1.6.0"));
        if (protocol != .string or !std.mem.eql(u8, protocol.string, "zpi-ts-host") or version != .number_string or !std.mem.eql(u8, version.number_string, "1") or !valid_sdk or tools != .array or tools.array.items.len > 256) return error.InvalidExtensionHandshake;
        return response;
    }
    pub fn sendInput(self: *Host, text: []const u8, source: []const u8) !Response {
        return self.request("input", .{ .text = text, .source = source });
    }
    pub fn checkToolCall(self: *Host, name: []const u8, call_id: []const u8, arguments: std.json.Value) !Response {
        return self.request("tool_call", .{ .name = name, .callId = call_id, .arguments = arguments });
    }
    pub fn transformToolResult(self: *Host, name: []const u8, call_id: []const u8, arguments: std.json.Value, content: std.json.Value, details: std.json.Value, is_error: bool) !Response {
        return self.request("tool_result", .{ .name = name, .callId = call_id, .arguments = arguments, .content = content, .details = details, .isError = is_error });
    }
    /// Call only after Zpi records the tool call and its own policy permits it.
    /// Extensions run with the same OS permissions as this process.
    pub fn execute(self: *Host, name: []const u8, call_id: []const u8, arguments: std.json.Value) !Response {
        return self.request("tool_exec", .{ .name = name, .callId = call_id, .arguments = arguments });
    }
    pub fn shutdown(self: *Host) !void {
        if (self.closed) return;
        var response = try self.request("shutdown", .{});
        defer response.deinit();
        self.terminate();
    }
    pub fn request(self: *Host, operation: []const u8, payload: anytype) !Response {
        if (self.closed or self.failed) return error.ExtensionHostClosed;
        if (self.busy) return error.ExtensionHostBusy;
        if (self.next_id > 9007199254740991) return error.ExtensionRequestIdExhausted;
        self.busy = true;
        self.remote_rejected = false;
        defer self.busy = false;
        errdefer if (!self.remote_rejected) {
            self.failed = true;
            self.terminate();
        };
        if (self.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
        const id = self.next_id;
        self.next_id += 1;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, .{ .id = id, .op = operation, .timeoutMs = self.config.timeout_ms, .payload = payload }, .{});
        defer self.allocator.free(encoded);
        if (encoded.len + 1 > max_line_bytes) return error.ExtensionRequestTooLarge;
        const Completion = union(enum) { response: anyerror!Response, timer: std.Io.Cancelable!void, cancel: std.Io.Cancelable!void };
        var storage: [3]Completion = undefined;
        var selection = std.Io.Select(Completion).init(self.io, &storage);
        defer {
            // Join tasks and release a result that raced the deadline.
            while (selection.cancel()) |item| switch (item) {
                .response => |result| if (result) |owned| {
                    var reply = owned;
                    reply.deinit();
                } else |_| {},
                .timer, .cancel => {},
            };
        }
        try selection.concurrent(.timer, timer, .{ self.io, self.config.timeout_ms });
        try selection.concurrent(.response, exchange, .{ self, id, encoded });
        if (self.cancel) |cancel| try selection.concurrent(.cancel, waitCancel, .{ cancel, self.io });
        return switch (try selection.await()) {
            .response => |result| result,
            .timer => |result| blk: {
                try result;
                break :blk error.ExtensionHostTimeout;
            },
            .cancel => |result| blk: {
                try result;
                break :blk error.Canceled;
            },
        };
    }
    fn exchange(self: *Host, id: u64, encoded: []const u8) anyerror!Response {
        try self.child.stdin.?.writeStreamingAll(self.io, encoded);
        try self.child.stdin.?.writeStreamingAll(self.io, "\n");
        var aggregate: usize = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |newline| {
                aggregate += newline + 1;
                if (aggregate > 16 * max_line_bytes or newline > max_line_bytes) return error.ExtensionResponseTooLarge;
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, self.pending.items[0..newline], .{ .allocate = .alloc_always, .parse_numbers = false }) catch return error.InvalidExtensionProtocol;
                errdefer parsed.deinit();
                const remaining = self.pending.items.len - newline - 1;
                std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[newline + 1 ..]);
                self.pending.items.len = remaining;
                try validateValue(parsed.value, 0);
                if (parsed.value != .object) return error.InvalidExtensionProtocol;
                const record = parsed.value.object;
                const reply_id = record.get("id") orelse return error.InvalidExtensionProtocol;
                if (reply_id != .number_string or (std.fmt.parseInt(u64, reply_id.number_string, 10) catch return error.InvalidExtensionProtocol) != id) return error.InvalidExtensionProtocol;
                if (record.get("type")) |kind| {
                    if (kind != .string or (!std.mem.eql(u8, kind.string, "extension_error") and !std.mem.eql(u8, kind.string, "tool_update"))) return error.InvalidExtensionProtocol;
                    if (self.on_event) |emit| try emit(self.event_context, parsed.value);
                    parsed.deinit();
                    continue;
                }
                const ok = record.get("ok") orelse return error.InvalidExtensionProtocol;
                if (ok != .bool) return error.InvalidExtensionProtocol;
                if (!ok.bool) {
                    const remote_error = record.get("error") orelse return error.InvalidExtensionProtocol;
                    if (remote_error != .string) return error.InvalidExtensionProtocol;
                    const kind = record.get("kind") orelse return error.InvalidExtensionProtocol;
                    if (kind != .string) return error.InvalidExtensionProtocol;
                    if (std.mem.eql(u8, kind.string, "fatal")) return error.ExtensionHostFailed;
                    if (std.mem.eql(u8, kind.string, "tool_error")) {
                        self.remote_rejected = true;
                        return error.ExtensionToolFailed;
                    }
                    if (!std.mem.eql(u8, kind.string, "rejected")) return error.InvalidExtensionProtocol;
                    self.remote_rejected = true;
                    return error.ExtensionHostRejected;
                }
                if (record.get("result") == null) return error.InvalidExtensionProtocol;
                return .{ .parsed = parsed };
            }
            if (self.pending.items.len > max_line_bytes) return error.ExtensionResponseTooLarge;
            var buffer: [8192]u8 = undefined;
            const n = self.child.stdout.?.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => return error.ExtensionHostDisconnected,
                else => return err,
            };
            if (n > 0) try self.pending.appendSlice(self.allocator, buffer[0..n]);
        }
    }
};
fn timer(io: std.Io, milliseconds: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(milliseconds), .awake);
}
fn waitCancel(cancel: model.Cancel, io: std.Io) std.Io.Cancelable!void {
    try cancel.wait(io);
}
fn validateValue(value: std.json.Value, depth: usize) !void {
    if (depth > 64) return error.ExtensionValueTooDeep;
    switch (value) {
        .array => |items| for (items.items) |child| try validateValue(child, depth + 1),
        .object => |items| for (items.values()) |child| try validateValue(child, depth + 1),
        else => {},
    }
}

test "extension configuration rejects relative executable resources" {
    try std.testing.expectError(error.InvalidExtensionConfig, Host.start(std.testing.allocator, std.testing.io, .{ .host_script = "host.mjs", .sdk_directory = "/sdk", .cwd = "/tmp" }));
}
