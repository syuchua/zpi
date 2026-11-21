//! Bounded read-only conversion of a pi v3 active branch to a text transcript.
const std = @import("std");
const model = @import("model");
const session = @import("session");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const Transcript = struct { cwd: []const u8, messages: []const model.Message };
const Entry = struct {
    kind: []const u8,
    parent: ?usize,
    record: Value,
    path_position: ?usize = null,
    // A null JSON value means omit; Zig null means unchanged.
    replacement_content: ?Value = null,
};
const PendingCall = struct { id: []const u8, name: []const u8 };
const max_entries = 100_000;
const max_tool_calls = 64;
const max_input_bytes = 32 * 1024 * 1024;
const max_json_depth = 64;

/// Convert a snapshot of a regular file. The destination is published atomically
/// after validation and serialization, and must be a new file.
pub fn convert(allocator: Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const metadata = try dir.statFile(io, source, .{ .follow_symlinks = false });
    if (metadata.kind != .file) return error.PiSessionNotRegularFile;
    // A FIFO substituted between stat and open must not block the importer.
    const handle = try std.posix.openat(dir.handle, source, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0);
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.inode != metadata.inode or before.ctime.nanoseconds != metadata.ctime.nanoseconds)
        return error.SessionChanged;
    if (before.size > max_input_bytes) return error.PiSessionTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    defer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.SessionChanged;
    const after = try file.stat(io);
    if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds or
        after.ctime.nanoseconds != before.ctime.nanoseconds or after.inode != before.inode or
        after.kind != .file) return error.SessionChanged;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const transcript = try parse(arena.allocator(), bytes, session.max_record_bytes);
    try session.writeTranscript(allocator, io, destination, transcript.cwd, transcript.messages);
}

/// `a` is a temporary arena. The transcript may borrow from `bytes`.
fn parse(a: Allocator, bytes: []const u8, record_limit: usize) !Transcript {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidPiSessionUtf8;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return error.InvalidPiSessionHeader;
    const header = try parseLine(a, first, record_limit);
    if (!equal(try string(try field(header, "type")), "session") or header.object.contains("format")) return error.InvalidPiSessionHeader;
    const version = header.object.get("version") orelse return error.UnsupportedPiSessionVersion;
    if (version != .number_string or !equal(version.number_string, "3")) return error.UnsupportedPiSessionVersion;
    _ = try identifier(try field(header, "id"));
    const cwd = try string(try field(header, "cwd"));
    if (!std.fs.path.isAbsolute(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidPiSessionCwd;

    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len > record_limit + 1 or std.mem.trimEnd(u8, line, "\r").len > record_limit) return error.SessionRecordTooLarge;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        if (entries.items.len == max_entries) return error.TooManyPiSessionEntries;
        const entry = try parseLine(a, line, record_limit);
        const kind = try string(try field(entry, "type"));
        if (equal(kind, "session")) return error.InvalidPiSessionHeader;
        const id = try identifier(try field(entry, "id"));
        if (index.contains(id)) return error.DuplicatePiSessionEntry;
        const parent_value = try field(entry, "parentId");
        if (parent_value != .null and parent_value != .string) return error.InvalidPiSessionParent;
        const parent = if (parent_value == .null) null else index.get(try identifier(parent_value)) orelse return error.UnknownPiSessionParent;
        try index.put(a, id, entries.items.len);
        try entries.append(a, .{ .kind = kind, .parent = parent, .record = entry });
    }

    // Pi reconstructs its active leaf on reopen using the last entry.
    var path: std.ArrayList(usize) = .empty;
    var cursor: ?usize = if (entries.items.len == 0) null else entries.items.len - 1;
    while (cursor) |i| {
        try path.append(a, i);
        cursor = entries.items[i].parent;
    }
    std.mem.reverse(usize, path.items);
    var compaction_position: ?usize = null;
    for (path.items, 0..) |entry_index, position| {
        entries.items[entry_index].path_position = position;
        if (equal(entries.items[entry_index].kind, "compaction")) compaction_position = position;
    }
    const first_kept = if (compaction_position) |position| blk: {
        const compaction = entries.items[path.items[position]].record;
        const id = try identifier(try field(compaction, "firstKeptEntryId"));
        const kept_entry = index.get(id) orelse return error.InvalidPiCompactionRange;
        const kept_position = entries.items[kept_entry].path_position orelse return error.InvalidPiCompactionRange;
        // Pi uses the compaction's own ID to retain no preceding entries.
        if (kept_position > position) return error.InvalidPiCompactionRange;
        break :blk kept_position;
    } else 0;

    // Only retained edits contribute to pi's model context. Walk newest first
    // so only the effective replacement is decoded.
    var edit_path = std.mem.reverseIterator(path.items[first_kept..]);
    while (edit_path.next()) |entry_index| {
        const edit = entries.items[entry_index];
        if (!equal(edit.kind, "context_edit")) continue;
        const target_id = try identifier(try field(edit.record, "targetId"));
        const target_index = index.get(target_id) orelse return error.UnsupportedPiContextEdit;
        const target = &entries.items[target_index];
        const target_position = target.path_position orelse return error.UnsupportedPiContextEdit;
        if (target_index >= entry_index) return error.UnsupportedPiContextEdit;
        if (target_position < first_kept or target.replacement_content != null) continue;
        const target_kind = target.kind;
        if (!equal(target_kind, "message") and !equal(target_kind, "custom_message")) return error.UnsupportedPiContextEdit;
        const target_message = if (equal(target_kind, "message")) try field(target.record, "message") else target.record;
        const role = if (equal(target_kind, "custom_message")) "custom" else try string(try field(target_message, "role"));
        if (!equal(role, "user") and !equal(role, "assistant") and !equal(role, "toolResult") and !equal(role, "custom")) return error.UnsupportedPiContextEdit;
        const replacement = try field(edit.record, "replacement");
        target.replacement_content = if (replacement == .null) .{ .null = {} } else blk: {
            if (replacement != .object) return error.InvalidPiContextEdit;
            const content = replacement.object.get("content") orelse return error.InvalidPiContextEdit;
            if (content != .string and content != .array) return error.InvalidPiContextEdit;
            break :blk content;
        };
    }
    var messages: std.ArrayList(model.Message) = .empty;
    var calls: std.ArrayList(PendingCall) = .empty;
    var conversation_seen = false;
    var system_seen = false;
    if (compaction_position) |position| {
        const compaction = entries.items[path.items[position]].record;
        if (compaction.object.get("systemMessage")) |checkpoint| {
            if (!equal(try string(try field(checkpoint, "role")), "system")) return error.InvalidPiSessionRecord;
            try appendSystemPrompt(a, &messages, checkpoint, try field(checkpoint, "content"));
        }
        const summary = try string(try field(compaction, "summary"));
        const text = try std.fmt.allocPrint(a, "The conversation history before this point was compacted into the following summary:\n\n<summary>\n{s}\n</summary>", .{summary});
        const content = try a.dupe(model.Content, &.{.{ .text = text }});
        try messages.append(a, .{ .role = .user, .content = content });
        conversation_seen = true;
    }
    for (path.items[first_kept..], first_kept..) |i, position| {
        const entry = entries.items[i];
        if (equal(entry.kind, "compaction")) continue;
        if (equal(entry.kind, "branch_summary")) {
            const summary = try string(try field(entry.record, "summary"));
            if (summary.len == 0) continue;
            if (calls.items.len != 0) return error.UnsupportedPiToolHistory;
            const text = try std.fmt.allocPrint(a, "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n{s}</summary>", .{summary});
            const content = try a.dupe(model.Content, &.{.{ .text = text }});
            try messages.append(a, .{ .role = .user, .content = content });
            conversation_seen = true;
            continue;
        }
        const is_custom_message = equal(entry.kind, "custom_message");
        if (!equal(entry.kind, "message") and !is_custom_message) {
            if (equal(entry.kind, "label") or equal(entry.kind, "session_info") or
                equal(entry.kind, "usage") or equal(entry.kind, "model_change") or
                equal(entry.kind, "thinking_level_change") or equal(entry.kind, "custom") or
                equal(entry.kind, "context_edit")) continue;
            return error.UnsupportedPiSessionEntry;
        }
        const value = if (is_custom_message) entry.record else try field(entry.record, "message");
        const role_text = if (is_custom_message) "custom" else try string(try field(value, "role"));
        // The latest compaction checkpoint supersedes retained system entries.
        if (compaction_position) |cut| {
            if (position < cut and equal(role_text, "system")) continue;
        }
        const content = if (entry.replacement_content) |replacement| blk: {
            if (replacement == .null) continue;
            break :blk replacement;
        } else try field(value, "content");
        var parts: std.ArrayList(model.Content) = .empty;
        if (equal(role_text, "toolResult")) {
            const call_id = try identifier(try field(value, "toolCallId"));
            const tool_name = try string(try field(value, "toolName"));
            const match = for (calls.items, 0..) |call, j| {
                if (equal(call.id, call_id)) break j;
            } else return error.UnsupportedPiToolHistory;
            if (!equal(calls.items[match].name, tool_name)) return error.UnsupportedPiToolHistory;
            _ = calls.swapRemove(match);
            try appendText(a, &parts, content);
            const is_error = try field(value, "isError");
            if (is_error != .bool) return error.InvalidPiSessionRecord;
            try messages.append(a, .{
                .role = .tool_result,
                .content = parts.items,
                .tool_call_id = call_id,
                .tool_name = tool_name,
                .is_error = is_error.bool,
                .details = value.object.get("details"),
            });
            continue;
        }
        // Pi projects extension-injected text as user content.
        const role: model.Role = if (equal(role_text, "user") or equal(role_text, "custom"))
            .user
        else if (equal(role_text, "system"))
            .system
        else if (equal(role_text, "assistant"))
            .assistant
        else
            return error.UnsupportedPiSessionRole;
        if (calls.items.len != 0) return error.UnsupportedPiToolHistory;
        switch (role) {
            .system => {
                if (system_seen or conversation_seen) return error.UnsupportedPiSystemUpdate;
                system_seen = true;
                try appendSystemPrompt(a, &messages, value, content);
                continue;
            },
            .user => {
                try appendText(a, &parts, content);
                const flattened = try joinParts(a, parts.items, "\n");
                parts.clearRetainingCapacity();
                if (std.mem.trim(u8, flattened, " \t\r\n").len == 0) return error.UnsupportedPiUserContent;
                try parts.append(a, .{ .text = flattened });
                conversation_seen = true;
            },
            .assistant => {
                if (!conversation_seen) return error.UnsupportedPiAssistantCompletion;
                const stop_reason = try string(try field(value, "stopReason"));
                if (!equal(stop_reason, "stop") and !equal(stop_reason, "toolUse")) return error.UnsupportedPiAssistantCompletion;
                if (value.object.contains("deferred")) return error.UnsupportedPiAssistantCompletion;
                if (value.object.get("errorMessage")) |error_message| if (error_message != .null) return error.UnsupportedPiAssistantCompletion;
                if (entry.replacement_content != null) {
                    if (!equal(stop_reason, "stop")) return error.UnsupportedPiContextEdit;
                    try appendText(a, &parts, content);
                } else {
                    if (content != .array) return error.InvalidPiSessionRecord;
                    for (content.array.items) |block| {
                        const block_type = try string(try field(block, "type"));
                        if (equal(block_type, "text")) {
                            if (block.object.contains("textSignature") or block.object.contains("encryptedContent")) return error.UnsupportedPiSessionContent;
                            try parts.append(a, .{ .text = try string(try field(block, "text")) });
                        } else if (equal(block_type, "toolCall") and equal(stop_reason, "toolUse")) {
                            const id = try identifier(try field(block, "id"));
                            const name = try string(try field(block, "name"));
                            if (!validToolName(name) or !validToolName(id) or
                                block.object.contains("thoughtSignature") or block.object.contains("namespace") or
                                block.object.contains("argumentsError")) return error.UnsupportedPiSessionContent;
                            if (calls.items.len == max_tool_calls) return error.TooManyPiToolCalls;
                            const arguments = try field(block, "arguments");
                            if (arguments != .object) return error.InvalidPiSessionRecord;
                            for (calls.items) |previous| if (equal(previous.id, id)) return error.DuplicatePiToolCall;
                            try calls.append(a, .{ .id = id, .name = name });
                            try parts.append(a, .{ .tool_call = .{ .id = id, .name = name, .arguments = arguments } });
                        } else return error.UnsupportedPiSessionContent;
                    }
                }
                if (equal(stop_reason, "toolUse")) {
                    if (calls.items.len == 0) return error.InvalidPiToolCall;
                } else {
                    for (parts.items) |part| {
                        if (std.mem.trim(u8, part.text, " \t\r\n").len > 0) break;
                    } else return error.UnsupportedPiAssistantContent;
                }
            },
            .tool_result => return error.UnsupportedPiSessionRole,
        }
        try messages.append(a, .{ .role = role, .content = parts.items });
    }
    if (calls.items.len != 0) return error.UnsupportedPiToolHistory;
    if (!conversation_seen) return error.EmptyPiConversation;
    return .{ .cwd = cwd, .messages = messages.items };
}

fn appendSystemPrompt(a: Allocator, messages: *std.ArrayList(model.Message), value: Value, content: Value) !void {
    var parts: std.ArrayList(model.Content) = .empty;
    try appendText(a, &parts, content);
    const main_text = try joinParts(a, parts.items, "\n");
    parts.clearRetainingCapacity();
    if (main_text.len > 0) try parts.append(a, .{ .text = main_text });
    // Tool declarations are invocation settings in Zpi.
    for ([_][]const u8{ "toolsAdded", "toolsRemoved" }) |key| {
        if (value.object.get(key)) |tools| if (tools != .array) return error.InvalidPiSessionRecord;
    }
    if (value.object.get("sections")) |sections| {
        if (sections != .object) return error.InvalidPiSessionRecord;
        const keys = try a.dupe([]const u8, sections.object.keys());
        std.mem.sort([]const u8, keys, {}, sectionLessThan);
        for (keys) |key| switch (sections.object.get(key).?) {
            .null => {},
            .string => |text| if (text.len > 0) try parts.append(a, .{ .text = text }),
            else => return error.InvalidPiSessionRecord,
        };
    }
    const prompt_text = try joinParts(a, parts.items, "\n\n");
    if (prompt_text.len == 0) return;
    parts.clearRetainingCapacity();
    try parts.append(a, .{ .text = prompt_text });
    try messages.append(a, .{ .role = .system, .content = parts.items });
}

fn joinParts(a: Allocator, parts: []const model.Content, separator: []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0].text;
    const texts = try a.alloc([]const u8, parts.len);
    for (parts, texts) |part, *text| text.* = part.text;
    return std.mem.join(a, separator, texts);
}

// JavaScript Object.values enumerates array-index keys before other keys.
fn sectionLessThan(_: void, left: []const u8, right: []const u8) bool {
    return sectionIndex(left) < sectionIndex(right);
}

fn sectionIndex(key: []const u8) u32 {
    const non_index = std.math.maxInt(u32);
    if (key.len == 0 or (key.len > 1 and key[0] == '0')) return non_index;
    for (key) |ch| if (!std.ascii.isDigit(ch)) return non_index;
    return std.fmt.parseInt(u32, key, 10) catch non_index;
}

fn appendText(a: Allocator, parts: *std.ArrayList(model.Content), content: Value) !void {
    switch (content) {
        .string => |text| try parts.append(a, .{ .text = text }),
        .array => |blocks| for (blocks.items) |block| {
            if (!equal(try string(try field(block, "type")), "text")) return error.UnsupportedPiSessionContent;
            if (block.object.contains("textSignature") or block.object.contains("encryptedContent")) return error.UnsupportedPiSessionContent;
            try parts.append(a, .{ .text = try string(try field(block, "text")) });
        },
        else => return error.InvalidPiSessionRecord,
    }
}

fn parseLine(a: Allocator, line: []const u8, limit: usize) !Value {
    const text = std.mem.trimEnd(u8, line, "\r");
    if (text.len > limit) return error.SessionRecordTooLarge;
    // Bound nesting before the recursive dynamic JSON parser runs.
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (text) |c| {
        if (quoted) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
        } else switch (c) {
            '"' => quoted = true,
            '[', '{' => {
                depth += 1;
                if (depth > max_json_depth) return error.PiSessionRecordTooDeep;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .parse_numbers = false, .max_value_len = limit }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPiSessionRecord,
    };
}

fn field(value: Value, key: []const u8) !Value {
    if (value != .object) return error.InvalidPiSessionRecord;
    return value.object.get(key) orelse error.InvalidPiSessionRecord;
}

fn string(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidPiSessionRecord;
    return value.string;
}

fn identifier(value: Value) ![]const u8 {
    const id = try string(value);
    if (id.len == 0 or id.len > 128 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidPiSessionId;
    return id;
}

fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "pi v3 importer follows the last leaf and preserves closed tool history" {
    const fixture =
        "{\"type\":\"session\",\"version\":3,\"id\":\"session\",\"cwd\":\"/workspace\"}\n" ++
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"task\"}}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"2025-01-01T00:00:01.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"c1\",\"name\":\"read\",\"arguments\":{\"path\":\"x\"}}],\"stopReason\":\"toolUse\"}}\n" ++
        "{\"type\":\"message\",\"id\":\"r1\",\"parentId\":\"a1\",\"timestamp\":\"2025-01-01T00:00:02.000Z\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"c1\",\"toolName\":\"read\",\"content\":[{\"type\":\"text\",\"text\":\"file\"}],\"isError\":false}}\n" ++
        "{\"type\":\"message\",\"id\":\"a2\",\"parentId\":\"r1\",\"timestamp\":\"2025-01-01T00:00:03.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"stopReason\":\"stop\"}}\n" ++
        "{\"type\":\"compaction\",\"id\":\"other\",\"parentId\":\"u1\",\"timestamp\":\"2025-01-01T00:00:04.000Z\",\"summary\":\"inactive\"}\n" ++
        "{\"type\":\"label\",\"id\":\"leaf\",\"parentId\":\"a2\",\"timestamp\":\"2025-01-01T00:00:05.000Z\",\"targetId\":\"u1\",\"label\":\"active\"}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), fixture, session.max_record_bytes);
    try std.testing.expectEqualStrings("/workspace", result.cwd);
    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
    try std.testing.expectEqualStrings("task", result.messages[0].content[0].text);
    try std.testing.expectEqual(model.Role.assistant, result.messages[1].role);
    try std.testing.expectEqualStrings("c1", result.messages[1].content[0].tool_call.id);
    try std.testing.expectEqual(model.Role.tool_result, result.messages[2].role);
    try std.testing.expectEqualStrings("file", result.messages[2].content[0].text);
    try std.testing.expectEqualStrings("done", result.messages[3].content[0].text);
}

test "pi v3 importer rejects unsupported active context and malformed tool pairs" {
    const header = "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"cwd\":\"/workspace\"}\n";
    const unsupported = header ++ "{\"type\":\"new_entry_type\",\"id\":\"c\",\"parentId\":null}\n";
    const missing_result = header ++
        "{\"type\":\"message\",\"id\":\"u\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"task\"}}\n" ++
        "{\"type\":\"message\",\"id\":\"a\",\"parentId\":\"u\",\"timestamp\":\"2025-01-01T00:00:01.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"c1\",\"name\":\"read\",\"arguments\":{}}],\"stopReason\":\"toolUse\"}}\n";
    const malformed_result = missing_result ++
        "{\"type\":\"message\",\"id\":\"r\",\"parentId\":\"a\",\"timestamp\":\"2025-01-01T00:00:02.000Z\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"other\",\"toolName\":\"read\",\"content\":[],\"isError\":false}}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedPiSessionEntry, parse(arena.allocator(), unsupported, session.max_record_bytes));
    try std.testing.expectError(error.UnsupportedPiToolHistory, parse(arena.allocator(), missing_result, session.max_record_bytes));
    try std.testing.expectError(error.UnsupportedPiToolHistory, parse(arena.allocator(), malformed_result, session.max_record_bytes));
}

test "pi v3 importer enforces strict JSON and record limits" {
    const header = "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"cwd\":\"/workspace\"}\n";
    const bad_utf8 = [_]u8{0xff};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidPiSessionUtf8, parse(arena.allocator(), &bad_utf8, session.max_record_bytes));
    try std.testing.expectError(error.SessionRecordTooLarge, parse(arena.allocator(), header, 8));
    const malformed = header ++ "{\"type\":\"label\",\"id\":\"l\",\"parentId\":null,\"value\":[]}}\n";
    try std.testing.expectError(error.InvalidPiSessionRecord, parse(arena.allocator(), malformed, session.max_record_bytes));
    var nested = std.ArrayList(u8).empty;
    try nested.appendSlice(arena.allocator(), header);
    try nested.appendSlice(arena.allocator(), "{\"value\":");
    for (0..max_json_depth) |_| try nested.append(arena.allocator(), '[');
    try nested.append(arena.allocator(), '0');
    for (0..max_json_depth) |_| try nested.append(arena.allocator(), ']');
    try nested.appendSlice(arena.allocator(), "}\n");
    const deep = nested.items;
    try std.testing.expectError(error.PiSessionRecordTooDeep, parse(arena.allocator(), deep, session.max_record_bytes));
    const user = "{\"type\":\"message\",\"id\":\"u\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}\n";
    try std.testing.expectError(error.DuplicatePiSessionEntry, parse(arena.allocator(), header ++ user ++ user, session.max_record_bytes));
    const orphan = header ++ "{\"type\":\"label\",\"id\":\"l\",\"parentId\":\"missing\",\"timestamp\":\"2025-01-01T00:00:00.000Z\"}\n";
    try std.testing.expectError(error.UnknownPiSessionParent, parse(arena.allocator(), orphan, session.max_record_bytes));
}
