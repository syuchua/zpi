//! Pi's models.json syntax subset: leading UTF-8 BOM, // comments and
//! trailing commas. Strings retain their bytes; block comments are unsupported.
const std = @import("std");

pub fn normalize(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidModelsUtf8;
    const text = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) input[3..] else input;
    const output = try allocator.dupe(u8, text);
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const byte = output[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else if (byte == '"') {
            in_string = true;
        } else if (byte == '/' and i + 1 < output.len and output[i + 1] == '/') {
            while (i < output.len and output[i] != '\n') : (i += 1) output[i] = ' ';
        }
    }
    in_string = false;
    escaped = false;
    for (output, 0..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else if (byte == '"') {
            in_string = true;
        } else if (byte == ',') {
            var next = index + 1;
            while (next < output.len and std.mem.indexOfScalar(u8, " \t\r\n", output[next]) != null) : (next += 1) {}
            if (next < output.len and (output[next] == '}' or output[next] == ']')) output[index] = ' ';
        }
    }
    return output;
}

test "models JSON syntax preserves strings while removing comments and trailing commas" {
    const input = "\xef\xbb\xbf" ++
        \\{// comment with unmatched " and ,}
        \\ "url":"https://example.invalid/v1//literal", "escaped":"quote\"//text", // comment
        \\ "values":[1, 2, // array tail
        \\ ], "literal":",}", // object tail
        \\} // EOF comment
    ;
    const normalized = try normalize(std.testing.allocator, input);
    defer std.testing.allocator.free(normalized);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, normalized, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://example.invalid/v1//literal", parsed.value.object.get("url").?.string);
    try std.testing.expectEqualStrings("quote\"//text", parsed.value.object.get("escaped").?.string);
    try std.testing.expectEqualStrings(",}", parsed.value.object.get("literal").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("values").?.array.items.len);
}

test "models JSON syntax leaves malformed JSON for the parser to reject" {
    for ([_][]const u8{ "{/* block */\"x\":1}", "{\"x\":1,,}", "{\"x\":\"unterminated // text}", "[1 2,]" }) |input| {
        const normalized = try normalize(std.testing.allocator, input);
        defer std.testing.allocator.free(normalized);
        if (std.json.parseFromSlice(std.json.Value, std.testing.allocator, normalized, .{})) |parsed| {
            parsed.deinit();
            return error.ExpectedInvalidJson;
        } else |err| {
            try std.testing.expect(err == error.SyntaxError or err == error.UnexpectedEndOfInput);
        }
    }
    try std.testing.expectError(error.InvalidModelsUtf8, normalize(std.testing.allocator, "\xff"));
}
