//! Read-only grep/find/ls adapters for installed ripgrep and fd. No tool binary
//! is downloaded; gitignore/glob semantics are delegated to these dependencies.
const std = @import("std");
const sandbox_mod = @import("sandbox");
pub const max_output_bytes = 50 * 1024;
pub const GrepOptions = struct { pattern: []const u8, path: []const u8 = ".", glob: ?[]const u8 = null, ignore_case: bool = false, literal: bool = false, context: usize = 0, limit: usize = 100, sandbox: sandbox_mod.Config = .{} };
pub const FindOptions = struct { pattern: []const u8, path: []const u8 = ".", limit: usize = 1000, sandbox: sandbox_mod.Config = .{} };
pub const LsOptions = struct { path: []const u8 = ".", limit: usize = 500, sandbox: sandbox_mod.Config = .{} };
pub const Result = struct { text: []u8, limited: bool = false, matches: usize = 0 };

const Process = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    sandbox: sandbox_mod.Config = .{},
    fn execute(self: *const Process) anyerror!std.process.RunResult {
        var cfg = self.sandbox;
        if (cfg.isConfined()) cfg.mode = .read_only;
        return sandbox_mod.run(self.allocator, self.io, cfg, .{
            .argv = self.argv,
            .cwd = self.cwd,
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }
};
fn timer(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(seconds), .awake);
}
fn runProcess(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8, sb: sandbox_mod.Config) anyerror!std.process.RunResult {
    var process = Process{ .allocator = allocator, .io = io, .argv = argv, .cwd = cwd, .sandbox = sb };
    const Completion = union(enum) { process: anyerror!std.process.RunResult, timer: std.Io.Cancelable!void };
    var storage: [2]Completion = undefined;
    var selection = std.Io.Select(Completion).init(io, &storage);
    defer {
        // Join before stack/argv go away and release a result that raced timeout.
        while (selection.cancel()) |item| switch (item) {
            .process => |result| if (result) |owned| {
                allocator.free(owned.stdout);
                allocator.free(owned.stderr);
            } else |_| {},
            .timer => {},
        };
    }
    try selection.concurrent(.timer, timer, .{ io, 30 });
    try selection.concurrent(.process, Process.execute, .{&process});
    switch (try selection.await()) {
        .process => |result| return result,
        .timer => |result| {
            try result;
            return error.SearchTimeout;
        },
    }
}

const Output = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(u8) = .empty,
    stored_bytes: usize = 0,
    total_bytes: usize = 0,
    total_lines: usize = 0,
    storage_full: bool = false,
    fn append(self: *Output, line: []const u8) !void {
        const separator: usize = @intFromBool(self.total_lines > 0);
        self.total_bytes += line.len + separator;
        self.total_lines += 1;
        if (self.storage_full) return;
        const next = self.stored_bytes + line.len + separator;
        if (next > max_output_bytes) {
            self.storage_full = true;
            return;
        }
        if (separator != 0) try self.lines.append(self.allocator, '\n');
        try self.lines.appendSlice(self.allocator, line);
        self.stored_bytes = next;
    }
    fn finish(self: *Output, count: usize, limit: usize, limited: bool, noun: []const u8, line_truncated: bool) !Result {
        const truncated = self.storage_full;
        const notice = truncated or limited or line_truncated;
        if (notice) {
            try self.lines.appendSlice(self.allocator, "\n\n[");
            var has_notice = false;
            if (limited) {
                const formatted = if (std.mem.eql(u8, noun, "entries"))
                    try std.fmt.allocPrint(self.allocator, "{d} entries limit reached. Use limit={d} for more", .{ limit, limit *| 2 })
                else
                    try std.fmt.allocPrint(self.allocator, "{d} {s} limit reached. Use limit={d} for more, or refine pattern", .{ limit, noun, limit *| 2 });
                defer self.allocator.free(formatted);
                try self.lines.appendSlice(self.allocator, formatted);
                has_notice = true;
            }
            if (truncated) {
                if (has_notice) try self.lines.appendSlice(self.allocator, ". ");
                try self.lines.appendSlice(self.allocator, "50.0KB limit reached");
                has_notice = true;
            }
            if (line_truncated) {
                if (has_notice) try self.lines.appendSlice(self.allocator, ". ");
                try self.lines.appendSlice(self.allocator, "Some lines truncated to 500 chars. Use read tool to see full lines");
            }
            try self.lines.append(self.allocator, ']');
        }
        return .{ .text = try self.lines.toOwnedSlice(self.allocator), .limited = truncated or limited, .matches = count };
    }
};

pub fn grep(a: std.mem.Allocator, io: std.Io, options: GrepOptions) !Result {
    if (options.pattern.len == 0) return error.EmptyPattern;
    if (options.pattern.len > 4096 or options.context > 10000 or options.limit > 100000) return error.SearchLimitTooLarge;
    try validateText(options.pattern);
    const root = try absolute(a, io, options.path);
    defer a.free(root);
    const stat = try std.Io.Dir.cwd().statFile(io, root, .{});
    const directory = stat.kind == .directory;
    const cwd = if (directory) root else std.fs.path.dirname(root) orelse "/";
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "rg", "--no-config", "--json", "--line-number", "--color=never", "--hidden" });
    if (options.ignore_case) try argv.append(a, "--ignore-case");
    if (options.literal) try argv.append(a, "--fixed-strings");
    var glob: ?[]u8 = null;
    defer if (glob) |value| a.free(value);
    if (options.glob) |raw| {
        try validateText(raw);
        const negated = std.mem.startsWith(u8, raw, "!");
        const clean = stripDot(if (negated) raw[1..] else raw);
        glob = try std.mem.concat(a, u8, &.{ if (negated) "!" else "", clean });
        try argv.appendSlice(a, &.{ "--glob", glob.? });
    }
    const context = try std.fmt.allocPrint(a, "{d}", .{options.context});
    defer a.free(context);
    if (options.context > 0) try argv.appendSlice(a, &.{ "--context", context });
    try argv.appendSlice(a, &.{ "--", options.pattern, if (directory) "." else root });
    const result = runProcess(a, io, argv.items, cwd, options.sandbox) catch |err| {
        if (err == error.FileNotFound) return error.RipgrepNotInstalled;
        return err;
    };
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited > 1) return error.RipgrepFailed;
    return formatGrep(a, result.stdout, @max(options.limit, 1), options.context, directory);
}

pub fn formatGrep(a: std.mem.Allocator, records: []const u8, limit: usize, context: usize, directory: bool) !Result {
    if (limit == 0) return error.InvalidSearchLimit;
    var output = Output{ .allocator = a };
    errdefer output.lines.deinit(a);
    var count: usize = 0;
    var limit_reached = false;
    var lines_truncated = false;
    var last_file: ?[]u8 = null;
    defer if (last_file) |name| a.free(name);
    var trailing_end: u64 = 0;
    var iterator = std.mem.splitScalar(u8, records, '\n');
    while (iterator.next()) |raw| {
        if (raw.len == 0) continue;
        var record = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return error.InvalidSearchRecord;
        defer record.deinit();
        const kind = try str(try field(record.value, "type"));
        const matched = std.mem.eql(u8, kind, "match");
        if (!matched and !std.mem.eql(u8, kind, "context")) continue;
        const data = try field(record.value, "data");
        const file_path = try decodeText(a, try field(data, "path"));
        defer a.free(file_path);
        const raw_line = try decodeText(a, try field(data, "lines"));
        defer a.free(raw_line);
        const value = try field(data, "line_number");
        if (value != .integer or value.integer < 1) return error.InvalidSearchRecord;
        const line_number: u64 = @intCast(value.integer);
        var show_as_match = matched;
        if (count >= limit) {
            const trailing_context = if (last_file) |last| std.mem.eql(u8, last, file_path) and line_number <= trailing_end else false;
            if (matched) limit_reached = true;
            if (!trailing_context) {
                if (limit_reached) break;
                continue;
            }
            show_as_match = false;
        } else if (matched) {
            count += 1;
            if (count == limit) {
                last_file = try a.dupe(u8, file_path);
                trailing_end = line_number +| context;
            }
        }
        var line = raw_line;
        if (std.mem.endsWith(u8, line, "\n")) line = line[0 .. line.len - 1];
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        const end = utf16Prefix(line, 500);
        lines_truncated = lines_truncated or end < line.len;
        const display_path = if (directory) stripDot(file_path) else std.fs.path.basename(file_path);
        const rendered = if (show_as_match)
            try std.fmt.allocPrint(a, "{s}:{d}: {s}{s}", .{ display_path, line_number, line[0..end], if (end < line.len) "... [truncated]" else "" })
        else
            try std.fmt.allocPrint(a, "{s}-{d}- {s}{s}", .{ display_path, line_number, line[0..end], if (end < line.len) "... [truncated]" else "" });
        defer a.free(rendered);
        try output.append(rendered);
        if (limit_reached and line_number >= trailing_end) break;
    }
    if (count == 0) try output.append("No matches found");
    return output.finish(count, limit, limit_reached, "matches", lines_truncated);
}

pub fn find(a: std.mem.Allocator, io: std.Io, options: FindOptions) !Result {
    if (options.pattern.len == 0) return error.EmptyPattern;
    if (options.pattern.len > 4096 or options.limit > 100000) return error.SearchLimitTooLarge;
    try validateText(options.pattern);
    const root = try absolute(a, io, options.path);
    defer a.free(root);
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    directory.close(io);
    const pattern = stripDot(options.pattern);
    const has_path = std.mem.indexOfScalar(u8, pattern, '/') != null;
    const is_absolute = std.fs.path.isAbsolute(pattern);
    const escaped_root = try escapeGlob(a, std.mem.trimEnd(u8, root, "/"));
    defer a.free(escaped_root);
    const effective = if (has_path and !is_absolute) try std.fmt.allocPrint(a, "{s}/{s}", .{ escaped_root, pattern }) else try a.dupe(u8, pattern);
    defer a.free(effective);
    const limit = @max(options.limit, 1);
    const max_results = try std.fmt.allocPrint(a, "{d}", .{limit + 1});
    defer a.free(max_results);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "fd", "--color=never", "--hidden", "--print0" });
    if (!try insideGit(a, io, root)) try argv.append(a, "--no-require-git");
    try argv.appendSlice(a, &.{ "--glob", "--max-results", max_results });
    if (has_path) try argv.append(a, "--full-path");
    if (has_path and !is_absolute and allLower(pattern)) try argv.append(a, "--ignore-case");
    try argv.appendSlice(a, &.{ "--", effective, root });
    const result = runProcess(a, io, argv.items, root, options.sandbox) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        argv.items[0] = "fdfind";
        break :blk runProcess(a, io, argv.items, root, options.sandbox) catch |fallback_err| {
            if (fallback_err == error.FileNotFound) return error.FdNotInstalled;
            return fallback_err;
        };
    };
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (!result.term.success()) return error.FdFailed;
    var output = Output{ .allocator = a };
    errdefer output.lines.deinit(a);
    var paths = std.mem.splitScalar(u8, result.stdout, 0);
    var count: usize = 0;
    var limited = false;
    while (paths.next()) |raw_path| {
        if (raw_path.len == 0) continue;
        if (count == limit) {
            limited = true;
            break;
        }
        const relative = try std.fs.path.relativeAlloc(a, root, null, root, std.mem.trimEnd(u8, raw_path, "/"));
        defer a.free(relative);
        const rendered = try std.mem.concat(a, u8, &.{ relative, if (std.mem.endsWith(u8, raw_path, "/")) "/" else "" });
        defer a.free(rendered);
        try output.append(rendered);
        count += 1;
    }
    if (count == 0) try output.append("No files found matching pattern");
    return output.finish(count, limit, limited, "results", false);
}

pub fn ls(a: std.mem.Allocator, io: std.Io, options: LsOptions) !Result {
    const directory = try std.Io.Dir.cwd().openDir(io, options.path, .{ .iterate = true });
    defer directory.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (names.items.len >= 100000) return error.DirectoryTooLarge;
        const name = try a.dupe(u8, entry.name);
        errdefer a.free(name);
        try names.append(a, name);
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, left: []u8, right: []u8) bool {
            const order = std.ascii.orderIgnoreCase(left, right);
            return order == .lt or (order == .eq and std.mem.order(u8, left, right) == .lt);
        }
    }.less);
    var output = Output{ .allocator = a };
    errdefer output.lines.deinit(a);
    var count: usize = 0;
    var limited = false;
    const limit = @max(options.limit, 1);
    for (names.items) |name| {
        const stat = directory.statFile(io, name, .{}) catch continue;
        if (count == limit) {
            limited = true;
            break;
        }
        const rendered = try std.mem.concat(a, u8, &.{ name, if (stat.kind == .directory) "/" else "" });
        defer a.free(rendered);
        try output.append(rendered);
        count += 1;
    }
    if (count == 0) try output.append("(empty directory)");
    return output.finish(count, limit, limited, "entries", false);
}

test "installed search binaries honor ignore rules, anchored globs and literal flags" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git");
    try tmp.dir.createDirPath(std.testing.io, "src/nested");
    try tmp.dir.createDirPath(std.testing.io, "pkg/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored.txt", .data = "needle\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/a.ts", .data = "before\nneedle a\nafter\nneedle b\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/src/b.ts", .data = "needle other\n" });
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(path);
    const searched = grep(a, std.testing.io, .{ .path = path, .pattern = "needle", .glob = "./src/*.ts", .context = 1, .limit = 1 }) catch |err| {
        if (err == error.RipgrepNotInstalled) return error.SkipZigTest;
        return err;
    };
    defer a.free(searched.text);
    try std.testing.expectEqual(@as(usize, 1), searched.matches);
    try std.testing.expect(searched.limited);
    try std.testing.expect(std.mem.startsWith(u8, searched.text, "src/a.ts-1- before\nsrc/a.ts:2: needle a\nsrc/a.ts-3- after"));
    try std.testing.expect(std.mem.indexOf(u8, searched.text, "ignored.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, searched.text, "pkg/src") == null);
    const flag_pattern = try grep(a, std.testing.io, .{ .path = path, .pattern = "--pre=touch marker", .literal = true });
    defer a.free(flag_pattern.text);
    try std.testing.expectEqualStrings("No matches found", flag_pattern.text);
    const found = find(a, std.testing.io, .{ .path = path, .pattern = "src/*.ts" }) catch |err| {
        if (err == error.FdNotInstalled) return error.SkipZigTest;
        return err;
    };
    defer a.free(found.text);
    try std.testing.expectEqualStrings("src/a.ts", found.text);
    const ignored = try find(a, std.testing.io, .{ .path = path, .pattern = "*.txt" });
    defer a.free(ignored.text);
    try std.testing.expectEqualStrings("No files found matching pattern", ignored.text);
}

test "grep keeps trailing context and reports limits only when exceeded" {
    const records =
        "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"./a\"},\"lines\":{\"text\":\"first\\n\"},\"line_number\":1}}\n" ++
        "{\"type\":\"context\",\"data\":{\"path\":{\"text\":\"./a\"},\"lines\":{\"text\":\"after\\n\"},\"line_number\":2}}\n" ++
        "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"./b\"},\"lines\":{\"text\":\"second\\n\"},\"line_number\":1}}\n";
    const a = std.testing.allocator;
    const capped = try formatGrep(a, records, 1, 1, true);
    defer a.free(capped.text);
    try std.testing.expectEqualStrings("a:1: first\na-2- after\n\n[1 matches limit reached. Use limit=2 for more, or refine pattern]", capped.text);
    const exact = try formatGrep(a, records, 2, 0, true);
    defer a.free(exact.text);
    try std.testing.expect(!exact.limited);
    try std.testing.expect(std.mem.indexOf(u8, exact.text, "limit reached") == null);
}

fn absolute(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    try validateText(path);
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    return std.fs.path.resolveAlloc(a, &.{ cwd, path });
}
fn validateText(text: []const u8) !void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSearchArgument;
}
fn stripDot(text: []const u8) []const u8 {
    var result = text;
    while (std.mem.startsWith(u8, result, "./")) result = result[2..];
    return result;
}
fn allLower(text: []const u8) bool {
    for (text) |c| if (std.ascii.isUpper(c)) return false;
    return true;
}
fn escapeGlob(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, "\\*?[]{}", c) != null) try result.append(a, '\\');
        try result.append(a, c);
    }
    return result.toOwnedSlice(a);
}
fn insideGit(a: std.mem.Allocator, io: std.Io, root: []const u8) !bool {
    var current = root;
    while (true) {
        const candidate = try std.fs.path.join(a, &.{ current, ".git" });
        defer a.free(candidate);
        _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| {
            if (err != error.FileNotFound and err != error.NotDir) return err;
            const parent = std.fs.path.dirname(current) orelse return false;
            if (std.mem.eql(u8, parent, current)) return false;
            current = parent;
            continue;
        };
        return true;
    }
}
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidSearchRecord;
    return value.object.get(name) orelse error.InvalidSearchRecord;
}
fn str(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidSearchRecord;
    return value.string;
}
fn decodeText(a: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (value != .object) return error.InvalidSearchRecord;
    if (value.object.get("text")) |text| return a.dupe(u8, try str(text));
    const encoded = try str(try field(value, "bytes"));
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try a.alloc(u8, size);
    errdefer a.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.NonUtf8SearchResult;
    return decoded;
}
fn utf16Prefix(text: []const u8, max_units: usize) usize {
    var pos: usize = 0;
    var units: usize = 0;
    while (pos < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[pos]) catch return pos;
        if (size > text.len - pos) return pos;
        const cp = std.unicode.utf8Decode(text[pos..][0..size]) catch return pos;
        const width: usize = if (cp > 0xffff) 2 else 1;
        if (units + width > max_units) break;
        units += width;
        pos += size;
    }
    return pos;
}

test "directory listing includes hidden files and directory suffixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "z.txt", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "A", .default_dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(path);
    const result = try ls(std.testing.allocator, std.testing.io, .{ .path = path });
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqualStrings(".hidden\nA/\nz.txt", result.text);
}
