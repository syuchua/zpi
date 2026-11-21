const std = @import("std");
const agent = @import("agent");
const tools_mod = @import("tools");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    path: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
        defer std.testing.allocator.free(cwd);
        const absolute = try std.fs.path.resolveAlloc(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
        return .{ .tmp = tmp, .arena = .init(std.testing.allocator), .path = absolute };
    }
    fn context(self: *Fixture) agent.ToolContext {
        return .{ .allocator = self.arena.allocator(), .io = std.testing.io, .cwd = self.path };
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
        std.testing.allocator.free(self.path);
    }
    fn run(tool: agent.Tool, ctx: agent.ToolContext, text: []const u8) !agent.ToolResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, text, .{});
        defer parsed.deinit();
        return tool.execute(tool.context, ctx, parsed.value);
    }
};

test "core tools write edit and read project files" {
    var set = try tools_mod.ToolSet.init(std.testing.allocator);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const write_result = try Fixture.run(set.tools[1], fixture.context(), "{\"path\":\"nested/file.txt\",\"content\":\"one\\ntwo\\n\"}");
    try std.testing.expect(std.mem.indexOf(u8, write_result.text, "Wrote") != null);
    const edit_result = try Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"nested/file.txt\",\"oldText\":\"two\",\"newText\":\"three\"}");
    try std.testing.expect(std.mem.indexOf(u8, edit_result.text, "Edited") != null);
    const read_result = try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"nested/file.txt\",\"offset\":2}");
    try std.testing.expectEqualStrings("three\n", read_result.text);
    try std.testing.expectError(error.OffsetBeyondEnd, Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"nested/file.txt\",\"offset\":4}"));
    _ = try Fixture.run(set.tools[1], fixture.context(), "{\"path\":\"empty.txt\",\"content\":\"\"}");
    try std.testing.expectEqualStrings("", (try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"empty.txt\"}")).text);
    _ = try Fixture.run(set.tools[1], fixture.context(), "{\"path\":\"trailing.txt\",\"content\":\"one\\n\\n\"}");
    const trailing = try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"trailing.txt\"}");
    try std.testing.expectEqualStrings("one\n\n", trailing.text);
    try std.testing.expectEqualStrings("", (try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"trailing.txt\",\"offset\":3}")).text);
    try std.testing.expectError(error.OffsetBeyondEnd, Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"trailing.txt\",\"offset\":4}"));
    try std.testing.expectEqualStrings("one\n\n[2 more lines in file. Use offset=2 to continue.]", (try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"trailing.txt\",\"limit\":1}")).text);
    try std.testing.expectEqualStrings("\n\n[3 more lines in file. Use offset=1 to continue.]", (try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"trailing.txt\",\"limit\":0}")).text);
    try std.testing.expectError(error.ExpectedNonnegativeInteger, Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"trailing.txt\",\"limit\":-1}"));
}

test "read truncation reports line and byte boundaries" {
    const a = std.testing.allocator;
    var set = try tools_mod.ToolSet.init(a);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const many = try a.alloc(u8, 4002);
    defer a.free(many);
    for (0..2001) |i| @memcpy(many[i * 2 ..][0..2], "x\n");
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lines.txt", .data = many });
    const lines = try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"lines.txt\"}");
    const line_details = lines.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("lines", line_details.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, 2000), line_details.get("outputLines").?.integer);
    try std.testing.expectEqual(@as(i64, 3999), line_details.get("outputBytes").?.integer);
    try std.testing.expectEqualStrings(many[0..3999], line_details.get("content").?.string);
    try std.testing.expectEqual(@as(i64, 2001), line_details.get("totalLines").?.integer);
    try std.testing.expectEqual(@as(i64, 4002), line_details.get("totalBytes").?.integer);
    try std.testing.expect(std.mem.endsWith(u8, lines.text, "[Showing lines 1-2000 of 2002. Use offset=2001 to continue.]"));
    const big = try a.alloc(u8, 50 * 1024 + 1);
    defer a.free(big);
    @memset(big, 'x');
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = big });
    const oversized_line = try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"big.txt\"}");
    const big_details = oversized_line.details.?.object.get("truncation").?.object;
    try std.testing.expect(big_details.get("firstLineExceedsLimit").?.bool);
    try std.testing.expectEqualStrings("bytes", big_details.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, 0), big_details.get("outputBytes").?.integer);
    big[50 * 1024 - 1] = '\n';
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bytes.txt", .data = big });
    const byte_result = try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"bytes.txt\"}");
    const byte_details = byte_result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("bytes", byte_details.get("truncatedBy").?.string);
    try std.testing.expect(std.mem.startsWith(u8, byte_result.text, big[0 .. 50 * 1024 - 1]));
    try std.testing.expectEqual(@as(i64, 50 * 1024 - 1), byte_details.get("outputBytes").?.integer);
    try std.testing.expect(std.mem.endsWith(u8, byte_result.text, "[Showing lines 1-1 of 2 (50.0KB limit). Use offset=2 to continue.]"));
}

test "edit refuses ambiguous matches and argument/path validation fails before effects" {
    var set = try tools_mod.ToolSet.init(std.testing.allocator);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    _ = try Fixture.run(set.tools[1], fixture.context(), "{\"path\":\"repeat.txt\",\"content\":\"x x\"}");
    try std.testing.expectError(error.AmbiguousMatch, Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"repeat.txt\",\"oldText\":\"x\",\"newText\":\"y\"}"));
    try std.testing.expectError(error.InvalidPath, Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"\\u0000bad\"}"));
    try std.testing.expectError(error.UnknownArgument, Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"repeat.txt\",\"other\":true}"));
    const unchanged = try fixture.tmp.dir.readFileAlloc(std.testing.io, "repeat.txt", fixture.arena.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("x x", unchanged);
}

test "batch edit matches the original file and failed validation leaves it unchanged" {
    var set = try tools_mod.ToolSet.init(std.testing.allocator);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    _ = try Fixture.run(set.tools[1], fixture.context(), "{\"path\":\"batch.txt\",\"content\":\"alpha beta gamma\"}");
    _ = try Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"batch.txt\",\"edits\":[{\"oldText\":\"gamma\",\"newText\":\"alpha\"},{\"oldText\":\"alpha\",\"newText\":\"gamma\"}]}");
    const swapped = try fixture.tmp.dir.readFileAlloc(std.testing.io, "batch.txt", fixture.arena.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("gamma beta alpha", swapped);
    try std.testing.expectError(error.OverlappingEdits, Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"batch.txt\",\"edits\":[{\"oldText\":\"gamma beta\",\"newText\":\"x\"},{\"oldText\":\"beta\",\"newText\":\"y\"}]}"));
    try std.testing.expectError(error.MatchNotFound, Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"batch.txt\",\"edits\":[{\"oldText\":\"gamma\",\"newText\":\"created\"},{\"oldText\":\"created\",\"newText\":\"no\"}]}"));
    try std.testing.expectError(error.EmptyEdits, Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"batch.txt\",\"edits\":[]}"));
    try std.testing.expectError(error.UnknownArgument, Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"batch.txt\",\"edits\":[{\"oldText\":\"gamma\",\"newText\":\"x\",\"unexpected\":true}]}"));
    try std.testing.expectError(error.MissingArgument, Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"batch.txt\",\"newText\":\"x\"}"));
    const unchanged = try fixture.tmp.dir.readFileAlloc(std.testing.io, "batch.txt", fixture.arena.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("gamma beta alpha", unchanged);
}

test "file tools accept the inclusive write limit and reject larger or nonregular reads" {
    const a = std.testing.allocator;
    var set = try tools_mod.ToolSet.init(a);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const bytes = try a.alloc(u8, 8 * 1024 * 1024 + 1);
    defer a.free(bytes);
    @memset(bytes, 'x');
    @memcpy(bytes[0..7], "marker\n");
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(a);
    try args.put(a, "path", .{ .string = "boundary.txt" });
    try args.put(a, "content", .{ .string = bytes[0 .. bytes.len - 1] });
    _ = try set.tools[1].execute(null, fixture.context(), .{ .object = args });
    const result = try Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"boundary.txt\",\"limit\":1}");
    try std.testing.expect(std.mem.startsWith(u8, result.text, "marker\n"));
    try std.testing.expectEqualStrings("marker\n\n[1 more lines in file. Use offset=2 to continue.]", result.text);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), (try fixture.tmp.dir.statFile(std.testing.io, "boundary.txt", .{})).size);
    try args.put(a, "content", .{ .string = bytes });
    try std.testing.expectError(error.FileTooLarge, set.tools[1].execute(null, fixture.context(), .{ .object = args }));
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), (try fixture.tmp.dir.statFile(std.testing.io, "boundary.txt", .{})).size);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "oversized.txt", .data = bytes });
    try std.testing.expectError(error.FileTooLarge, Fixture.run(set.tools[0], fixture.context(), "{\"path\":\"oversized.txt\"}"));
    try std.testing.expectError(error.FileTooLarge, Fixture.run(set.tools[2], fixture.context(), "{\"path\":\"oversized.txt\",\"oldText\":\"marker\",\"newText\":\"changed\"}"));
    try std.testing.expectError(error.NotRegularFile, Fixture.run(set.tools[0], fixture.context(), "{\"path\":\".\"}"));
    try std.testing.expectEqual(@as(u64, bytes.len), (try fixture.tmp.dir.statFile(std.testing.io, "oversized.txt", .{})).size);
}

test "search wrappers use tool cwd and validate arguments" {
    var set = try tools_mod.ToolSet.init(std.testing.allocator);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(std.testing.io, ".git");
    try fixture.tmp.dir.createDirPath(std.testing.io, "src");
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored.txt", .data = "needle\n" });
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/a.txt", .data = "first\nneedle\nlast\n" });
    const listing = try Fixture.run(set.tools[6], fixture.context(), "{\"path\":\"src\"}");
    try std.testing.expectEqualStrings("a.txt", listing.text);
    const grep_result = Fixture.run(set.tools[4], fixture.context(), "{\"pattern\":\"needle\",\"path\":\"src\",\"context\":0}") catch |err| {
        if (err == error.RipgrepNotInstalled) return error.SkipZigTest;
        return err;
    };
    try std.testing.expectEqualStrings("a.txt:2: needle", grep_result.text);
    const find_result = Fixture.run(set.tools[5], fixture.context(), "{\"pattern\":\"src/*.txt\"}") catch |err| {
        if (err == error.FdNotInstalled) return error.SkipZigTest;
        return err;
    };
    try std.testing.expectEqualStrings("src/a.txt", find_result.text);
    try std.testing.expectError(error.ExpectedBoolean, Fixture.run(set.tools[4], fixture.context(), "{\"pattern\":\"x\",\"literal\":\"yes\"}"));
    try std.testing.expectError(error.UnknownArgument, Fixture.run(set.tools[6], fixture.context(), "{\"unexpected\":true}"));
}

test "bash timeout terminates the process group" {
    var set = try tools_mod.ToolSet.init(std.testing.allocator);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.testing.expectError(error.Timeout, Fixture.run(set.tools[3], fixture.context(), "{\"command\":\"sleep 3; touch late-marker\",\"timeout\":1}"));
    try std.Io.sleep(std.testing.io, .fromSeconds(3), .awake);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "late-marker", .{}));
}

test "bash receives command as argv data and reports failure output" {
    var set = try tools_mod.ToolSet.init(std.testing.allocator);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const result = try Fixture.run(set.tools[3], fixture.context(), "{\"command\":\"printf '%s' 'hello world'\",\"timeout\":3}");
    try std.testing.expectEqualStrings("hello world", result.text);
    try std.testing.expect(!result.is_error);
    const failed = try Fixture.run(set.tools[3], fixture.context(), "{\"command\":\"printf failed >&2; exit 3\",\"timeout\":3}");
    try std.testing.expect(failed.is_error);
    try std.testing.expectEqualStrings("failed\n\nCommand exited with code 3", failed.text);
    const empty = try Fixture.run(set.tools[3], fixture.context(), "{\"command\":\":\",\"timeout\":3}");
    try std.testing.expectEqualStrings("(no output)", empty.text);
    try std.testing.expect(!empty.is_error);
    const empty_failed = try Fixture.run(set.tools[3], fixture.context(), "{\"command\":\"exit 7\",\"timeout\":3}");
    try std.testing.expectEqualStrings("(no output)\n\nCommand exited with code 7", empty_failed.text);
    try std.testing.expect(empty_failed.is_error);
    const signaled = try Fixture.run(set.tools[3], fixture.context(), "{\"command\":\"kill -TERM $$\",\"timeout\":3}");
    try std.testing.expectEqualStrings("(no output)\n\nCommand exited with code 143", signaled.text);
    try std.testing.expect(signaled.is_error);
}

test "bash interrupt cancels and terminates the process group" {
    var set = try tools_mod.ToolSet.init(std.testing.allocator);
    defer set.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var interrupt = try agent.model.Interrupt.init();
    defer interrupt.deinit(std.testing.io);
    const Trigger = struct {
        target: *agent.model.Interrupt,
        fn run(self: *@This(), io: std.Io) std.Io.Cancelable!void {
            try io.sleep(.fromMilliseconds(100), .awake);
            self.target.trigger();
        }
    };
    var trig = Trigger{ .target = &interrupt };
    var trig_task = try std.Io.concurrent(std.testing.io, Trigger.run, .{ &trig, std.testing.io });
    defer _ = trig_task.cancel(std.testing.io) catch {};
    var ctx = fixture.context();
    ctx.cancel = interrupt.cancel();
    try std.testing.expectError(error.Canceled, Fixture.run(set.tools[3], ctx, "{\"command\":\"sleep 3; touch canceled-late-marker\",\"timeout\":10}"));
    try trig_task.await(std.testing.io);
    try std.Io.sleep(std.testing.io, .fromSeconds(2), .awake);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "canceled-late-marker", .{}));
}
