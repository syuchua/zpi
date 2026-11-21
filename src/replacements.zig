//! Exact replacements use original-file coordinates. Validate the whole batch
//! before constructing output; callers write only after apply succeeds.
const std = @import("std");

pub const Edit = struct { oldText: []const u8, newText: []const u8 };
const Match = struct { start: usize, end: usize, replacement: []const u8 };
pub const max_file_bytes = 8 * 1024 * 1024;
pub const max_edits = 1024;

pub fn apply(allocator: std.mem.Allocator, original: []const u8, edits: []const Edit) ![]u8 {
    if (edits.len == 0) return error.EmptyEdits;
    if (edits.len > max_edits) return error.TooManyEdits;
    if (original.len > max_file_bytes) return error.FileTooLarge;
    const matches = try allocator.alloc(Match, edits.len);
    defer allocator.free(matches);
    for (edits, matches) |edit, *match| {
        if (edit.oldText.len == 0) return error.EmptyMatch;
        const start = std.mem.indexOf(u8, original, edit.oldText) orelse return error.MatchNotFound;
        if (std.mem.indexOf(u8, original[start + 1 ..], edit.oldText) != null) return error.AmbiguousMatch;
        match.* = .{ .start = start, .end = start + edit.oldText.len, .replacement = edit.newText };
    }
    std.mem.sort(Match, matches, {}, struct {
        fn less(_: void, left: Match, right: Match) bool {
            return left.start < right.start;
        }
    }.less);
    for (matches[1..], matches[0 .. matches.len - 1]) |current, previous| {
        if (current.start < previous.end) return error.OverlappingEdits;
    }
    var size = original.len;
    // Compute from disjoint ranges only, so duplicate/overlapping edits cannot
    // underflow size before their actual validation error is reported.
    for (matches) |match| {
        size -= match.end - match.start;
    }
    for (matches) |match| size = std.math.add(usize, size, match.replacement.len) catch return error.FileTooLarge;
    if (size > max_file_bytes) return error.FileTooLarge;
    const result = try allocator.alloc(u8, size);
    errdefer allocator.free(result);
    var source: usize = 0;
    var destination: usize = 0;
    for (matches) |match| {
        const unchanged = original[source..match.start];
        @memcpy(result[destination..][0..unchanged.len], unchanged);
        destination += unchanged.len;
        @memcpy(result[destination..][0..match.replacement.len], match.replacement);
        destination += match.replacement.len;
        source = match.end;
    }
    @memcpy(result[destination..], original[source..]);
    if (std.mem.eql(u8, original, result)) return error.NoChange;
    return result;
}

test "replacement order uses original positions, including adjacent ranges" {
    const a = std.testing.allocator;
    const output = try apply(a, "alpha beta gamma", &.{
        .{ .oldText = "gamma", .newText = "alpha" },
        .{ .oldText = "alpha", .newText = "gamma" },
        .{ .oldText = " beta ", .newText = " / " },
    });
    defer a.free(output);
    try std.testing.expectEqualStrings("gamma / alpha", output);
}

test "overlapping nested duplicate and newly introduced matches fail" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.OverlappingEdits, apply(a, "abcdef", &.{
        .{ .oldText = "abcd", .newText = "x" }, .{ .oldText = "cd", .newText = "y" },
    }));
    try std.testing.expectError(error.OverlappingEdits, apply(a, "abcdef", &.{
        .{ .oldText = "abc", .newText = "x" }, .{ .oldText = "abc", .newText = "y" },
    }));
    try std.testing.expectError(error.AmbiguousMatch, apply(a, "aaa", &.{.{ .oldText = "aa", .newText = "b" }}));
    try std.testing.expectError(error.MatchNotFound, apply(a, "alpha", &.{
        .{ .oldText = "alpha", .newText = "beta" }, .{ .oldText = "beta", .newText = "gamma" },
    }));
}

test "no-op empty inputs and byte-preserving CRLF BOM UTF8 handling" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyEdits, apply(a, "a", &.{}));
    try std.testing.expectError(error.EmptyMatch, apply(a, "a", &.{.{ .oldText = "", .newText = "b" }}));
    try std.testing.expectError(error.NoChange, apply(a, "a", &.{.{ .oldText = "a", .newText = "a" }}));
    const output = try apply(a, "\xef\xbb\xbf你好\r\nworld\r\n", &.{.{ .oldText = "world", .newText = "Zig" }});
    defer a.free(output);
    try std.testing.expectEqualStrings("\xef\xbb\xbf你好\r\nZig\r\n", output);
}
