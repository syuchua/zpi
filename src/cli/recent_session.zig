//! Read-only discovery for --continue. The selected session is opened normally
//! after discovery; a corrupt or locked newest file must fail closed.
const std = @import("std");
const max_entries = 10000;
const header_limit = 64 * 1024;

/// Returns an owned absolute path. Empty environment values use the default,
/// matching pi's truthy environment lookup; explicit CLI values take priority.
pub fn resolveDirectory(a: std.mem.Allocator, launch_cwd: []const u8, home: ?[]const u8, explicit: ?[]const u8, environment: ?[]const u8) ![]u8 {
    const env_path = if (environment) |path| (if (path.len > 0) path else null) else null;
    const configured = explicit orelse env_path;
    if (configured) |raw| {
        if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidSessionDirectory;
        if (std.mem.startsWith(u8, raw, "file://")) return error.UnsupportedSessionDirectoryUrl;
        if (std.mem.eql(u8, raw, "~") or std.mem.startsWith(u8, raw, "~/")) {
            const home_path = home orelse return error.MissingHome;
            const expanded = if (raw.len == 1) try a.dupe(u8, home_path) else try std.fs.path.join(a, &.{ home_path, raw[2..] });
            defer a.free(expanded);
            return std.fs.path.resolveAlloc(a, &.{ launch_cwd, expanded });
        }
        return std.fs.path.resolveAlloc(a, &.{ launch_cwd, raw });
    }
    return std.fs.path.resolveAlloc(a, &.{ launch_cwd, home orelse return error.MissingHome, ".zpi", "agent", "sessions" });
}

test "session directory follows CLI, environment and default precedence" {
    const a = std.testing.allocator;
    const home = "/home/test";
    const cwd = "/launch";

    const from_env = try resolveDirectory(a, cwd, home, null, "~/pi-sessions");
    defer a.free(from_env);
    try std.testing.expectEqualStrings("/home/test/pi-sessions", from_env);

    const relative_env = try resolveDirectory(a, cwd, home, null, "env-sessions");
    defer a.free(relative_env);
    try std.testing.expectEqualStrings("/launch/env-sessions", relative_env);

    const cli_over_env = try resolveDirectory(a, cwd, home, "cli-sessions", "~/ignored");
    defer a.free(cli_over_env);
    try std.testing.expectEqualStrings("/launch/cli-sessions", cli_over_env);

    const empty_env = try resolveDirectory(a, cwd, home, null, "");
    defer a.free(empty_env);
    try std.testing.expectEqualStrings("/home/test/.zpi/agent/sessions", empty_env);

    const home_only = try resolveDirectory(a, cwd, home, "~", null);
    defer a.free(home_only);
    try std.testing.expectEqualStrings(home, home_only);

    const without_home = try resolveDirectory(a, cwd, null, null, "sessions/../env");
    defer a.free(without_home);
    try std.testing.expectEqualStrings("/launch/env", without_home);

    const invalid_ignored = try resolveDirectory(a, cwd, null, "chosen", "file:///ignored");
    defer a.free(invalid_ignored);
    try std.testing.expectEqualStrings("/launch/chosen", invalid_ignored);

    try std.testing.expectError(error.MissingHome, resolveDirectory(a, cwd, null, null, null));
    try std.testing.expectError(error.MissingHome, resolveDirectory(a, cwd, null, null, "~/sessions"));
    try std.testing.expectError(error.UnsupportedSessionDirectoryUrl, resolveDirectory(a, cwd, home, null, "file:///sessions"));
    try std.testing.expectError(error.InvalidSessionDirectory, resolveDirectory(a, cwd, home, null, "bad\x00path"));
    try std.testing.expectError(error.InvalidSessionDirectory, resolveDirectory(a, cwd, home, null, "bad\xffpath"));
    try std.testing.expectError(error.InvalidSessionDirectory, resolveDirectory(a, cwd, home, "", null));
}

pub fn newest(a: std.mem.Allocator, io: std.Io, directory: []const u8, cwd: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    const normalized_cwd = try std.fs.path.resolveAlloc(a, &.{cwd});
    defer a.free(normalized_cwd);
    var selected: ?[]u8 = null;
    errdefer if (selected) |path| a.free(path);
    var selected_mtime: i96 = std.math.minInt(i96);
    var count: usize = 0;
    // Reuse the header buffer even when the caller uses a process arena.
    var buffer: [header_limit]u8 = undefined;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        count += 1;
        if (count > max_entries) return error.TooManySessionFiles;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        // An entry may change between iteration and open. Opening a FIFO in
        // nonblocking mode lets the handle check below reject it promptly.
        const handle = std.posix.openat(dir.handle, entry.name, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0) catch |err| switch (err) {
            error.FileNotFound, error.SymLinkLoop => continue,
            else => return err,
        };
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) continue;
        _ = scratch.reset(.retain_capacity);
        const temporary = scratch.allocator();
        const n = try file.readPositionalAll(io, &buffer, 0);
        const end = std.mem.indexOfScalar(u8, buffer[0..n], '\n') orelse continue;
        const Header = struct { type: []const u8, version: u32 = 1, format: []const u8 = "zpi", cwd: []const u8 };
        const parsed = std.json.parseFromSlice(Header, temporary, std.mem.trimEnd(u8, buffer[0..end], "\r"), .{ .ignore_unknown_fields = true, .max_value_len = header_limit }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer parsed.deinit();
        const header = parsed.value;
        if (!std.mem.eql(u8, header.type, "session") or !std.mem.eql(u8, header.format, "zpi") or header.version != 1) continue;
        if (!std.fs.path.isAbsolute(header.cwd) or std.mem.indexOfScalar(u8, header.cwd, 0) != null) continue;
        const stored_cwd = try std.fs.path.resolveAlloc(temporary, &.{header.cwd});
        if (!std.mem.eql(u8, normalized_cwd, stored_cwd)) continue;
        const path = try std.fs.path.resolveAlloc(a, &.{ directory, entry.name });
        const mtime = stat.mtime.nanoseconds;
        if (selected == null or mtime > selected_mtime or (mtime == selected_mtime and std.mem.lessThan(u8, path, selected.?))) {
            if (selected) |old| a.free(old);
            selected = path;
            selected_mtime = mtime;
        } else a.free(path);
    }
    return selected;
}

pub const SessionCandidate = struct {
    path: []u8,
    basename: []const u8,
    preview: []u8,
    mtime_ns: i96,
    message_count: usize,
};

pub fn freeList(a: std.mem.Allocator, items: []SessionCandidate) void {
    for (items) |item| {
        a.free(item.path);
        a.free(item.preview);
    }
    a.free(items);
}

pub fn list(a: std.mem.Allocator, io: std.Io, directory: []const u8, cwd: []const u8, max_results: usize) ![]SessionCandidate {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try a.alloc(SessionCandidate, 0),
        else => return err,
    };
    defer dir.close(io);
    const normalized_cwd = try std.fs.path.resolveAlloc(a, &.{cwd});
    defer a.free(normalized_cwd);

    var candidates: std.ArrayList(SessionCandidate) = .empty;
    errdefer {
        for (candidates.items) |item| {
            a.free(item.path);
            a.free(item.preview);
        }
        candidates.deinit(a);
    }

    var count: usize = 0;
    var buffer: [header_limit]u8 = undefined;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        count += 1;
        if (count > max_entries) return error.TooManySessionFiles;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const handle = std.posix.openat(dir.handle, entry.name, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0) catch |err| switch (err) {
            error.FileNotFound, error.SymLinkLoop => continue,
            else => return err,
        };
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) continue;

        _ = scratch.reset(.retain_capacity);
        const temporary = scratch.allocator();
        const n = try file.readPositionalAll(io, &buffer, 0);
        const content = buffer[0..n];
        const end = std.mem.indexOfScalar(u8, content, '\n') orelse continue;
        const Header = struct { type: []const u8, version: u32 = 1, format: []const u8 = "zpi", cwd: []const u8 };
        const parsed = std.json.parseFromSlice(Header, temporary, std.mem.trimEnd(u8, content[0..end], "\r"), .{ .ignore_unknown_fields = true, .max_value_len = header_limit }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer parsed.deinit();
        const header = parsed.value;
        if (!std.mem.eql(u8, header.type, "session") or !std.mem.eql(u8, header.format, "zpi") or header.version != 1) continue;
        if (!std.fs.path.isAbsolute(header.cwd) or std.mem.indexOfScalar(u8, header.cwd, 0) != null) continue;
        const stored_cwd = try std.fs.path.resolveAlloc(temporary, &.{header.cwd});
        if (!std.mem.eql(u8, normalized_cwd, stored_cwd)) continue;

        var msg_count: usize = 0;
        var preview_text: []const u8 = "";
        var lines = std.mem.splitScalar(u8, content[end + 1 ..], '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) continue;
            const LinePeek = struct {
                type: []const u8,
                message: ?struct {
                    role: []const u8,
                    content: []const struct { text: ?[]const u8 = null } = &.{},
                } = null,
            };
            const lp = std.json.parseFromSlice(LinePeek, temporary, line, .{ .ignore_unknown_fields = true, .max_value_len = header_limit }) catch continue;
            if (std.mem.eql(u8, lp.value.type, "message")) {
                if (lp.value.message) |m| {
                    if (!std.mem.eql(u8, m.role, "system")) {
                        msg_count += 1;
                        if (preview_text.len == 0 and std.mem.eql(u8, m.role, "user")) {
                            for (m.content) |part| {
                                if (part.text) |t| {
                                    const trimmed = std.mem.trim(u8, t, " \t\r\n");
                                    if (trimmed.len > 0) {
                                        preview_text = trimmed;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        const path = try std.fs.path.resolveAlloc(a, &.{ directory, entry.name });
        errdefer a.free(path);
        const preview = try sanitizePreviewAlloc(a, if (preview_text.len > 0) preview_text else "(empty session)", 72);
        try candidates.append(a, .{
            .path = path,
            .basename = std.fs.path.basename(path),
            .preview = preview,
            .mtime_ns = stat.mtime.nanoseconds,
            .message_count = msg_count,
        });
    }

    std.mem.sort(SessionCandidate, candidates.items, {}, struct {
        fn less(_: void, l: SessionCandidate, r: SessionCandidate) bool {
            if (l.mtime_ns != r.mtime_ns) return l.mtime_ns > r.mtime_ns;
            return std.mem.lessThan(u8, l.path, r.path);
        }
    }.less);

    if (candidates.items.len > max_results) {
        for (candidates.items[max_results..]) |item| {
            a.free(item.path);
            a.free(item.preview);
        }
        candidates.items.len = max_results;
    }
    return try candidates.toOwnedSlice(a);
}

fn sanitizePreviewAlloc(a: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len and out.items.len < max_bytes) {
        if (text[i] == '\r' or text[i] == '\n' or text[i] == '\t') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(a, ' ');
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = @min(len, text.len - i);
        if (out.items.len + step > max_bytes) break;
        if (step == 1 and (text[i] < 0x20 or text[i] == 0x7f)) {
            try out.append(a, '?');
        } else {
            try out.appendSlice(a, text[i .. i + step]);
        }
        i += step;
    }
    return try out.toOwnedSlice(a);
}

test "recent session discovery is cwd-aware, bounded and read-only" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const host = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(host);
    const directory = try std.fs.path.resolveAlloc(a, &.{ host, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(directory);
    const header = "{\"type\":\"session\",\"version\":1,\"format\":\"zpi\",\"cwd\":\"/project\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.jsonl", .data = header ++ "broken conversation\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.jsonl", .data = "{\"type\":\"session\",\"cwd\":\"/other\"}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.jsonl", .data = "not json\n" });
    const selected = (try newest(a, std.testing.io, directory, "/project/./")).?;
    defer a.free(selected);
    try std.testing.expectEqualStrings("a.jsonl", std.fs.path.basename(selected));
    const unchanged = try tmp.dir.readFileAlloc(std.testing.io, "a.jsonl", a, .limited(4096));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(header ++ "broken conversation\n", unchanged);
    // Equal timestamps have deterministic lexical ordering; a newer matching
    // header takes precedence even when its conversation body is corrupt.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.jsonl", .data = header });
    const timestamp: std.Io.Timestamp = .{ .nanoseconds = 1000000000 };
    for ([_][]const u8{ "a.jsonl", "b.jsonl" }) |name| {
        const file = try tmp.dir.openFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        try file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = timestamp } });
    }
    const tied = (try newest(a, std.testing.io, directory, "/project")).?;
    defer a.free(tied);
    try std.testing.expectEqualStrings("a.jsonl", std.fs.path.basename(tied));
    const newer = try tmp.dir.openFile(std.testing.io, "b.jsonl", .{});
    defer newer.close(std.testing.io);
    try newer.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 2000000000 } } });
    const latest = (try newest(a, std.testing.io, directory, "/project")).?;
    defer a.free(latest);
    try std.testing.expectEqualStrings("b.jsonl", std.fs.path.basename(latest));
    try std.testing.expect((try newest(a, std.testing.io, directory, "/missing")) == null);
    const missing = try std.fs.path.join(a, &.{ directory, "absent" });
    defer a.free(missing);
    try std.testing.expect((try newest(a, std.testing.io, missing, "/project")) == null);

    // list() returns matching sessions newest-first with extracted first-user preview.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "first.jsonl",
        .data = header ++ "{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"system\",\"content\":[{\"text\":\"sys\"}]}}\n{\"type\":\"message\",\"id\":\"2\",\"message\":{\"role\":\"user\",\"content\":[{\"text\":\"older prompt\"}]}}\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "second.jsonl",
        .data = header ++ "{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"user\",\"content\":[{\"text\":\"newest\\nprompt\"}]}}\n",
    });
    const f1 = try tmp.dir.openFile(std.testing.io, "first.jsonl", .{});
    defer f1.close(std.testing.io);
    try f1.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 3000000000 } } });
    const f2 = try tmp.dir.openFile(std.testing.io, "second.jsonl", .{});
    defer f2.close(std.testing.io);
    try f2.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 4000000000 } } });

    const listed = try list(a, std.testing.io, directory, "/project", 10);
    defer freeList(a, listed);
    try std.testing.expectEqual(@as(usize, 4), listed.len);
    try std.testing.expectEqualStrings("second.jsonl", listed[0].basename);
    try std.testing.expectEqualStrings("newest prompt", listed[0].preview);
    try std.testing.expectEqual(@as(usize, 1), listed[0].message_count);
    try std.testing.expectEqualStrings("first.jsonl", listed[1].basename);
    try std.testing.expectEqualStrings("older prompt", listed[1].preview);
}
