//! Bounded request headers shared by configuration and provider adapters.
const std = @import("std");
pub const max_headers = 64;
pub const max_bytes = 16 * 1024;

pub fn validate(header: std.http.Header) !void {
    if (header.name.len == 0) return error.InvalidHeaderName;
    for (header.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeaderName;
    }
    for (header.value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidHeaderValue;
    // HTTP framing and connection ownership remain with the adapter.
    for ([_][]const u8{ "host", "content-length", "transfer-encoding", "connection", "proxy-authorization", "proxy-connection", "upgrade", "trailer", "te", "content-type", "accept-encoding", "user-agent" }) |name| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return error.ReservedRequestHeader;
    }
}

pub fn validateAll(headers: []const std.http.Header) !void {
    if (headers.len > max_headers) return error.TooManyHeaders;
    var bytes: usize = 0;
    for (headers, 0..) |header, index| {
        try validate(header);
        if (header.name.len > max_bytes - bytes) return error.HeadersTooLarge;
        bytes += header.name.len;
        if (header.value.len > max_bytes - bytes) return error.HeadersTooLarge;
        bytes += header.value.len;
        for (headers[0..index]) |previous| if (std.ascii.eqlIgnoreCase(previous.name, header.name)) return error.DuplicateHeader;
    }
}

/// Later sources replace names case-insensitively. Input slices are borrowed.
pub fn merge(a: std.mem.Allocator, base: []const std.http.Header, overrides: []const std.http.Header) ![]std.http.Header {
    try validateAll(base);
    try validateAll(overrides);
    var result: std.ArrayList(std.http.Header) = .empty;
    errdefer result.deinit(a);
    try result.appendSlice(a, base);
    for (overrides) |header| {
        var replaced = false;
        for (result.items) |*previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, header.name)) {
                previous.* = header;
                replaced = true;
                break;
            }
        }
        if (!replaced) try result.append(a, header);
    }
    try validateAll(result.items);
    return result.toOwnedSlice(a);
}

pub fn get(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

test "header validation rejects malformed and reserved request fields" {
    try validate(.{ .name = "x-fixture", .value = "ok" });
    try validate(.{ .name = "x-fixture", .value = "tab\tvalue" });
    try std.testing.expectError(error.InvalidHeaderName, validate(.{ .name = "", .value = "x" }));
    try std.testing.expectError(error.InvalidHeaderName, validate(.{ .name = "bad name", .value = "x" }));
    try std.testing.expectError(error.InvalidHeaderValue, validate(.{ .name = "x-fixture", .value = "a\r\nb" }));
    try std.testing.expectError(error.ReservedRequestHeader, validate(.{ .name = "Content-Type", .value = "text/plain" }));
    try std.testing.expectError(error.ReservedRequestHeader, validate(.{ .name = "User-Agent", .value = "fixture" }));
}

test "header sets reject duplicates and enforce count and byte limits" {
    const duplicates = [_]std.http.Header{
        .{ .name = "x-fixture", .value = "one" },
        .{ .name = "X-Fixture", .value = "two" },
    };
    try std.testing.expectError(error.DuplicateHeader, validateAll(&duplicates));

    var headers: [max_headers + 1]std.http.Header = undefined;
    var names: [max_headers + 1][8]u8 = undefined;
    for (&headers, &names, 0..) |*header, *name, index| {
        const text = try std.fmt.bufPrint(name, "x-{d}", .{index});
        header.* = .{ .name = text, .value = "v" };
    }
    try std.testing.expectError(error.TooManyHeaders, validateAll(&headers));

    const value = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(value);
    @memset(value, 'a');
    const oversized = [_]std.http.Header{.{ .name = "x-fixture", .value = value }};
    try std.testing.expectError(error.HeadersTooLarge, validateAll(&oversized));
}

test "header merge replaces names case-insensitively in place" {
    const base = [_]std.http.Header{
        .{ .name = "x-a", .value = "one" },
        .{ .name = "x-b", .value = "two" },
    };
    const overrides = [_]std.http.Header{
        .{ .name = "X-A", .value = "three" },
        .{ .name = "x-c", .value = "four" },
    };
    const merged = try merge(std.testing.allocator, &base, &overrides);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("three", merged[0].value);
    try std.testing.expectEqualStrings("two", merged[1].value);
    try std.testing.expectEqualStrings("four", merged[2].value);
    try std.testing.expectEqualStrings("three", get(merged, "x-a").?);
    try std.testing.expectEqualStrings("four", get(merged, "X-C").?);
}
