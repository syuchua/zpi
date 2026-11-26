//! Initial prompt text and validated image attachments, resolved from launch cwd.
const std = @import("std");
const model = @import("zpi").model;

pub const max_file_bytes = 1024 * 1024;
pub const max_prompt_bytes = 4 * 1024 * 1024;
pub const max_image_bytes = model.Image.max_message_bytes;

pub fn buildImages(a: std.mem.Allocator, io: std.Io, cwd: []const u8, home: ?[]const u8, paths: []const []const u8) ![]model.Image {
    if (paths.len > model.Image.max_message_images) return error.TooManyImages;
    var images: std.ArrayList(model.Image) = .empty;
    errdefer {
        for (images.items) |image| a.free(image.bytes);
        images.deinit(a);
    }
    var remaining: usize = model.Image.max_message_bytes;
    for (paths) |input| {
        if (input.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null or !std.unicode.utf8ValidateSlice(input)) return error.InvalidImagePath;
        const expanded = if (std.mem.eql(u8, input, "~")) home orelse return error.MissingHome else if (std.mem.startsWith(u8, input, "~/")) try std.fs.path.join(a, &.{ home orelse return error.MissingHome, input[2..] }) else input;
        defer if (std.mem.startsWith(u8, input, "~/")) a.free(expanded);
        const path = try std.fs.path.resolveAlloc(a, &.{ cwd, expanded });
        defer a.free(path);
        const dir = std.Io.Dir.cwd();
        const handle = try std.posix.openat(dir.handle, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.ImageNotRegularFile;
        if (stat.size == 0 or stat.size > model.Image.max_message_bytes) return error.InvalidImageSize;
        if (stat.size > remaining) return error.ImageAttachmentsTooLarge;
        const bytes = try a.alloc(u8, @intCast(stat.size));
        errdefer a.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len or try file.length(io) != stat.size) return error.ImageFileChanged;
        const mime_type = model.Image.detectMime(bytes) orelse return error.UnsupportedImageType;
        try images.append(a, .{ .bytes = bytes, .mime_type = mime_type });
        remaining -= bytes.len;
    }
    return images.toOwnedSlice(a);
}

/// Caller owns the returned text. Paths use the launch directory, independently of --cwd.
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
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null or model.Image.detectMime(bytes) != null) return error.UnsupportedInputFile;
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
    try std.testing.expectEqualStrings("image/png", model.Image.detectMime("\x89PNG\r\n\x1a\nbytes").?);
    try std.testing.expectEqualStrings("image/jpeg", model.Image.detectMime("\xff\xd8\xffbytes").?);
    try std.testing.expectEqualStrings("image/gif", model.Image.detectMime("GIF89a").?);
    try std.testing.expectEqualStrings("image/webp", model.Image.detectMime("RIFF1234WEBP").?);
    try std.testing.expect(model.Image.detectMime("not an image") == null);
    try std.testing.expectError(error.InitialPromptTooLarge, build(a, std.testing.io, dir, null, "", &.{ "large", "large", "large", "large" }, &.{}));
}
