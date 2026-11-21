//! Invocation-local Markdown templates. Expansion treats both body and arguments as text.
const std = @import("std");

const max_templates = 256;
const max_entries = 16 * 1024;
const max_file_bytes = 256 * 1024;
const max_frontmatter_bytes = 16 * 1024;
const max_expansion_bytes = 1024 * 1024;
const whitespace = " \t\r\n\x0b\x0c";

pub const Template = struct { name: []const u8, body: []const u8 };

pub const Options = struct {
    launch_cwd: []const u8,
    project_cwd: []const u8,
    home: ?[]const u8 = null,
    agent_dir: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    defaults: bool = true,
    trust_project: bool = false,
};

/// Results belong to the invocation arena.
pub fn discover(a: std.mem.Allocator, io: std.Io, options: Options) ![]const Template {
    var loader = Loader{ .arena = a, .io = io };
    if (options.defaults) {
        const configured = options.agent_dir orelse "";
        const base = if (configured.len > 0)
            try resolvePath(a, options.launch_cwd, options.home, configured)
        else if (options.home) |home|
            try std.fs.path.join(a, &.{ home, ".zpi", "agent" })
        else
            null;
        if (base) |dir| try loader.scan(try std.fs.path.join(a, &.{ dir, "prompts" }));
        if (options.trust_project) try loader.scan(try std.fs.path.join(a, &.{ options.project_cwd, ".zpi", "prompts" }));
    }
    for (options.paths) |raw| {
        const path = try resolvePath(a, options.project_cwd, options.home, raw);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .file => try loader.add(std.Io.Dir.cwd(), path, std.fs.path.basename(path), true),
            .directory => try loader.scan(path),
            else => return error.InvalidPromptTemplatePath,
        }
    }
    return loader.result.toOwnedSlice(a);
}

fn resolvePath(a: std.mem.Allocator, cwd: []const u8, home: ?[]const u8, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or raw.len > 4096 or !std.unicode.utf8ValidateSlice(raw) or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPromptTemplatePath;
    if (std.mem.eql(u8, raw, "~") or std.mem.startsWith(u8, raw, "~/")) {
        return std.fs.path.resolveAlloc(a, &.{ cwd, home orelse return error.MissingHome, if (raw.len > 1) raw[2..] else "" });
    }
    return std.fs.path.resolveAlloc(a, &.{ cwd, raw });
}

const Loader = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    result: std.ArrayList(Template) = .empty,
    entries: usize = 0,

    fn scan(self: *Loader, path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            self.entries += 1;
            if (self.entries > max_entries) return error.TooManyPromptTemplateEntries;
            if (entry.kind == .file) try self.add(dir, entry.name, entry.name, false);
        }
    }

    fn add(self: *Loader, dir: std.Io.Dir, path: []const u8, basename: []const u8, explicit: bool) !void {
        const name = templateName(basename) orelse {
            if (explicit) return error.InvalidPromptTemplateName;
            return;
        };
        for (self.result.items) |existing| if (std.mem.eql(u8, existing.name, name)) return;
        if (self.result.items.len >= max_templates) return error.TooManyPromptTemplates;
        const file = dir.openFile(self.io, path, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| {
            if (explicit) return err;
            return;
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size > max_file_bytes) {
            if (explicit) return error.InvalidPromptTemplateFile;
            return;
        }
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &buffer);
        const scratch = std.heap.page_allocator;
        const bytes = reader.interface.allocRemaining(scratch, .limited(max_file_bytes + 1)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (explicit) return error.InvalidPromptTemplateFile;
                return;
            },
        };
        defer scratch.free(bytes);
        const body = (try parseBody(scratch, bytes)) orelse {
            if (explicit) return error.InvalidPromptTemplateFile;
            return;
        };
        defer scratch.free(body);
        try self.result.append(self.arena, .{ .name = try self.arena.dupe(u8, name), .body = try self.arena.dupe(u8, body) });
    }
};

fn templateName(basename: []const u8) ?[]const u8 {
    if (basename.len <= 3 or !std.mem.endsWith(u8, basename, ".md")) return null;
    const name = basename[0 .. basename.len - 3];
    if (name.len > 64) return null;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    return name;
}

fn parseBody(a: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    if (bytes.len > max_file_bytes or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
    const source = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(a);
    try normalized.ensureTotalCapacity(a, source.len);
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        normalized.appendAssumeCapacity(if (c == '\r') '\n' else c);
        if (c == '\r' and i + 1 < source.len and source[i + 1] == '\n') i += 1;
    }
    var body: []const u8 = normalized.items;
    if (std.mem.startsWith(u8, body, "---\n")) {
        const close = std.mem.indexOfPos(u8, body, 3, "\n---") orelse return null;
        if (close - 3 > max_frontmatter_bytes) return null;
        const marker_end = close + 4;
        if (marker_end < body.len and body[marker_end] != '\n') return null;
        body = if (marker_end < body.len) body[marker_end + 1 ..] else body[marker_end..];
        body = std.mem.trim(u8, body, whitespace);
    }
    return try a.dupe(u8, std.mem.trim(u8, body, whitespace));
}

pub fn expand(a: std.mem.Allocator, text: []const u8, templates: []const Template) !?[]u8 {
    if (text.len < 2 or text[0] != '/') return null;
    const end = std.mem.indexOfAnyPos(u8, text, 1, whitespace) orelse text.len;
    for (templates) |template| {
        if (!std.mem.eql(u8, template.name, text[1..end])) continue;
        if (text.len - end > max_expansion_bytes) return error.PromptTemplateExpansionTooLarge;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const args = try parseArgs(arena.allocator(), text[end..]);
        return try substitute(a, template.body, args);
    }
    return null;
}

/// Quotes only open a token. An unmatched opener is replayed as literal text.
fn parseArgs(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| a.free(arg);
        args.deinit(a);
    }
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(a);
    var has_token = false;
    var quote: u8 = 0;
    var quote_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == '\\' and i + 1 < text.len and text[i + 1] == quote) {
                try token.append(a, quote);
                i += 1;
            } else if (c == quote) {
                quote = 0;
            } else try token.append(a, c);
        } else if ((c == '"' or c == '\'') and !has_token) {
            quote = c;
            quote_start = i;
            has_token = true;
        } else if (std.mem.indexOfScalar(u8, whitespace, c) != null) {
            if (has_token) {
                if (args.items.len >= 4096) return error.TooManyPromptTemplateArguments;
                try args.append(a, try token.toOwnedSlice(a));
                token = .empty;
                has_token = false;
            }
        } else {
            try token.append(a, c);
            has_token = true;
        }
        if (quote != 0 and i == text.len - 1) {
            quote = 0;
            token.clearRetainingCapacity();
            try token.append(a, text[quote_start]);
            i = quote_start;
        }
    }
    if (has_token) {
        if (args.items.len >= 4096) return error.TooManyPromptTemplateArguments;
        try args.append(a, try token.toOwnedSlice(a));
    }
    return args.toOwnedSlice(a);
}

const Target = union(enum) { all, position: usize };
const ParsedTarget = struct { target: Target, end: usize };

fn digits(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    return end;
}

fn decimal(text: []const u8) usize {
    return std.fmt.parseInt(usize, text, 10) catch std.math.maxInt(usize);
}

fn targetAt(text: []const u8, start: usize) ?ParsedTarget {
    if (start >= text.len) return null;
    if (text[start] == '@') return .{ .target = .all, .end = start + 1 };
    if (std.mem.startsWith(u8, text[start..], "ARGUMENTS")) return .{ .target = .all, .end = start + "ARGUMENTS".len };
    const end = digits(text, start);
    if (end == start) return null;
    return .{ .target = .{ .position = decimal(text[start..end]) }, .end = end };
}

fn substitute(a: std.mem.Allocator, body: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var no_more_closing_braces = false;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, i, '$')) |dollar| {
        try append(a, &out, body[i..dollar]);
        i = dollar + 1;
        if (i < body.len and body[i] == '{') {
            if (targetAt(body, i + 1)) |parsed| {
                const tail = body[parsed.end..];
                if (std.mem.startsWith(u8, tail, ":-")) {
                    if (!no_more_closing_braces) {
                        if (std.mem.indexOfScalarPos(u8, body, parsed.end + 2, '}')) |close| {
                            try appendTarget(a, &out, args, parsed.target, body[parsed.end + 2 .. close]);
                            i = close + 1;
                            continue;
                        }
                        no_more_closing_braces = true;
                    }
                } else if (body[i + 1] == '@' and std.mem.startsWith(u8, tail, ":")) {
                    const start = parsed.end + 1;
                    const end = digits(body, start);
                    if (end > start and end < body.len) {
                        var close = end;
                        var count: usize = args.len;
                        if (body[end] == ':') {
                            const length_end = digits(body, end + 1);
                            if (length_end > end + 1) {
                                close = length_end;
                                count = decimal(body[end + 1 .. close]);
                            }
                        }
                        if (close < body.len and body[close] == '}') {
                            const offset = @min(args.len, decimal(body[start..end]) -| 1);
                            try appendArgs(a, &out, args[offset..][0..@min(count, args.len - offset)]);
                            i = close + 1;
                            continue;
                        }
                    }
                }
            }
        } else if (targetAt(body, i)) |parsed| {
            try appendTarget(a, &out, args, parsed.target, "");
            i = parsed.end;
            continue;
        }
        try append(a, &out, "$");
    }
    try append(a, &out, body[i..]);
    return out.toOwnedSlice(a);
}

fn appendTarget(a: std.mem.Allocator, out: *std.ArrayList(u8), args: []const []const u8, target: Target, fallback: []const u8) !void {
    switch (target) {
        .all => if (args.len == 0 or (args.len == 1 and args[0].len == 0)) try append(a, out, fallback) else try appendArgs(a, out, args),
        .position => |n| {
            const value = if (n > 0 and n <= args.len) args[n - 1] else "";
            try append(a, out, if (value.len == 0) fallback else value);
        },
    }
}

fn appendArgs(a: std.mem.Allocator, out: *std.ArrayList(u8), args: []const []const u8) !void {
    for (args, 0..) |arg, i| {
        if (i != 0) try append(a, out, " ");
        try append(a, out, arg);
    }
}

fn append(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len > max_expansion_bytes - out.items.len) return error.PromptTemplateExpansionTooLarge;
    try out.appendSlice(a, text);
}

test "template quoting, slicing, defaults and literal nonrecursive arguments" {
    const a = std.testing.allocator;
    const template = Template{ .name = "review", .body = "[$1][$2][${2:-fallback}][$ARGUMENTS][${@:2:2}][${@:0:1}][${@:x}][${HOME}][${4:-$1}]" };
    const result = (try expand(a, "/review \"say \\\"hi\\\"\" \"\" '$@'", &.{template})).?;
    defer a.free(result);
    try std.testing.expectEqualStrings("[say \"hi\"][][fallback][say \"hi\"  $@][ $@][say \"hi\"][${@:x}][${HOME}][$1]", result);
    try std.testing.expect((try expand(a, "/other", &.{template})) == null);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "doesn't 'unmatched word \"quoted\"suffix");
    try std.testing.expectEqual(@as(usize, 4), args.len);
    for (args, [_][]const u8{ "doesn't", "'unmatched", "word", "quotedsuffix" }) |actual, expected| try std.testing.expectEqualStrings(expected, actual);
}

test "template substitutions preserve malformed syntax and do not evaluate nested defaults" {
    const a = std.testing.allocator;
    const result = try substitute(a, "${@:1:}|${@:1:0}|${2:-${1:-nested}}|${2:-unterminated $1 ${2:-also", &.{"one"});
    defer a.free(result);
    try std.testing.expectEqualStrings("${@:1:}||${1:-nested}|${2:-unterminated one ${2:-also", result);
}

test "template text supports BOM and exact frontmatter delimiters" {
    const a = std.testing.allocator;
    const result = (try parseBody(a, "\xef\xbb\xbf---\r\ndescription: Example\r---\r\n Hello\rworld \n")).?;
    defer a.free(result);
    try std.testing.expectEqualStrings("Hello\nworld", result);
    const empty_header = (try parseBody(a, "---\n---\nBody\n")).?;
    defer a.free(empty_header);
    try std.testing.expectEqualStrings("Body", empty_header);
    try std.testing.expect((try parseBody(a, "---\n---not a delimiter\ntext")) == null);
    try std.testing.expect((try parseBody(a, "a\x00b")) == null);
}

test "empty template body remains a valid command" {
    const a = std.testing.allocator;
    const body = (try parseBody(a, "---\ndescription: empty\n---\n")).?;
    defer a.free(body);
    try std.testing.expectEqualStrings("", body);
    try std.testing.expectEqualStrings("", (try expand(a, "/review", &.{.{ .name = "review", .body = body }})).?);
}

test "template expansion is bounded before returning output" {
    const a = std.testing.allocator;
    const arg = try a.alloc(u8, max_expansion_bytes / 2 + 1);
    defer a.free(arg);
    @memset(arg, 'x');
    try std.testing.expectError(error.PromptTemplateExpansionTooLarge, substitute(a, "$1$1", &.{arg}));
}
