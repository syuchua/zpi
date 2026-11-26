//! Shared HTTP/HTTPS SSE transport with `NO_PROXY` matching and HTTPS `CONNECT`
//! TLS tunneling so all provider adapters support system proxies uniformly.
const builtin = @import("builtin");
const std = @import("std");
const model = @import("model");
const sse = @import("sse");
const http_headers = @import("http_headers");

pub const ProxyPolicy = enum { system, none };

pub fn retryHint(err: anyerror, status: ?std.http.Status, retry_after_ms: ?u64) model.RetryHint {
    return switch (err) {
        error.HttpRequestFailed => if (status) |code| .{
            .retryable = http_headers.isRetryableHttpStatus(code),
            .retry_after_ms = retry_after_ms,
            .context_overflow = code == .payload_too_large,
        } else .{ .retryable = false },
        error.RequestTimeout,
        error.TruncatedStream,
        error.ResponseReadFailed,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.TemporaryNameServerFailure,
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.NetworkDown,
        error.Timeout,
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.WriteFailed,
        error.BrokenPipe,
        error.TlsConnectionTruncated,
        => .{ .retryable = true },
        else => .{ .retryable = false },
    };
}

pub const Request = struct {
    uri: std.Uri,
    authorization: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    payload: []const u8,
    environ: ?*const std.process.Environ.Map = null,
    proxy_policy: ProxyPolicy = .system,
    cancel_socket: ?*model.CancelSocket = null,
    /// Optional caller-supplied CA bundle (primarily for tests). When null,
    /// loads `SSL_CERT_FILE` (if set) or rescans OS root certificates.
    ca_bundle: ?*std.crypto.Certificate.Bundle = null,
    timing: ?model.Timing = null,
};

pub fn postSse(
    allocator: std.mem.Allocator,
    io: std.Io,
    req_opts: Request,
    sse_sink: sse.Sink,
    done_flag: *const bool,
    out_status: *?std.http.Status,
    out_retry_after_ms: *?u64,
) !void {
    const uri = req_opts.uri;
    const is_https = std.mem.eql(u8, uri.scheme, "https");
    const request_started = model.Timing.start(req_opts.timing, io);
    if (!is_https and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidEndpoint;
    if (uri.user != null or uri.password != null) return error.InvalidEndpoint;
    try http_headers.validateAll(req_opts.extra_headers);

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const origin_host = std.Io.net.HostName.fromUri(uri, &host_buf) catch |err| switch (err) {
        error.UriMissingHost => return error.InvalidEndpoint,
        error.NameTooLong, error.InvalidHostName => return error.InvalidEndpoint,
    };
    const origin_port: u16 = uri.port orelse if (is_https) 443 else 80;

    var http: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http.deinit();
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    defer proxy_arena.deinit();

    if (req_opts.proxy_policy == .system) {
        if (req_opts.environ) |env| {
            if (!shouldBypassProxy(env, origin_host.bytes, origin_port)) {
                try http.initDefaultProxies(proxy_arena.allocator(), env);
            }
        }
    }

    if (is_https) {
        if (http.https_proxy) |proxy| {
            if (!(proxy.host.eql(origin_host) and proxy.port == origin_port and proxy.protocol == .tls)) {
                return runTunneledPost(
                    allocator,
                    io,
                    proxy.*,
                    origin_host,
                    origin_port,
                    req_opts,
                    sse_sink,
                    done_flag,
                    out_status,
                    out_retry_after_ms,
                );
            }
        }
    }

    // If SSL_CERT_FILE was supplied for direct HTTPS, load it into std.http.Client's
    // bundle so custom roots work identically with and without a proxy.
    if (is_https) {
        if (req_opts.environ) |env| {
            if (env.get("SSL_CERT_FILE")) |cert_file| {
                if (cert_file.len > 0) {
                    const now = std.Io.Clock.real.now(io);
                    var custom: std.crypto.Certificate.Bundle = .empty;
                    errdefer custom.deinit(allocator);
                    try loadCertFile(&custom, allocator, io, now, cert_file);
                    http.now = now;
                    http.ca_bundle = custom;
                }
            }
        }
    }

    var req = try http.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = if (req_opts.authorization) |value| .{ .override = value } else .omit,
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = req_opts.extra_headers,
    });
    defer req.deinit();
    if (req.connection) |conn| {
        if (req_opts.cancel_socket) |cs| cs.set(io, conn.stream_reader.stream);
    }
    defer if (req_opts.cancel_socket) |cs| cs.clear(io);

    const body_copy = try allocator.dupe(u8, req_opts.payload);
    defer allocator.free(body_copy);
    try req.sendBodyComplete(body_copy);
    model.Timing.finish(req_opts.timing, io, request_started, "http_connect_and_send");
    const response_started = model.Timing.start(req_opts.timing, io);
    var response = req.receiveHead(&.{}) catch |err| switch (err) {
        error.ReadFailed => return if (req.connection) |conn| conn.getReadError() orelse error.ResponseReadFailed else error.ResponseReadFailed,
        else => |e| return e,
    };
    model.Timing.finish(req_opts.timing, io, response_started, "http_wait_for_response_headers");
    out_status.* = response.head.status;
    if (response.head.status != .ok) {
        out_retry_after_ms.* = http_headers.parseRetryAfterMs(response.head);
        return error.HttpRequestFailed;
    }
    if (response.head.content_encoding != .identity) return error.UnsupportedContentEncoding;
    const content_type = response.head.content_type orelse return error.InvalidContentType;
    const delimiter = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..delimiter], " \t"), "text/event-stream")) {
        return error.InvalidContentType;
    }

    var transfer_buffer: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);
    try timedDrainSseStream(allocator, io, req_opts.timing, body_reader, sse_sink, done_flag);
}

fn runTunneledPost(
    allocator: std.mem.Allocator,
    io: std.Io,
    proxy: std.http.Client.Proxy,
    origin_host: std.Io.net.HostName,
    origin_port: u16,
    req_opts: Request,
    sse_sink: sse.Sink,
    done_flag: *const bool,
    out_status: *?std.http.Status,
    out_retry_after_ms: *?u64,
) !void {
    const request_started = model.Timing.start(req_opts.timing, io);
    const tls_buf_len = std.crypto.tls.Client.min_buffer_len;
    const max_head_len: usize = 16 * 1024;
    const now = std.Io.Clock.real.now(io);

    var owned_bundle: std.crypto.Certificate.Bundle = .empty;
    defer owned_bundle.deinit(allocator);
    var bundle_lock: std.Io.RwLock = .init;
    const active_bundle: *std.crypto.Certificate.Bundle = if (req_opts.ca_bundle) |provided|
        provided
    else blk: {
        if (req_opts.environ) |env| {
            if (env.get("SSL_CERT_FILE")) |cert_file| {
                if (cert_file.len > 0) {
                    try loadCertFile(&owned_bundle, allocator, io, now, cert_file);
                    break :blk &owned_bundle;
                }
            }
        }
        owned_bundle.rescan(allocator, io, now) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.CertificateBundleLoadFailure,
        };
        break :blk &owned_bundle;
    };

    var stream = try proxy.host.connect(io, proxy.port, .{ .mode = .stream });
    defer stream.close(io);
    if (req_opts.cancel_socket) |cs| cs.set(io, stream);
    defer if (req_opts.cancel_socket) |cs| cs.clear(io);

    const sock_read_buf = try allocator.alloc(u8, tls_buf_len + max_head_len);
    defer allocator.free(sock_read_buf);
    const sock_write_buf = try allocator.alloc(u8, tls_buf_len);
    defer allocator.free(sock_write_buf);
    var sock_reader = stream.reader(io, sock_read_buf);
    var sock_writer = stream.writer(io, sock_write_buf);

    var outer_tls_read_buf: ?[]u8 = null;
    defer if (outer_tls_read_buf) |b| allocator.free(b);
    var outer_tls_write_buf: ?[]u8 = null;
    defer if (outer_tls_write_buf) |b| allocator.free(b);
    var outer_tls: std.crypto.tls.Client = undefined;
    var has_outer_tls = false;

    if (proxy.protocol == .tls) {
        outer_tls_read_buf = try allocator.alloc(u8, tls_buf_len + max_head_len);
        outer_tls_write_buf = try allocator.alloc(u8, tls_buf_len);
        var outer_entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&outer_entropy);
        outer_tls = std.crypto.tls.Client.init(&sock_reader.interface, &sock_writer.interface, .{
            .host = .{ .explicit = proxy.host.bytes },
            .ca = .{ .bundle = .{
                .gpa = allocator,
                .io = io,
                .lock = &bundle_lock,
                .bundle = active_bundle,
            } },
            .read_buffer = outer_tls_read_buf.?,
            .write_buffer = outer_tls_write_buf.?,
            .entropy = &outer_entropy,
            .realtime_now = now,
            .allow_truncation_attacks = true,
        }) catch |err| switch (err) {
            error.WriteFailed => return sock_writer.err orelse error.TlsInitializationFailed,
            error.ReadFailed => return sock_reader.err orelse error.TlsInitializationFailed,
            error.Canceled => |e| return e,
            else => return error.TlsInitializationFailed,
        };
        has_outer_tls = true;
    }

    const tunnel_in: *std.Io.Reader = if (has_outer_tls) &outer_tls.reader else &sock_reader.interface;
    const tunnel_out: *std.Io.Writer = if (has_outer_tls) &outer_tls.writer else &sock_writer.interface;

    // 1. Establish HTTP CONNECT tunnel to origin_host:origin_port.
    try writeAuthorityRequestLine(tunnel_out, "CONNECT ", origin_host.bytes, origin_port, " HTTP/1.1\r\n");
    try writeAuthorityHeader(tunnel_out, "host: ", origin_host.bytes, origin_port);
    if (proxy.authorization) |auth| {
        try tunnel_out.writeAll("proxy-authorization: ");
        try tunnel_out.writeAll(auth);
        try tunnel_out.writeAll("\r\n");
    }
    try tunnel_out.writeAll("proxy-connection: keep-alive\r\n\r\n");
    try tunnel_out.flush();
    if (has_outer_tls) try sock_writer.interface.flush();

    var connect_http = std.http.Reader{
        .in = tunnel_in,
        .state = .ready,
        .interface = undefined,
        .max_head_len = max_head_len,
    };
    const connect_head_bytes = connect_http.receiveHead() catch |err| switch (err) {
        error.ReadFailed => return sock_reader.err orelse error.ResponseReadFailed,
        error.HttpConnectionClosing, error.HttpRequestTruncated => |e| return e,
        else => return error.ProxyConnectFailed,
    };
    const connect_head = std.http.Client.Response.Head.parse(connect_head_bytes) catch return error.ProxyConnectFailed;
    if (connect_head.status.class() != .success) return error.ProxyConnectFailed;

    // 2. Negotiate origin TLS inside the established tunnel.
    const tls_read_buf = try allocator.alloc(u8, tls_buf_len + max_head_len);
    defer allocator.free(tls_read_buf);
    const tls_write_buf = try allocator.alloc(u8, tls_buf_len);
    defer allocator.free(tls_write_buf);
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    var origin_tls = std.crypto.tls.Client.init(tunnel_in, tunnel_out, .{
        .host = .{ .explicit = origin_host.bytes },
        .ca = .{ .bundle = .{
            .gpa = allocator,
            .io = io,
            .lock = &bundle_lock,
            .bundle = active_bundle,
        } },
        .read_buffer = tls_read_buf,
        .write_buffer = tls_write_buf,
        .entropy = &entropy,
        .realtime_now = now,
        .allow_truncation_attacks = true,
    }) catch |err| switch (err) {
        error.WriteFailed => return sock_writer.err orelse error.TlsInitializationFailed,
        error.ReadFailed => return sock_reader.err orelse error.TlsInitializationFailed,
        error.Canceled => |e| return e,
        else => return error.TlsInitializationFailed,
    };

    // 3. Send HTTP/1.1 POST request over origin TLS.
    const w = &origin_tls.writer;
    try w.writeAll("POST ");
    if (req_opts.uri.path.isEmpty()) {
        try w.writeByte('/');
        try req_opts.uri.writeToStream(w, .{ .query = true });
    } else {
        try req_opts.uri.writeToStream(w, .{ .path = true, .query = true });
    }
    try w.writeAll(" HTTP/1.1\r\n");
    try w.writeAll("host: ");
    try req_opts.uri.writeToStream(w, .{ .authority = true });
    try w.writeAll("\r\n");
    if (req_opts.authorization) |auth| {
        try w.writeAll("authorization: ");
        try w.writeAll(auth);
        try w.writeAll("\r\n");
    }
    try w.writeAll("user-agent: zig/");
    try w.writeAll(builtin.zig_version_string);
    try w.writeAll(" (std.http)\r\n");
    try w.writeAll("connection: close\r\n");
    try w.writeAll("accept-encoding: identity\r\n");
    try w.print("content-length: {d}\r\n", .{req_opts.payload.len});
    try w.writeAll("content-type: application/json\r\n");
    for (req_opts.extra_headers) |header| {
        try w.writeAll(header.name);
        try w.writeAll(": ");
        try w.writeAll(header.value);
        try w.writeAll("\r\n");
    }
    try w.writeAll("\r\n");
    try w.writeAll(req_opts.payload);
    try w.flush();
    try tunnel_out.flush();
    if (has_outer_tls) try sock_writer.interface.flush();

    // 4. Read HTTP response head and stream SSE body.
    var resp_http = std.http.Reader{
        .in = &origin_tls.reader,
        .state = .ready,
        .interface = undefined,
        .max_head_len = max_head_len,
    };
    model.Timing.finish(req_opts.timing, io, request_started, "http_connect_and_send");
    const response_started = model.Timing.start(req_opts.timing, io);
    const resp_head_bytes = resp_http.receiveHead() catch |err| switch (err) {
        error.ReadFailed => return if (origin_tls.read_err) |e| e else if (sock_reader.err) |e| e else error.ResponseReadFailed,
        else => |e| return e,
    };
    const head = try std.http.Client.Response.Head.parse(resp_head_bytes);
    model.Timing.finish(req_opts.timing, io, response_started, "http_wait_for_response_headers");
    out_status.* = head.status;
    if (head.status != .ok) {
        out_retry_after_ms.* = http_headers.parseRetryAfterMs(head);
        return error.HttpRequestFailed;
    }
    if (head.content_encoding != .identity) return error.UnsupportedContentEncoding;
    const content_type = head.content_type orelse return error.InvalidContentType;
    const delimiter = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..delimiter], " \t"), "text/event-stream")) {
        return error.InvalidContentType;
    }

    var transfer_buffer: [8192]u8 = undefined;
    const body_reader = resp_http.bodyReader(&transfer_buffer, head.transfer_encoding, head.content_length);
    try timedDrainSseStream(allocator, io, req_opts.timing, body_reader, sse_sink, done_flag);
}

fn timedDrainSseStream(allocator: std.mem.Allocator, io: std.Io, timing: ?model.Timing, reader: *std.Io.Reader, sink: sse.Sink, done: *const bool) !void {
    const started = model.Timing.start(timing, io);
    try drainSseStream(allocator, reader, sink, done);
    model.Timing.finish(timing, io, started, "sse_read_decode_and_delivery");
}

fn drainSseStream(
    allocator: std.mem.Allocator,
    body_reader: *std.Io.Reader,
    sse_sink: sse.Sink,
    done_flag: *const bool,
) !void {
    var framing = sse.Decoder.init(allocator, 1024 * 1024);
    defer framing.deinit();
    var chunk: [8192]u8 = undefined;
    while (!done_flag.*) {
        const buffered = body_reader.buffered();
        if (buffered.len > 0) {
            try framing.feed(buffered, sse_sink);
            body_reader.toss(buffered.len);
            continue;
        }
        var vectors = [_][]u8{&chunk};
        const count = body_reader.readVec(&vectors) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ResponseReadFailed,
        };
        if (count > 0) try framing.feed(chunk[0..count], sse_sink);
    }
    try framing.finish();
    if (!done_flag.*) return error.TruncatedStream;
}

fn loadCertFile(
    bundle: *std.crypto.Certificate.Bundle,
    allocator: std.mem.Allocator,
    io: std.Io,
    now: std.Io.Timestamp,
    path: []const u8,
) !void {
    if (std.fs.path.isAbsolute(path)) {
        bundle.addCertsFromFilePathAbsolute(allocator, io, now, path) catch return error.CertificateBundleLoadFailure;
    } else {
        bundle.addCertsFromFilePath(allocator, io, now, std.Io.Dir.cwd(), path) catch return error.CertificateBundleLoadFailure;
    }
}

fn writeAuthorityRequestLine(w: *std.Io.Writer, prefix: []const u8, host: []const u8, port: u16, suffix: []const u8) !void {
    try w.writeAll(prefix);
    if (std.mem.indexOfScalar(u8, host, ':') != null and !std.mem.startsWith(u8, host, "[")) {
        try w.print("[{s}]:{d}", .{ host, port });
    } else {
        try w.print("{s}:{d}", .{ host, port });
    }
    try w.writeAll(suffix);
}

fn writeAuthorityHeader(w: *std.Io.Writer, prefix: []const u8, host: []const u8, port: u16) !void {
    try w.writeAll(prefix);
    if (std.mem.indexOfScalar(u8, host, ':') != null and !std.mem.startsWith(u8, host, "[")) {
        try w.print("[{s}]:{d}\r\n", .{ host, port });
    } else {
        try w.print("{s}:{d}\r\n", .{ host, port });
    }
}

pub fn shouldBypassProxy(env: *const std.process.Environ.Map, raw_host: []const u8, port: u16) bool {
    const raw_list = blk: {
        if (env.get("NO_PROXY")) |v| {
            if (v.len > 0) break :blk v;
        }
        if (env.get("no_proxy")) |v| {
            if (v.len > 0) break :blk v;
        }
        return false;
    };
    const host = trimBrackets(raw_host);
    var it = std.mem.splitScalar(u8, raw_list, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return true;

        var rule_host = entry;
        if (std.mem.startsWith(u8, entry, "[")) {
            const close = std.mem.indexOfScalar(u8, entry, ']') orelse continue;
            rule_host = entry[1..close];
            const rest = entry[close + 1 ..];
            if (rest.len > 0) {
                if (rest[0] != ':') continue;
                const rule_port = std.fmt.parseInt(u16, rest[1..], 10) catch continue;
                if (rule_port != port) continue;
            }
        } else if (std.mem.indexOfScalar(u8, entry, ':')) |colon| {
            // Only treat as host:port when there is a single colon (not bare IPv6 literal).
            if (std.mem.lastIndexOfScalar(u8, entry, ':') == colon) {
                const rule_port = std.fmt.parseInt(u16, entry[colon + 1 ..], 10) catch continue;
                if (rule_port != port) continue;
                rule_host = entry[0..colon];
            }
        }

        const norm_rule = std.mem.trimStart(u8, rule_host, ".");
        if (norm_rule.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(host, norm_rule)) return true;
        if (host.len > norm_rule.len and host[host.len - norm_rule.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - norm_rule.len ..], norm_rule))
        {
            return true;
        }
    }
    return false;
}

fn trimBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}
