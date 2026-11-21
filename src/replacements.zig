//! Exact replacements use original-file coordinates. Validate the whole batch
//! before constructing output; callers write only after apply succeeds.
const std = @import("std");

pub const Edit = struct { oldText: []const u8, newText: []const u8 };
const Match = struct { start: usize, end: usize, replacement: []const u8 };
pub const ApplyResult = struct {
    content: []u8,
    diff: []u8,
    first_changed_line: ?usize,
};
pub const max_file_bytes = 8 * 1024 * 1024;
pub const max_edits = 1024;
const diff_context_lines = 4;
const max_diff_bytes = 32 * 1024;

pub fn apply(allocator: std.mem.Allocator, original: []const u8, edits: []const Edit) ![]u8 {
    const result = try applyWithDiff(allocator, original, edits);
    allocator.free(result.diff);
    return result.content;
}

pub fn applyWithDiff(allocator: std.mem.Allocator, original: []const u8, edits: []const Edit) !ApplyResult {
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
    const diff_info = try buildDiff(allocator, original, result, matches);
    return .{ .content = result, .diff = diff_info.diff, .first_changed_line = diff_info.first_changed_line };
}

const LineSlice = struct { start: usize, end: usize };

fn splitLineSlices(allocator: std.mem.Allocator, text: []const u8) ![]LineSlice {
    if (text.len == 0) return allocator.alloc(LineSlice, 0);
    const trimmed_len = if (text[text.len - 1] == '\n') text.len - 1 else text.len;
    if (trimmed_len == 0) {
        const list = try allocator.alloc(LineSlice, 1);
        list[0] = .{ .start = 0, .end = 0 };
        return list;
    }
    var count: usize = 1;
    for (text[0..trimmed_len]) |b| {
        if (b == '\n') count += 1;
    }
    var list = try allocator.alloc(LineSlice, count);
    var idx: usize = 0;
    var start: usize = 0;
    for (text[0..trimmed_len], 0..) |b, i| {
        if (b == '\n') {
            list[idx] = .{ .start = start, .end = i };
            idx += 1;
            start = i + 1;
        }
    }
    list[idx] = .{ .start = start, .end = trimmed_len };
    return list;
}

fn lineIndexAtOffset(lines: []const LineSlice, offset: usize) usize {
    if (lines.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = lines.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid].start <= offset) lo = mid else hi = mid;
    }
    return lo;
}

const ChangeRange = struct {
    old_start: usize, // 0-based inclusive line index in original
    old_end: usize, // 0-based exclusive line index in original
    new_start: usize, // 0-based inclusive line index in result
    new_end: usize, // 0-based exclusive line index in result
};

fn buildDiff(allocator: std.mem.Allocator, original: []const u8, updated: []const u8, matches: []const Match) !struct { diff: []u8, first_changed_line: ?usize } {
    const old_lines = try splitLineSlices(allocator, original);
    defer allocator.free(old_lines);
    const new_lines = try splitLineSlices(allocator, updated);
    defer allocator.free(new_lines);

    var raw_changes: std.ArrayList(ChangeRange) = .empty;
    defer raw_changes.deinit(allocator);

    var offset_delta: isize = 0;
    for (matches) |match| {
        const new_start_off: usize = @intCast(@as(isize, @intCast(match.start)) + offset_delta);
        const new_end_off = new_start_off + match.replacement.len;
        offset_delta += @as(isize, @intCast(match.replacement.len)) - @as(isize, @intCast(match.end - match.start));

        const old_first = lineIndexAtOffset(old_lines, match.start);
        const old_last_byte = if (match.end > match.start) match.end - 1 else match.start;
        const old_last = if (old_lines.len == 0) 0 else lineIndexAtOffset(old_lines, @min(old_last_byte, original.len)) + 1;

        const new_first = lineIndexAtOffset(new_lines, new_start_off);
        const new_last_byte = if (new_end_off > new_start_off) new_end_off - 1 else new_start_off;
        const new_last = if (new_lines.len == 0) 0 else lineIndexAtOffset(new_lines, @min(new_last_byte, updated.len)) + 1;

        var c = ChangeRange{
            .old_start = old_first,
            .old_end = @max(old_first, old_last),
            .new_start = new_first,
            .new_end = @max(new_first, new_last),
        };

        // Trim identical leading and trailing lines inside the affected line range.
        while (c.old_start < c.old_end and c.new_start < c.new_end) {
            const o = std.mem.trimEnd(u8, original[old_lines[c.old_start].start..old_lines[c.old_start].end], "\r");
            const n = std.mem.trimEnd(u8, updated[new_lines[c.new_start].start..new_lines[c.new_start].end], "\r");
            if (!std.mem.eql(u8, o, n)) break;
            c.old_start += 1;
            c.new_start += 1;
        }
        while (c.old_start < c.old_end and c.new_start < c.new_end) {
            const o = std.mem.trimEnd(u8, original[old_lines[c.old_end - 1].start..old_lines[c.old_end - 1].end], "\r");
            const n = std.mem.trimEnd(u8, updated[new_lines[c.new_end - 1].start..new_lines[c.new_end - 1].end], "\r");
            if (!std.mem.eql(u8, o, n)) break;
            c.old_end -= 1;
            c.new_end -= 1;
        }
        if (c.old_start == c.old_end and c.new_start == c.new_end) continue;

        if (raw_changes.items.len > 0) {
            const prev = &raw_changes.items[raw_changes.items.len - 1];
            if (c.old_start <= prev.old_end or c.new_start <= prev.new_end) {
                prev.old_end = @max(prev.old_end, c.old_end);
                prev.new_end = @max(prev.new_end, c.new_end);
                continue;
            }
        }
        try raw_changes.append(allocator, c);
    }

    if (raw_changes.items.len == 0) {
        return .{ .diff = try allocator.dupe(u8, ""), .first_changed_line = null };
    }

    const first_changed_line: usize = raw_changes.items[0].new_start + 1;
    var max_line_num: usize = 1;
    for (raw_changes.items) |c| {
        const ctx_old_end = @min(old_lines.len, c.old_end + diff_context_lines);
        const ctx_new_end = @min(new_lines.len, c.new_end + diff_context_lines);
        max_line_num = @max(max_line_num, @max(ctx_old_end, ctx_new_end));
    }
    var width: usize = 1;
    var tmp = max_line_num;
    while (tmp >= 10) : (tmp /= 10) width += 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var truncated = false;

    var i: usize = 0;
    while (i < raw_changes.items.len and !truncated) {
        const hunk_ctx_old_start = raw_changes.items[i].old_start -| diff_context_lines;
        var j = i;
        while (j + 1 < raw_changes.items.len) {
            const cur_ctx_end = @min(old_lines.len, raw_changes.items[j].old_end + diff_context_lines);
            const next_ctx_start = raw_changes.items[j + 1].old_start -| diff_context_lines;
            if (next_ctx_start <= cur_ctx_end) {
                j += 1;
            } else break;
        }
        const hunk_ctx_old_end = @min(old_lines.len, raw_changes.items[j].old_end + diff_context_lines);

        if (i > 0) try appendDiffLine(&out, allocator, " ...", &truncated);

        var old_cur = hunk_ctx_old_start;
        for (raw_changes.items[i .. j + 1]) |c| {
            while (old_cur < c.old_start and !truncated) : (old_cur += 1) {
                const text = std.mem.trimEnd(u8, original[old_lines[old_cur].start..old_lines[old_cur].end], "\r");
                try appendNumberedDiffLine(&out, allocator, ' ', old_cur + 1, width, text, &truncated);
            }
            var o = c.old_start;
            while (o < c.old_end and !truncated) : (o += 1) {
                const text = std.mem.trimEnd(u8, original[old_lines[o].start..old_lines[o].end], "\r");
                try appendNumberedDiffLine(&out, allocator, '-', o + 1, width, text, &truncated);
            }
            var n = c.new_start;
            while (n < c.new_end and !truncated) : (n += 1) {
                const text = std.mem.trimEnd(u8, updated[new_lines[n].start..new_lines[n].end], "\r");
                try appendNumberedDiffLine(&out, allocator, '+', n + 1, width, text, &truncated);
            }
            old_cur = c.old_end;
        }
        while (old_cur < hunk_ctx_old_end and !truncated) : (old_cur += 1) {
            const text = std.mem.trimEnd(u8, original[old_lines[old_cur].start..old_lines[old_cur].end], "\r");
            try appendNumberedDiffLine(&out, allocator, ' ', old_cur + 1, width, text, &truncated);
        }
        i = j + 1;
    }

    if (truncated) {
        try out.appendSlice(allocator, "\n... (diff truncated)");
    }
    return .{ .diff = try out.toOwnedSlice(allocator), .first_changed_line = first_changed_line };
}

fn appendDiffLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8, truncated: *bool) !void {
    const add_len = line.len + @intFromBool(out.items.len > 0);
    if (out.items.len + add_len > max_diff_bytes) {
        truncated.* = true;
        return;
    }
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, line);
}

fn appendNumberedDiffLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: u8, line_num: usize, width: usize, text: []const u8, truncated: *bool) !void {
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch unreachable;
    const pad = width -| num_str.len;
    const line_len = 1 + pad + num_str.len + 1 + text.len;
    const add_len = line_len + @intFromBool(out.items.len > 0);
    if (out.items.len + add_len > max_diff_bytes) {
        truncated.* = true;
        return;
    }
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.append(allocator, prefix);
    for (0..pad) |_| try out.append(allocator, ' ');
    try out.appendSlice(allocator, num_str);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, text);
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

test "applyWithDiff formats numbered hunks trims unchanged edges and tracks firstChangedLine" {
    const a = std.testing.allocator;
    const single = try applyWithDiff(a, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", &.{.{ .oldText = "5\n6\n7", .newText = "5\nSIX\n7" }});
    defer {
        a.free(single.content);
        a.free(single.diff);
    }
    try std.testing.expectEqual(@as(?usize, 6), single.first_changed_line);
    try std.testing.expectEqualStrings(
        "  2 2\n  3 3\n  4 4\n  5 5\n- 6 6\n+ 6 SIX\n  7 7\n  8 8\n  9 9\n 10 10",
        single.diff,
    );

    const multi = try applyWithDiff(
        a,
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\n",
        &.{
            .{ .oldText = "l2", .newText = "L2" },
            .{ .oldText = "l14", .newText = "L14" },
        },
    );
    defer {
        a.free(multi.content);
        a.free(multi.diff);
    }
    try std.testing.expectEqual(@as(?usize, 2), multi.first_changed_line);
    try std.testing.expect(std.mem.indexOf(u8, multi.diff, " ...") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi.diff, "- 2 l2\n+ 2 L2") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi.diff, "-14 l14\n+14 L14") != null);
}
