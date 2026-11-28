//! Pure Zig lightweight `web_search` tool with SSRF protection, policy URL
//! authorization, bounded output, and zero external runtime dependencies.
//!
//! Supported backends (selected explicitly via `ZPI_SEARCH_BACKEND` or
//! auto-detected from environment):
//!   1. `brave`      — Brave Search JSON API (`BRAVE_API_KEY`)
//!   2. `tavily`     — Tavily Search JSON API (`TAVILY_API_KEY`)
//!   3. `searxng`    — Self-hosted SearXNG JSON API (`SEARXNG_URL` or `ZPI_SEARCH_URL`)
//!   4. `exa`        — Zero-config Exa hosted MCP endpoint (`https://mcp.exa.ai/mcp`, default when no key is set)
//!   5. `duckduckgo` — Zero-config DuckDuckGo HTML Lite (`ZPI_SEARCH_BACKEND=duckduckgo`)
const std = @import("std");
const agent = @import("agent");
const model = @import("model");
const web_fetch = @import("web_fetch");

pub const max_query_bytes: usize = 512;
pub const max_response_bytes: usize = 1024 * 1024;
pub const default_max_results: usize = 5;
pub const max_results_cap: usize = 10;
pub const default_timeout_sec: usize = 15;
pub const max_timeout_sec: usize = 60;

pub const Backend = enum {
    auto,
    brave,
    tavily,
    searxng,
    exa,
    duckduckgo,

    pub fn parse(raw: []const u8) ?Backend {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "brave")) return .brave;
        if (std.ascii.eqlIgnoreCase(raw, "tavily")) return .tavily;
        if (std.ascii.eqlIgnoreCase(raw, "searxng")) return .searxng;
        if (std.ascii.eqlIgnoreCase(raw, "exa")) return .exa;
        if (std.ascii.eqlIgnoreCase(raw, "duckduckgo") or std.ascii.eqlIgnoreCase(raw, "ddg")) return .duckduckgo;
        return null;
    }
};

pub const ResolvedBackend = enum { brave, tavily, searxng, exa, duckduckgo };

pub const Config = struct {
    backend: Backend = .auto,
    brave_api_key: []const u8 = "",
    tavily_api_key: []const u8 = "",
    searxng_url: []const u8 = "",
    exa_api_key: []const u8 = "",
    /// Optional base URL override (primarily for custom endpoints or loopback fixtures).
    endpoint_override: []const u8 = "",
    allow_loopback: bool = false,

    pub fn fromEnv(env: ?*const std.process.Environ.Map, allow_loopback: bool) Config {
        const m = env orelse return .{ .allow_loopback = allow_loopback };
        const raw_backend = m.get("ZPI_SEARCH_BACKEND") orelse "auto";
        const backend = Backend.parse(raw_backend) orelse .auto;
        const generic_key = m.get("ZPI_SEARCH_API_KEY") orelse "";
        return .{
            .backend = backend,
            .brave_api_key = m.get("BRAVE_API_KEY") orelse (if (backend == .brave) generic_key else ""),
            .tavily_api_key = m.get("TAVILY_API_KEY") orelse (if (backend == .tavily) generic_key else ""),
            .searxng_url = m.get("SEARXNG_URL") orelse (if (backend == .searxng) (m.get("ZPI_SEARCH_URL") orelse "") else ""),
            .exa_api_key = m.get("EXA_API_KEY") orelse (if (backend == .exa) generic_key else ""),
            .endpoint_override = m.get("ZPI_SEARCH_URL") orelse "",
            .allow_loopback = allow_loopback,
        };
    }

    pub fn resolveBackend(self: Config) !ResolvedBackend {
        return switch (self.backend) {
            .brave => if (self.brave_api_key.len > 0) .brave else error.MissingSearchApiKey,
            .tavily => if (self.tavily_api_key.len > 0) .tavily else error.MissingSearchApiKey,
            .searxng => if (self.searxng_url.len > 0 or self.endpoint_override.len > 0) .searxng else error.MissingSearchEndpoint,
            .exa => .exa,
            .duckduckgo => .duckduckgo,
            .auto => blk: {
                if (self.brave_api_key.len > 0) break :blk .brave;
                if (self.tavily_api_key.len > 0) break :blk .tavily;
                if (self.searxng_url.len > 0) break :blk .searxng;
                break :blk .exa;
            },
        };
    }
};

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

pub fn executeWebSearch(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    const cfg: Config = if (context) |ptr| @as(*const Config, @ptrCast(@alignCast(ptr))).* else .{};
    if (args != .object) return error.ExpectedObject;
    for (args.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "query") and !std.mem.eql(u8, key, "maxResults") and !std.mem.eql(u8, key, "timeout")) {
            return error.UnknownArgument;
        }
    }
    const query_val = args.object.get("query") orelse return error.MissingArgument;
    if (query_val != .string) return error.ExpectedString;
    const query = std.mem.trim(u8, query_val.string, " \t");
    if (query.len == 0 or query.len > max_query_bytes) return error.InvalidSearchQuery;
    if (!std.unicode.utf8ValidateSlice(query) or std.mem.indexOfAny(u8, query, "\x00\r\n") != null) return error.InvalidSearchQuery;

    const max_results = try parsePositive(args, "maxResults", default_max_results, max_results_cap);
    const timeout_sec = try parsePositive(args, "timeout", default_timeout_sec, max_timeout_sec);
    if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;

    const backend = try cfg.resolveBackend();
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const results = switch (backend) {
        .brave => try searchBrave(scratch, ctx, cfg, query, max_results, timeout_sec),
        .tavily => try searchTavily(scratch, ctx, cfg, query, max_results, timeout_sec),
        .searxng => try searchSearxng(scratch, ctx, cfg, query, max_results, timeout_sec),
        .exa => try searchExa(scratch, ctx, cfg, query, max_results, timeout_sec),
        .duckduckgo => try searchDuckDuckGo(scratch, ctx, cfg, query, max_results, timeout_sec),
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.allocator);
    if (results.len == 0) {
        try out.print(ctx.allocator, "No search results found ({s}).", .{@tagName(backend)});
    } else {
        try out.print(ctx.allocator, "Search results ({s}, {d}):\n", .{ @tagName(backend), results.len });
        for (results, 0..) |item, idx| {
            try out.print(ctx.allocator, "\n{d}. {s}\n   {s}", .{ idx + 1, item.title, item.url });
            if (item.snippet.len > 0) {
                try out.print(ctx.allocator, "\n   {s}", .{item.snippet});
            }
        }
    }

    const encoded = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .backend = @tagName(backend),
        .query = query,
        .count = results.len,
        .results = results,
    }, .{});
    defer ctx.allocator.free(encoded);
    return .{
        .text = try out.toOwnedSlice(ctx.allocator),
        .details = try std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, encoded, .{ .allocate = .alloc_always }),
    };
}

fn parsePositive(args: std.json.Value, key: []const u8, fallback: usize, cap: usize) !usize {
    const val = args.object.get(key) orelse return fallback;
    const n: i64 = switch (val) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch return error.ExpectedPositiveInteger,
        else => return error.ExpectedPositiveInteger,
    };
    if (n <= 0 or n > cap) return error.ExpectedPositiveInteger;
    return @intCast(n);
}

fn urlEncodeAlloc(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(a, c);
        } else if (c == ' ') {
            try out.append(a, '+');
        } else {
            try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 0x0f] });
        }
    }
    return out.toOwnedSlice(a);
}

fn urlDecodeAlloc(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '+') {
            try out.append(a, ' ');
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(a, input[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(a, input[i]);
                continue;
            };
            try out.append(a, (hi << 4) | lo);
            i += 2;
        } else {
            try out.append(a, input[i]);
        }
    }
    return out.toOwnedSlice(a);
}

fn httpExchange(
    a: std.mem.Allocator,
    ctx: agent.ToolContext,
    method: std.http.Method,
    raw_url: []const u8,
    extra_headers: []const std.http.Header,
    body: ?[]const u8,
    timeout_sec: usize,
    allow_loopback: bool,
) ![]u8 {
    if (std.mem.indexOfAny(u8, raw_url, "\x00\r\n") != null) return error.InvalidUrl;
    const uri = std.Uri.parse(raw_url) catch return error.InvalidUrl;
    try web_fetch.validateUriBasics(uri);
    if (ctx.authorize_url) |authorize| {
        var local_auth: ?agent.security.Authorization = null;
        const slot = ctx.rewritten_authorization orelse &local_auth;
        try authorize(ctx.authorization_context, raw_url, slot);
    }
    try web_fetch.validateUrlSsrf(ctx.io, uri, allow_loopback);

    const deadline_ms = std.Io.Timestamp.now(ctx.io, .awake).toMilliseconds() + @as(i64, @intCast(timeout_sec)) * 1000;
    var http: std.http.Client = .{ .allocator = a, .io = ctx.io };
    defer http.deinit();

    var req = try http.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "zpi/0.1 (web_search)" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    if (req.connection) |conn| {
        try web_fetch.verifyConnectedPeerSsrf(conn.stream_reader.stream, allow_loopback);
    }

    var cancel_sock = model.CancelSocket{};
    if (req.connection) |conn| cancel_sock.set(ctx.io, conn.stream_reader.stream);
    defer cancel_sock.clear(ctx.io);

    var done = std.atomic.Value(bool).init(false);
    const Watchdog = struct {
        io: std.Io,
        cancel: ?model.Cancel,
        cs: *model.CancelSocket,
        done: *std.atomic.Value(bool),
        deadline_ms: i64,
        timed_out: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            while (!self.done.load(.acquire)) {
                if (self.cancel) |c| if (c.isCanceled()) {
                    self.cs.abort(self.io);
                    return;
                };
                if (std.Io.Timestamp.now(self.io, .awake).toMilliseconds() >= self.deadline_ms) {
                    self.timed_out.store(true, .release);
                    self.cs.abort(self.io);
                    return;
                }
                self.io.sleep(.fromMilliseconds(20), .awake) catch return;
            }
        }
    };
    var watchdog: Watchdog = .{
        .io = ctx.io,
        .cancel = ctx.cancel,
        .cs = &cancel_sock,
        .done = &done,
        .deadline_ms = deadline_ms,
    };
    const wt = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
    defer {
        done.store(true, .release);
        wt.join();
    }

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
            if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            return err;
        };
        body_writer.writer.writeAll(payload) catch |err| {
            if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            return err;
        };
        body_writer.end() catch |err| {
            if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            return err;
        };
        if (req.connection) |conn| conn.flush() catch {};
    } else {
        req.sendBodiless() catch |err| {
            if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            return err;
        };
    }

    var head_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch |err| {
        if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;
        if (watchdog.timed_out.load(.acquire)) return error.Timeout;
        return err;
    };
    const status: u16 = @backingInt(response.head.status);
    if (status < 200 or status >= 300) return error.SearchHttpError;

    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(a);
    while (collected.items.len < max_response_bytes) {
        var chunk: [4096]u8 = undefined;
        const limit = @min(chunk.len, max_response_bytes - collected.items.len);
        const n = reader.readSliceShort(chunk[0..limit]) catch |err| {
            if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            return err;
        };
        if (n == 0) break;
        try collected.appendSlice(a, chunk[0..n]);
    }
    return collected.toOwnedSlice(a);
}

fn searchBrave(a: std.mem.Allocator, ctx: agent.ToolContext, cfg: Config, query: []const u8, max_results: usize, timeout_sec: usize) ![]SearchResult {
    const encoded = try urlEncodeAlloc(a, query);
    const base = if (cfg.endpoint_override.len > 0) cfg.endpoint_override else "https://api.search.brave.com/res/v1/web/search";
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) "&" else "?";
    const url = try a.print("{s}{s}q={s}&count={d}", .{ base, sep, encoded, max_results });
    const body = try httpExchange(a, ctx, .GET, url, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "X-Subscription-Token", .value = cfg.brave_api_key },
    }, null, timeout_sec, cfg.allow_loopback);
    return parseBraveJson(a, body, max_results);
}

fn searchTavily(a: std.mem.Allocator, ctx: agent.ToolContext, cfg: Config, query: []const u8, max_results: usize, timeout_sec: usize) ![]SearchResult {
    const url = if (cfg.endpoint_override.len > 0) cfg.endpoint_override else "https://api.tavily.com/search";
    const payload = try std.json.Stringify.valueAlloc(a, .{
        .api_key = cfg.tavily_api_key,
        .query = query,
        .max_results = max_results,
        .search_depth = "basic",
    }, .{});
    const body = try httpExchange(a, ctx, .POST, url, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/json" },
    }, payload, timeout_sec, cfg.allow_loopback);
    return parseGenericJsonResults(a, body, max_results, "content");
}

fn searchSearxng(a: std.mem.Allocator, ctx: agent.ToolContext, cfg: Config, query: []const u8, max_results: usize, timeout_sec: usize) ![]SearchResult {
    const encoded = try urlEncodeAlloc(a, query);
    const base = if (cfg.searxng_url.len > 0) cfg.searxng_url else cfg.endpoint_override;
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) "&" else "?";
    const url = try a.print("{s}{s}q={s}&format=json", .{ base, sep, encoded });
    const body = try httpExchange(a, ctx, .GET, url, &.{
        .{ .name = "Accept", .value = "application/json" },
    }, null, timeout_sec, cfg.allow_loopback);
    return parseGenericJsonResults(a, body, max_results, "content");
}

fn searchExa(a: std.mem.Allocator, ctx: agent.ToolContext, cfg: Config, query: []const u8, max_results: usize, timeout_sec: usize) ![]SearchResult {
    const url = if (cfg.endpoint_override.len > 0) cfg.endpoint_override else "https://mcp.exa.ai/mcp";
    const payload = try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "tools/call",
        .params = .{
            .name = "web_search_exa",
            .arguments = .{
                .query = query,
                .numResults = max_results,
                .type = "auto",
                .livecrawl = "fallback",
            },
        },
    }, .{});
    var headers_buf: [3]std.http.Header = .{
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-api-key", .value = cfg.exa_api_key },
    };
    const headers: []const std.http.Header = if (cfg.exa_api_key.len > 0) headers_buf[0..3] else headers_buf[0..2];
    const body = try httpExchange(a, ctx, .POST, url, headers, payload, timeout_sec, cfg.allow_loopback);
    return parseExaMcpResponse(a, body, max_results);
}

/// Parse an Exa MCP Streamable HTTP response (either direct JSON-RPC or SSE
/// `data: {...}` lines). Supports both `result.structuredContent.results` and
/// `result.content[].text` (`Title:` / `URL:` / `Text:` blocks).
pub fn parseExaMcpResponse(a: std.mem.Allocator, bytes: []const u8, max_results: usize) ![]SearchResult {
    const json_slice = extractJsonFromMcpBody(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, a, json_slice, .{}) catch return error.InvalidSearchResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSearchResponse;
    if (parsed.value.object.get("error") != null) return error.SearchHttpError;
    const result_val = parsed.value.object.get("result") orelse return try a.alloc(SearchResult, 0);
    if (result_val != .object) return error.InvalidSearchResponse;

    if (result_val.object.get("structuredContent")) |sc| {
        if (sc == .object) {
            if (sc.object.get("results")) |res_arr| {
                if (res_arr == .array and res_arr.array.items.len > 0) {
                    return collectExaStructuredResults(a, res_arr.array.items, max_results);
                }
            }
        }
    }

    if (result_val.object.get("content")) |content_val| {
        if (content_val == .array) {
            var combined: std.ArrayList(u8) = .empty;
            defer combined.deinit(a);
            for (content_val.array.items) |block| {
                if (block != .object) continue;
                const text_v = block.object.get("text") orelse continue;
                if (text_v != .string or text_v.string.len == 0) continue;
                if (combined.items.len > 0) try combined.append(a, '\n');
                try combined.appendSlice(a, text_v.string);
            }
            if (combined.items.len > 0) {
                return parseExaTextBlocks(a, combined.items, max_results);
            }
        }
    }
    return try a.alloc(SearchResult, 0);
}

fn extractJsonFromMcpBody(bytes: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') return trimmed;
    // Streamable HTTP SSE format: pick the last `data:` payload that looks like JSON.
    var best: []const u8 = trimmed;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "data:")) {
            const payload = std.mem.trim(u8, line["data:".len..], " \t");
            if (payload.len > 0 and payload[0] == '{') best = payload;
        }
    }
    return best;
}

fn collectExaStructuredResults(a: std.mem.Allocator, items: []const std.json.Value, max_results: usize) ![]SearchResult {
    var out: std.ArrayList(SearchResult) = .empty;
    for (items) |item| {
        if (out.items.len >= max_results) break;
        if (item != .object) continue;
        const url_v = item.object.get("url") orelse continue;
        if (url_v != .string or url_v.string.len == 0) continue;
        const title_v = item.object.get("title");
        const title_raw = if (title_v != null and title_v.? == .string and title_v.?.string.len > 0) title_v.?.string else url_v.string;
        var snip_raw: []const u8 = "";
        if (item.object.get("text")) |tv| {
            if (tv == .string and tv.string.len > 0) snip_raw = tv.string;
        }
        if (snip_raw.len == 0) {
            if (item.object.get("highlights")) |hv| {
                if (hv == .array and hv.array.items.len > 0 and hv.array.items[0] == .string) {
                    snip_raw = hv.array.items[0].string;
                }
            }
        }
        if (snip_raw.len == 0) {
            if (item.object.get("snippet")) |sv| {
                if (sv == .string) snip_raw = sv.string;
            }
        }
        try out.append(a, .{
            .title = try cleanTextAlloc(a, title_raw, 200),
            .url = try a.dupe(u8, url_v.string[0..@min(url_v.string.len, 2048)]),
            .snippet = try cleanTextAlloc(a, snip_raw, 400),
        });
    }
    return out.toOwnedSlice(a);
}

fn parseExaTextBlocks(a: std.mem.Allocator, text: []const u8, max_results: usize) ![]SearchResult {
    var out: std.ArrayList(SearchResult) = .empty;
    var cur_title: []const u8 = "";
    var cur_url: []const u8 = "";
    var cur_snip: std.ArrayList(u8) = .empty;
    defer cur_snip.deinit(a);
    var in_snippet = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (stripExaLabel(line, "Title:")) |t| {
            if (cur_url.len > 0 and out.items.len < max_results) {
                try out.append(a, .{
                    .title = try cleanTextAlloc(a, if (cur_title.len > 0) cur_title else cur_url, 200),
                    .url = try a.dupe(u8, cur_url[0..@min(cur_url.len, 2048)]),
                    .snippet = try cleanTextAlloc(a, cur_snip.items, 400),
                });
            }
            cur_title = t;
            cur_url = "";
            cur_snip.clearRetainingCapacity();
            in_snippet = false;
        } else if (stripExaLabel(line, "URL:")) |u| {
            cur_url = u;
            in_snippet = false;
        } else if (stripExaLabel(line, "Text:") orelse stripExaLabel(line, "Highlights:") orelse stripExaLabel(line, "Summary:")) |s| {
            if (cur_snip.items.len > 0 and s.len > 0) try cur_snip.append(a, ' ');
            try cur_snip.appendSlice(a, s);
            in_snippet = true;
        } else if (stripExaLabel(line, "Author:") != null or stripExaLabel(line, "Published Date:") != null) {
            in_snippet = false;
        } else if (in_snippet and line.len > 0 and cur_snip.items.len < 600) {
            if (cur_snip.items.len > 0) try cur_snip.append(a, ' ');
            try cur_snip.appendSlice(a, line);
        }
    }
    if (cur_url.len > 0 and out.items.len < max_results) {
        try out.append(a, .{
            .title = try cleanTextAlloc(a, if (cur_title.len > 0) cur_title else cur_url, 200),
            .url = try a.dupe(u8, cur_url[0..@min(cur_url.len, 2048)]),
            .snippet = try cleanTextAlloc(a, cur_snip.items, 400),
        });
    }
    if (out.items.len == 0) {
        // Fallback: preserve compact Exa text output if format lacked explicit URL labels.
        const cleaned = try cleanTextAlloc(a, text, 1000);
        if (cleaned.len > 0) {
            try out.append(a, .{
                .title = try a.dupe(u8, "Exa Search Result"),
                .url = try a.dupe(u8, "https://exa.ai"),
                .snippet = cleaned,
            });
        }
    }
    return out.toOwnedSlice(a);
}

fn stripExaLabel(line: []const u8, label: []const u8) ?[]const u8 {
    // Handle optional leading list index like "[1] Title: ..."
    var s = line;
    if (s.len > 3 and s[0] == '[') {
        if (std.mem.indexOfScalar(u8, s, ']')) |rb| {
            s = std.mem.trim(u8, s[rb + 1 ..], " \t");
        }
    }
    if (s.len >= label.len and std.ascii.eqlIgnoreCase(s[0..label.len], label)) {
        return std.mem.trim(u8, s[label.len..], " \t");
    }
    return null;
}

fn searchDuckDuckGo(a: std.mem.Allocator, ctx: agent.ToolContext, cfg: Config, query: []const u8, max_results: usize, timeout_sec: usize) ![]SearchResult {
    const encoded = try urlEncodeAlloc(a, query);
    const base = if (cfg.endpoint_override.len > 0) cfg.endpoint_override else "https://html.duckduckgo.com/html/";
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) "&" else "?";
    const url = try a.print("{s}{s}q={s}", .{ base, sep, encoded });
    const body = try httpExchange(a, ctx, .GET, url, &.{
        .{ .name = "Accept", .value = "text/html, application/xhtml+xml;q=0.9" },
    }, null, timeout_sec, cfg.allow_loopback);
    return parseDuckDuckGoHtml(a, body, max_results);
}

pub fn parseBraveJson(a: std.mem.Allocator, bytes: []const u8, max_results: usize) ![]SearchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidSearchResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSearchResponse;
    const web = parsed.value.object.get("web") orelse return try a.alloc(SearchResult, 0);
    if (web != .object) return error.InvalidSearchResponse;
    const items = web.object.get("results") orelse return try a.alloc(SearchResult, 0);
    if (items != .array) return error.InvalidSearchResponse;
    return collectJsonResults(a, items.array.items, max_results, "description");
}

pub fn parseGenericJsonResults(a: std.mem.Allocator, bytes: []const u8, max_results: usize, snippet_key: []const u8) ![]SearchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidSearchResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSearchResponse;
    const items = parsed.value.object.get("results") orelse return try a.alloc(SearchResult, 0);
    if (items != .array) return error.InvalidSearchResponse;
    return collectJsonResults(a, items.array.items, max_results, snippet_key);
}

fn collectJsonResults(a: std.mem.Allocator, items: []const std.json.Value, max_results: usize, snippet_key: []const u8) ![]SearchResult {
    var out: std.ArrayList(SearchResult) = .empty;
    for (items) |item| {
        if (out.items.len >= max_results) break;
        if (item != .object) continue;
        const url_v = item.object.get("url") orelse continue;
        if (url_v != .string or url_v.string.len == 0) continue;
        const title_v = item.object.get("title");
        const title_raw = if (title_v != null and title_v.? == .string and title_v.?.string.len > 0) title_v.?.string else url_v.string;
        const snip_v = item.object.get(snippet_key) orelse item.object.get("snippet");
        const snip_raw = if (snip_v != null and snip_v.? == .string) snip_v.?.string else "";
        try out.append(a, .{
            .title = try cleanTextAlloc(a, title_raw, 200),
            .url = try a.dupe(u8, url_v.string[0..@min(url_v.string.len, 2048)]),
            .snippet = try cleanTextAlloc(a, snip_raw, 400),
        });
    }
    return out.toOwnedSlice(a);
}

/// Lightweight parser for DuckDuckGo HTML Lite (`<a class="result__a" ...>` + `result__snippet`).
pub fn parseDuckDuckGoHtml(a: std.mem.Allocator, html: []const u8, max_results: usize) ![]SearchResult {
    var out: std.ArrayList(SearchResult) = .empty;
    var pos: usize = 0;
    while (out.items.len < max_results and pos < html.len) {
        const marker = std.mem.indexOfPos(u8, html, pos, "result__a") orelse break;
        const tag_start = std.mem.lastIndexOfScalar(u8, html[0..marker], '<') orelse {
            pos = marker + 9;
            continue;
        };
        const tag_end = std.mem.indexOfScalarPos(u8, html, marker, '>') orelse break;
        const close_a = std.mem.indexOfPos(u8, html, tag_end + 1, "</a>") orelse break;
        const open_tag = html[tag_start .. tag_end + 1];
        const raw_href = extractHref(open_tag) orelse {
            pos = close_a + 4;
            continue;
        };
        const decoded_href = try decodeHtmlEntitiesAlloc(a, raw_href);
        const target_url = try unwrapDuckDuckGoUrl(a, decoded_href);
        const title_plain = try stripHtmlAndDecodeAlloc(a, html[tag_end + 1 .. close_a], 200);

        // Look ahead (bounded to next result__a) for a result__snippet.
        const next_result = std.mem.indexOfPos(u8, html, close_a + 4, "result__a") orelse html.len;
        var snippet: []const u8 = "";
        if (std.mem.indexOfPos(u8, html[0..next_result], close_a + 4, "result__snippet")) |snip_marker| {
            const snip_tag_start = std.mem.lastIndexOfScalar(u8, html[0..snip_marker], '<') orelse snip_marker;
            if (std.mem.indexOfScalarPos(u8, html[0..next_result], snip_marker, '>')) |snip_start| {
                const close_tag: []const u8 = if (std.mem.startsWith(u8, html[snip_tag_start..], "<a"))
                    "</a>"
                else if (std.mem.startsWith(u8, html[snip_tag_start..], "<div"))
                    "</div>"
                else if (std.mem.startsWith(u8, html[snip_tag_start..], "<span"))
                    "</span>"
                else
                    "</";
                const snip_end = std.mem.indexOfPos(u8, html[0..next_result], snip_start + 1, close_tag) orelse next_result;
                snippet = try stripHtmlAndDecodeAlloc(a, html[snip_start + 1 .. snip_end], 400);
            }
        }
        if (target_url.len > 0 and title_plain.len > 0) {
            try out.append(a, .{
                .title = title_plain,
                .url = target_url,
                .snippet = snippet,
            });
        }
        pos = close_a + 4;
    }
    return out.toOwnedSlice(a);
}

fn extractHref(tag: []const u8) ?[]const u8 {
    const idx = std.ascii.findIgnoreCase(tag, "href=") orelse return null;
    var start = idx + 5;
    if (start >= tag.len) return null;
    const quote = tag[start];
    if (quote == '"' or quote == '\'') {
        start += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, start, quote) orelse return null;
        return tag[start..end];
    }
    var end = start;
    while (end < tag.len and !std.ascii.isWhitespace(tag[end]) and tag[end] != '>') : (end += 1) {}
    return tag[start..end];
}

fn unwrapDuckDuckGoUrl(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, raw, "uddg=")) |idx| {
        const start = idx + 5;
        const end = std.mem.indexOfScalarPos(u8, raw, start, '&') orelse raw.len;
        const decoded = try urlDecodeAlloc(a, raw[start..end]);
        if (std.mem.startsWith(u8, decoded, "http://") or std.mem.startsWith(u8, decoded, "https://")) {
            return decoded;
        }
    }
    if (std.mem.startsWith(u8, raw, "//")) {
        return a.print("https:{s}", .{raw});
    }
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) {
        return a.dupe(u8, raw);
    }
    return a.dupe(u8, "");
}

fn stripHtmlAndDecodeAlloc(a: std.mem.Allocator, raw: []const u8, max_len: usize) ![]u8 {
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(a);
    var in_tag = false;
    for (raw) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) try stripped.append(a, c);
    }
    const decoded = try decodeHtmlEntitiesAlloc(a, stripped.items);
    defer a.free(decoded);
    return cleanTextAlloc(a, decoded, max_len);
}

fn decodeHtmlEntitiesAlloc(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try out.append(a, '&');
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try out.append(a, '<');
                i += 3;
                continue;
            } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try out.append(a, '>');
                i += 3;
                continue;
            } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try out.append(a, '"');
                i += 5;
                continue;
            } else if (std.mem.startsWith(u8, input[i..], "&#x27;") or std.mem.startsWith(u8, input[i..], "&#39;") or std.mem.startsWith(u8, input[i..], "&apos;")) {
                const skip: usize = if (std.mem.startsWith(u8, input[i..], "&#39;")) 4 else 5;
                try out.append(a, '\'');
                i += skip;
                continue;
            } else if (std.mem.startsWith(u8, input[i..], "&nbsp;")) {
                try out.append(a, ' ');
                i += 5;
                continue;
            }
        }
        try out.append(a, input[i]);
    }
    return out.toOwnedSlice(a);
}

fn cleanTextAlloc(a: std.mem.Allocator, input: []const u8, max_len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var prev_space = true;
    for (input) |c| {
        if (c < 0x20 or c == 0x7f) {
            if (!prev_space) {
                try out.append(a, ' ');
                prev_space = true;
            }
        } else if (c == ' ') {
            if (!prev_space) {
                try out.append(a, ' ');
                prev_space = true;
            }
        } else {
            try out.append(a, c);
            prev_space = false;
        }
        if (out.items.len >= max_len) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    // Ensure valid UTF-8 boundary after length clipping.
    while (out.items.len > 0 and !std.unicode.utf8ValidateSlice(out.items)) out.items.len -= 1;
    return out.toOwnedSlice(a);
}

// -----------------------------------------------------------------------------
// Unit tests
// -----------------------------------------------------------------------------

test "web_search parsers decode Brave, Tavily/SearXNG JSON, and DuckDuckGo HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brave = try parseBraveJson(a,
        \\{"web":{"results":[{"title":"Zig 0.17","url":"https://ziglang.org","description":"Zig release notes"}]}}
    , 5);
    try std.testing.expectEqual(@as(usize, 1), brave.len);
    try std.testing.expectEqualStrings("Zig 0.17", brave[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org", brave[0].url);
    try std.testing.expectEqualStrings("Zig release notes", brave[0].snippet);

    const generic = try parseGenericJsonResults(a,
        \\{"results":[{"title":"Zpi","url":"https://github.com/syuchua/zpi","content":"Fast Zig agent"}]}
    , 5, "content");
    try std.testing.expectEqual(@as(usize, 1), generic.len);
    try std.testing.expectEqualStrings("Fast Zig agent", generic[0].snippet);

    const ddg = try parseDuckDuckGoHtml(a,
        \\<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2Fdocs&amp;rut=abc">Zig &amp; Docs</a>
        \\<a class="result__snippet">Official <b>Zig</b> documentation.</a></div>
    , 5);
    try std.testing.expectEqual(@as(usize, 1), ddg.len);
    try std.testing.expectEqualStrings("Zig & Docs", ddg[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org/docs", ddg[0].url);
    try std.testing.expectEqualStrings("Official Zig documentation.", ddg[0].snippet);

    const exa_sse = try parseExaMcpResponse(
        a,
        "event: message\n" ++
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Title: Exa Zig Guide\\nURL: https://ziglang.org/learn/\\nText: Learn Zig 0.17 fast.\"}]}}\n\n",
        5,
    );
    try std.testing.expectEqual(@as(usize, 1), exa_sse.len);
    try std.testing.expectEqualStrings("Exa Zig Guide", exa_sse[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org/learn/", exa_sse[0].url);
    try std.testing.expectEqualStrings("Learn Zig 0.17 fast.", exa_sse[0].snippet);

    const exa_structured = try parseExaMcpResponse(a,
        \\{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"results":[{"title":"Exa Structured","url":"https://exa.ai/docs","highlights":["Zero-config neural search"]}]}}}
    , 5);
    try std.testing.expectEqual(@as(usize, 1), exa_structured.len);
    try std.testing.expectEqualStrings("Exa Structured", exa_structured[0].title);
    try std.testing.expectEqualStrings("https://exa.ai/docs", exa_structured[0].url);
    try std.testing.expectEqualStrings("Zero-config neural search", exa_structured[0].snippet);
}

test "web_search executes against loopback HTTP fixture and enforces authorize_url and SSRF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    const port = srv.socket.address.getPort();

    const Server = struct {
        srv: *std.Io.net.Server,
        io: std.Io,
        fn serve(self: *@This()) void {
            var count: usize = 0;
            while (count < 3) : (count += 1) {
                var stream = self.srv.accept(self.io) catch return;
                defer stream.close(self.io);
                var rbuf: [4096]u8 = undefined;
                var wbuf: [4096]u8 = undefined;
                var reader = stream.reader(self.io, &rbuf);
                var writer = stream.writer(self.io, &wbuf);
                var http_srv = std.http.Server.init(&reader.interface, &writer.interface);
                var req = http_srv.receiveHead() catch return;
                const is_post = req.head.method == .POST;
                var is_brave = false;
                var it = req.iterateHeaders();
                while (it.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "x-subscription-token") and std.mem.eql(u8, h.value, "brave-key")) {
                        is_brave = true;
                    }
                }
                if (is_post) {
                    var body_buf: [2048]u8 = undefined;
                    var br = req.readerExpectNone(&body_buf);
                    _ = br.discardRemaining() catch {};
                }
                const body = if (is_post)
                    "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Title: Exa Hit\\nURL: https://example.org/exa\\nText: Matched via Exa\"}]}}\n\n"
                else if (is_brave)
                    "{\"web\":{\"results\":[{\"title\":\"Brave Hit\",\"url\":\"https://example.org/a\",\"description\":\"Matched via Brave\"}]}}"
                else
                    "<a class=\"result__a\" href=\"https://example.org/ddg\">DDG Hit</a><a class=\"result__snippet\">Matched via DDG</a>";
                const ctype = if (is_post) "text/event-stream" else if (is_brave) "application/json" else "text/html";
                req.respond(body, .{
                    .status = .ok,
                    .extra_headers = &.{.{ .name = "content-type", .value = ctype }},
                }) catch return;
            }
        }
    };
    var server: Server = .{ .srv = &srv, .io = io };
    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});
    defer thread.join();

    const base_url = try a.print("http://127.0.0.1:{d}/search", .{port});
    const parsed_args = try std.json.parseFromSlice(std.json.Value, a, "{\"query\":\"zig 0.17\",\"maxResults\":3}", .{});
    const ctx: agent.ToolContext = .{ .allocator = a, .io = io, .cwd = "." };

    // 1. SSRF blocks loopback when allow_loopback is false.
    var blocked_cfg: Config = .{ .backend = .duckduckgo, .endpoint_override = base_url, .allow_loopback = false };
    try std.testing.expectError(error.SsrfBlocked, executeWebSearch(&blocked_cfg, ctx, parsed_args.value));

    // 2. authorize_url denial blocks before network request.
    const DenyUrl = struct {
        fn authorize(_: ?*anyopaque, _: []const u8, _: *?agent.security.Authorization) anyerror!void {
            return error.CapabilityDenied;
        }
    };
    var allowed_ddg: Config = .{ .backend = .duckduckgo, .endpoint_override = base_url, .allow_loopback = true };
    var denied_ctx = ctx;
    denied_ctx.authorize_url = DenyUrl.authorize;
    try std.testing.expectError(error.CapabilityDenied, executeWebSearch(&allowed_ddg, denied_ctx, parsed_args.value));

    // 3. DuckDuckGo HTML loopback search succeeds.
    const ddg_res = try executeWebSearch(&allowed_ddg, ctx, parsed_args.value);
    try std.testing.expect(!ddg_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, ddg_res.text, "DDG Hit") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddg_res.text, "https://example.org/ddg") != null);

    // 4. Brave JSON loopback search sends X-Subscription-Token and parses results.
    var brave_cfg: Config = .{ .backend = .brave, .brave_api_key = "brave-key", .endpoint_override = base_url, .allow_loopback = true };
    const brave_res = try executeWebSearch(&brave_cfg, ctx, parsed_args.value);
    try std.testing.expect(!brave_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, brave_res.text, "Brave Hit") != null);
    try std.testing.expect(std.mem.indexOf(u8, brave_res.text, "brave-key") == null);

    // 5. Auto zero-config default resolves to Exa MCP and parses SSE response.
    var exa_auto_cfg: Config = .{ .backend = .auto, .endpoint_override = base_url, .allow_loopback = true };
    const exa_res = try executeWebSearch(&exa_auto_cfg, ctx, parsed_args.value);
    try std.testing.expect(!exa_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, exa_res.text, "Search results (exa, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, exa_res.text, "Exa Hit") != null);
    try std.testing.expect(std.mem.indexOf(u8, exa_res.text, "https://example.org/exa") != null);
}
