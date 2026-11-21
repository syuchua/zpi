const std = @import("std");
const native = @import("native_plugin");
extern fn zpi_fixture_roundtrip(native.Value, *native.OwnedValue, *c_uint) c_int;

test "C and Zig exchange typed values and release through the producer callback" {
    var releases: c_uint = 0;
    var output: native.OwnedValue = undefined;
    const input: native.Value = .{ .tag = @backingInt(native.Tag.unsigned_integer), .flags = 0, .payload = .{ .unsigned_integer = 18446744073709551615 } };
    try std.testing.expectEqual(@as(c_int, 0), zpi_fixture_roundtrip(input, &output, &releases));
    try native.validate(output.value, .{});
    try std.testing.expectEqual(input.payload.unsigned_integer, output.value.payload.unsigned_integer);
    try std.testing.expectEqual(@as(c_uint, 0), releases);
    output.release.?(output.context);
    try std.testing.expectEqual(@as(c_uint, 1), releases);
}
