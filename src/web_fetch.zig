//! Native `web_fetch` and `get_content` tools with SSRF protection, readable
//! HTML extraction, redirect validation, cancellation, and cached pagination.
const std = @import("std");
const agent = @import("agent");
const model = @import("model");

pub const max_urls_per_call: usize = 10;
pub const max_redirects: usize = 5;
pub const max_raw_body_bytes: usize = 2 * 1024 * 1024;
pub const max_preview_bytes: usize = 16 * 1024;
pub const max_get_limit_bytes: usize = 50 * 1024;
pub const max_stored_responses: usize = 16;
pub const max_store_total_bytes: usize = 16 * 1024 * 1024;
pub const default_timeout_sec: usize = 30;

pub const RedirectMode = enum { follow, same_origin };
pub const FetchMode = enum { readable, raw };
pub const FindMode = enum { exact, case_insensitive };

pub const PageRecord = struct {
    url: []u8,
    final_url: []u8,
    title: []u8,
    content: []u8,
    mime_type: []u8,
    status: u16,
    error_text: ?[]u8 = null,

    fn byteSize(self: *const PageRecord) usize {
        return self.url.len + self.final_url.len + self.title.len + self.content.len + self.mime_type.len +
            if (self.error_text) |e| e.len else 0;
    }

    fn deinit(self: *PageRecord, a: std.mem.Allocator) void {
        a.free(self.url);
        a.free(self.final_url);
        a.free(self.title);
        a.free(self.content);
        a.free(self.mime_type);
        if (self.error_text) |e| a.free(e);
    }
};

pub const ResponseEntry = struct {
    id: []u8,
    pages: []PageRecord,
    total_bytes: usize,

    fn deinit(self: *ResponseEntry, a: std.mem.Allocator) void {
        a.free(self.id);
        for (self.pages) |*p| p.deinit(a);
        a.free(self.pages);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    next_id: u64 = 1,
    entries: std.ArrayList(ResponseEntry) = .empty,
    total_bytes: usize = 0,
    allow_loopback: bool = false,

    pub fn init(allocator: std.mem.Allocator, allow_loopback: bool) Store {
        return .{
            .allocator = allocator,
            .allow_loopback = allow_loopback,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn putPages(self: *Store, io: std.Io, pages: []PageRecord) ![]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var entry_bytes: usize = 0;
        for (pages) |*p| entry_bytes += p.byteSize();

        while (self.entries.items.len >= max_stored_responses or
            (self.entries.items.len > 0 and self.total_bytes + entry_bytes > max_store_total_bytes))
        {
            var oldest = self.entries.orderedRemove(0);
            self.total_bytes -|= oldest.total_bytes;
            oldest.deinit(self.allocator);
        }

        const id = try std.fmt.allocPrint(self.allocator, "wf_{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        self.next_id += 1;

        try self.entries.append(self.allocator, .{
            .id = id,
            .pages = pages,
            .total_bytes = entry_bytes,
        });
        self.total_bytes += entry_bytes;
        return id;
    }

    pub fn queryContent(
        self: *Store,
        io: std.Io,
        out_alloc: std.mem.Allocator,
        response_id: []const u8,
        url_filter: ?[]const u8,
        url_index: ?usize,
        offset: usize,
        limit: usize,
        find_terms: []const []const u8,
        find_mode: FindMode,
    ) ![]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var found_entry: ?*const ResponseEntry = null;
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, response_id)) {
                found_entry = entry;
                break;
            }
        }
        const entry = found_entry orelse return error.ResponseNotFound;

        var selected: std.ArrayList(*const PageRecord) = .empty;
        defer selected.deinit(out_alloc);
        if (url_index) |idx| {
            if (idx >= entry.pages.len) return error.UrlIndexOutOfRange;
            try selected.append(out_alloc, &entry.pages[idx]);
        } else if (url_filter) |u| {
            for (entry.pages) |*p| {
                if (std.mem.eql(u8, p.url, u) or std.mem.eql(u8, p.final_url, u)) {
                    try selected.append(out_alloc, p);
                }
            }
            if (selected.items.len == 0) return error.UrlNotFoundInResponse;
        } else {
            for (entry.pages) |*p| try selected.append(out_alloc, p);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(out_alloc);

        if (find_terms.len > 0) {
            try formatSearchPassages(&out, out_alloc, selected.items, find_terms, find_mode, limit);
            return try out.toOwnedSlice(out_alloc);
        }

        const single = selected.items[0];
        if (single.error_text) |err_txt| {
            try out.print(out_alloc, "URL: {s}\nError: {s}\n", .{ single.url, err_txt });
            return try out.toOwnedSlice(out_alloc);
        }
        const body = single.content;
        const start = alignUtf8Forward(body, @min(offset, body.len));
        const end = alignUtf8Backward(body, @min(start +| limit, body.len));
        if (selected.items.len > 1) {
            try out.print(out_alloc, "[Showing page 1 of {d}; pass urlIndex=0..{d} for other pages]\n", .{ selected.items.len, selected.items.len - 1 });
        }
        try out.print(out_alloc, "URL: {s}", .{single.final_url});
        if (single.title.len > 0) try out.print(out_alloc, "\nTitle: {s}", .{single.title});
        try out.print(out_alloc, "\n\n{s}", .{body[start..end]});
        if (end < body.len) {
            try out.print(out_alloc, "\n\n[Showing bytes {d}-{d} of {d}. Use offset={d} to continue.]", .{ start, end, body.len, end });
        }
        return try out.toOwnedSlice(out_alloc);
    }
};

fn formatSearchPassages(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    pages: []const *const PageRecord,
    terms: []const []const u8,
    find_mode: FindMode,
    limit: usize,
) !void {
    const context_radius: usize = 160;
    var matches: usize = 0;
    for (pages, 0..) |page, pidx| {
        if (page.error_text != null or page.content.len == 0) continue;
        for (terms) |term| {
            if (term.len == 0) continue;
            var pos: usize = 0;
            while (pos < page.content.len and out.items.len < limit) {
                const hit = findMatch(page.content, pos, term, find_mode) orelse break;
                matches += 1;
                const s = alignUtf8Forward(page.content, hit -| context_radius);
                const e = alignUtf8Backward(page.content, @min(page.content.len, hit + term.len + context_radius));
                if (pages.len > 1) {
                    try out.print(a, "[page {d}: {s} @ {d}]\n", .{ pidx, page.final_url, hit });
                } else {
                    try out.print(a, "[match @ {d}]\n", .{hit});
                }
                try out.appendSlice(a, page.content[s..e]);
                try out.appendSlice(a, "\n---\n");
                pos = hit + @max(@as(usize, 1), term.len);
                if (matches >= 25) break;
            }
        }
    }
    if (matches == 0) {
        try out.appendSlice(a, "No matching passages found.");
    }
}

fn findMatch(haystack: []const u8, start: usize, needle: []const u8, mode: FindMode) ?usize {
    if (mode == .exact) return std.mem.indexOfPos(u8, haystack, start, needle);
    if (needle.len == 0 or start + needle.len > haystack.len) return null;
    var i: usize = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn executeWebFetch(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) !agent.ToolResult {
    const store: *Store = @ptrCast(@alignCast(context orelse return error.MissingStoreContext));
    try validateKeys(args, &.{ "url", "urls", "mode", "redirects", "timeout" });

    const mode: FetchMode = blk: {
        if (args.object.get("mode")) |v| {
            if (v != .string) return error.ExpectedString;
            if (std.mem.eql(u8, v.string, "readable")) break :blk .readable;
            if (std.mem.eql(u8, v.string, "raw")) break :blk .raw;
            return error.InvalidFetchMode;
        }
        break :blk .readable;
    };
    const redirect_mode: RedirectMode = blk: {
        if (args.object.get("redirects")) |v| {
            if (v != .string) return error.ExpectedString;
            if (std.mem.eql(u8, v.string, "follow")) break :blk .follow;
            if (std.mem.eql(u8, v.string, "same-origin")) break :blk .same_origin;
            return error.InvalidRedirectMode;
        }
        break :blk .follow;
    };
    const timeout_sec = try positiveInt(args, "timeout", default_timeout_sec, 120);

    var url_list: std.ArrayList([]const u8) = .empty;
    defer url_list.deinit(ctx.allocator);

    if (args.object.get("urls")) |v| {
        if (v != .array) return error.ExpectedArray;
        if (v.array.items.len == 0 or v.array.items.len > max_urls_per_call) return error.InvalidUrlCount;
        for (v.array.items) |item| {
            if (item != .string) return error.ExpectedString;
            const trimmed = std.mem.trim(u8, item.string, " \t\r\n");
            if (trimmed.len == 0) return error.InvalidUrl;
            try appendUniqueStr(&url_list, ctx.allocator, trimmed);
        }
    }
    if (url_list.items.len == 0) {
        const raw = args.object.get("url") orelse return error.MissingUrl;
        if (raw != .string) return error.ExpectedString;
        const trimmed = std.mem.trim(u8, raw.string, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidUrl;
        try url_list.append(ctx.allocator, trimmed);
    }

    const pages = try store.allocator.alloc(PageRecord, url_list.items.len);
    var built: usize = 0;
    errdefer {
        for (pages[0..built]) |*p| p.deinit(store.allocator);
        store.allocator.free(pages);
    }

    for (url_list.items) |raw_url| {
        if (ctx.cancel) |c| if (c.isCanceled()) return error.Canceled;
        pages[built] = try fetchSingleUrl(
            store.allocator,
            ctx.allocator,
            ctx.io,
            raw_url,
            mode,
            redirect_mode,
            timeout_sec,
            store.allow_loopback,
            ctx.cancel,
        );
        built += 1;
    }

    const pages_snapshot = try ctx.allocator.alloc(PageRecordView, pages.len);
    for (pages, pages_snapshot) |*p, *v| {
        v.* = .{
            .url = try ctx.allocator.dupe(u8, p.url),
            .final_url = try ctx.allocator.dupe(u8, p.final_url),
            .title = try ctx.allocator.dupe(u8, p.title),
            .content = try ctx.allocator.dupe(u8, p.content),
            .mime_type = try ctx.allocator.dupe(u8, p.mime_type),
            .status = p.status,
            .error_text = if (p.error_text) |e| try ctx.allocator.dupe(u8, e) else null,
        };
    }

    const response_id = try store.putPages(ctx.io, pages);
    const resp_id_copy = try ctx.allocator.dupe(u8, response_id);

    var out: std.ArrayList(u8) = .empty;
    try out.print(ctx.allocator, "responseId: {s}\n", .{resp_id_copy});
    var any_ok = false;
    for (pages_snapshot, 0..) |page, idx| {
        if (pages_snapshot.len > 1) try out.print(ctx.allocator, "\n--- [{d}] {s} ---\n", .{ idx, page.url });
        if (page.error_text) |err_txt| {
            try out.print(ctx.allocator, "Error ({s}): {s}\n", .{ page.url, err_txt });
            continue;
        }
        any_ok = true;
        try out.print(ctx.allocator, "URL: {s} (HTTP {d}, {s})\n", .{ page.final_url, page.status, page.mime_type });
        if (page.title.len > 0) try out.print(ctx.allocator, "Title: {s}\n", .{page.title});
        const preview_end = alignUtf8Backward(page.content, @min(max_preview_bytes, page.content.len));
        try out.appendSlice(ctx.allocator, "\n");
        try out.appendSlice(ctx.allocator, page.content[0..preview_end]);
        if (preview_end < page.content.len) {
            try out.print(
                ctx.allocator,
                "\n\n[Truncated at {d} of {d} bytes. Call get_content with responseId=\"{s}\"{s} offset={d} to continue.]",
                .{
                    preview_end,
                    page.content.len,
                    resp_id_copy,
                    if (pages_snapshot.len > 1) try std.fmt.allocPrint(ctx.allocator, " urlIndex={d}", .{idx}) else "",
                    preview_end,
                },
            );
        }
    }

    var details_urls = std.json.Array.init(ctx.allocator);
    for (pages_snapshot) |page| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(ctx.allocator, "url", .{ .string = page.url });
        try obj.put(ctx.allocator, "finalUrl", .{ .string = page.final_url });
        try obj.put(ctx.allocator, "title", .{ .string = page.title });
        try obj.put(ctx.allocator, "status", .{ .integer = @intCast(page.status) });
        if (page.error_text) |e| try obj.put(ctx.allocator, "error", .{ .string = e });
        try details_urls.append(.{ .object = obj });
    }
    var details: std.json.ObjectMap = .empty;
    try details.put(ctx.allocator, "responseId", .{ .string = resp_id_copy });
    try details.put(ctx.allocator, "urls", .{ .array = details_urls });

    return .{
        .text = try out.toOwnedSlice(ctx.allocator),
        .is_error = !any_ok,
        .details = .{ .object = details },
    };
}

const PageRecordView = struct {
    url: []const u8,
    final_url: []const u8,
    title: []const u8,
    content: []const u8,
    mime_type: []const u8,
    status: u16,
    error_text: ?[]const u8 = null,
};

pub fn executeGetContent(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) !agent.ToolResult {
    const store: *Store = @ptrCast(@alignCast(context orelse return error.MissingStoreContext));
    try validateKeys(args, &.{ "responseId", "url", "urlIndex", "offset", "limit", "findText", "findMode" });

    const rid_val = args.object.get("responseId") orelse return error.MissingResponseId;
    if (rid_val != .string or rid_val.string.len == 0) return error.InvalidResponseId;

    const url_filter: ?[]const u8 = if (args.object.get("url")) |v| blk: {
        if (v != .string or v.string.len == 0) return error.InvalidUrl;
        break :blk v.string;
    } else null;

    const url_index: ?usize = if (args.object.get("urlIndex")) |v| blk: {
        const n = switch (v) {
            .integer => v.integer,
            else => return error.ExpectedNonnegativeInteger,
        };
        if (n < 0 or n > std.math.maxInt(u32)) return error.ExpectedNonnegativeInteger;
        break :blk @intCast(n);
    } else null;

    const offset = try nonnegativeInt(args, "offset", 0, std.math.maxInt(u32));
    const limit = try positiveInt(args, "limit", max_preview_bytes, max_get_limit_bytes);

    const find_mode: FindMode = if (args.object.get("findMode")) |v| blk: {
        if (v != .string) return error.ExpectedString;
        if (std.mem.eql(u8, v.string, "exact")) break :blk .exact;
        if (std.mem.eql(u8, v.string, "case-insensitive")) break :blk .case_insensitive;
        return error.InvalidFindMode;
    } else .case_insensitive;

    var terms: std.ArrayList([]const u8) = .empty;
    defer terms.deinit(ctx.allocator);
    if (args.object.get("findText")) |v| {
        switch (v) {
            .string => |s| if (s.len > 0) try terms.append(ctx.allocator, s),
            .array => |arr| {
                if (arr.items.len > 10) return error.TooManySearchTerms;
                for (arr.items) |item| {
                    if (item != .string) return error.ExpectedString;
                    if (item.string.len > 0) try terms.append(ctx.allocator, item.string);
                }
            },
            else => return error.InvalidFindText,
        }
    }

    const text = store.queryContent(
        ctx.io,
        ctx.allocator,
        rid_val.string,
        url_filter,
        url_index,
        offset,
        limit,
        terms.items,
        find_mode,
    ) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(ctx.allocator, "get_content failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    return .{ .text = text };
}

fn fetchSingleUrl(
    store_alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    raw_url: []const u8,
    mode: FetchMode,
    redirect_mode: RedirectMode,
    timeout_sec: usize,
    allow_loopback: bool,
    cancel: ?model.Cancel,
) !PageRecord {
    const owned_url = try store_alloc.dupe(u8, raw_url);
    errdefer store_alloc.free(owned_url);

    const res = fetchWithRedirects(scratch, io, raw_url, mode, redirect_mode, timeout_sec, allow_loopback, cancel) catch |err| {
        const err_msg = try store_alloc.dupe(u8, @errorName(err));
        errdefer store_alloc.free(err_msg);
        return .{
            .url = owned_url,
            .final_url = try store_alloc.dupe(u8, raw_url),
            .title = try store_alloc.dupe(u8, ""),
            .content = try store_alloc.dupe(u8, ""),
            .mime_type = try store_alloc.dupe(u8, ""),
            .status = 0,
            .error_text = err_msg,
        };
    };
    const final_url = try store_alloc.dupe(u8, res.final_url);
    errdefer store_alloc.free(final_url);
    const title = try store_alloc.dupe(u8, res.title);
    errdefer store_alloc.free(title);
    const content = try store_alloc.dupe(u8, res.content);
    errdefer store_alloc.free(content);
    const mime_type = try store_alloc.dupe(u8, res.mime_type);
    errdefer store_alloc.free(mime_type);

    return .{
        .url = owned_url,
        .final_url = final_url,
        .title = title,
        .content = content,
        .mime_type = mime_type,
        .status = res.status,
    };
}

const FetchOutcome = struct {
    final_url: []const u8,
    title: []const u8,
    content: []const u8,
    mime_type: []const u8,
    status: u16,
};

fn fetchWithRedirects(
    a: std.mem.Allocator,
    io: std.Io,
    raw_url: []const u8,
    mode: FetchMode,
    redirect_mode: RedirectMode,
    timeout_sec: usize,
    allow_loopback: bool,
    cancel: ?model.Cancel,
) !FetchOutcome {
    if (std.mem.indexOfAny(u8, raw_url, "\x00\r\n") != null) return error.InvalidUrl;
    var current_url = try a.dupe(u8, raw_url);
    var current_uri = std.Uri.parse(current_url) catch return error.InvalidUrl;
    const initial_uri = current_uri;

    const deadline_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() + @as(i64, @intCast(timeout_sec)) * 1000;

    var hop: usize = 0;
    while (true) {
        if (cancel) |c| if (c.isCanceled()) return error.Canceled;
        const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now_ms >= deadline_ms) return error.Timeout;
        const remain_ms: u64 = @intCast(deadline_ms - now_ms);

        try validateUriBasics(current_uri);
        try validateUrlSsrf(io, current_uri, allow_loopback);

        var http: std.http.Client = .{ .allocator = a, .io = io };
        defer http.deinit();

        var req = try http.request(.GET, current_uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .user_agent = .{ .override = "zpi/0.1 (web_fetch)" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "text/html, application/xhtml+xml, text/markdown, text/plain, application/json;q=0.9, */*;q=0.5" },
            },
        });
        defer req.deinit();

        if (req.connection) |conn| {
            try verifyConnectedPeerSsrf(conn.stream_reader.stream, allow_loopback);
        }

        var cancel_sock = model.CancelSocket{};
        if (req.connection) |conn| cancel_sock.set(io, conn.stream_reader.stream);
        defer cancel_sock.clear(io);

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
        var watchdog = Watchdog{
            .io = io,
            .cancel = cancel,
            .cs = &cancel_sock,
            .done = &done,
            .deadline_ms = deadline_ms,
        };
        const wt = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
        defer {
            done.store(true, .release);
            wt.join();
        }
        _ = remain_ms;

        req.sendBodiless() catch |err| {
            if (cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            return err;
        };

        var head_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&head_buf) catch |err| {
            if (cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            return err;
        };

        const status: u16 = @backingInt(response.head.status);
        if (isRedirectStatus(status)) {
            if (hop >= max_redirects) return error.TooManyRedirects;
            const loc = response.head.location orelse return error.MissingRedirectLocation;
            if (loc.len == 0 or loc.len > 4096) return error.InvalidRedirectLocation;
            var resolve_buf: [8192]u8 = undefined;
            @memcpy(resolve_buf[0..loc.len], loc);
            var aux: []u8 = &resolve_buf;
            const resolved = current_uri.resolveInPlace(loc.len, &aux) catch return error.InvalidRedirectLocation;
            const next_url = try std.fmt.allocPrint(a, "{f}", .{resolved});
            const next_uri = std.Uri.parse(next_url) catch return error.InvalidRedirectLocation;
            try validateUriBasics(next_uri);
            if (redirect_mode == .same_origin and !sameOrigin(initial_uri, next_uri)) {
                return error.CrossOriginRedirectBlocked;
            }
            try validateUrlSsrf(io, next_uri, allow_loopback);
            current_url = next_url;
            current_uri = next_uri;
            hop += 1;
            continue;
        }

        if (status < 200 or status >= 400) return error.HttpStatusError;
        if (response.head.content_encoding != .identity) return error.UnsupportedContentEncoding;

        const mime_raw = response.head.content_type orelse "text/plain";
        const mime_semi = std.mem.indexOfScalar(u8, mime_raw, ';') orelse mime_raw.len;
        const mime_type = std.mem.trim(u8, mime_raw[0..mime_semi], " \t");

        var transfer_buf: [8192]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        var raw_body: std.ArrayList(u8) = .empty;
        var chunk: [4096]u8 = undefined;
        while (raw_body.items.len < max_raw_body_bytes) {
            if (cancel) |c| if (c.isCanceled()) return error.Canceled;
            if (watchdog.timed_out.load(.acquire)) return error.Timeout;
            const buffered = body_reader.buffered();
            if (buffered.len > 0) {
                const take = @min(buffered.len, max_raw_body_bytes - raw_body.items.len);
                try raw_body.appendSlice(a, buffered[0..take]);
                body_reader.toss(take);
                continue;
            }
            var vectors = [_][]u8{&chunk};
            const count = body_reader.readVec(&vectors) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    if (cancel) |c| if (c.isCanceled()) return error.Canceled;
                    if (watchdog.timed_out.load(.acquire)) return error.Timeout;
                    return error.ResponseReadFailed;
                },
            };
            if (count > 0) {
                const take = @min(count, max_raw_body_bytes - raw_body.items.len);
                try raw_body.appendSlice(a, chunk[0..take]);
            }
        }
        if (cancel) |c| if (c.isCanceled()) return error.Canceled;
        if (watchdog.timed_out.load(.acquire)) return error.Timeout;

        const is_html = isHtmlMime(mime_type, raw_body.items);
        if (mode == .readable and is_html) {
            const extracted = try extractReadableHtml(a, raw_body.items);
            return .{
                .final_url = current_url,
                .title = extracted.title,
                .content = extracted.content,
                .mime_type = try a.dupe(u8, mime_type),
                .status = status,
            };
        }
        const safe = try sanitizeUtf8Lossy(a, raw_body.items);
        return .{
            .final_url = current_url,
            .title = "",
            .content = safe,
            .mime_type = try a.dupe(u8, mime_type),
            .status = status,
        };
    }
}

fn validateUriBasics(uri: std.Uri) !void {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.UnsupportedUrlScheme;
    }
    if (uri.user != null or uri.password != null) return error.EmbeddedCredentialsRejected;
    if (uri.host == null) return error.InvalidUrl;
}

fn sameOrigin(a_uri: std.Uri, b_uri: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a_uri.scheme, b_uri.scheme)) return false;
    var abuf: [std.Io.net.HostName.max_len]u8 = undefined;
    var bbuf: [std.Io.net.HostName.max_len]u8 = undefined;
    const ha = std.Io.net.HostName.fromUri(a_uri, &abuf) catch return false;
    const hb = std.Io.net.HostName.fromUri(b_uri, &bbuf) catch return false;
    if (!std.ascii.eqlIgnoreCase(ha.bytes, hb.bytes)) return false;
    const pa: u16 = a_uri.port orelse if (std.ascii.eqlIgnoreCase(a_uri.scheme, "https")) @as(u16, 443) else 80;
    const pb: u16 = b_uri.port orelse if (std.ascii.eqlIgnoreCase(b_uri.scheme, "https")) @as(u16, 443) else 80;
    return pa == pb;
}

fn isRedirectStatus(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

pub fn validateUrlSsrf(io: std.Io, uri: std.Uri, allow_loopback: bool) !void {
    const host_comp = uri.host orelse return error.InvalidUrl;
    var raw_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const raw_host = host_comp.toRaw(&raw_buf) catch return error.InvalidUrl;
    const trimmed = trimBrackets(std.mem.trimEnd(u8, raw_host, "."));
    if (trimmed.len == 0) return error.InvalidUrl;

    if (isBlockedHostname(trimmed, allow_loopback)) return error.SsrfBlocked;

    const port: u16 = uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
    if (std.Io.net.IpAddress.parse(trimmed, port)) |literal_ip| {
        if (!isAllowedIp(literal_ip, allow_loopback)) return error.SsrfBlocked;
        return;
    } else |_| {}

    const host_name = std.Io.net.HostName.fromUri(uri, &raw_buf) catch return error.InvalidUrl;
    var res_buf: [32]std.Io.net.HostName.LookupResult = undefined;
    var resolved = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&res_buf);
    host_name.lookup(io, &resolved, .{ .port = port }) catch return error.DnsLookupFailed;

    var saw_any = false;
    while (resolved.getOne(io)) |item| {
        switch (item) {
            .address => |addr| {
                saw_any = true;
                if (!isAllowedIp(addr, allow_loopback)) return error.SsrfBlocked;
            },
            .canonical_name => {},
        }
    } else |_| {}
    if (!saw_any) return error.SsrfBlocked;
}

fn verifyConnectedPeerSsrf(stream: std.Io.net.Stream, allow_loopback: bool) !void {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(stream.socket.handle, @ptrCast(&storage), &len) catch return error.SsrfBlocked;
    switch (storage.family) {
        std.posix.AF.INET => {
            const in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&storage));
            const bytes: *const [4]u8 = @ptrCast(&in.addr);
            if (!isAllowedIp4(bytes.*, allow_loopback)) return error.SsrfBlocked;
        },
        std.posix.AF.INET6 => {
            const in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
            if (!isAllowedIp6(in6.addr, allow_loopback)) return error.SsrfBlocked;
        },
        else => return error.SsrfBlocked,
    }
}

fn trimBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

pub fn isBlockedHostname(raw: []const u8, allow_loopback: bool) bool {
    const host = trimBrackets(std.mem.trimEnd(u8, raw, "."));
    if (host.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(host, "localhost") or endsWithIgnoreCase(host, ".localhost")) {
        return !allow_loopback;
    }
    if (endsWithIgnoreCase(host, ".local") or
        endsWithIgnoreCase(host, ".internal") or
        endsWithIgnoreCase(host, ".arpa") or
        std.ascii.eqlIgnoreCase(host, "metadata") or
        std.ascii.eqlIgnoreCase(host, "metadata.google.internal"))
    {
        return true;
    }
    return false;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

pub fn isAllowedIp(addr: std.Io.net.IpAddress, allow_loopback: bool) bool {
    return switch (addr) {
        .ip4 => |v4| isAllowedIp4(v4.bytes, allow_loopback),
        .ip6 => |v6| isAllowedIp6(v6.bytes, allow_loopback),
    };
}

pub fn isAllowedIp4(b: [4]u8, allow_loopback: bool) bool {
    if (b[0] == 127) return allow_loopback;
    if (b[0] == 0) return false; // 0.0.0.0/8
    if (b[0] == 10) return false; // 10.0.0.0/8
    if (b[0] == 100 and (b[1] & 0xc0) == 64) return false; // 100.64.0.0/10 CGNAT
    if (b[0] == 169 and b[1] == 254) return false; // 169.254.0.0/16 link-local & cloud metadata
    if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return false; // 172.16.0.0/12
    if (b[0] == 192 and b[1] == 0 and b[2] == 0) return false; // 192.0.0.0/24
    if (b[0] == 192 and b[1] == 0 and b[2] == 2) return false; // 192.0.2.0/24 TEST-NET-1
    if (b[0] == 192 and b[1] == 168) return false; // 192.168.0.0/16
    if (b[0] == 198 and (b[1] == 18 or b[1] == 19)) return false; // 198.18.0.0/15
    if (b[0] == 198 and b[1] == 51 and b[2] == 100) return false; // 198.51.100.0/24 TEST-NET-2
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return false; // 203.0.113.0/24 TEST-NET-3
    if (b[0] >= 224) return false; // multicast & reserved & 255.255.255.255
    return true;
}

pub fn isAllowedIp6(b: [16]u8, allow_loopback: bool) bool {
    const all_zero_prefix = std.mem.allEqual(u8, b[0..15], 0);
    if (all_zero_prefix and b[15] == 0) return false; // ::
    if (all_zero_prefix and b[15] == 1) return allow_loopback; // ::1
    if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) {
        return isAllowedIp4(b[12..16].*, allow_loopback); // ::ffff:0:0/96
    }
    if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7 ULA
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return false; // fe80::/10 link-local
    if (b[0] == 0xff) return false; // ff00::/8 multicast
    if (b[0] == 0x01 and b[1] == 0x00 and std.mem.allEqual(u8, b[2..8], 0)) return false; // 100::/64 discard
    return true;
}

fn isHtmlMime(mime: []const u8, body: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(mime, "text/html") or std.ascii.eqlIgnoreCase(mime, "application/xhtml+xml")) return true;
    const probe = std.mem.trimStart(u8, body[0..@min(body.len, 256)], " \t\r\n");
    return startsWithIgnoreCase(probe, "<!doctype html") or startsWithIgnoreCase(probe, "<html");
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

const ExtractedHtml = struct {
    title: []const u8,
    content: []const u8,
};

pub fn extractReadableHtml(a: std.mem.Allocator, html: []const u8) !ExtractedHtml {
    var title_buf: std.ArrayList(u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var skip_tag: ?[]const u8 = null;
    var in_title = false;
    var in_pre = false;
    var last_space = true;
    var newline_run: usize = 2;

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            if (i + 4 <= html.len and std.mem.eql(u8, html[i .. i + 4], "<!--")) {
                const close = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
                i = if (close < html.len) close + 3 else html.len;
                continue;
            }
            const gt = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            const raw_tag = std.mem.trim(u8, html[i + 1 .. gt], " \t\r\n");
            i = gt + 1;
            if (raw_tag.len == 0) continue;

            const is_close = raw_tag[0] == '/';
            const after_slash = if (is_close) std.mem.trimStart(u8, raw_tag[1..], " \t") else raw_tag;
            var name_end: usize = 0;
            while (name_end < after_slash.len and !std.ascii.isWhitespace(after_slash[name_end]) and after_slash[name_end] != '/') : (name_end += 1) {}
            const tag = after_slash[0..name_end];

            if (skip_tag) |sk| {
                if (is_close and std.ascii.eqlIgnoreCase(tag, sk)) skip_tag = null;
                continue;
            }

            if (!is_close and (std.ascii.eqlIgnoreCase(tag, "script") or
                std.ascii.eqlIgnoreCase(tag, "style") or
                std.ascii.eqlIgnoreCase(tag, "noscript") or
                std.ascii.eqlIgnoreCase(tag, "svg") or
                std.ascii.eqlIgnoreCase(tag, "template")))
            {
                if (raw_tag[raw_tag.len - 1] != '/') skip_tag = tag;
                continue;
            }

            if (std.ascii.eqlIgnoreCase(tag, "title")) {
                in_title = !is_close;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(tag, "pre")) {
                in_pre = !is_close;
                try pushNewlines(&out, a, &newline_run, &last_space, 2);
                try out.appendSlice(a, "```\n");
                continue;
            }
            if (!is_close) {
                if (isHeadingTag(tag)) |level| {
                    try pushNewlines(&out, a, &newline_run, &last_space, 2);
                    try out.appendNTimes(a, '#', level);
                    try out.append(a, ' ');
                    last_space = true;
                    newline_run = 0;
                    continue;
                }
            }
            if (!is_close and std.ascii.eqlIgnoreCase(tag, "li")) {
                try pushNewlines(&out, a, &newline_run, &last_space, 1);
                try out.appendSlice(a, "- ");
                last_space = true;
                newline_run = 0;
                continue;
            }
            if (!is_close and std.ascii.eqlIgnoreCase(tag, "blockquote")) {
                try pushNewlines(&out, a, &newline_run, &last_space, 2);
                try out.appendSlice(a, "> ");
                last_space = true;
                newline_run = 0;
                continue;
            }
            if (isBlockBreakTag(tag)) {
                const count: usize = if (std.ascii.eqlIgnoreCase(tag, "br") or std.ascii.eqlIgnoreCase(tag, "tr") or std.ascii.eqlIgnoreCase(tag, "li")) 1 else 2;
                try pushNewlines(&out, a, &newline_run, &last_space, count);
            }
            continue;
        }

        if (skip_tag != null) {
            i += 1;
            continue;
        }

        if (html[i] == '&') {
            if (decodeHtmlEntity(html[i..])) |decoded| {
                if (in_title) {
                    try title_buf.appendSlice(a, decoded.bytes());
                } else {
                    try appendTextChar(&out, a, decoded.bytes(), &last_space, &newline_run, in_pre);
                }
                i += decoded.consumed;
                continue;
            }
        }

        const step = std.unicode.utf8ByteSequenceLength(html[i]) catch 1;
        const end = @min(i + step, html.len);
        const slice = html[i..end];
        if (in_title) {
            if (slice.len == 1 and std.ascii.isWhitespace(slice[0])) {
                if (title_buf.items.len > 0 and title_buf.items[title_buf.items.len - 1] != ' ') {
                    try title_buf.append(a, ' ');
                }
            } else if (std.unicode.utf8ValidateSlice(slice)) {
                try title_buf.appendSlice(a, slice);
            }
        } else {
            if (std.unicode.utf8ValidateSlice(slice)) {
                try appendTextChar(&out, a, slice, &last_space, &newline_run, in_pre);
            }
        }
        i = end;
    }

    const trimmed_title = std.mem.trim(u8, title_buf.items, " \t\r\n");
    const trimmed_body = std.mem.trim(u8, out.items, " \t\r\n");
    return .{
        .title = try a.dupe(u8, trimmed_title),
        .content = try a.dupe(u8, trimmed_body),
    };
}

fn isHeadingTag(tag: []const u8) ?usize {
    if (tag.len == 2 and (tag[0] == 'h' or tag[0] == 'H') and tag[1] >= '1' and tag[1] <= '6') {
        return tag[1] - '0';
    }
    return null;
}

fn isBlockBreakTag(tag: []const u8) bool {
    const blocks = [_][]const u8{ "p", "div", "section", "article", "header", "footer", "main", "nav", "aside", "br", "hr", "tr", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li" };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(tag, b)) return true;
    return false;
}

fn pushNewlines(out: *std.ArrayList(u8), a: std.mem.Allocator, newline_run: *usize, last_space: *bool, target: usize) !void {
    while (newline_run.* < target) {
        if (out.items.len == 0) {
            newline_run.* = target;
            break;
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            out.items.len -= 1;
        }
        try out.append(a, '\n');
        newline_run.* += 1;
        last_space.* = true;
    }
}

fn appendTextChar(out: *std.ArrayList(u8), a: std.mem.Allocator, slice: []const u8, last_space: *bool, newline_run: *usize, in_pre: bool) !void {
    if (slice.len == 1 and (slice[0] == ' ' or slice[0] == '\t' or slice[0] == '\r' or slice[0] == '\n')) {
        if (in_pre) {
            try out.append(a, if (slice[0] == '\r') '\n' else slice[0]);
            newline_run.* = if (slice[0] == '\n') newline_run.* + 1 else 0;
            last_space.* = true;
            return;
        }
        if (!last_space.*) {
            try out.append(a, ' ');
            last_space.* = true;
        }
        return;
    }
    if (slice.len == 1 and slice[0] < 0x20) return;
    try out.appendSlice(a, slice);
    last_space.* = false;
    newline_run.* = 0;
}

const DecodedEntity = struct {
    buf: [4]u8 = undefined,
    len: usize = 0,
    consumed: usize = 0,
    fn bytes(self: *const DecodedEntity) []const u8 {
        return self.buf[0..self.len];
    }
};

fn decodeHtmlEntity(slice: []const u8) ?DecodedEntity {
    if (slice.len < 3 or slice[0] != '&') return null;
    const semi = std.mem.indexOfScalarPos(u8, slice[0..@min(slice.len, 16)], 1, ';') orelse return null;
    const body = slice[1..semi];
    var res = DecodedEntity{ .consumed = semi + 1 };
    if (std.mem.eql(u8, body, "amp")) {
        res.buf[0] = '&';
        res.len = 1;
        return res;
    } else if (std.mem.eql(u8, body, "lt")) {
        res.buf[0] = '<';
        res.len = 1;
        return res;
    } else if (std.mem.eql(u8, body, "gt")) {
        res.buf[0] = '>';
        res.len = 1;
        return res;
    } else if (std.mem.eql(u8, body, "quot")) {
        res.buf[0] = '"';
        res.len = 1;
        return res;
    } else if (std.mem.eql(u8, body, "apos") or std.mem.eql(u8, body, "#39")) {
        res.buf[0] = '\'';
        res.len = 1;
        return res;
    } else if (std.mem.eql(u8, body, "nbsp")) {
        res.buf[0] = ' ';
        res.len = 1;
        return res;
    } else if (body.len >= 2 and body[0] == '#') {
        const cp: u21 = if (body[1] == 'x' or body[1] == 'X')
            std.fmt.parseInt(u21, body[2..], 16) catch return null
        else
            std.fmt.parseInt(u21, body[1..], 10) catch return null;
        if (!std.unicode.utf8ValidCodepoint(cp) or cp < 0x20) return null;
        res.len = std.unicode.utf8Encode(cp, &res.buf) catch return null;
        return res;
    }
    return null;
}

fn sanitizeUtf8Lossy(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            try out.append(a, '?');
            i += 1;
            continue;
        };
        if (i + len <= raw.len and std.unicode.utf8ValidateSlice(raw[i .. i + len])) {
            try out.appendSlice(a, raw[i .. i + len]);
            i += len;
        } else {
            try out.append(a, '?');
            i += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

fn alignUtf8Forward(text: []const u8, pos: usize) usize {
    var p = @min(pos, text.len);
    while (p < text.len and (text[p] & 0xc0) == 0x80) : (p += 1) {}
    return p;
}

fn alignUtf8Backward(text: []const u8, pos: usize) usize {
    var p = @min(pos, text.len);
    while (p > 0 and p < text.len and (text[p] & 0xc0) == 0x80) : (p -= 1) {}
    return p;
}

fn validateKeys(args: std.json.Value, allowed: []const []const u8) !void {
    if (args != .object) return error.ExpectedObject;
    for (args.object.keys()) |k| {
        var ok = false;
        for (allowed) |ak| if (std.mem.eql(u8, k, ak)) {
            ok = true;
            break;
        };
        if (!ok) return error.UnknownArgument;
    }
}

fn nonnegativeInt(args: std.json.Value, key: []const u8, fallback: usize, max_val: usize) !usize {
    const val = args.object.get(key) orelse return fallback;
    const n = switch (val) {
        .integer => val.integer,
        else => return error.ExpectedNonnegativeInteger,
    };
    if (n < 0 or n > max_val) return error.OutOfRange;
    return @intCast(n);
}

fn positiveInt(args: std.json.Value, key: []const u8, fallback: usize, max_val: usize) !usize {
    const val = args.object.get(key) orelse return fallback;
    const n = switch (val) {
        .integer => val.integer,
        else => return error.ExpectedPositiveInteger,
    };
    if (n <= 0 or n > max_val) return error.OutOfRange;
    return @intCast(n);
}

fn appendUniqueStr(list: *std.ArrayList([]const u8), a: std.mem.Allocator, value: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(a, value);
}

test "SSRF blocks private, loopback, metadata, local hostnames, and embedded creds" {
    try std.testing.expect(!isAllowedIp4(.{ 127, 0, 0, 1 }, false));
    try std.testing.expect(isAllowedIp4(.{ 127, 0, 0, 1 }, true));
    try std.testing.expect(!isAllowedIp4(.{ 10, 0, 0, 1 }, false));
    try std.testing.expect(!isAllowedIp4(.{ 172, 16, 5, 4 }, false));
    try std.testing.expect(!isAllowedIp4(.{ 192, 168, 1, 10 }, false));
    try std.testing.expect(!isAllowedIp4(.{ 169, 254, 169, 254 }, false));
    try std.testing.expect(!isAllowedIp4(.{ 100, 64, 0, 1 }, false));
    try std.testing.expect(!isAllowedIp4(.{ 0, 0, 0, 0 }, false));
    try std.testing.expect(isAllowedIp4(.{ 93, 184, 216, 34 }, false));

    var loopback6: [16]u8 = @splat(0);
    loopback6[15] = 1;
    try std.testing.expect(!isAllowedIp6(loopback6, false));
    try std.testing.expect(isAllowedIp6(loopback6, true));
    var link_local6: [16]u8 = @splat(0);
    link_local6[0] = 0xfe;
    link_local6[1] = 0x80;
    try std.testing.expect(!isAllowedIp6(link_local6, false));
    var ula6: [16]u8 = @splat(0);
    ula6[0] = 0xfc;
    try std.testing.expect(!isAllowedIp6(ula6, false));
    try std.testing.expect(!isAllowedIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 }, false));

    try std.testing.expect(isBlockedHostname("localhost", false));
    try std.testing.expect(!isBlockedHostname("localhost", true));
    try std.testing.expect(isBlockedHostname("metadata.google.internal", false));
    try std.testing.expect(isBlockedHostname("printer.local", true));

    const uri_loop = try std.Uri.parse("http://127.0.0.1:8080/test");
    try std.testing.expectError(error.SsrfBlocked, validateUrlSsrf(std.testing.io, uri_loop, false));
    try validateUrlSsrf(std.testing.io, uri_loop, true);
}

test "extractReadableHtml strips scripts, converts headings/lists, and decodes entities" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const html =
        \\<html><head><title>Doc &amp; Guide</title><style>body{color:red}</style></head>
        \\<body><script>alert(1)</script><h1>Hello &lt;World&gt;</h1>
        \\<p>First   paragraph.</p><ul><li>Item 1</li><li>Item 2&#33;</li></ul></body></html>
    ;
    const ext = try extractReadableHtml(arena.allocator(), html);
    try std.testing.expectEqualStrings("Doc & Guide", ext.title);
    try std.testing.expect(std.mem.indexOf(u8, ext.content, "alert") == null);
    try std.testing.expect(std.mem.indexOf(u8, ext.content, "color:red") == null);
    try std.testing.expect(std.mem.indexOf(u8, ext.content, "# Hello <World>") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext.content, "First paragraph.") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext.content, "- Item 1\n- Item 2!") != null);
}

test "web_fetch and get_content handle loopback HTTP, redirects, SSRF, pagination, and cancellation" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = try listen_addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    const port = srv.socket.address.getPort();

    const ServerState = struct {
        srv: *std.Io.net.Server,
        io: std.Io,
        port: u16,
        fn serve(self: *@This()) void {
            var count: usize = 0;
            while (count < 5) : (count += 1) {
                var stream = self.srv.accept(self.io) catch return;
                defer stream.close(self.io);
                var rbuf: [4096]u8 = undefined;
                var reader = stream.reader(self.io, &rbuf);
                var req_buf: [2048]u8 = undefined;
                var got: usize = 0;
                while (got < req_buf.len) {
                    const buffered = reader.interface.buffered();
                    if (buffered.len > 0) {
                        const n = @min(buffered.len, req_buf.len - got);
                        @memcpy(req_buf[got .. got + n], buffered[0..n]);
                        reader.interface.toss(n);
                        got += n;
                        if (std.mem.indexOf(u8, req_buf[0..got], "\r\n\r\n") != null) break;
                        continue;
                    }
                    var v = [_][]u8{req_buf[got..]};
                    const n = reader.interface.readVec(&v) catch break;
                    if (n == 0) break;
                    got += n;
                    if (std.mem.indexOf(u8, req_buf[0..got], "\r\n\r\n") != null) break;
                }
                const req_text = req_buf[0..got];
                var wbuf: [4096]u8 = undefined;
                var writer = stream.writer(self.io, &wbuf);
                if (std.mem.indexOf(u8, req_text, "GET /redir-private ") != null) {
                    writer.interface.writeAll("HTTP/1.1 302 Found\r\nLocation: http://10.0.0.1/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                } else if (std.mem.indexOf(u8, req_text, "GET /redir-ok ") != null) {
                    writer.interface.writeAll("HTTP/1.1 302 Found\r\nLocation: /page\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                } else if (std.mem.indexOf(u8, req_text, "GET /slow ") != null) {
                    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 100\r\nConnection: close\r\n\r\npart1") catch {};
                    writer.interface.flush() catch {};
                    self.io.sleep(.fromMilliseconds(400), .awake) catch {};
                } else {
                    const body = "<html><head><title>Zpi Page</title></head><body><h1>Section Alpha</h1><p>needle_marker_here and more text.</p></body></html>";
                    writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch {};
                }
                writer.interface.flush() catch {};
            }
        }
    };

    var st = ServerState{ .srv = &srv, .io = io, .port = port };
    const th = try std.Thread.spawn(.{}, ServerState.serve, .{&st});
    defer th.join();

    // 1. Default store blocks loopback SSRF.
    var blocked_store = Store.init(a, false);
    defer blocked_store.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ctx = agent.ToolContext{ .allocator = arena.allocator(), .io = io, .cwd = "." };

    const loop_url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/page", .{port});
    const args1 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"url\":\"{s}\"}}", .{loop_url}), .{});
    const res1 = try executeWebFetch(&blocked_store, ctx, args1.value);
    try std.testing.expect(res1.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res1.text, "SsrfBlocked") != null);

    // 2. Loopback-enabled test store follows same-origin redirect, caches page, paginates & searches.
    var test_store = Store.init(a, true);
    defer test_store.deinit();
    const redir_ok = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/redir-ok", .{port});
    const args2 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"url\":\"{s}\"}}", .{redir_ok}), .{});
    const res2 = try executeWebFetch(&test_store, ctx, args2.value);
    try std.testing.expect(!res2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res2.text, "Zpi Page") != null);
    try std.testing.expect(std.mem.indexOf(u8, res2.text, "needle_marker_here") != null);
    const rid = res2.details.?.object.get("responseId").?.string;

    const get_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"responseId\":\"{s}\",\"findText\":\"NEEDLE_MARKER_HERE\"}}", .{rid}), .{});
    const get_res = try executeGetContent(&test_store, ctx, get_args.value);
    try std.testing.expect(!get_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, get_res.text, "needle_marker_here") != null);

    const page_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"responseId\":\"{s}\",\"offset\":2,\"limit\":10}}", .{rid}), .{});
    const page_res = try executeGetContent(&test_store, ctx, page_args.value);
    try std.testing.expect(std.mem.indexOf(u8, page_res.text, "Showing bytes 2-") != null);

    // 3. Redirect to private 10.0.0.1 is blocked even when loopback is enabled.
    const redir_priv = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/redir-private", .{port});
    const args3 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"url\":\"{s}\"}}", .{redir_priv}), .{});
    const res3 = try executeWebFetch(&test_store, ctx, args3.value);
    try std.testing.expect(res3.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res3.text, "SsrfBlocked") != null);

    // 4. Raw mode returns raw HTML without stripping tags.
    const raw_url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/page", .{port});
    const args4 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"url\":\"{s}\",\"mode\":\"raw\"}}", .{raw_url}), .{});
    const res4 = try executeWebFetch(&test_store, ctx, args4.value);
    try std.testing.expect(!res4.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res4.text, "<html><head>") != null);

    // 5. Cancellation aborts stalled slow fetch.
    var intr = try model.Interrupt.init();
    defer intr.deinit(io);
    const CancelThread = struct {
        i: *model.Interrupt,
        io: std.Io,
        fn run(self: *@This()) void {
            self.io.sleep(.fromMilliseconds(40), .awake) catch {};
            self.i.trigger();
        }
    };
    var ct = CancelThread{ .i = &intr, .io = io };
    const cth = try std.Thread.spawn(.{}, CancelThread.run, .{&ct});
    defer cth.join();
    const slow_url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/slow", .{port});
    const args5 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"url\":\"{s}\"}}", .{slow_url}), .{});
    const cancel_ctx = agent.ToolContext{ .allocator = arena.allocator(), .io = io, .cwd = ".", .cancel = intr.cancel() };
    const res5 = try executeWebFetch(&test_store, cancel_ctx, args5.value);
    try std.testing.expect(res5.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res5.text, "Canceled") != null);
}
