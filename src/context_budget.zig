//! Character-based output budget subset. Counts UTF-16 code units like pi.
//! Caller supplies the projected active context.
const std = @import("std");
const model = @import("model");

pub const context_safety_tokens: u64 = 4096;
pub const context_safety_ratio_percent: u64 = 15;
pub const min_output_with_ratio_margin: u64 = 32768;
pub const min_max_tokens: u64 = 1;

fn saturatingAdd(a: u64, b: u64) u64 {
    return a +| b;
}

fn charsToTokens(chars: u64) u64 {
    return chars / 7 * 2 + (chars % 7 * 2 + 6) / 7;
}

/// JavaScript String.length counts astral code points as two code units.
/// Validate UTF-8 before iterating; borrowed native inputs may be malformed.
fn utf16Length(text: []const u8) !u64 {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidContextUtf8;
    var iterator = view.iterator();
    var units: u64 = 0;
    while (iterator.nextCodepoint()) |codepoint| units += if (codepoint > 0xffff) @as(u64, 2) else 1;
    return units;
}

fn addContentChars(allocator: std.mem.Allocator, total: *u64, contents: []const model.Content) !void {
    for (contents) |content| switch (content) {
        .text => |text| total.* = saturatingAdd(total.*, try utf16Length(text)),
        .thinking => |thinking| total.* = saturatingAdd(total.*, try utf16Length(thinking.text)),
        .image => total.* = saturatingAdd(total.*, 4800),
        .tool_call => |call| {
            total.* = saturatingAdd(total.*, try utf16Length(call.name));
            const json = try std.json.Stringify.valueAlloc(allocator, call.arguments, .{});
            defer allocator.free(json);
            total.* = saturatingAdd(total.*, try utf16Length(json));
        },
    };
}

fn estimateMessageTokens(allocator: std.mem.Allocator, message: model.Message) !u64 {
    var chars: u64 = 0;
    try addContentChars(allocator, &chars, message.content);
    return charsToTokens(chars);
}

pub fn estimateInputTokens(allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition) !u64 {
    var total: u64 = 0;
    for (messages) |message| total = saturatingAdd(total, try estimateMessageTokens(allocator, message));
    if (tools.len > 0) {
        const json = try std.json.Stringify.valueAlloc(allocator, tools, .{});
        defer allocator.free(json);
        total = saturatingAdd(total, charsToTokens(try utf16Length(json)));
    }
    return total;
}

pub fn clampMaxTokens(allocator: std.mem.Allocator, messages: []const model.Message, tools: []const model.ToolDefinition, context_window: u64, max_tokens: u32) !u32 {
    if (max_tokens == 0) return error.InvalidTokenLimit;
    if (context_window == 0) return @max(min_max_tokens, max_tokens);
    const input = try estimateInputTokens(allocator, messages, tools);
    const ratio_margin = (input *| context_safety_ratio_percent +| 99) / 100;
    const margin = @max(context_safety_tokens, ratio_margin);
    var room = context_window -| input -| margin;
    if (room < min_output_with_ratio_margin) {
        room = @min(min_output_with_ratio_margin, context_window -| input -| context_safety_tokens);
    }
    return @intCast(@min(max_tokens, @max(min_max_tokens, room)));
}

test "context estimate rounds each message and includes image and tool payload estimates" {
    const messages = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "1234567" }} },
        .{ .role = .user, .content = &.{.{ .image = .{ .bytes = "", .mime_type = "image/png" } }} },
        .{ .role = .assistant, .content = &.{.{ .thinking = .{ .text = "reasoning" } }} },
    };
    const tools = [_]model.ToolDefinition{.{ .name = "read", .description = "file", .parameters = .{ .object = .empty } }};
    const tool_json = try std.json.Stringify.valueAlloc(std.testing.allocator, &tools, .{});
    defer std.testing.allocator.free(tool_json);
    const expected = charsToTokens(7) + charsToTokens(4800) + charsToTokens(9) + charsToTokens(tool_json.len);
    try std.testing.expectEqual(expected, try estimateInputTokens(std.testing.allocator, &messages, &tools));
}

test "UTF16 lengths cover BMP astral combining characters and invalid UTF8" {
    try std.testing.expectEqual(@as(u64, 0), try utf16Length(""));
    try std.testing.expectEqual(@as(u64, 4), try utf16Length("你好🙂"));
    try std.testing.expectEqual(@as(u64, 2), try utf16Length("e\u{0301}"));
    try std.testing.expectEqual(@as(u64, 5), try utf16Length("👩‍💻"));
    for ([_][]const u8{ "\xff", "\xf0\x9f", "\xed\xa0\x80", "\xc0\xaf" }) |invalid| {
        const messages = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = invalid }} }};
        try std.testing.expectError(error.InvalidContextUtf8, estimateInputTokens(std.testing.allocator, &messages, &.{}));
    }
    const arguments = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"text\":\"你好🙂\"}", .{});
    defer arguments.deinit();
    const messages = [_]model.Message{.{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "c", .name = "read", .arguments = arguments.value } }} }};
    // read (4) + JSON syntax (11) + value (4) = 19 UTF16 units -> 6 tokens.
    try std.testing.expectEqual(@as(u64, 6), try estimateInputTokens(std.testing.allocator, &messages, &.{}));
    const tools = [_]model.ToolDefinition{.{ .name = "read", .description = "你好🙂", .parameters = .{ .object = .empty } }};
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, &tools, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqual(charsToTokens(try utf16Length(json)), try estimateInputTokens(std.testing.allocator, &.{}, &tools));
}

test "context clamp applies pi margins, configured ceiling and one-token floor" {
    const empty = [_]model.Message{};
    try std.testing.expectEqual(@as(u32, 1000), try clampMaxTokens(std.testing.allocator, &empty, &.{}, 100_000, 1000));
    try std.testing.expectEqual(@as(u32, 15_904), try clampMaxTokens(std.testing.allocator, &empty, &.{}, 20_000, 100_000));
    try std.testing.expectError(error.InvalidTokenLimit, clampMaxTokens(std.testing.allocator, &empty, &.{}, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), try clampMaxTokens(std.testing.allocator, &empty, &.{}, 4096, 100_000));
    try std.testing.expectEqual(@as(u32, 1000), try clampMaxTokens(std.testing.allocator, &empty, &.{}, 0, 1000));
    const overfull = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = "1234567" }} }};
    try std.testing.expectEqual(@as(u32, 1), try clampMaxTokens(std.testing.allocator, &overfull, &.{}, 1, 1000));
}

test "context estimate counts UTF16 units and tool calls without mutating input" {
    const messages = [_]model.Message{
        .{ .role = .user, .content = &.{.{ .text = "你好🙂" }} },
        .{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "ignored", .name = "read", .arguments = .{ .object = .empty } } }} },
        .{ .role = .tool_result, .content = &.{.{ .text = "12345678" }}, .tool_call_id = "ignored" },
    };
    // UTF16: 4 units -> 2; read + {}: 6 units -> 2; result: 8 -> 3.
    try std.testing.expectEqual(@as(u64, 7), try estimateInputTokens(std.testing.allocator, &messages, &.{}));
    try std.testing.expectEqualStrings("你好🙂", messages[0].content[0].text);
}

test "ratio margin and fixed-margin fallback have independent expected budgets" {
    const text = try std.testing.allocator.alloc(u8, 100_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    const messages = [_]model.Message{.{ .role = .user, .content = &.{.{ .text = text }} }};
    // ceil(100000 / 3.5) = 28572 and ceil(15% * 28572) = 4286.
    try std.testing.expectEqual(@as(u64, 28_572), charsToTokens(text.len));
    try std.testing.expectEqual(@as(u32, 67_142), try clampMaxTokens(std.testing.allocator, &messages, &.{}, 100_000, 100_000));
    const with_system = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "1234567" }} },
        messages[0],
    };
    try std.testing.expectEqual(@as(u32, 67139), try clampMaxTokens(std.testing.allocator, &with_system, &.{}, 100_000, 100_000));
    // Ratio room falls below 32768, so pi uses the fixed-margin fallback.
    try std.testing.expectEqual(@as(u32, 32768), try clampMaxTokens(std.testing.allocator, &messages, &.{}, 65_500, 100_000));
    try std.testing.expectEqual(@as(u32, 27332), try clampMaxTokens(std.testing.allocator, &messages, &.{}, 60_000, 100_000));
}
