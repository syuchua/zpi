//! MVP tools use the process user's OS permissions. cwd is a default path,
//! not a sandbox. Calls are serialized by the agent; no hidden approval UI.
const std = @import("std");
const agent = @import("agent");
const replacements = @import("replacements");
const search = @import("search");

pub const ToolSet = struct {
    arena: std.heap.ArenaAllocator,
    tools: [7]agent.Tool,

    pub fn init(allocator: std.mem.Allocator) !ToolSet {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const definitions = [7]agent.Tool{
            try definition(a, "read", "Read a text file. Output is truncated to 2000 lines or 50 KiB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to read (relative or absolute)\"},\"offset\":{\"type\":\"integer\",\"minimum\":1,\"description\":\"Line number to start reading from (1-indexed)\"},\"limit\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"Maximum number of lines to read\"}},\"required\":[\"path\"],\"additionalProperties\":false}", read),
            try definition(a, "write", "Create or overwrite a text file, creating parent directories.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}", write),
            try definition(a, "edit", "Make precise unique exact replacements. All edits match the original file; overlapping edits, duplicates and no-ops are rejected.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"},\"edits\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"}},\"required\":[\"oldText\",\"newText\"],\"additionalProperties\":false},\"minItems\":1,\"maxItems\":1024}},\"required\":[\"path\"],\"additionalProperties\":false}", edit),
            try definition(a, "bash", "Execute a shell command in the project directory. Optional timeout in seconds (default 60, maximum 3600). Fails with StreamTooLong above 1 MiB of combined output; timeout/output errors stop the process group.", "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"timeout\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":3600}},\"required\":[\"command\"],\"additionalProperties\":false}", bash),
            try definition(a, "grep", "Search with installed ripgrep, respecting gitignore. Returns paths and line numbers; bounded to 50 KiB and an optional match limit.", "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"glob\":{\"type\":\"string\"},\"ignoreCase\":{\"type\":\"boolean\"},\"literal\":{\"type\":\"boolean\"},\"context\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":10000},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100000}},\"required\":[\"pattern\"],\"additionalProperties\":false}", grep),
            try definition(a, "find", "Find paths with installed fd/fdfind using glob patterns and gitignore rules. Results are relative to the search directory.", "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100000}},\"required\":[\"pattern\"],\"additionalProperties\":false}", find),
            try definition(a, "ls", "List directory entries including dotfiles, sorted by ASCII case-insensitive name; directory names end with a slash.", "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100000}},\"additionalProperties\":false}", ls),
        };
        return .{ .arena = arena, .tools = definitions };
    }
    pub fn deinit(self: *ToolSet) void {
        self.arena.deinit();
    }
};

fn definition(a: std.mem.Allocator, name: []const u8, description: []const u8, schema: []const u8, execute: @FieldType(agent.Tool, "execute")) !agent.Tool {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, schema, .{});
    return .{ .definition = .{ .name = name, .description = description, .parameters = parsed.value }, .execute = execute, .builtin = true };
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
fn resolve(ctx: agent.ToolContext, input: []const u8) ![]u8 {
    if (input.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPath;
    return std.fs.path.resolveAlloc(ctx.allocator, &.{ ctx.cwd, input });
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
fn read(_: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "offset", "limit" });
    const path = try resolve(ctx, try string(args, "path"));
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
fn write(_: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "content" });
    const path = try resolve(ctx, try string(args, "path"));
    defer ctx.allocator.free(path);
    const content = try string(args, "content");
    try save(ctx, path, content);
    return .{ .text = try std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes to {s}", .{ content.len, path }) };
}
fn edit(_: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "oldText", "newText", "edits" });
    const path = try resolve(ctx, try string(args, "path"));
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
    const updated = try replacements.apply(ctx.allocator, content, entries.items);
    defer ctx.allocator.free(updated);
    try save(ctx, path, updated);
    return .{ .text = try std.fmt.allocPrint(ctx.allocator, "Edited {d} block(s) in {s}", .{ entries.items.len, path }) };
}
fn grep(_: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "pattern", "path", "glob", "ignoreCase", "literal", "context", "limit" });
    const pattern = try string(args, "pattern");
    const path = if (args.object.get("path") != null) try string(args, "path") else ".";
    const resolved = try resolve(ctx, path);
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
    const context = if (args.object.get("context")) |v| blk: {
        if (v == .integer and v.integer == 0) break :blk 0;
        if (v == .number_string and std.mem.eql(u8, v.number_string, "0")) break :blk 0;
        break :blk try positive(args, "context", 0);
    } else 0;
    const limit = @min(try positive(args, "limit", 100), 100000);
    const result = try search.grep(ctx.allocator, ctx.io, .{ .pattern = pattern, .path = resolved, .glob = glob, .ignore_case = ignore_case, .literal = literal, .context = context, .limit = limit });
    return .{ .text = result.text };
}
fn find(_: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "pattern", "path", "limit" });
    const pattern = try string(args, "pattern");
    const path = if (args.object.get("path") != null) try string(args, "path") else ".";
    const resolved = try resolve(ctx, path);
    defer ctx.allocator.free(resolved);
    const limit = @min(try positive(args, "limit", 1000), 100000);
    const result = try search.find(ctx.allocator, ctx.io, .{ .pattern = pattern, .path = resolved, .limit = limit });
    return .{ .text = result.text };
}
fn ls(_: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
    try validate(args, &.{ "path", "limit" });
    const path = if (args.object.get("path") != null) try string(args, "path") else ".";
    const resolved = try resolve(ctx, path);
    defer ctx.allocator.free(resolved);
    const limit = @min(try positive(args, "limit", 500), 100000);
    const result = try search.ls(ctx.allocator, ctx.io, .{ .path = resolved, .limit = limit });
    return .{ .text = result.text };
}
fn bash(_: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) anyerror!agent.ToolResult {
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
    try select.concurrent(.process, shellRun, .{ ctx, command });
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
fn shellDrain(ctx: agent.ToolContext, stdout: std.Io.File) anyerror![]u8 {
    var buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(ctx.allocator, ctx.io, buffer.toStreams(), &.{stdout});
    defer reader.deinit();
    while (reader.fill(4096, .none)) |_| {
        if (reader.reader(0).bufferedLen() > 1024 * 1024) {
            // The same selected group owner performs the bounded drain and
            // escalates to KILL if ordinary descendants ignore TERM.
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    return reader.toOwnedSlice(0);
}
fn shellRun(ctx: agent.ToolContext, command: []const u8) anyerror!agent.ToolResult {
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ "/bin/sh", "-c", "exec /bin/sh -c \"$1\" 2>&1", "zpi-bash", command },
        .cwd = .{ .path = ctx.cwd },
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
    const owned_output = try shellDrain(ctx, stdout);
    errdefer ctx.allocator.free(owned_output);
    const waited = try child.wait(ctx.io);
    completed = true;
    const text = if (owned_output.len == 0) "(no output)" else owned_output;
    const status: ?u32 = switch (waited) {
        .exited => |code| code,
        .signal => |signal| 128 + @as(u32, @intCast(@backingInt(signal))),
        .stopped, .unknown => null,
    };
    return .{
        .text = if (status) |code|
            if (code == 0) try ctx.allocator.dupe(u8, text) else try std.fmt.allocPrint(ctx.allocator, "{s}\n\nCommand exited with code {d}", .{ text, code })
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}\n\nCommand terminated without an exit code", .{text}),
        .is_error = !waited.success(),
    };
}
