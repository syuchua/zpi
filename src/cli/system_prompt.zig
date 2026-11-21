//! Explicit system prompt inputs; no automatic project resource discovery.
const std = @import("std");
pub const default_prompt = "You are a coding assistant. Use the available tools when needed. Read files before editing. Tool paths resolve from the working directory; do not assume a sandbox. Report results truthfully and concisely.";
pub const max_bytes = 1024 * 1024;

/// Existing paths load UTF-8 file content with BOM removal; other inputs are
/// literal text. Relative paths and `~` resolve from launch cwd and home.
pub fn resolve(a: std.mem.Allocator, io: std.Io, cwd: []const u8, home: ?[]const u8, input: []const u8) ![]u8 {
    if (input.len > max_bytes) return error.SystemPromptTooLarge;
    if (!std.unicode.utf8ValidateSlice(input) or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidSystemPrompt;
    if (input.len == 0) return a.dupe(u8, "");
    const expanded = if (std.mem.eql(u8, input, "~")) try a.dupe(u8, home orelse return error.MissingHome) else if (std.mem.startsWith(u8, input, "~/")) try std.fs.path.join(a, &.{ home orelse return error.MissingHome, input[2..] }) else try a.dupe(u8, input);
    defer a.free(expanded);
    const path = try std.fs.path.resolveAlloc(a, &.{ cwd, expanded });
    defer a.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NameTooLong, error.NotDir => return a.dupe(u8, input),
        else => return err,
    };
    if (stat.kind != .file) return error.SystemPromptNotRegularFile;
    if (stat.size > max_bytes) return error.SystemPromptTooLarge;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.SystemPromptTooLarge,
        else => return err,
    };
    defer a.free(bytes);
    if (bytes.len > max_bytes) return error.SystemPromptTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidSystemPrompt;
    return a.dupe(u8, if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes);
}

/// Compose already resolved text without interpreting it as another path.
pub fn compose(a: std.mem.Allocator, base: []const u8, additions: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try append(a, &out, base);
    for (additions) |text| {
        if (text.len == 0) continue;
        if (out.items.len > 0) try append(a, &out, "\n\n");
        try append(a, &out, text);
    }
    return out.toOwnedSlice(a);
}
fn append(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len > max_bytes - out.items.len) return error.SystemPromptTooLarge;
    try out.appendSlice(a, text);
}

test "explicit system prompt resolves paths and literals then composes additions" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const dir = try std.fs.path.resolveAlloc(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "instructions.md", .data = "\xef\xbb\xbf规则" });
    const from_file = try resolve(a, std.testing.io, dir, dir, "instructions.md");
    defer a.free(from_file);
    try std.testing.expectEqualStrings("规则", from_file);
    const from_home = try resolve(a, std.testing.io, dir, dir, "~/instructions.md");
    defer a.free(from_home);
    try std.testing.expectEqualStrings("规则", from_home);
    const literal = try resolve(a, std.testing.io, dir, dir, "missing.md");
    defer a.free(literal);
    try std.testing.expectEqualStrings("missing.md", literal);
    const prompt = try compose(a, "base", &.{ "first", "second" });
    defer a.free(prompt);
    try std.testing.expectEqualStrings("base\n\nfirst\n\nsecond", prompt);
    try std.testing.expectError(error.SystemPromptNotRegularFile, resolve(a, std.testing.io, dir, dir, "."));
    try std.testing.expectError(error.MissingHome, resolve(a, std.testing.io, dir, null, "~/missing.md"));
}

test "system prompts reject invalid files and excessive composed content" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const dir = try std.fs.path.resolveAlloc(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary", .data = "bad\x00text" });
    try std.testing.expectError(error.InvalidSystemPrompt, resolve(a, std.testing.io, dir, null, "binary"));
    const large = try a.alloc(u8, max_bytes);
    defer a.free(large);
    @memset(large, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large", .data = large });
    const at_limit = try resolve(a, std.testing.io, dir, null, "large");
    defer a.free(at_limit);
    try std.testing.expectEqual(max_bytes, at_limit.len);
    try std.testing.expectError(error.SystemPromptTooLarge, compose(a, "base", &.{large}));
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.SystemPromptTooLarge, resolve(a, std.testing.io, dir, null, oversized));
}
