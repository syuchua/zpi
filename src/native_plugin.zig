//! Experimental C-compatible native plugin value layout. This module defines
//! data records only; it is not yet a loader or a frozen ABI.
const std = @import("std");

pub const abi_major: u32 = 1;
pub const abi_minor: u32 = 0;
pub const Tag = enum(u32) {
    null = 0,
    boolean = 1,
    signed_integer = 2,
    unsigned_integer = 3,
    float = 4,
    exact_number = 5,
    string = 6,
    bytes = 7,
    list = 8,
    object = 9,
};

pub const Span = extern struct { ptr: ?[*]const u8, len: usize };
pub const Value = extern struct {
    tag: u32,
    flags: u32,
    payload: extern union {
        boolean: u8,
        signed_integer: i64,
        unsigned_integer: u64,
        float_number: f64,
        span: Span,
        list: List,
        object: Object,
    },
};
pub const List = extern struct { ptr: ?[*]const Value, len: usize };
pub const Object = extern struct { ptr: ?[*]const Entry, len: usize };
pub const Entry = extern struct { key: Span, value: Value };
pub const ReleaseFn = *const fn (?*anyopaque) callconv(.c) void;
pub const OwnedValue = extern struct { value: Value, context: ?*anyopaque, release: ?ReleaseFn };

pub const Limits = struct {
    max_depth: usize = 64,
    max_nodes: usize = 100_000,
    max_bytes: usize = 1024 * 1024,
};

/// Validates descriptors and aggregate bounds. Pointer accessibility remains
/// the trusted plugin's responsibility in this in-process ABI.
pub fn validate(root: Value, limits: Limits) !void {
    return validateAlloc(std.heap.page_allocator, root, limits);
}
pub fn validateAlloc(allocator: std.mem.Allocator, root: Value, limits: Limits) !void {
    var budget: Budget = .{ .allocator = allocator, .limits = limits };
    try budget.visit(root, 0);
}
fn validNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[i] == '-') {
        i += 1;
        if (i == text.len) return false;
    }
    if (text[i] == '0') {
        i += 1;
        if (i < text.len and std.ascii.isDigit(text[i])) return false;
    } else {
        if (text[i] < '1' or text[i] > '9') return false;
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (start == i) return false;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (start == i) return false;
    }
    return i == text.len;
}
const Budget = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    nodes: usize = 0,
    bytes: usize = 0,

    fn addBytes(self: *Budget, count: usize) !void {
        self.bytes = std.math.add(usize, self.bytes, count) catch return error.ValueTooLarge;
        if (self.bytes > self.limits.max_bytes) return error.ValueTooLarge;
    }
    fn checkSpan(self: *Budget, span: Span) ![]const u8 {
        if (span.ptr == null and span.len != 0) return error.InvalidPointerLength;
        try self.addBytes(span.len);
        return if (span.ptr) |ptr| ptr[0..span.len] else &.{};
    }
    fn visit(self: *Budget, value: Value, depth: usize) anyerror!void {
        if (depth > self.limits.max_depth) return error.ValueTooDeep;
        self.nodes = std.math.add(usize, self.nodes, 1) catch return error.ValueTooLarge;
        if (self.nodes > self.limits.max_nodes) return error.ValueTooLarge;
        if (value.flags != 0) return error.UnsupportedValueFlags;
        if (value.tag > @backingInt(Tag.object)) return error.InvalidValueTag;
        const tag: Tag = @fromBackingInt(@intCast(value.tag));
        switch (tag) {
            .null => {},
            .boolean => if (value.payload.boolean > 1) return error.InvalidBoolean,
            .signed_integer, .unsigned_integer => {},
            .float => if (!std.math.isFinite(value.payload.float_number)) return error.NonFiniteNumber,
            .exact_number => {
                const text = try self.checkSpan(value.payload.span);
                if (!validNumber(text)) return error.InvalidNumberText;
            },
            .string, .bytes => {
                const bytes = try self.checkSpan(value.payload.span);
                if (tag == .string and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            },
            .list => {
                const list = value.payload.list;
                if (list.ptr == null and list.len != 0) return error.InvalidPointerLength;
                if (list.len > self.limits.max_nodes -| self.nodes) return error.ValueTooLarge;
                if (list.ptr) |ptr| for (ptr[0..list.len]) |child| try self.visit(child, depth + 1);
            },
            .object => {
                const object = value.payload.object;
                if (object.ptr == null and object.len != 0) return error.InvalidPointerLength;
                if (object.len > self.limits.max_nodes -| self.nodes) return error.ValueTooLarge;
                var keys: std.StringHashMap(void) = .init(self.allocator);
                defer keys.deinit();
                if (object.ptr) |ptr| for (ptr[0..object.len]) |entry| {
                    const key = try self.checkSpan(entry.key);
                    if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidUtf8;
                    const gop = try keys.getOrPut(key);
                    if (gop.found_existing) return error.DuplicateObjectKey;
                    gop.value_ptr.* = {};
                    try self.visit(entry.value, depth + 1);
                };
            },
        }
    }
};

test "native C ABI layouts match the documented 64-bit C contract" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Span));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(List));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Object));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Entry));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(OwnedValue));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Value, "payload"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(OwnedValue, "context"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(OwnedValue, "release"));
}

test "native values reject invalid descriptors, numeric text and duplicate object keys" {
    try validate(.{ .tag = @backingInt(Tag.null), .flags = 0, .payload = .{ .signed_integer = 0 } }, .{});
    try std.testing.expectError(error.InvalidBoolean, validate(.{ .tag = 1, .flags = 0, .payload = .{ .boolean = 2 } }, .{}));
    try std.testing.expectError(error.NonFiniteNumber, validate(.{ .tag = 4, .flags = 0, .payload = .{ .float_number = std.math.nan(f64) } }, .{}));
    const number = "900719925474099312345";
    try validate(.{ .tag = 5, .flags = 0, .payload = .{ .span = .{ .ptr = number.ptr, .len = number.len } } }, .{});
    const bad_number = "01";
    try std.testing.expectError(error.InvalidNumberText, validate(.{ .tag = 5, .flags = 0, .payload = .{ .span = .{ .ptr = bad_number.ptr, .len = bad_number.len } } }, .{}));
    const key = "x";
    const entries = [_]Entry{
        .{ .key = .{ .ptr = key.ptr, .len = key.len }, .value = .{ .tag = 0, .flags = 0, .payload = .{ .signed_integer = 0 } } },
        .{ .key = .{ .ptr = key.ptr, .len = key.len }, .value = .{ .tag = 0, .flags = 0, .payload = .{ .signed_integer = 0 } } },
    };
    try std.testing.expectError(error.DuplicateObjectKey, validate(.{ .tag = 9, .flags = 0, .payload = .{ .object = .{ .ptr = &entries, .len = entries.len } } }, .{}));
}
