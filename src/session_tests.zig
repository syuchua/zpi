const std = @import("std");
const model = @import("model");
const session = @import("session");

test "memory session branches active context and preserves message ownership" {
    var store = session.Store.memory(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const first = [_]model.Content{.{ .text = "first" }};
    const second = [_]model.Content{.{ .text = "second" }};
    const id1 = try store.appendMessage(.{ .role = .user, .content = &first });
    const id2 = try store.appendMessage(.{ .role = .assistant, .content = &second });
    try std.testing.expectEqualStrings("0000000000000001", id1);
    try std.testing.expectEqualStrings("0000000000000002", id2);
    const initial = try store.activePath(std.testing.allocator);
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 2), initial.len);
    try store.branch(id1);
    const branched = try store.activePath(std.testing.allocator);
    defer std.testing.allocator.free(branched);
    try std.testing.expectEqual(@as(usize, 1), branched.len);
    try std.testing.expectEqualStrings("first", branched[0].message.content[0].text);
}

test "torn final append is removed and a new message remains readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/session.jsonl", .{&tmp.sub_path});
    var created = try session.Store.create(std.testing.allocator, std.testing.io, path, "/workspace");
    _ = try created.appendMessage(.{ .role = .user, .content = &.{.{ .text = "committed" }} });
    const offset = created.write_offset;
    created.deinit();
    const file = try tmp.dir.openFile(std.testing.io, "session.jsonl", .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "{\"type\":\"message\",", offset);
    file.close(std.testing.io);
    var recovered = try session.Store.open(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqual(offset, recovered.write_offset);
    try std.testing.expectEqual(offset, try recovered.file.?.length(std.testing.io));
    _ = try recovered.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "new reply" }} });
    recovered.deinit();
    var reopened = try session.Store.open(std.testing.allocator, std.testing.io, path);
    defer reopened.deinit();
    const active = try reopened.activePath(std.testing.allocator);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqual(@as(usize, 2), active.len);
    try std.testing.expectEqualStrings("committed", active[0].message.content[0].text);
    try std.testing.expectEqualStrings("new reply", active[1].message.content[0].text);
}

test "binary images round trip in v3 session records without changing legacy record versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/images.jsonl", .{&tmp.sub_path});
    defer std.testing.allocator.free(path);
    const png = "\x89PNG\r\n\x1a\nfixture";
    var store = try session.Store.create(std.testing.allocator, std.testing.io, path, "/workspace");
    _ = try store.appendMessage(.{ .role = .user, .content = &.{.{ .image = .{ .bytes = png, .mime_type = "image/png" } }} });
    store.deinit();
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "images.jsonl", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "iVBORw0KGgpmaXh0dXJl") != null);
    var reopened = try session.Store.open(std.testing.allocator, std.testing.io, path);
    defer reopened.deinit();
    const restored = reopened.entries.items[0].message.content[0].image;
    try std.testing.expectEqualStrings(png, restored.bytes);
    try std.testing.expectEqualStrings("image/png", restored.mime_type);
}

test "session open rejects symlinks and nonregular files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "{\"type\":\"session\",\"version\":1,\"format\":\"zpi\",\"cwd\":\"/workspace\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.jsonl", .data = content });
    try tmp.dir.symLink(std.testing.io, "target.jsonl", "link.jsonl", .{});
    const link_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/link.jsonl", .{&tmp.sub_path});
    defer std.testing.allocator.free(link_path);
    try std.testing.expectError(error.SymLinkLoop, session.Store.open(std.testing.allocator, std.testing.io, link_path));
    try std.testing.expectError(error.IsDir, session.Store.open(std.testing.allocator, std.testing.io, ".zig-cache/tmp/" ++ &tmp.sub_path));
}

test "completed malformed records fail without truncating the session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/broken.jsonl", .{&tmp.sub_path});
    const corrupt = "{\"type\":\"session\",\"cwd\":\"/workspace\"}\nnot-json\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "broken.jsonl", .data = corrupt });
    try std.testing.expectError(error.CorruptSessionEntry, session.Store.open(std.testing.allocator, std.testing.io, path));
    const after = try tmp.dir.readFileAlloc(std.testing.io, "broken.jsonl", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(corrupt, after);
}

test "branch navigation and exact numeric tool arguments survive reload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/tree.jsonl", .{&tmp.sub_path});
    var created = try session.Store.create(std.testing.allocator, std.testing.io, path, "/workspace");
    const root = try created.appendMessage(.{ .role = .user, .content = &.{.{ .text = "root" }} });
    var arguments = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"exact\":18446744073709551616,\"decimal\":1.234567890123456789}", .{ .parse_numbers = false });
    defer arguments.deinit();
    _ = try created.appendMessage(.{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "c1", .name = "example", .arguments = arguments.value } }} });
    try created.branch(root);
    created.deinit();
    var reopened = try session.Store.open(std.testing.allocator, std.testing.io, path);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.entries.items.len);
    const active = try reopened.activePath(std.testing.allocator);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    const restored = reopened.entries.items[1].message.content[0].tool_call.arguments;
    try std.testing.expectEqualStrings("18446744073709551616", restored.object.get("exact").?.number_string);
    try std.testing.expectEqualStrings("1.234567890123456789", restored.object.get("decimal").?.number_string);
}

test "unknown active leaf is never silently converted into a new session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const json = "{\"type\":\"session\",\"version\":1,\"format\":\"zpi\",\"cwd\":\"/workspace\"}\n{\"type\":\"leaf\",\"version\":1,\"format\":\"zpi\",\"id\":\"missing\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "leaf.jsonl", .data = json });
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/leaf.jsonl", .{&tmp.sub_path});
    try std.testing.expectError(error.UnknownSessionEntry, session.Store.open(std.testing.allocator, std.testing.io, path));
}

test "system prompt checkpoints persist with explicit version and follow selected ancestry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/prompts.jsonl", .{&tmp.sub_path});
    var store = try session.Store.create(std.testing.allocator, std.testing.io, path, "/workspace");
    const original = try store.appendMessage(.{ .role = .system, .content = &.{.{ .text = "original" }} });
    _ = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "task" }} });
    const checkpoint = try store.appendMessage(.{ .role = .system, .content = &.{.{ .text = "updated" }}, .system_prompt_replace = true });
    try std.testing.expectError(error.InvalidSystemPromptCheckpoint, store.appendMessage(.{ .role = .user, .content = &.{}, .system_prompt_replace = true }));
    try store.branch(original);
    const checkpoint_copy = try std.testing.allocator.dupe(u8, checkpoint);
    defer std.testing.allocator.free(checkpoint_copy);
    store.deinit();
    var restored = try session.Store.open(std.testing.allocator, std.testing.io, path);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 3), restored.entries.items.len);
    try std.testing.expect(restored.entries.items[2].message.system_prompt_replace);
    const before = try restored.activePath(std.testing.allocator);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try restored.branch(checkpoint_copy);
    const after = try restored.activePath(std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqual(@as(usize, 3), after.len);
    try std.testing.expectEqualStrings("updated", after[2].message.content[0].text);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "prompts.jsonl", std.testing.allocator, .limited(16384));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"version\":2") != null);
    const invalid = "{\"type\":\"session\",\"cwd\":\"/workspace\"}\n{\"type\":\"message\",\"version\":1,\"id\":\"1\",\"message\":{\"role\":\"system\",\"content\":[],\"system_prompt_replace\":true}}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.jsonl", .data = invalid });
    const bad_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/invalid.jsonl", .{&tmp.sub_path});
    defer std.testing.allocator.free(bad_path);
    try std.testing.expectError(error.UnsupportedSystemPromptCheckpointVersion, session.Store.open(std.testing.allocator, std.testing.io, bad_path));
}

test "session index survives growth branching reload and rejected duplicate IDs" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/indexed.jsonl", .{&tmp.sub_path});
    defer a.free(path);
    // Generate a sizeable committed log without thousands of fsync calls.
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    try log.writer.writeAll("{\"type\":\"session\",\"cwd\":\"/workspace\"}\n");
    for (1..2049) |i| {
        try log.writer.print("{{\"type\":\"message\",\"id\":\"{x:0>16}\",", .{i});
        if (i > 1) try log.writer.print("\"parent_id\":\"{x:0>16}\",", .{i - 1});
        try log.writer.writeAll("\"message\":{\"role\":\"user\",\"content\":[{\"text\":\"entry\"}]}}\n");
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "indexed.jsonl", .data = log.written() });
    var store = try session.Store.open(a, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 2048), store.id_index.count());
    try store.branch("0000000000000400");
    const id = try store.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "alternate" }} });
    try std.testing.expectEqualStrings("0000000000000801", id);
    const active = try store.activePath(a);
    defer a.free(active);
    try std.testing.expectEqual(@as(usize, 1025), active.len);
    store.deinit();
    var reopened = try session.Store.open(a, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 2049), reopened.id_index.count());
    try reopened.branch("0000000000000800");
    const original = try reopened.activePath(a);
    defer a.free(original);
    try std.testing.expectEqual(@as(usize, 2048), original.len);
    reopened.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "duplicate.jsonl", .data = log.written() });
    const duplicate = try tmp.dir.openFile(std.testing.io, "duplicate.jsonl", .{ .mode = .read_write });
    defer duplicate.close(std.testing.io);
    try duplicate.writePositionalAll(std.testing.io, "{\"type\":\"message\",\"id\":\"0000000000000400\",\"message\":{\"role\":\"user\",\"content\":[]}}\n", log.written().len);
    const duplicate_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/duplicate.jsonl", .{&tmp.sub_path});
    defer a.free(duplicate_path);
    try std.testing.expectError(error.DuplicateSessionEntry, session.Store.open(a, std.testing.io, duplicate_path));
}

test "session append enforces the inclusive reopen limit before file and index changes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bounded.jsonl", .{&tmp.sub_path});
    defer a.free(path);
    var store = try session.Store.create(a, std.testing.io, path, "/workspace");
    defer store.deinit();
    const message: model.Message = .{ .role = .user, .content = &.{.{ .text = "bounded" }} };
    _ = try store.appendMessage(message);
    const first_offset = store.write_offset;
    _ = try store.appendMessage(message);
    const committed_offset = store.write_offset;
    const record_size = committed_offset - first_offset;
    const next_id = store.next_id;
    const leaf = store.active_leaf.?;
    // Exercise the boundary without allocating a 128 MiB transcript. Rejected
    // appends must leave the real small file and every committed index intact.
    for ([_]u64{ session.max_session_bytes, session.max_session_bytes + 1, session.max_session_bytes - record_size + 1, std.math.maxInt(u64) }) |offset| {
        store.write_offset = offset;
        try std.testing.expectError(error.SessionTooLarge, store.appendMessage(message));
        try std.testing.expectEqual(offset, store.write_offset);
        try std.testing.expectEqual(committed_offset, try store.file.?.length(std.testing.io));
        try std.testing.expectEqual(next_id, store.next_id);
        try std.testing.expectEqualStrings(leaf, store.active_leaf.?);
        try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
        try std.testing.expectEqual(@as(usize, 2), store.id_index.count());
        try std.testing.expect(!store.failed);
    }
    // A sparse positional write proves that exactly reaching the limit is
    // accepted, including the newline commit marker. No giant buffer is read.
    store.write_offset = session.max_session_bytes - record_size;
    _ = try store.appendMessage(message);
    try std.testing.expectEqual(@as(u64, session.max_session_bytes), store.write_offset);
    try std.testing.expectEqual(@as(u64, session.max_session_bytes), try store.file.?.length(std.testing.io));
    var final_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try store.file.?.readPositionalAll(std.testing.io, &final_byte, session.max_session_bytes - 1));
    try std.testing.expectEqual(@as(u8, '\n'), final_byte[0]);
    try std.testing.expectEqual(@as(usize, 3), store.id_index.count());
    try std.testing.expectError(error.SessionTooLarge, store.appendMessage(message));
}

test "jsonl session reloads messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/session.jsonl", .{&tmp.sub_path});
    var store = try session.Store.create(std.testing.allocator, std.testing.io, path, "/workspace");
    const content = [_]model.Content{.{ .text = "hello" }};
    _ = try store.appendMessage(.{ .role = .user, .content = &content });
    store.deinit();
    var reopened = try session.Store.open(std.testing.allocator, std.testing.io, path);
    defer reopened.deinit();
    const active = try reopened.activePath(std.testing.allocator);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings("hello", active[0].message.content[0].text);
}

test "tree branch summaries attach atomically to the selected user branch and survive reload" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/branch-summary.jsonl", .{&tmp.sub_path});
    defer a.free(path);

    var store = try session.Store.create(a, std.testing.io, path, "/workspace");
    var store_open = true;
    defer if (store_open) store.deinit();
    _ = try store.appendMessage(.{ .role = .system, .content = &.{.{ .text = "system" }} });
    const target = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "target request" }} });
    _ = try store.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "target answer" }} });
    const old_user = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "explore alternative" }} });
    _ = try store.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "alternative done" }} });

    const departed = try store.departedPath(a, target);
    defer a.free(departed);
    try std.testing.expectEqual(@as(usize, 3), departed.len);
    try std.testing.expectEqualStrings("target answer", departed[0].message.content[0].text);
    try std.testing.expectEqualStrings("explore alternative", departed[1].message.content[0].text);
    try std.testing.expectEqualStrings("alternative done", departed[2].message.content[0].text);

    const original_leaf = store.active_leaf.?;
    const summary_id = try a.dupe(u8, try store.branchWithSummary(target, "## Goal\nAlternative exploration"));
    defer a.free(summary_id);
    const old_path = try store.pathFrom(a, original_leaf);
    defer a.free(old_path);
    try std.testing.expectEqualStrings(summary_id, store.active_leaf.?);
    try std.testing.expectEqualStrings(original_leaf, store.entries.items[store.entries.items.len - 1].branch_summary.?.from_id);
    try std.testing.expectEqualStrings("## Goal\nAlternative exploration", store.entries.last().?.branch_summary.?.summary);

    const active = try store.projectedActivePath(a);
    defer a.free(active);
    try std.testing.expectEqual(@as(usize, 3), active.len);
    try std.testing.expectEqualStrings("target request", active[1].message.content[0].text);
    try std.testing.expectEqualStrings("The following is a summary of a branch that this conversation came back from:\n\n<summary>\n## Goal\nAlternative exploration</summary>", active[2].message.content[0].text);
    try std.testing.expectEqual(@as(usize, 5), old_path.len);
    try std.testing.expectEqualStrings(old_user, old_path[3].id);
    store.deinit();
    store_open = false;

    var reopened = try session.Store.open(a, std.testing.io, path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings(summary_id, reopened.active_leaf.?);
    const restored = try reopened.projectedActivePath(a);
    defer a.free(restored);
    try std.testing.expectEqual(@as(usize, 3), restored.len);
    try std.testing.expect(restored[2].branch_summary != null);
    try std.testing.expectEqualStrings("## Goal\nAlternative exploration", restored[2].branch_summary.?.summary);
}

test "tree summary rejects invalid and converged navigation without changing the active leaf" {
    const a = std.testing.allocator;
    var store = session.Store.memory(a, std.testing.io);
    defer store.deinit();
    const root = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "root" }} });
    _ = try store.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "answer" }} });
    const tip = store.active_leaf.?;
    try std.testing.expectError(error.SameSessionEntry, store.branchWithSummary(tip, "summary"));
    try std.testing.expectError(error.InvalidBranchSummary, store.branchWithSummary(root, "  "));
    try std.testing.expectEqualStrings(tip, store.active_leaf.?);
}

test "compaction entries persist project kept span preserve system prompt and keep raw branch intact" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/compacted.jsonl", .{&tmp.sub_path});
    defer a.free(path);

    var store = try session.Store.create(a, std.testing.io, path, "/workspace");
    _ = try store.appendMessage(.{ .role = .system, .content = &.{.{ .text = "sys-v1" }} });
    const user1 = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "old question" }} });
    const asst1 = try store.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "old answer" }} });
    const a1_owned = try a.dupe(u8, asst1);
    defer a.free(a1_owned);
    _ = user1;
    const user2 = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "kept question" }} });
    const u2_owned = try a.dupe(u8, user2);
    defer a.free(u2_owned);
    _ = try store.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "kept answer" }} });
    _ = try store.appendCompaction("## Goal\nKeep going", u2_owned, 5000);
    _ = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "follow up" }} });
    store.deinit();

    var reopened = try session.Store.open(a, std.testing.io, path);
    defer reopened.deinit();
    const projected = try reopened.projectedActivePath(a);
    defer a.free(projected);
    try std.testing.expectEqual(@as(usize, 5), projected.len);
    try std.testing.expectEqual(model.Role.system, projected[0].message.role);
    try std.testing.expectEqualStrings("sys-v1", projected[0].message.content[0].text);
    try std.testing.expect(projected[1].compaction != null);
    try std.testing.expect(std.mem.indexOf(u8, projected[1].message.content[0].text, "## Goal\nKeep going") != null);
    try std.testing.expectEqualStrings("kept question", projected[2].message.content[0].text);
    try std.testing.expectEqualStrings("kept answer", projected[3].message.content[0].text);
    try std.testing.expectEqualStrings("follow up", projected[4].message.content[0].text);

    // Branching to an entry before compaction still sees the raw uncompacted history.
    const pre_branch = try reopened.projectedPathFrom(a, a1_owned);
    defer a.free(pre_branch);
    try std.testing.expectEqual(@as(usize, 3), pre_branch.len);
    try std.testing.expectEqualStrings("old answer", pre_branch[2].message.content[0].text);
}

test "deferred session avoids file creation for system-only history and flushes on first user message" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/lazy.jsonl", .{&tmp.sub_path});
    defer a.free(path);

    {
        var store = try session.Store.deferred(a, std.testing.io, path, "/workspace");
        defer store.deinit();
        _ = try store.appendMessage(.{ .role = .system, .content = &.{.{ .text = "initial sys" }} });
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));

    {
        var store = try session.Store.deferred(a, std.testing.io, path, "/workspace");
        defer store.deinit();
        _ = try store.appendMessage(.{ .role = .system, .content = &.{.{ .text = "initial sys" }} });
        _ = try store.appendMessage(.{ .role = .user, .content = &.{.{ .text = "hello" }} });
    }

    var reopened = try session.Store.open(a, std.testing.io, path);
    defer reopened.deinit();
    const active = try reopened.activePath(a);
    defer a.free(active);
    try std.testing.expectEqual(@as(usize, 2), active.len);
    try std.testing.expectEqual(model.Role.system, active[0].message.role);
    try std.testing.expectEqualStrings("initial sys", active[0].message.content[0].text);
    try std.testing.expectEqual(model.Role.user, active[1].message.role);
    try std.testing.expectEqualStrings("hello", active[1].message.content[0].text);
}
