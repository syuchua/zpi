const std = @import("std");
const extensions = @import("extensions");
const a = std.testing.allocator;

test "Zig extension bridge invokes the real SDK and keeps result ownership across requests" {
    const sdk = std.process.Environ.getPosix(std.testing.environ, "ZPI_PI_SDK") orelse return error.SkipZigTest;
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const script = try std.fs.path.join(a, &.{ cwd, "scripts", "ts-host.mjs" });
    defer a.free(script);
    const hello = try std.fs.path.join(a, &.{ cwd, ".reference/pi/packages/coding-agent/examples/extensions/hello.ts" });
    defer a.free(hello);
    const transform = try std.fs.path.join(a, &.{ cwd, ".reference/pi/packages/coding-agent/examples/extensions/input-transform.ts" });
    defer a.free(transform);
    var host = try extensions.Host.start(a, std.testing.io, .{ .host_script = script, .sdk_directory = sdk, .cwd = cwd, .timeout_ms = 10000 });
    defer host.deinit();
    var ready = try host.load(&.{ hello, transform });
    defer ready.deinit();
    try std.testing.expectEqual(@as(usize, 1), ready.value().object.get("tools").?.array.items.len);
    var input = try host.request("input", .{ .text = "?quick Zig", .source = "interactive" });
    defer input.deinit();
    try std.testing.expectEqualStrings("transform", input.value().object.get("action").?.string);
    try std.testing.expectEqualStrings("Respond briefly in 1-2 sentences: Zig", input.value().object.get("text").?.string);
    var result = try host.request("tool_exec", .{ .name = "hello", .callId = "zig_1", .arguments = .{ .name = "Zig" } });
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello, Zig!", result.value().object.get("content").?.array.items[0].object.get("text").?.string);
    // The original ready and input records remain valid after another exchange.
    try std.testing.expectEqualStrings("hello", ready.value().object.get("tools").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("transform", input.value().object.get("action").?.string);
    try std.testing.expectError(error.ExtensionToolFailed, host.request("tool_exec", .{ .name = "hello", .callId = "bad", .arguments = .{} }));
    try std.testing.expect(!host.closed);
    try host.shutdown();
    try std.testing.expect(host.closed);
}

test "tool runtime errors keep the TypeScript host available for later hooks" {
    const sdk = std.process.Environ.getPosix(std.testing.environ, "ZPI_PI_SDK") orelse return error.SkipZigTest;
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const script = try std.fs.path.join(a, &.{ cwd, "scripts", "ts-host.mjs" });
    defer a.free(script);
    const fixture = try std.fs.path.join(a, &.{ cwd, "scripts", "fixtures", "ts-extension.ts" });
    defer a.free(fixture);
    var host = try extensions.Host.start(a, std.testing.io, .{ .host_script = script, .sdk_directory = sdk, .cwd = cwd, .timeout_ms = 10000 });
    defer host.deinit();
    var ready = try host.load(&.{fixture});
    defer ready.deinit();
    try std.testing.expectError(error.ExtensionToolFailed, host.execute("throw_fixture", "throw", .{ .object = .empty }));
    try std.testing.expect(!host.closed);
    var input = try host.request("input", .{ .text = "prefix recovered", .source = "interactive" });
    defer input.deinit();
    try std.testing.expectEqualStrings("transformed recovered", input.value().object.get("text").?.string);
}

test "extension gate errors reject execution while preserving host availability" {
    const sdk = std.process.Environ.getPosix(std.testing.environ, "ZPI_PI_SDK") orelse return error.SkipZigTest;
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const script = try std.fs.path.join(a, &.{ cwd, "scripts", "ts-host.mjs" });
    defer a.free(script);
    const fixture = try std.fs.path.join(a, &.{ cwd, "scripts", "fixtures", "ts-extension.ts" });
    defer a.free(fixture);
    var host = try extensions.Host.start(a, std.testing.io, .{ .host_script = script, .sdk_directory = sdk, .cwd = cwd, .timeout_ms = 10000 });
    defer host.deinit();
    var ready = try host.load(&.{fixture});
    defer ready.deinit();
    var arguments: std.json.Value = .{ .object = .empty };
    defer arguments.object.deinit(a);
    try arguments.object.put(a, "path", .{ .string = "throw-gate.txt" });
    try arguments.object.put(a, "content", .{ .string = "must-not-write" });
    try std.testing.expectError(error.ExtensionHostRejected, host.request("tool_call", .{ .name = "write", .callId = "gate", .arguments = arguments, .schema = .{ .type = "object", .additionalProperties = true } }));
    try std.testing.expect(!host.closed);
    var input = try host.request("input", .{ .text = "prefix recovered", .source = "interactive" });
    defer input.deinit();
    try std.testing.expectEqualStrings("transformed recovered", input.value().object.get("text").?.string);
}

test "Zig extension bridge kills an unresponsive host on deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stall.sh", .data = "while read line; do sleep 30; done\n" });
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const script = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "stall.sh" });
    defer a.free(script);
    var host = try extensions.Host.start(a, std.testing.io, .{ .node_exe = "/bin/sh", .host_script = script, .sdk_directory = "/unused", .cwd = cwd, .timeout_ms = 100 });
    defer host.deinit();
    try std.testing.expectError(error.ExtensionHostTimeout, host.request("input", .{ .text = "never" }));
    try std.testing.expect(host.closed);
    try std.testing.expect(host.child.id == null);
}
