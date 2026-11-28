//! Experimental MCP stdio transport. One request at a time; no automatic retry.
const std = @import("std");
const model = @import("model");
const build_version = @import("version");

const max_line = 1024 * 1024;
const max_inbound_frames = 128;
const max_depth = 64;
const preferred_version = "2025-11-25";

pub const Config = struct {
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32 = 60_000,
};

pub const Reply = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn result(self: Reply) std.json.Value {
        return self.parsed.value.object.get("result").?;
    }

    pub fn deinit(self: Reply) void {
        self.parsed.deinit();
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    timeout_ms: u32,
    pending: std.ArrayList(u8) = .empty,
    next_id: u32 = 1,
    ready: bool = false,
    has_tools: bool = false,
    cancel: ?model.Cancel = null,

    /// An explicit command, with no intervening shell. This is not a sandbox.
    pub fn start(a: std.mem.Allocator, io: std.Io, config: Config) !Client {
        if (config.cwd.len > 4096 or config.argv.len == 0 or config.argv.len > 128 or config.argv[0].len == 0 or
            config.timeout_ms == 0 or config.timeout_ms > 300_000 or
            !std.fs.path.isAbsolute(config.cwd) or std.mem.indexOfScalar(u8, config.cwd, 0) != null or
            !std.unicode.utf8ValidateSlice(config.cwd))
            return error.InvalidMcpConfig;
        for (config.argv) |arg| {
            if (arg.len > 16 * 1024 or std.mem.indexOfScalar(u8, arg, 0) != null or !std.unicode.utf8ValidateSlice(arg)) return error.InvalidMcpConfig;
        }
        const child = try std.process.spawn(io, .{
            .argv = config.argv,
            .cwd = .{ .path = config.cwd },
            .pgid = 0,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{ .allocator = a, .io = io, .child = child, .timeout_ms = config.timeout_ms };
    }

    pub fn deinit(self: *Client) void {
        self.terminate();
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    fn terminate(self: *Client) void {
        if (self.child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
        self.child.kill(self.io);
        self.ready = false;
        self.has_tools = false;
    }

    pub fn initialize(self: *Client) !void {
        if (self.ready) return error.McpAlreadyInitialized;
        errdefer self.terminate();
        const reply = (try self.exchange(self.next_id, .{
            .jsonrpc = "2.0",
            .id = self.next_id,
            .method = "initialize",
            .params = .{ .protocolVersion = preferred_version, .capabilities = .{}, .clientInfo = .{ .name = "zpi", .version = build_version.VERSION } },
        })).?;
        self.next_id += 1;
        defer reply.deinit();
        const result = reply.result();
        const version = get(result, "protocolVersion");
        if (version != .string) return error.InvalidMcpHandshake;
        if (!supportedVersion(version.string)) return error.UnsupportedMcpVersion;
        const server = get(result, "serverInfo");
        if (get(server, "name") != .string or get(server, "version") != .string or get(result, "capabilities") != .object)
            return error.InvalidMcpHandshake;
        const tools = get(get(result, "capabilities"), "tools");
        if (tools != .null and tools != .object) return error.InvalidMcpHandshake;
        self.has_tools = tools == .object;
        _ = try self.exchange(null, .{ .jsonrpc = "2.0", .method = "notifications/initialized" });
        self.ready = true;
    }

    pub fn supportsTools(self: *const Client) bool {
        return self.has_tools;
    }

    pub fn listTools(self: *Client) !Reply {
        if (!self.has_tools) return error.McpToolsUnavailable;
        return self.request("tools/list", .{});
    }

    pub fn callTool(self: *Client, name: []const u8, arguments: std.json.Value) !Reply {
        if (!self.ready) return error.McpNotReady;
        if (!self.has_tools) return error.McpToolsUnavailable;
        if (!validToolName(name) or arguments != .object) return error.InvalidMcpToolArguments;
        return self.request("tools/call", .{ .name = name, .arguments = arguments });
    }

    pub fn request(self: *Client, method: []const u8, params: anytype) !Reply {
        if (!self.ready) return error.McpNotReady;
        if (self.next_id == std.math.maxInt(u32)) return error.McpRequestIdExhausted;
        const id = self.next_id;
        self.next_id += 1;
        return (try self.exchange(id, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params })).?;
    }

    fn exchange(self: *Client, id: ?u32, payload: anytype) !?Reply {
        if (self.child.id == null) return error.McpDisconnected;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(encoded);
        if (encoded.len >= max_line) return error.McpRequestTooLarge;
        return self.exchangeTimed(id, encoded) catch |err| {
            if (err != error.McpRemoteError) self.terminate();
            return err;
        };
    }

    fn exchangeTimed(self: *Client, id: ?u32, encoded: []const u8) !?Reply {
        if (self.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
        const Completion = union(enum) { reply: anyerror!?Reply, timer: std.Io.Cancelable!void, cancel: std.Io.Cancelable!void };
        var storage: [3]Completion = undefined;
        var select = std.Io.Select(Completion).init(self.io, &storage);
        defer while (select.cancel()) |item| switch (item) {
            .reply => |result| if (result) |owned| {
                if (owned) |reply| reply.deinit();
            } else |_| {},
            .timer, .cancel => {},
        };
        try select.concurrent(.timer, timer, .{ self.io, self.timeout_ms });
        try select.concurrent(.reply, exchangeFrames, .{ self, id, encoded });
        if (self.cancel) |cancel| try select.concurrent(.cancel, waitCancel, .{ cancel, self.io });
        return switch (try select.await()) {
            .reply => |reply| reply,
            .timer => |finished| blk: {
                try finished;
                break :blk error.McpTimeout;
            },
            .cancel => |finished| blk: {
                try finished;
                break :blk error.Canceled;
            },
        };
    }

    fn exchangeFrames(self: *Client, id: ?u32, encoded: []const u8) anyerror!?Reply {
        try self.child.stdin.?.writeStreamingAll(self.io, encoded);
        try self.child.stdin.?.writeStreamingAll(self.io, "\n");
        const expected = id orelse return null;
        var id_buffer: [10]u8 = undefined;
        const expected_id = std.fmt.bufPrint(&id_buffer, "{d}", .{expected}) catch unreachable;
        var aggregate: usize = 0;
        for (0..max_inbound_frames) |_| {
            const len = try self.frameLength();
            aggregate += len + 1;
            if (aggregate > 4 * max_line) return error.McpResponseTooLarge;
            const frame = self.pending.items[0..len];
            try validateFrame(frame);
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidMcpMessage,
            };
            errdefer parsed.deinit();
            const tail = self.pending.items[len + 1 ..];
            std.mem.copyForwards(u8, self.pending.items[0..tail.len], tail);
            self.pending.items.len = tail.len;
            const root = parsed.value;
            if (root != .object) return error.InvalidMcpMessage;
            const rpc = get(root, "jsonrpc");
            if (rpc != .string or !std.mem.eql(u8, rpc.string, "2.0")) return error.InvalidMcpMessage;
            const request_id = get(root, "id");
            const result = root.object.get("result");
            const remote_error = root.object.get("error");
            if (root.object.get("method")) |method| {
                if (method != .string or method.string.len == 0 or result != null or remote_error != null) return error.InvalidMcpMessage;
                if (root.object.contains("id")) return error.UnsupportedMcpServerRequest;
                parsed.deinit();
                continue;
            }
            if (request_id != .number_string or !std.mem.eql(u8, request_id.number_string, expected_id)) return error.UnexpectedMcpReplyId;
            if ((result == null) == (remote_error == null)) return error.InvalidMcpMessage;
            if (remote_error) |failure| {
                if (failure != .object) return error.InvalidMcpMessage;
                const code = get(failure, "code");
                if (code != .number_string or get(failure, "message") != .string) return error.InvalidMcpMessage;
                _ = std.fmt.parseInt(i32, code.number_string, 10) catch return error.InvalidMcpMessage;
                return error.McpRemoteError;
            }
            return .{ .parsed = parsed };
        }
        return error.TooManyMcpFrames;
    }

    fn frameLength(self: *Client) !usize {
        var searched: usize = 0;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.pending.items, searched, '\n')) |newline| {
                if (newline >= max_line) return error.McpResponseTooLarge;
                return newline;
            }
            searched = self.pending.items.len;
            if (searched >= max_line) return error.McpResponseTooLarge;
            var scratch: [8192]u8 = undefined;
            const n = self.child.stdout.?.readStreaming(self.io, &.{&scratch}) catch |err| switch (err) {
                error.EndOfStream => return error.McpDisconnected,
                else => return err,
            };
            try self.pending.appendSlice(self.allocator, scratch[0..n]);
        }
    }
};

fn timer(io: std.Io, ms: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(ms), .awake);
}
fn waitCancel(cancel: model.Cancel, io: std.Io) std.Io.Cancelable!void {
    try cancel.wait(io);
}

pub fn validToolName(name: []const u8) bool {
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return name.len > 0 and name.len <= 64;
}

fn get(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

fn supportedVersion(version: []const u8) bool {
    for ([_][]const u8{ preferred_version, "2025-06-18", "2025-03-26", "2024-11-05" }) |candidate| {
        if (std.mem.eql(u8, version, candidate)) return true;
    }
    return false;
}

// Bound parser nesting before constructing a dynamic value. The JSON parser
// remains responsible for syntax, escape validity and duplicate keys.
fn validateFrame(frame: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(frame)) return error.InvalidMcpMessage;
    var nesting: usize = 0;
    var quoted = false;
    var escaped = false;
    for (frame) |c| {
        if (quoted) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
        } else switch (c) {
            '"' => quoted = true,
            '{', '[' => {
                nesting += 1;
                if (nesting > max_depth) return error.McpMessageTooDeep;
            },
            '}', ']' => {
                if (nesting == 0) return error.InvalidMcpMessage;
                nesting -= 1;
            },
            else => {},
        }
    }
}

test "MCP frame nesting ignores quoted brackets" {
    try validateFrame("{\"text\":\"\\\"[[[\"}");
    var deep: [max_depth + 1]u8 = undefined;
    @memset(&deep, '[');
    try std.testing.expectError(error.McpMessageTooDeep, validateFrame(&deep));
    try std.testing.expectError(error.InvalidMcpMessage, validateFrame("\xff"));
}

fn fixture(script: []const u8, timeout_ms: u32) !Client {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    return Client.start(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-ec", script },
        .cwd = cwd,
        .timeout_ms = timeout_ms,
    });
}

const fixture_handshake_prefix = std.fmt.comptimePrint(
    \\IFS= read -r init
    \\case "$init" in *'"id":1'*'"method":"initialize"'*'"protocolVersion":"2025-11-25"'*) ;; *) exit 12;; esac
    \\case "$init" in *'"clientInfo":{{"name":"zpi","version":"{s}"}}'*) ;; *) exit 14;; esac
    \\printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"2025-06-18","serverInfo":{{"name":"fixture","version":"1"}},"capabilities":{{"tools":{{}}}}}}}}'
    \\IFS= read -r initialized
    \\case "$initialized" in *'"method":"notifications/initialized"'*) ;; *) exit 13;; esac
, .{build_version.VERSION});

const fixture_handshake = fixture_handshake_prefix ++ "\n" ++
    \\IFS= read -r request
    \\case "$request" in *'"id":2'*'"method":"tools/list"'*) ;; *) exit 17;; esac
    \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"fixture"}}'
    \\printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"fixture error"}}'
    \\IFS= read -r request
    \\case "$request" in *'"id":3'*'"method":"tools/list"'*) ;; *) exit 18;; esac
    \\printf '%s' '{"jsonrpc":"2.0","id":3,"result":'
    \\printf '%s\n' '{"tools":[]}}'
;

test "MCP stdio negotiates, accepts notifications and recovers from RPC errors" {
    var client = try fixture(fixture_handshake, 5000);
    defer client.deinit();
    try std.testing.expectError(error.McpNotReady, client.request("tools/list", .{}));
    try client.initialize();
    try std.testing.expectError(error.McpRemoteError, client.request("tools/list", .{}));
    const reply = try client.request("tools/list", .{});
    defer reply.deinit();
    try std.testing.expectEqual(@as(usize, 0), get(reply.result(), "tools").array.items.len);
}

test "MCP mismatched reply ID closes the connection" {
    var client = try fixture(fixture_handshake_prefix ++ "\n" ++
        \\IFS= read -r request
        \\case "$request" in *'"method":"tools/list"'*) ;; *) exit 16;; esac
        \\printf '%s\n' '{"jsonrpc":"2.0","id":99,"result":{}}'
    , 5000);
    defer client.deinit();
    try client.initialize();
    try std.testing.expectError(error.UnexpectedMcpReplyId, client.request("tools/list", .{}));
    try std.testing.expectEqual(null, client.child.id);
    try std.testing.expectError(error.McpNotReady, client.request("tools/list", .{}));
}

test "MCP rejects invalid replies and server requests and closes the connection" {
    const read_request = fixture_handshake_prefix ++ "\n" ++
        \\IFS= read -r request
        \\case "$request" in *'"method":"tools/list"'*) ;; *) exit 19;; esac
    ++ "\n";
    const cases = .{
        .{ "printf '%s\\n' '[]'", error.InvalidMcpMessage },
        .{ "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":null}'", error.InvalidMcpMessage },
        .{ "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{},\"error\":{}}'", error.InvalidMcpMessage },
        .{ "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}'", error.UnsupportedMcpServerRequest },
        .{ "printf '%s' '{\"jsonrpc\":\"2.0\"'", error.McpDisconnected },
    };
    inline for (cases) |case| {
        var client = try fixture(read_request ++ case[0], 5000);
        defer client.deinit();
        try client.initialize();
        try std.testing.expectError(case[1], client.listTools());
        try std.testing.expectEqual(null, client.child.id);
        try std.testing.expect(!client.supportsTools());
    }
}

test "MCP deadline terminates and reaps a stalled server" {
    var client = try fixture("IFS= read -r init; sleep 30", 150);
    defer client.deinit();
    try std.testing.expectError(error.McpTimeout, client.initialize());
    try std.testing.expectEqual(null, client.child.id);
}
