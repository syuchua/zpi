//! MVP tools use the process user's OS permissions. cwd is a default path,
//! not a sandbox. Calls are serialized by the agent; no hidden approval UI.
const std = @import("std");
const agent = @import("agent");
const replacements = @import("replacements");
const search = @import("search");
const web_fetch = @import("web_fetch");
const web_search = @import("web_search");
const bg_tasks = @import("bg_tasks");
const sandbox_mod = @import("sandbox");

pub const Options = struct {
    temp_dir: []const u8 = "/tmp",
    allow_loopback_web_fetch: bool = false,
    web_search_config: web_search.Config = .{},
    io: ?std.Io = null,
    cwd: []const u8 = ".",
    sandbox: sandbox_mod.Config = .{},
};

pub const ToolSet = struct {
    arena: std.heap.ArenaAllocator,
    tools: []agent.Tool,
    temp_dir: []const u8,
    web_fetch_store: *web_fetch.Store,
    web_search_config: web_search.Config = .{},
    bg_manager: ?*bg_tasks.Manager = null,

    pub fn init(allocator: std.mem.Allocator) !ToolSet {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithTempDir(allocator: std.mem.Allocator, temp_dir: []const u8) !ToolSet {
        return initWithOptions(allocator, .{ .temp_dir = temp_dir });
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, opts: Options) !ToolSet {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_temp = try a.dupe(u8, if (opts.temp_dir.len > 0) opts.temp_dir else "/tmp");
        const runtime_ctx: *RuntimeContext = try a.create(RuntimeContext);
        runtime_ctx.* = .{ .temp_dir = owned_temp, .sandbox = opts.sandbox };

        const wf_store = try allocator.create(web_fetch.Store);
        errdefer allocator.destroy(wf_store);
        wf_store.* = web_fetch.Store.init(allocator, opts.allow_loopback_web_fetch);
        errdefer wf_store.deinit();

        const ws_cfg: *web_search.Config = try a.create(web_search.Config);
        ws_cfg.* = opts.web_search_config;
        if (opts.allow_loopback_web_fetch) ws_cfg.allow_loopback = true;

        const bg_mgr: ?*bg_tasks.Manager = if (opts.io) |io| try bg_tasks.Manager.initWithSandbox(allocator, io, opts.cwd, opts.sandbox) else null;
        errdefer if (bg_mgr) |mgr| mgr.deinit();

        const tool_count: usize = if (bg_mgr != null) 14 else 10;
        const definitions = try a.alloc(agent.Tool, tool_count);
        definitions[0] = try definition(a, "read", "Read a text file. Output is truncated to 2000 lines or 50 KiB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to read (relative or absolute)\"},\"offset\":{\"type\":\"integer\",\"minimum\":1,\"description\":\"Line number to start reading from (1-indexed)\"},\"limit\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"Maximum number of lines to read\"}},\"required\":[\"path\"],\"additionalProperties\":false}", runtime_ctx, read);
        definitions[1] = try definition(a, "write", "Create or overwrite a text file, creating parent directories.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}", runtime_ctx, write);
        definitions[2] = try definition(a, "edit", "Make precise unique exact replacements. All edits match the original file; overlapping edits, duplicates and no-ops are rejected.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"},\"edits\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"}},\"required\":[\"oldText\",\"newText\"],\"additionalProperties\":false},\"minItems\":1,\"maxItems\":1024}},\"required\":[\"path\"],\"additionalProperties\":false}", runtime_ctx, edit);
        definitions[3] = try definition(a, "bash", "Execute a shell command in the project directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optional timeout in seconds (default 60, maximum 3600).", "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"timeout\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":3600}},\"required\":[\"command\"],\"additionalProperties\":false}", runtime_ctx, bash);
        definitions[4] = try definition(a, "grep", "Search with installed ripgrep, respecting gitignore. Returns paths and line numbers; bounded to 50 KiB and an optional match limit.", "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"glob\":{\"type\":\"string\"},\"ignoreCase\":{\"type\":\"boolean\"},\"literal\":{\"type\":\"boolean\"},\"context\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":10000},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100000}},\"required\":[\"pattern\"],\"additionalProperties\":false}", runtime_ctx, grep);
        definitions[5] = try definition(a, "find", "Find paths with installed fd/fdfind using glob patterns and gitignore rules. Results are relative to the search directory.", "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100000}},\"required\":[\"pattern\"],\"additionalProperties\":false}", runtime_ctx, find);
        definitions[6] = try definition(a, "ls", "List directory entries including dotfiles, sorted by ASCII case-insensitive name; directory names end with a slash.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100000}},\"additionalProperties\":false}", runtime_ctx, ls);
        definitions[7] = try definition(a, "web_fetch", "Fetch public HTTP(S) web pages with SSRF protection, returning readable text/markdown or raw content plus a cached responseId for pagination via get_content.", "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"Public http(s) URL to fetch\"},\"urls\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"maxItems\":10},\"mode\":{\"type\":\"string\",\"enum\":[\"readable\",\"raw\"]},\"redirects\":{\"type\":\"string\",\"enum\":[\"follow\",\"same-origin\"]},\"timeout\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":120}},\"additionalProperties\":false}", wf_store, web_fetch.executeWebFetch);
        definitions[8] = try definition(a, "get_content", "Page through or search stored content returned by web_fetch using responseId.", "{\"type\":\"object\",\"properties\":{\"responseId\":{\"type\":\"string\"},\"url\":{\"type\":\"string\"},\"urlIndex\":{\"type\":\"integer\",\"minimum\":0},\"offset\":{\"type\":\"integer\",\"minimum\":0},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":50000},\"findText\":{\"oneOf\":[{\"type\":\"string\"},{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"maxItems\":10}]},\"findMode\":{\"type\":\"string\",\"enum\":[\"exact\",\"case-insensitive\"]}},\"required\":[\"responseId\"],\"additionalProperties\":false}", wf_store, web_fetch.executeGetContent);
        definitions[9] = try definition(a, "web_search", "Search the web using a lightweight native HTTP client (Brave/Tavily/SearXNG when configured, or zero-config Exa / DuckDuckGo) with SSRF protection and bounded results.", "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query\"},\"maxResults\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":10},\"timeout\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":60}},\"required\":[\"query\"],\"additionalProperties\":false}", ws_cfg, web_search.executeWebSearch);
        if (bg_mgr) |mgr| {
            definitions[10] = try definition(a, "bg_run", "Start a named long-running shell command in the background and return immediately with a taskId and output path. Terminal completion delivers <background-task-notification> and triggers a follow-up turn by default.", "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"timeoutSeconds\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":86400},\"notifyOnCompletion\":{\"type\":\"boolean\"},\"triggerOnCompletion\":{\"type\":\"boolean\"}},\"required\":[\"name\",\"command\"],\"additionalProperties\":false}", mgr, bg_tasks.executeBgRun);
            definitions[11] = try definition(a, "bg_status", "Inspect point-in-time status for one or all background tasks.", "{\"type\":\"object\",\"properties\":{\"taskId\":{\"type\":\"string\"}},\"additionalProperties\":false}", mgr, bg_tasks.executeBgStatus);
            definitions[12] = try definition(a, "bg_logs", "Read bounded head or tail output from a background task log file.", "{\"type\":\"object\",\"properties\":{\"taskId\":{\"type\":\"string\"},\"tail\":{\"type\":\"boolean\"},\"maxBytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":51200}},\"required\":[\"taskId\"],\"additionalProperties\":false}", mgr, bg_tasks.executeBgLogs);
            definitions[13] = try definition(a, "bg_kill", "Terminate a running background task process group by taskId.", "{\"type\":\"object\",\"properties\":{\"taskId\":{\"type\":\"string\"}},\"required\":[\"taskId\"],\"additionalProperties\":false}", mgr, bg_tasks.executeBgKill);
        }
        return .{ .arena = arena, .tools = definitions, .temp_dir = owned_temp, .web_fetch_store = wf_store, .web_search_config = ws_cfg.*, .bg_manager = bg_mgr };
    }
    pub fn deinit(self: *ToolSet) void {
        const alloc = self.arena.child_allocator;
        if (self.bg_manager) |mgr| mgr.deinit();
        self.web_fetch_store.deinit();
        alloc.destroy(self.web_fetch_store);
        self.arena.deinit();
    }
};

const RuntimeContext = struct {
    temp_dir: []const u8,
    sandbox: sandbox_mod.Config = .{},
};

fn sandboxFromContext(context: ?*anyopaque) sandbox_mod.Config {
    const rt: ?*const RuntimeContext = if (context) |ptr| @ptrCast(@alignCast(ptr)) else null;
    return if (rt) |r| r.sandbox else .{};
}

fn definition(a: std.mem.Allocator, name: []const u8, description: []const u8, schema: []const u8, context: ?*anyopaque, execute: @FieldType(agent.Tool, "execute")) !agent.Tool {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, schema, .{});
    const capability: @import("agent").security.Capability = if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "grep") or std.mem.eql(u8, name, "find") or std.mem.eql(u8, name, "ls") or std.mem.eql(u8, name, "get_content")) .filesystem_read else if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit")) .filesystem_write else if (std.mem.eql(u8, name, "bash") or std.mem.startsWith(u8, name, "bg_")) .process_exec else if (std.mem.eql(u8, name, "web_fetch") or std.mem.eql(u8, name, "web_search")) .network_connect else .process_exec;
    return .{ .definition = .{ .name = name, .description = description, .parameters = parsed.value }, .capability = capability, .context = context, .execute = execute, .builtin = true };
}
fn string(args: std.json.Value, key: []const u8) ![]const u8 {
    if (args != .object) return error.ExpectedObject;
    const v = args.object.get(key) orelse return error.MissingArgument;
    if (v != .string) return error.ExpectedString;
    return v.string;
}
fn nonnegative(args: std.json.Value, key: []const u8, fallback: usize) !usize {
    if (args != .object) return error.ExpectedObject;
    const value = args.object.get(key) orelse return fallback;
    const number = switch (value) {
        .integer => value.integer,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return error.ExpectedNonnegativeInteger,
        else => return error.ExpectedNonnegativeInteger,
    };
    if (number < 0 or number > std.math.maxInt(u32)) return error.ExpectedNonnegativeInteger;
    return @intCast(number);
}
fn positive(args: std.json.Value, key: []const u8, fallback: usize) !usize {
    if (args != .object) return error.ExpectedObject;
    const v = args.object.get(key) orelse return fallback;
    const n = switch (v) {
        .integer => v.integer,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch return error.ExpectedPositiveInteger,
        else => return error.ExpectedPositiveInteger,
    };
    if (n <= 0 or n > std.math.maxInt(u32)) return error.ExpectedPositiveInteger;
    return @intCast(n);
}
fn validate(args: std.json.Value, keys: []const []const u8) !void {
    if (args != .object) return error.ExpectedObject;
    for (args.object.keys()) |key| {
        var allowed = false;
        for (keys) |known| if (std.mem.eql(u8, key, known)) {
            allowed = true;
            break;
        };
        if (!allowed) return error.UnknownArgument;
    }
}
fn resolve(context: ?*anyopaque, ctx: agent.ToolContext, input: []const u8, write_access: bool) ![]u8 {
    return sandbox_mod.resolveToolPath(ctx.allocator, ctx.io, sandboxFromContext(context), ctx.cwd, input, write_access);
}
fn load(ctx: agent.ToolContext, path: []const u8) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(ctx.io, path, .{});
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > 8 * 1024 * 1024) return error.FileTooLarge;
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(8 * 1024 * 1024 + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooLarge,
        else => return err,
    };
    if (bytes.len > 8 * 1024 * 1024) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.NotUtf8Text;
    return bytes;
}
fn read(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "offset", "limit" });
    const path = try resolve(context, ctx, try string(args, "path"), false);
    defer ctx.allocator.free(path);
    const bytes = try load(ctx, path);
    const offset = try positive(args, "offset", 1);
    const limit = try nonnegative(args, "limit", std.math.maxInt(u32));
    return selectReadText(ctx.allocator, bytes, offset, limit);
}

/// Match pi's text.split("\n") range selection before applying independent
/// output caps. In particular, empty files and the item after a final newline
/// are valid selections, and selecting the whole file preserves its bytes.
fn selectReadText(a: std.mem.Allocator, bytes: []const u8, offset: usize, limit: usize) !agent.ToolResult {
    const max_lines = 2000;
    const max_bytes = 50 * 1024;
    const total_file_lines = std.mem.count(u8, bytes, "\n") + 1;
    if (offset > total_file_lines) return error.OffsetBeyondEnd;
    const selected_count = @min(limit, total_file_lines - offset + 1);
    var start: usize = 0;
    for (1..offset) |_| start = (std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse unreachable) + 1;
    var end = start;
    for (0..selected_count) |index| {
        end = std.mem.indexOfScalarPos(u8, bytes, end, '\n') orelse bytes.len;
        if (index + 1 < selected_count) end += 1;
    }
    const selected_text = bytes[start..end];
    const offset_display = offset;
    // truncateHead ignores one trailing empty split item when counting lines.
    const selected_lines = if (selected_text.len == 0) 0 else std.mem.count(u8, selected_text, "\n") + @intFromBool(selected_text[selected_text.len - 1] != '\n');
    if (selected_lines <= max_lines and selected_text.len <= max_bytes) {
        if (offset - 1 + selected_count < total_file_lines) return .{ .text = try std.fmt.allocPrint(a, "{s}\n\n[{d} more lines in file. Use offset={d} to continue.]", .{ selected_text, total_file_lines - (offset - 1 + selected_count), offset + selected_count }) };
        return .{ .text = selected_text };
    }
    const first_line_bytes = if (selected_count == 0) 0 else std.mem.indexOfScalar(u8, selected_text, '\n') orelse selected_text.len;
    const first_line_exceeds = first_line_bytes > max_bytes;
    var output_lines: usize = 0;
    var output_bytes: usize = 0;
    var truncated_by: []const u8 = "lines";
    if (first_line_exceeds) {
        truncated_by = "bytes";
    } else {
        var lines = std.mem.splitScalar(u8, selected_text, '\n');
        while (output_lines < @min(selected_lines, max_lines)) {
            const line = lines.next().?;
            const size = line.len + @intFromBool(output_lines > 0);
            if (output_bytes + size > max_bytes) {
                truncated_by = "bytes";
                break;
            }
            output_bytes += size;
            output_lines += 1;
        }
    }
    const output_text = selected_text[0..output_bytes];
    const text = if (first_line_exceeds) blk: {
        const size = try readSize(a, first_line_bytes);
        defer a.free(size);
        break :blk try std.fmt.allocPrint(a, "[Line {d} is {s}, exceeds 50.0KB limit. Use bash with a safely quoted path to inspect part of this line.]", .{ offset_display, size });
    } else if (std.mem.eql(u8, truncated_by, "lines"))
        try std.fmt.allocPrint(a, "{s}\n\n[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]", .{ output_text, offset_display, offset_display + output_lines - 1, total_file_lines, offset_display + output_lines })
    else
        try std.fmt.allocPrint(a, "{s}\n\n[Showing lines {d}-{d} of {d} (50.0KB limit). Use offset={d} to continue.]", .{ output_text, offset_display, offset_display + output_lines - 1, total_file_lines, offset_display + output_lines });
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .truncation = .{
        .content = output_text,
        .truncated = true,
        .truncatedBy = truncated_by,
        .totalLines = selected_lines,
        .totalBytes = selected_text.len,
        .outputLines = output_lines,
        .outputBytes = output_text.len,
        .lastLinePartial = false,
        .firstLineExceedsLimit = first_line_exceeds,
        .maxLines = max_lines,
        .maxBytes = max_bytes,
    } }, .{});
    defer a.free(encoded);
    return .{ .text = text, .details = try std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{ .allocate = .alloc_always }) };
}

fn readSize(a: std.mem.Allocator, size: usize) ![]const u8 {
    if (size < 1024) return std.fmt.allocPrint(a, "{d}B", .{size});
    const divisor: f64 = if (size < 1024 * 1024) 1024 else 1024 * 1024;
    return std.fmt.allocPrint(a, "{d:.1}{s}", .{ @as(f64, @floatFromInt(size)) / divisor, if (size < 1024 * 1024) "KB" else "MB" });
}
fn save(ctx: agent.ToolContext, path: []const u8, content: []const u8) !void {
    if (content.len > 8 * 1024 * 1024) return error.FileTooLarge;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(ctx.io, parent);
    // Preserve executable/read permissions on replacement; new files use the
    // process umask. Replacing a symlink is deliberately rejected rather than
    // unexpectedly replacing the link itself with a regular file.
    const existing = std.Io.Dir.cwd().statFile(ctx.io, path, .{ .follow_symlinks = false }) catch |err| blk: {
        if (err == error.FileNotFound) break :blk null;
        return err;
    };
    if (existing) |stat| if (stat.kind != .file) return error.NotRegularFile;
    var file = try std.Io.Dir.cwd().createFileAtomic(ctx.io, path, .{
        .replace = true,
        .permissions = if (existing) |stat| stat.permissions else .default_file,
    });
    defer file.deinit(ctx.io);
    try file.file.writeStreamingAll(ctx.io, content);
    try file.replace(ctx.io);
}
fn write(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "content" });
    const path = try resolve(context, ctx, try string(args, "path"), true);
    defer ctx.allocator.free(path);
    const content = try string(args, "content");
    try save(ctx, path, content);
    return .{ .text = try std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes to {s}", .{ content.len, path }) };
}
fn edit(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "oldText", "newText", "edits" });
    const path = try resolve(context, ctx, try string(args, "path"), true);
    defer ctx.allocator.free(path);
    const content = try load(ctx, path);
    var entries: std.ArrayList(replacements.Edit) = .empty;
    defer entries.deinit(ctx.allocator);
    if (args.object.get("edits")) |list| {
        if (list != .array) return error.ExpectedEditArray;
        if (list.array.items.len > replacements.max_edits) return error.TooManyEdits;
        for (list.array.items) |item| {
            if (item != .object) return error.ExpectedEditObject;
            try validate(item, &.{ "oldText", "newText" });
            try entries.append(ctx.allocator, .{
                .oldText = try string(item, "oldText"),
                .newText = try string(item, "newText"),
            });
        }
    }
    if (args.object.get("newText") != null and args.object.get("oldText") == null) return error.MissingArgument;
    if (args.object.get("oldText")) |_| {
        try entries.append(ctx.allocator, .{
            .oldText = try string(args, "oldText"),
            .newText = try string(args, "newText"),
        });
    }
    const updated = try replacements.applyWithDiff(ctx.allocator, content, entries.items);
    defer {
        ctx.allocator.free(updated.content);
        ctx.allocator.free(updated.diff);
    }
    try save(ctx, path, updated.content);
    const encoded = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .diff = updated.diff,
        .firstChangedLine = updated.first_changed_line,
    }, .{});
    defer ctx.allocator.free(encoded);
    return .{
        .text = try std.fmt.allocPrint(ctx.allocator, "Edited {d} block(s) in {s}", .{ entries.items.len, path }),
        .details = try std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, encoded, .{ .allocate = .alloc_always }),
    };
}
fn grep(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "pattern", "path", "glob", "ignoreCase", "literal", "context", "limit" });
    const pattern = try string(args, "pattern");
    const path = if (args.object.get("path") != null) try string(args, "path") else ".";
    const resolved = try resolve(context, ctx, path, false);
    defer ctx.allocator.free(resolved);
    const glob = if (args.object.get("glob") != null) try string(args, "glob") else null;
    const ignore_case = if (args.object.get("ignoreCase")) |v| switch (v) {
        .bool => |b| b,
        else => return error.ExpectedBoolean,
    } else false;
    const literal = if (args.object.get("literal")) |v| switch (v) {
        .bool => |b| b,
        else => return error.ExpectedBoolean,
    } else false;
    const context_lines = if (args.object.get("context")) |v| blk: {
        if (v == .integer and v.integer == 0) break :blk 0;
        if (v == .number_string and std.mem.eql(u8, v.number_string, "0")) break :blk 0;
        break :blk try positive(args, "context", 0);
    } else 0;
    const limit = @min(try positive(args, "limit", 100), 100000);
    const result = try search.grep(ctx.allocator, ctx.io, .{ .pattern = pattern, .path = resolved, .glob = glob, .ignore_case = ignore_case, .literal = literal, .context = context_lines, .limit = limit, .sandbox = sandboxFromContext(context) });
    return .{ .text = result.text };
}
fn find(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "pattern", "path", "limit" });
    const pattern = try string(args, "pattern");
    const path = if (args.object.get("path") != null) try string(args, "path") else ".";
    const resolved = try resolve(context, ctx, path, false);
    defer ctx.allocator.free(resolved);
    const limit = @min(try positive(args, "limit", 1000), 100000);
    const result = try search.find(ctx.allocator, ctx.io, .{ .pattern = pattern, .path = resolved, .limit = limit, .sandbox = sandboxFromContext(context) });
    return .{ .text = result.text };
}
fn ls(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "limit" });
    const path = if (args.object.get("path") != null) try string(args, "path") else ".";
    const resolved = try resolve(context, ctx, path, false);
    defer ctx.allocator.free(resolved);
    const limit = @min(try positive(args, "limit", 500), 100000);
    const result = try search.ls(ctx.allocator, ctx.io, .{ .path = resolved, .limit = limit, .sandbox = sandboxFromContext(context) });
    return .{ .text = result.text };
}
fn bash(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    const rt: ?*const RuntimeContext = if (context) |ptr| @ptrCast(@alignCast(ptr)) else null;
    const temp_dir = if (rt) |r| r.temp_dir else "/tmp";
    const sb = if (rt) |r| r.sandbox else sandbox_mod.Config{};
    try validate(args, &.{ "command", "timeout" });
    const command = try string(args, "command");
    const seconds = try positive(args, "timeout", 60);
    if (seconds > 3600) return error.InvalidTimeout;
    // No command interpolation into a wrapper: use a fixed shell source and
    // pass the command as $1. Redirection combines stderr before output capture.
    if (std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidCommand;
    if (ctx.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
    const Completion = union(enum) { process: anyerror!agent.ToolResult, timer: std.Io.Cancelable!void, cancel: std.Io.Cancelable!void };
    var storage: [3]Completion = undefined;
    var select = std.Io.Select(Completion).init(ctx.io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.timer, shellTimer, .{ ctx.io, seconds });
    try select.concurrent(.process, shellRun, .{ ctx, temp_dir, sb, command });
    if (ctx.cancel) |cancel| try select.concurrent(.cancel, shellCancel, .{ cancel, ctx.io });
    return switch (try select.await()) {
        .process => |result| result,
        .timer => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
        .cancel => |result| blk: {
            try result;
            break :blk error.Canceled;
        },
    };
}

fn shellTimer(io: std.Io, seconds: usize) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(@intCast(seconds)), .awake);
}
fn shellCancel(cancel: agent.model.Cancel, io: std.Io) std.Io.Cancelable!void {
    try cancel.wait(io);
}

const bash_max_lines: usize = 2000;
const bash_max_bytes: usize = 50 * 1024;
const bash_tail_keep_bytes: usize = 64 * 1024;
const bash_tail_compact_threshold: usize = 128 * 1024;
const bash_max_spill_bytes: usize = 32 * 1024 * 1024;
const bash_stream_preview_cap: usize = 64 * 1024;

const BashAccumulator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_dir: []const u8,
    tail: std.ArrayList(u8) = .empty,
    total_bytes: usize = 0,
    newline_count: usize = 0,
    ended_with_nl: bool = false,
    prev_line_bytes: usize = 0,
    current_line_bytes: usize = 0,
    spill_file: ?std.Io.File = null,
    spill_path: ?[]u8 = null,

    fn deinitAndCleanupOnError(self: *BashAccumulator) void {
        if (self.spill_file) |f| {
            f.close(self.io);
            self.spill_file = null;
        }
        if (self.spill_path) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.allocator.free(path);
            self.spill_path = null;
        }
        self.tail.deinit(self.allocator);
    }

    fn closeSpillFile(self: *BashAccumulator) void {
        if (self.spill_file) |f| {
            f.close(self.io);
            self.spill_file = null;
        }
    }

    fn openSpillFile(self: *BashAccumulator) !void {
        if (self.spill_file != null) return;
        const dir = blk: {
            const trimmed = std.mem.trimEnd(u8, self.temp_dir, "/");
            break :blk if (trimmed.len == 0) "/" else trimmed;
        };
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            var rand_bytes: [8]u8 = undefined;
            self.io.random(&rand_bytes);
            const path = try std.fmt.allocPrint(self.allocator, "{s}/zpi-bash-{x}.log", .{ dir, rand_bytes });
            errdefer self.allocator.free(path);
            const file = std.Io.Dir.cwd().createFile(self.io, path, .{
                .exclusive = true,
                .permissions = .fromMode(0o600),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    self.allocator.free(path);
                    continue;
                },
                else => return err,
            };
            self.spill_file = file;
            self.spill_path = path;
            return;
        }
        return error.TempFileExhausted;
    }

    fn append(self: *BashAccumulator, chunk: []const u8) !void {
        if (chunk.len == 0) return;
        const next_total = std.math.add(usize, self.total_bytes, chunk.len) catch return error.StreamTooLong;
        if (next_total > bash_max_spill_bytes) return error.StreamTooLong;

        for (chunk) |b| {
            if (b == '\n') {
                self.newline_count += 1;
                self.prev_line_bytes = self.current_line_bytes;
                self.current_line_bytes = 0;
                self.ended_with_nl = true;
            } else {
                self.current_line_bytes += 1;
                self.ended_with_nl = false;
            }
        }
        self.total_bytes = next_total;

        if (self.spill_file) |f| {
            try f.writeStreamingAll(self.io, chunk);
        } else if (self.total_bytes > bash_max_bytes) {
            try self.openSpillFile();
            if (self.tail.items.len > 0) try self.spill_file.?.writeStreamingAll(self.io, self.tail.items);
            try self.spill_file.?.writeStreamingAll(self.io, chunk);
        }

        try self.tail.appendSlice(self.allocator, chunk);
        if (self.tail.items.len > bash_tail_compact_threshold) {
            const drop = self.tail.items.len - bash_tail_keep_bytes;
            std.mem.copyForwards(u8, self.tail.items[0..bash_tail_keep_bytes], self.tail.items[drop..]);
            self.tail.items.len = bash_tail_keep_bytes;
        }
    }

    fn totalLines(self: *const BashAccumulator) usize {
        if (self.total_bytes == 0) return 0;
        return if (self.ended_with_nl) self.newline_count else self.newline_count + 1;
    }

    fn lastLineBytes(self: *const BashAccumulator) usize {
        if (self.total_bytes == 0) return 0;
        return if (self.ended_with_nl) self.prev_line_bytes else self.current_line_bytes;
    }

    fn ensureSpilledIfTruncated(self: *BashAccumulator) !void {
        if (self.totalLines() > bash_max_lines or self.total_bytes > bash_max_bytes) {
            if (self.spill_path == null) {
                try self.openSpillFile();
                if (self.tail.items.len > 0) try self.spill_file.?.writeStreamingAll(self.io, self.tail.items);
            }
        }
        self.closeSpillFile();
    }
};

fn shellDrain(ctx: agent.ToolContext, temp_dir: []const u8, stdout: std.Io.File) anyerror!BashAccumulator {
    var acc = BashAccumulator{ .allocator = ctx.allocator, .io = ctx.io, .temp_dir = temp_dir };
    errdefer acc.deinitAndCleanupOnError();
    var stream_buf: std.ArrayList(u8) = .empty;
    defer stream_buf.deinit(ctx.allocator);
    var emitted_bytes: usize = 0;
    while (true) {
        var read_buf: [8192]u8 = undefined;
        const n = stdout.readStreaming(ctx.io, &.{&read_buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        const chunk = read_buf[0..n];
        try acc.append(chunk);
        if (ctx.on_update) |emit| {
            if (emitted_bytes < bash_stream_preview_cap) {
                const remain = bash_stream_preview_cap - emitted_bytes;
                const take = @min(chunk.len, remain);
                try stream_buf.appendSlice(ctx.allocator, chunk[0..take]);
                if (std.mem.lastIndexOfScalar(u8, stream_buf.items, '\n')) |last_nl| {
                    const text = stream_buf.items[0..last_nl];
                    if (text.len > 0) {
                        try emit(ctx.update_context, .{ .text = text });
                        emitted_bytes += text.len;
                    }
                    const tail_len = stream_buf.items.len - (last_nl + 1);
                    if (tail_len > 0) {
                        std.mem.copyForwards(u8, stream_buf.items[0..tail_len], stream_buf.items[last_nl + 1 ..]);
                    }
                    stream_buf.items.len = tail_len;
                } else if (stream_buf.items.len >= 2048) {
                    var cut = stream_buf.items.len;
                    while (cut > 0 and (stream_buf.items[cut - 1] & 0xc0) == 0x80) : (cut -= 1) {}
                    if (cut == 0) cut = stream_buf.items.len;
                    try emit(ctx.update_context, .{ .text = stream_buf.items[0..cut] });
                    emitted_bytes += cut;
                    const tail_len = stream_buf.items.len - cut;
                    if (tail_len > 0) {
                        std.mem.copyForwards(u8, stream_buf.items[0..tail_len], stream_buf.items[cut..]);
                    }
                    stream_buf.items.len = tail_len;
                }
            }
        }
    }
    if (ctx.on_update) |emit| {
        if (stream_buf.items.len > 0 and emitted_bytes < bash_stream_preview_cap) {
            const trimmed = std.mem.trimEnd(u8, stream_buf.items, "\n");
            if (trimmed.len > 0) try emit(ctx.update_context, .{ .text = trimmed });
        }
    }
    return acc;
}

fn truncateTailText(a: std.mem.Allocator, acc: *const BashAccumulator) !struct {
    content: []const u8,
    truncated: bool,
    truncated_by: ?[]const u8,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool,
} {
    const total_lines = acc.totalLines();
    const total_bytes = acc.total_bytes;
    const raw = acc.tail.items;
    const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;

    if (total_lines <= bash_max_lines and total_bytes <= bash_max_bytes) {
        return .{
            .content = raw,
            .truncated = false,
            .truncated_by = null,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = total_bytes,
            .last_line_partial = false,
        };
    }

    // Walk backwards from the end of `trimmed` up to bash_max_lines / bash_max_bytes.
    var output_lines: usize = 0;
    var output_bytes: usize = 0;
    var start_pos: usize = trimmed.len;
    var cursor: usize = trimmed.len;
    var truncated_by: []const u8 = "lines";
    var last_line_partial = false;

    while (output_lines < bash_max_lines) {
        const line_start = if (cursor == 0) 0 else if (std.mem.lastIndexOfScalar(u8, trimmed[0..cursor], '\n')) |nl| nl + 1 else 0;
        const line_len = cursor - line_start;
        const add_bytes = line_len + @intFromBool(output_lines > 0);
        if (output_bytes + add_bytes > bash_max_bytes) {
            truncated_by = "bytes";
            if (output_lines == 0) {
                var partial_start = trimmed.len - @min(trimmed.len, bash_max_bytes);
                while (partial_start < trimmed.len and (trimmed[partial_start] & 0xc0) == 0x80) : (partial_start += 1) {}
                start_pos = partial_start;
                output_bytes = trimmed.len - partial_start;
                output_lines = 1;
                last_line_partial = true;
            }
            break;
        }
        start_pos = line_start;
        output_bytes += add_bytes;
        output_lines += 1;
        if (line_start == 0) break;
        cursor = line_start - 1;
    }

    const tail_slice = if (raw.len > 0 and raw[raw.len - 1] == '\n' and !last_line_partial) blk: {
        // Keep trailing newline only when the original output fit? No, pi joins lines without trailing \n.
        break :blk trimmed[start_pos..];
    } else trimmed[start_pos..];

    return .{
        .content = try a.dupe(u8, tail_slice),
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = output_lines,
        .output_bytes = tail_slice.len,
        .last_line_partial = last_line_partial,
    };
}

fn shellRun(ctx: agent.ToolContext, temp_dir: []const u8, sb: sandbox_mod.Config, command: []const u8) anyerror!agent.ToolResult {
    var child = try sandbox_mod.spawn(ctx.allocator, ctx.io, sb, .{
        .argv = &.{ "/bin/sh", "-c", "exec /bin/sh -c \"$1\" 2>&1", "zpi-bash", command },
        .cwd = ctx.cwd,
        .pgid = 0,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const stdout = child.stdout orelse return error.MissingChildStdout;
    const pid = child.id orelse return error.ChildAlreadyTerminated;
    var completed = false;
    defer if (!completed) {
        // The direct child has not yet been reaped, so its PID and process-group
        // ID cannot be reused. Kill descendants before reaping it.
        std.posix.kill(-pid, .KILL) catch {};
        child.kill(ctx.io);
    };
    // Drain before waiting so a child blocked on a full pipe can make progress.
    // If the bounded drain fails or cancellation interrupts it, the defer above
    // kills and reaps the entire process group.
    var acc = try shellDrain(ctx, temp_dir, stdout);
    errdefer acc.deinitAndCleanupOnError();
    const waited = try child.wait(ctx.io);
    completed = true;
    try acc.ensureSpilledIfTruncated();

    const status: ?u32 = switch (waited) {
        .exited => |code| code,
        .signal => |signal| 128 + @as(u32, @intCast(@backingInt(signal))),
        .stopped, .unknown => null,
    };

    const trunc = try truncateTailText(ctx.allocator, &acc);
    defer if (trunc.truncated) ctx.allocator.free(trunc.content);

    var text_out: []const u8 = undefined;
    var details: std.json.Value = .null;

    if (!trunc.truncated) {
        text_out = if (acc.tail.items.len == 0) "(no output)" else acc.tail.items;
    } else {
        const spill_path = acc.spill_path orelse return error.TempFileExhausted;
        const start_line = trunc.total_lines - trunc.output_lines + 1;
        const end_line = trunc.total_lines;
        const notice = if (trunc.last_line_partial) blk: {
            const out_sz = try readSize(ctx.allocator, trunc.output_bytes);
            defer ctx.allocator.free(out_sz);
            const last_sz = try readSize(ctx.allocator, acc.lastLineBytes());
            defer ctx.allocator.free(last_sz);
            break :blk try std.fmt.allocPrint(ctx.allocator, "[Showing last {s} of line {d} (line is {s}). Full output: {s}]", .{ out_sz, end_line, last_sz, spill_path });
        } else if (std.mem.eql(u8, trunc.truncated_by.?, "lines"))
            try std.fmt.allocPrint(ctx.allocator, "[Showing lines {d}-{d} of {d}. Full output: {s}]", .{ start_line, end_line, trunc.total_lines, spill_path })
        else
            try std.fmt.allocPrint(ctx.allocator, "[Showing lines {d}-{d} of {d} (50.0KB limit). Full output: {s}]", .{ start_line, end_line, trunc.total_lines, spill_path });
        defer ctx.allocator.free(notice);

        text_out = if (trunc.content.len == 0)
            try ctx.allocator.dupe(u8, notice)
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}\n\n{s}", .{ trunc.content, notice });

        const encoded = try std.json.Stringify.valueAlloc(ctx.allocator, .{
            .truncation = .{
                .content = trunc.content,
                .truncated = true,
                .truncatedBy = trunc.truncated_by.?,
                .totalLines = trunc.total_lines,
                .totalBytes = trunc.total_bytes,
                .outputLines = trunc.output_lines,
                .outputBytes = trunc.output_bytes,
                .lastLinePartial = trunc.last_line_partial,
                .firstLineExceedsLimit = false,
                .maxLines = bash_max_lines,
                .maxBytes = bash_max_bytes,
            },
            .fullOutputPath = spill_path,
        }, .{});
        defer ctx.allocator.free(encoded);
        details = try std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, encoded, .{ .allocate = .alloc_always });
    }
    defer if (trunc.truncated) ctx.allocator.free(text_out);
    defer {
        if (acc.spill_path) |p| ctx.allocator.free(p);
        acc.tail.deinit(ctx.allocator);
    }

    return .{
        .text = if (status) |code|
            if (code == 0) try ctx.allocator.dupe(u8, text_out) else try std.fmt.allocPrint(ctx.allocator, "{s}\n\nCommand exited with code {d}", .{ text_out, code })
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}\n\nCommand terminated without an exit code", .{text_out}),
        .details = details,
        .is_error = !waited.success(),
    };
}
