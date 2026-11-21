const std = @import("std");
const sse = @import("sse");
const http_transport = @import("http_transport");

const SseCapture = struct {
    text: std.ArrayList(u8) = .empty,
    done: bool = false,

    fn sink(self: *SseCapture) sse.Sink {
        return .{ .context = self, .emit = onEvent };
    }

    fn onEvent(ctx: *anyopaque, ev: sse.Event) !void {
        const self: *SseCapture = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, ev.data, "[DONE]")) {
            self.done = true;
            return;
        }
        try self.text.appendSlice(std.testing.allocator, ev.data);
    }

    fn deinit(self: *SseCapture) void {
        self.text.deinit(std.testing.allocator);
    }
};

test "NO_PROXY matching supports wildcards, subdomains, ports, and IPv6 literals" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("NO_PROXY", "localhost, .internal.corp, api.example.com:8443, [::1]:443, 127.0.0.1");

    try std.testing.expect(http_transport.shouldBypassProxy(&env, "localhost", 443));
    try std.testing.expect(http_transport.shouldBypassProxy(&env, "LOCALHOST", 8080));
    try std.testing.expect(http_transport.shouldBypassProxy(&env, "127.0.0.1", 80));
    try std.testing.expect(http_transport.shouldBypassProxy(&env, "svc.internal.corp", 443));
    try std.testing.expect(http_transport.shouldBypassProxy(&env, "internal.corp", 443));
    try std.testing.expect(!http_transport.shouldBypassProxy(&env, "notinternal.corp", 443));
    try std.testing.expect(http_transport.shouldBypassProxy(&env, "api.example.com", 8443));
    try std.testing.expect(!http_transport.shouldBypassProxy(&env, "api.example.com", 443));
    try std.testing.expect(http_transport.shouldBypassProxy(&env, "::1", 443));
    try std.testing.expect(!http_transport.shouldBypassProxy(&env, "::1", 8443));
    try std.testing.expect(!http_transport.shouldBypassProxy(&env, "api.openai.com", 443));

    try env.put("NO_PROXY", "*");
    try std.testing.expect(http_transport.shouldBypassProxy(&env, "api.openai.com", 443));
}

test "HTTPS proxy sends CONNECT with Proxy-Authorization, fails closed on 407, and initiates TLS ClientHello with SNI" {
    const FakeProxy = struct {
        io: std.Io,
        server: *std.Io.net.Server,
        reject_with_407: bool,
        saw_connect: bool = false,
        saw_proxy_auth: bool = false,
        saw_tls_client_hello: bool = false,
        saw_sni: bool = false,
        leaked_secret: bool = false,

        fn run(self: *@This()) !void {
            const stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            var read_buf: [8192]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);

            var head_buf: std.ArrayList(u8) = .empty;
            defer head_buf.deinit(std.testing.allocator);
            var chunk: [1024]u8 = undefined;
            while (std.mem.indexOf(u8, head_buf.items, "\r\n\r\n") == null) {
                var vecs = [_][]u8{&chunk};
                const n = reader.interface.readVec(&vecs) catch break;
                if (n == 0) break;
                try head_buf.appendSlice(std.testing.allocator, chunk[0..n]);
            }
            self.saw_connect = std.mem.startsWith(u8, head_buf.items, "CONNECT api.example.invalid:8443 HTTP/1.1\r\n");
            // Base64("user:pass") == "dXNlcjpwYXNz"
            self.saw_proxy_auth = std.mem.indexOf(u8, head_buf.items, "proxy-authorization: Basic dXNlcjpwYXNz\r\n") != null;
            if (std.mem.indexOf(u8, head_buf.items, "secret-api-key") != null) self.leaked_secret = true;

            if (self.reject_with_407) {
                try writer.interface.writeAll("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n");
                try writer.interface.flush();
                // Drain briefly to ensure client never writes credentials/payload after 407.
                var extra: [256]u8 = undefined;
                var vecs = [_][]u8{&extra};
                const extra_n = reader.interface.readVec(&vecs) catch 0;
                if (extra_n > 0 and std.mem.indexOf(u8, extra[0..extra_n], "secret-api-key") != null) {
                    self.leaked_secret = true;
                }
                return;
            }

            try writer.interface.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n");
            try writer.interface.flush();

            var tls_buf: [2048]u8 = undefined;
            var vecs = [_][]u8{&tls_buf};
            const tls_n = reader.interface.readVec(&vecs) catch 0;
            if (tls_n >= 5 and tls_buf[0] == 0x16 and tls_buf[1] == 0x03) {
                self.saw_tls_client_hello = true;
                self.saw_sni = std.mem.indexOf(u8, tls_buf[0..tls_n], "api.example.invalid") != null;
            }
            if (tls_n > 0 and std.mem.indexOf(u8, tls_buf[0..tls_n], "secret-api-key") != null) {
                self.leaked_secret = true;
            }
        }
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const proxy_url = try std.fmt.allocPrint(std.testing.allocator, "http://user:pass@127.0.0.1:{d}", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(proxy_url);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("https_proxy", proxy_url);

    const uri = try std.Uri.parse("https://api.example.invalid:8443/v1/chat/completions");
    var empty_ca: std.crypto.Certificate.Bundle = .empty;
    defer empty_ca.deinit(std.testing.allocator);

    // 1. 407 rejection fails closed without leaking credentials or payload.
    {
        var proxy = FakeProxy{ .io = std.testing.io, .server = &server, .reject_with_407 = true };
        var task = try std.Io.concurrent(std.testing.io, FakeProxy.run, .{&proxy});
        defer _ = task.cancel(std.testing.io) catch {};
        var cap: SseCapture = .{};
        defer cap.deinit();
        var status: ?std.http.Status = null;
        var retry_after: ?u64 = null;
        try std.testing.expectError(error.ProxyConnectFailed, http_transport.postSse(std.testing.allocator, std.testing.io, .{
            .uri = uri,
            .authorization = "Bearer secret-api-key",
            .payload = "{\"model\":\"m\"}",
            .environ = &env,
            .ca_bundle = &empty_ca,
        }, cap.sink(), &cap.done, &status, &retry_after));
        try task.await(std.testing.io);
        try std.testing.expect(proxy.saw_connect);
        try std.testing.expect(proxy.saw_proxy_auth);
        try std.testing.expect(!proxy.leaked_secret);
    }

    // 2. 200 Connection Established negotiates TLS ClientHello with origin SNI inside tunnel.
    {
        var proxy = FakeProxy{ .io = std.testing.io, .server = &server, .reject_with_407 = false };
        var task = try std.Io.concurrent(std.testing.io, FakeProxy.run, .{&proxy});
        defer _ = task.cancel(std.testing.io) catch {};
        var cap: SseCapture = .{};
        defer cap.deinit();
        var status: ?std.http.Status = null;
        var retry_after: ?u64 = null;
        try std.testing.expectError(error.TlsInitializationFailed, http_transport.postSse(std.testing.allocator, std.testing.io, .{
            .uri = uri,
            .authorization = "Bearer secret-api-key",
            .payload = "{\"model\":\"m\"}",
            .environ = &env,
            .ca_bundle = &empty_ca,
        }, cap.sink(), &cap.done, &status, &retry_after));
        try task.await(std.testing.io);
        try std.testing.expect(proxy.saw_connect);
        try std.testing.expect(proxy.saw_proxy_auth);
        try std.testing.expect(proxy.saw_tls_client_hello);
        try std.testing.expect(proxy.saw_sni);
        try std.testing.expect(!proxy.leaked_secret);
    }
}

test "NO_PROXY and ProxyPolicy.none bypass configured proxy" {
    const Origin = struct {
        io: std.Io,
        server: *std.Io.net.Server,
        fn run(self: *@This()) !void {
            const stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var in = stream.reader(self.io, &in_buf);
            var out = stream.writer(self.io, &out_buf);
            var srv = std.http.Server.init(&in.interface, &out.interface);
            var req = try srv.receiveHead();
            var body_buf: [1024]u8 = undefined;
            const br = req.readerExpectNone(&body_buf);
            const body = try br.allocRemaining(std.testing.allocator, .limited(64 * 1024));
            defer std.testing.allocator.free(body);
            try req.respond("data: ok\n\ndata: [DONE]\n\n", .{
                .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            });
        }
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const endpoint = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(endpoint);
    const uri = try std.Uri.parse(endpoint);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("http_proxy", "http://127.0.0.1:1");
    try env.put("NO_PROXY", "127.0.0.1");

    var origin = Origin{ .io = std.testing.io, .server = &server };
    var task = try std.Io.concurrent(std.testing.io, Origin.run, .{&origin});
    defer _ = task.cancel(std.testing.io) catch {};
    var cap: SseCapture = .{};
    defer cap.deinit();
    var status: ?std.http.Status = null;
    var retry_after: ?u64 = null;
    try http_transport.postSse(std.testing.allocator, std.testing.io, .{
        .uri = uri,
        .payload = "{}",
        .environ = &env,
    }, cap.sink(), &cap.done, &status, &retry_after);
    try task.await(std.testing.io);
    try std.testing.expectEqualStrings("ok", cap.text.items);
    try std.testing.expectEqual(std.http.Status.ok, status.?);
}
