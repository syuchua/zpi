//! Initial text prompt: piped stdin, explicit @files, then positional text.
//! Paths use the launching directory, independent of tool/session cwd.
const std = @import("std");

pub const max_file_bytes = 1024 * 1024;
pub const max_prompt_bytes = 4 * 1024 * 1024;

/// Caller owns the returned buffer. Attachments are UTF-8 regular files only.
/// Matches pi's text wrapper and BOM stripping; binary/image input is rejected.
pub fn build(a: std.mem.Allocator, io: std.Io, cwd: []const u8, home: ?[]const u8, stdin_text: []const u8, files: []const []const u8, words: []const []const u8) ![]u8 {
    if (files.len > 64) return error.TooManyInputFiles;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try append(a, &out, stdin_text);
    for (files) |input| {
        if (input.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null or !std.unicode.utf8ValidateSlice(input)) return error.InvalidInputFilePath;
        const expanded = if (std.mem.eql(u8, input, "~")) home orelse return error.MissingHome else if (std.mem.startsWith(u8, input, "~/")) blk: {
            break :blk try std.fs.path.join(a, &.{ home orelse return error.MissingHome, input[2..] });
        } else input;
        const owned_expansion = std.mem.startsWith(u8, input, "~/");
        defer if (owned_expansion) a.free(expanded);
        const normalized = try normalizeSpaces(a, expanded);
        defer a.free(normalized);
        const path = try std.fs.path.resolveAlloc(a, &.{ cwd, normalized });
        defer a.free(path);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        if (stat.kind != .file) return error.InputNotRegularFile;
        if (stat.size > max_file_bytes) return error.InputFileTooLarge;
        // readFileAlloc treats its limit as exclusive. Allow one sentinel
        // byte, then check the inclusive public limit even if the file grew.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => return error.InputFileTooLarge,
            else => return err,
        };
        defer a.free(bytes);
        if (bytes.len > max_file_bytes) return error.InputFileTooLarge;
        if (bytes.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null or isImage(bytes)) return error.UnsupportedInputFile;
        const text = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
        for ([_][]const u8{ "<file name=\"", path, "\">\n", text, "\n</file>\n" }) |part| try append(a, &out, part);
    }
    for (words, 0..) |word, i| {
        if (i > 0) try append(a, &out, " ");
        try append(a, &out, word);
    }
    return out.toOwnedSlice(a);
}

fn normalizeSpaces(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var codepoints = (try std.unicode.Utf8View.init(text)).iterator();
    while (codepoints.nextCodepointSlice()) |bytes| {
        const cp = try std.unicode.utf8Decode(bytes);
        if (cp == 0xa0 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x202f or cp == 0x205f or cp == 0x3000) {
            try out.append(a, ' ');
        } else {
            try out.appendSlice(a, bytes);
        }
    }
    return out.toOwnedSlice(a);
}

fn append(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len > max_prompt_bytes - out.items.len) return error.InitialPromptTooLarge;
    try out.appendSlice(a, text);
}

fn isImage(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n") or
        std.mem.startsWith(u8, bytes, "\xff\xd8\xff") or
        std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a") or
        (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"));
}

test "initial prompt preserves attachment order BOM and exact text wrappers" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const dir = try std.fs.path.resolveAlloc(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "first.txt", .data = "\xef\xbb\xbf你好\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "second.txt", .data = "two" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.txt", .data = "" });
    const prompt = try build(a, std.testing.io, dir, dir, "piped", &.{ "~/first.txt", "empty.txt", "second.txt" }, &.{ "explain", "these" });
    defer a.free(prompt);
    const expected = try std.fmt.allocPrint(a, "piped<file name=\"{s}/first.txt\">\n你好\n\n</file>\n<file name=\"{s}/second.txt\">\ntwo\n</file>\nexplain these", .{ dir, dir });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, prompt);
    try std.testing.expectError(error.FileNotFound, build(a, std.testing.io, dir, null, "", &.{"missing.txt"}, &.{}));
    try std.testing.expectError(error.InputNotRegularFile, build(a, std.testing.io, dir, null, "", &.{"."}, &.{}));
    try std.testing.expectError(error.MissingHome, build(a, std.testing.io, dir, null, "", &.{"~/first.txt"}, &.{}));
}

test "initial prompt rejects binary input and bounds combined payload before dispatch" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const dir = try std.fs.path.resolveAlloc(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(dir);
    for ([_][]const u8{ "nul\x00text", "\xff", "GIF89aimage" }) |content| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary", .data = content });
        try std.testing.expectError(error.UnsupportedInputFile, build(a, std.testing.io, dir, null, "", &.{"binary"}, &.{}));
    }
    const large = try a.alloc(u8, max_file_bytes + 1);
    defer a.free(large);
    @memset(large, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large", .data = large });
    try std.testing.expectError(error.InputFileTooLarge, build(a, std.testing.io, dir, null, "", &.{"large"}, &.{}));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large", .data = large[0..max_file_bytes] });
    const at_limit = try build(a, std.testing.io, dir, null, "", &.{"large"}, &.{});
    defer a.free(at_limit);
    try std.testing.expect(at_limit.len > max_file_bytes);
    try std.testing.expectError(error.InitialPromptTooLarge, build(a, std.testing.io, dir, null, "", &.{ "large", "large", "large", "large" }, &.{}));
}
