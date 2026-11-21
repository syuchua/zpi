//! JSON facade for the experimental native value records. Typed native calls
//! traverse values directly; JSON is parsed/serialized only at this boundary.
//! Conversion results are allocated in the caller's arena and own all strings.
const std = @import("std");
const native = @import("native_plugin");

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    value: native.Value,
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(a: std.mem.Allocator, text: []const u8, limits: native.Limits) !Document {
    // Bound the scanner before the allocating dynamic JSON parser runs. Token
    // count includes keys and closing delimiters, so allow four per value.
    if (text.len > limits.max_bytes) return error.ValueTooLarge;
    var scanner = std.json.Scanner.initCompleteInput(a, text);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    const token_limit = std.math.mul(usize, limits.max_nodes, 4) catch std.math.maxInt(usize);
    while (true) {
        const token = try scanner.next();
        if (token == .end_of_document) break;
        tokens = std.math.add(usize, tokens, 1) catch return error.ValueTooLarge;
        if (tokens > token_limit) return error.ValueTooLarge;
        switch (token) {
            .array_begin, .object_begin => {
                // Root container has depth zero; nested children add one.
                if (depth > limits.max_depth) return error.ValueTooDeep;
                depth += 1;
            },
            .array_end, .object_end => depth -= 1,
            else => if (depth > limits.max_depth) return error.ValueTooDeep,
        }
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    var document: Document = .{ .arena = .init(a), .value = undefined };
    errdefer document.arena.deinit();
    var converter: Converter = .{ .allocator = document.arena.allocator(), .limits = limits };
    document.value = try converter.convert(parsed.value, 0);
    try native.validateAlloc(document.arena.allocator(), document.value, limits);
    return document;
}

/// The caller owns the entire returned graph through its arena. No JSON
/// stringify/parse round trip occurs, and exact numeric lexemes stay exact.
pub fn fromJson(a: std.mem.Allocator, source: std.json.Value, limits: native.Limits) !native.Value {
    var converter: Converter = .{ .allocator = a, .limits = limits };
    const result = try converter.convert(source, 0);
    try native.validateAlloc(a, result, limits);
    return result;
}
const Converter = struct {
    allocator: std.mem.Allocator,
    limits: native.Limits,
    nodes: usize = 0,
    bytes: usize = 0,

    fn text(self: *Converter, source: []const u8) !native.Span {
        self.bytes = std.math.add(usize, self.bytes, source.len) catch return error.ValueTooLarge;
        if (self.bytes > self.limits.max_bytes) return error.ValueTooLarge;
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        const copy = try self.allocator.dupe(u8, source);
        return .{ .ptr = if (copy.len == 0) null else copy.ptr, .len = copy.len };
    }
    fn convert(self: *Converter, source: std.json.Value, depth: usize) anyerror!native.Value {
        if (depth > self.limits.max_depth) return error.ValueTooDeep;
        self.nodes = std.math.add(usize, self.nodes, 1) catch return error.ValueTooLarge;
        if (self.nodes > self.limits.max_nodes) return error.ValueTooLarge;
        return switch (source) {
            .null => .{ .tag = @backingInt(native.Tag.null), .flags = 0, .payload = .{ .signed_integer = 0 } },
            .bool => |v| .{ .tag = @backingInt(native.Tag.boolean), .flags = 0, .payload = .{ .boolean = @intFromBool(v) } },
            .integer => |v| .{ .tag = @backingInt(native.Tag.signed_integer), .flags = 0, .payload = .{ .signed_integer = v } },
            .float => |v| blk: {
                if (!std.math.isFinite(v)) return error.NonFiniteNumber;
                break :blk .{ .tag = @backingInt(native.Tag.float), .flags = 0, .payload = .{ .float_number = v } };
            },
            .number_string => |v| .{ .tag = @backingInt(native.Tag.exact_number), .flags = 0, .payload = .{ .span = try self.text(v) } },
            .string => |v| .{ .tag = @backingInt(native.Tag.string), .flags = 0, .payload = .{ .span = try self.text(v) } },
            .array => |v| blk: {
                if (v.items.len > self.limits.max_nodes -| self.nodes) return error.ValueTooLarge;
                const items = try self.allocator.alloc(native.Value, v.items.len);
                for (v.items, items) |child, *item| item.* = try self.convert(child, depth + 1);
                break :blk .{ .tag = @backingInt(native.Tag.list), .flags = 0, .payload = .{ .list = .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len } } };
            },
            .object => |v| blk: {
                if (v.count() > self.limits.max_nodes -| self.nodes) return error.ValueTooLarge;
                const items = try self.allocator.alloc(native.Entry, v.count());
                for (v.keys(), v.values(), items) |key, child, *item| item.* = .{
                    .key = try self.text(key),
                    .value = try self.convert(child, depth + 1),
                };
                break :blk .{ .tag = @backingInt(native.Tag.object), .flags = 0, .payload = .{ .object = .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len } } };
            },
        };
    }
};

pub fn toJson(a: std.mem.Allocator, source: native.Value, limits: native.Limits) !std.json.Value {
    try native.validateAlloc(a, source, limits);
    return convertToJson(a, source);
}
fn bytes(span: native.Span) []const u8 {
    return if (span.ptr) |ptr| ptr[0..span.len] else &.{};
}
fn convertToJson(a: std.mem.Allocator, source: native.Value) anyerror!std.json.Value {
    const tag: native.Tag = @fromBackingInt(@intCast(source.tag));
    return switch (tag) {
        .null => .null,
        .boolean => .{ .bool = source.payload.boolean == 1 },
        .signed_integer => .{ .integer = source.payload.signed_integer },
        .unsigned_integer => .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{source.payload.unsigned_integer}) },
        .float => .{ .float = source.payload.float_number },
        .exact_number => .{ .number_string = try a.dupe(u8, bytes(source.payload.span)) },
        .string => .{ .string = try a.dupe(u8, bytes(source.payload.span)) },
        .bytes => error.BinaryJsonEncodingRequired,
        .list => blk: {
            var list: std.json.Array = .init(a);
            if (source.payload.list.ptr) |ptr| for (ptr[0..source.payload.list.len]) |child| {
                try list.append(try convertToJson(a, child));
            };
            break :blk .{ .array = list };
        },
        .object => blk: {
            var object: std.json.ObjectMap = .empty;
            if (source.payload.object.ptr) |ptr| for (ptr[0..source.payload.object.len]) |entry| {
                try object.put(a, try a.dupe(u8, bytes(entry.key)), try convertToJson(a, entry.value));
            };
            break :blk .{ .object = object };
        },
    };
}

pub fn stringify(a: std.mem.Allocator, source: native.Value, limits: native.Limits) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const value = try toJson(arena.allocator(), source, limits);
    return std.json.Stringify.valueAlloc(a, value, .{});
}

test "native JSON facade preserves nested order and exact decimal and large integer lexemes" {
    const a = std.testing.allocator;
    const source = "{\"large\":900719925474099312345,\"nested\":[true,null,\"雪\",{\"decimal\":-0.0012300e+400}],\"empty\":{}}";
    var document = try parse(a, source, .{});
    defer document.deinit();
    const result = try stringify(a, document.value, .{});
    defer a.free(result);
    try std.testing.expectEqualStrings(source, result);
    // The document owns its graph independently of the temporary JSON parser.
    try native.validateAlloc(a, document.value, .{});
    const max_u64: native.Value = .{ .tag = @backingInt(native.Tag.unsigned_integer), .flags = 0, .payload = .{ .unsigned_integer = std.math.maxInt(u64) } };
    const integer = try stringify(a, max_u64, .{});
    defer a.free(integer);
    try std.testing.expectEqualStrings("18446744073709551615", integer);
}

test "native JSON facade rejects duplicate keys invalid data and bounded nesting" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"x\":1,\"x\":2}", .{}));
    try std.testing.expectError(error.ValueTooDeep, parse(a, "[[[0]]]", .{ .max_depth = 1 }));
    try std.testing.expectError(error.ValueTooLarge, parse(a, "[1,2,3]", .{ .max_nodes = 2 }));
    try std.testing.expectError(error.ValueTooLarge, parse(a, "\"large\"", .{ .max_bytes = 3 }));
    const binary: native.Value = .{ .tag = @backingInt(native.Tag.bytes), .flags = 0, .payload = .{ .span = .{ .ptr = "\xff".ptr, .len = 1 } } };
    try native.validateAlloc(a, binary, .{});
    try std.testing.expectError(error.BinaryJsonEncodingRequired, stringify(a, binary, .{}));
    var invalid = binary;
    invalid.tag = @backingInt(native.Tag.string);
    try std.testing.expectError(error.InvalidUtf8, stringify(a, invalid, .{}));
}
