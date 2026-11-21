const std = @import("std");
const runtime = @import("native_runtime");
const fixtures = @import("rejection_fixtures");

fn fixturePath(comptime index: usize) ![]u8 {
    const a = std.testing.allocator;
    const directory = std.process.Environ.getPosix(std.testing.environ, "ZPI_REJECTION_DIR");
    if (directory) |dir| return std.fs.path.join(a, &.{ dir, std.fmt.comptimePrint("libzpi-rejection-{d}.so", .{index}) });
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    return std.fs.path.resolveAlloc(a, &.{ cwd, @field(fixtures, std.fmt.comptimePrint("case_{d}", .{index})) });
}

test "independent malformed native libraries reject before create and accept compatible table sizes" {
    const expected: [10]?anyerror = .{
        error.PluginMissingSymbol,
        error.PluginNullDescriptor,
        error.PluginAbiMajorMismatch,
        error.PluginTableTooShort,
        error.PluginRequiredCapabilities,
        error.PluginMissingCallback,
        error.PluginCreateFailed,
        null,
        null,
        error.PluginReservedFields,
    };
    inline for (0..10) |index| {
        const path = try fixturePath(index);
        defer std.testing.allocator.free(path);
        if (expected[index]) |err| {
            try std.testing.expectError(err, runtime.Module.open(path));
        } else {
            var module = try runtime.Module.open(path);
            try std.testing.expectEqual(@as(u32, 0), try module.toolCount());
            try module.close();
        }
    }
}
