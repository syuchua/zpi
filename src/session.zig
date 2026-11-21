//! Zpi-owned, versioned append-only JSONL sessions. This schema is not pi v3.
//! Parsed and appended messages live in the store arena until deinit. One
//! writer holds an exclusive advisory lock; writes use explicit file offsets.
const std = @import("std");
const model = @import("model");
const agent = @import("agent");
const compaction = @import("compaction");

pub const max_session_bytes = 128 * 1024 * 1024;
pub const max_record_bytes = 8 * 1024 * 1024;

pub const CompactionView = struct {
    summary: []const u8,
    first_kept_id: ?[]const u8 = null,
    tokens_before: u64 = 0,
};

pub const EntryView = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    message: model.Message,
    compaction: ?CompactionView = null,
};

const Record = struct {
    type: enum { session, message, leaf, compaction },
    version: u32 = 1,
    format: []const u8 = "zpi",
    cwd: ?[]const u8 = null,
    id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    message: ?model.Message = null,
    summary: ?[]const u8 = null,
    first_kept_id: ?[]const u8 = null,
    tokens_before: ?u64 = null,
};

/// Publish a linear transcript under a new path after all records are written.
pub fn writeTranscript(allocator: std.mem.Allocator, io: std.Io, path: []const u8, cwd: []const u8, messages: []const model.Message) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = .fromMode(0o600) });
    defer atomic.deinit(io);
    var offset: u64 = 0;
    try writeRecordAt(allocator, io, atomic.file, &offset, .{ .type = .session, .cwd = cwd });
    for (messages, 0..) |message, i| {
        try model.validateSystemCheckpoint(message);
        var id: [16]u8 = undefined;
        var parent_id: [16]u8 = undefined;
        try writeRecordAt(allocator, io, atomic.file, &offset, .{
            .type = .message,
            .version = if (message.system_prompt_replace) 2 else 1,
            .id = try std.fmt.bufPrint(&id, "{x:0>16}", .{i + 1}),
            .parent_id = if (i == 0) null else try std.fmt.bufPrint(&parent_id, "{x:0>16}", .{i}),
            .message = message,
        });
    }
    try atomic.file.sync(io);
    try atomic.link(io);
}

fn writeRecordAt(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, offset: *u64, record: Record) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, record, .{ .emit_null_optional_fields = false });
    defer allocator.free(encoded);
    try checkRecordSize(encoded.len, offset.*);
    try file.writePositionalAll(io, encoded, offset.*);
    try file.writePositionalAll(io, "\n", offset.* + encoded.len);
    offset.* += encoded.len + 1;
}

fn checkRecordSize(len: usize, offset: u64) !void {
    if (len > max_record_bytes) return error.SessionRecordTooLarge;
    if (offset > max_session_bytes or len + 1 > max_session_bytes - offset) return error.SessionTooLarge;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    file_path: ?[]const u8 = null,
    entries: std.ArrayList(EntryView) = .empty,
    id_index: std.StringHashMapUnmanaged(usize) = .empty,
    active_leaf: ?[]const u8 = null,
    cwd: []const u8 = "",
    next_id: u64 = 1,
    file: ?std.Io.File = null,
    write_offset: u64 = 0,
    corrupt_line: ?usize = null,
    failed: bool = false,

    pub fn memory(allocator: std.mem.Allocator, io: std.Io) Store {
        return .{ .allocator = allocator, .io = io, .arena = .init(allocator) };
    }
    /// Never truncate an existing session: creation must use a fresh path.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, path: []const u8, cwd: []const u8) !Store {
        var store = memory(allocator, io);
        errdefer store.deinit();
        if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        store.file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        });
        store.cwd = try store.arena.allocator().dupe(u8, cwd);
        store.file_path = try store.arena.allocator().dupe(u8, path);
        try store.writeRecord(.{ .type = .session, .cwd = cwd });
        return store;
    }
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        var store = memory(allocator, io);
        errdefer store.deinit();
        // Do not follow a session symlink or block while opening a FIFO swapped
        // into the selected path. Check the type before locking or reading.
        const handle = try std.posix.openat(std.Io.Dir.cwd().handle, path, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0);
        store.file = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        const file = store.file.?;
        const metadata = try file.stat(io);
        if (metadata.kind != .file) return error.SessionNotRegularFile;
        if (!try file.tryLock(io, .exclusive)) return error.WouldBlock;
        store.file_path = try store.arena.allocator().dupe(u8, path);
        const len = try file.length(io);
        if (len > max_session_bytes) return error.SessionTooLarge;
        const bytes = try allocator.alloc(u8, @intCast(len));
        defer allocator.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != len) return error.SessionChanged;
        try store.parse(bytes);
        // A newline is the commit marker. Remove a torn final record before
        // appending; completed malformed records fail instead of being skipped.
        if (store.write_offset < len) try file.setLength(io, store.write_offset);
        return store;
    }
    pub fn deinit(self: *Store) void {
        if (self.file) |file| file.close(self.io);
        self.entries.deinit(self.allocator);
        self.id_index.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn appendMessage(self: *Store, message: model.Message) ![]const u8 {
        if (self.failed) return error.SessionWriteFailed;
        if (self.next_id == std.math.maxInt(u64)) return error.SessionIdExhausted;
        const a = self.arena.allocator();
        const id = try std.fmt.allocPrint(a, "{x:0>16}", .{self.next_id});
        try model.validateSystemCheckpoint(message);
        const owned = try agent.cloneMessage(a, message);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.id_index.ensureUnusedCapacity(self.allocator, 1);
        try self.writeRecord(.{ .type = .message, .version = if (owned.system_prompt_replace) 2 else 1, .id = id, .parent_id = self.active_leaf, .message = owned });
        self.entries.appendAssumeCapacity(.{ .id = id, .parent_id = self.active_leaf, .message = owned });
        self.id_index.putAssumeCapacityNoClobber(id, self.entries.items.len - 1);
        self.next_id += 1;
        self.active_leaf = id;
        return id;
    }
    pub fn appendCompaction(self: *Store, summary: []const u8, first_kept_id: ?[]const u8, tokens_before: u64) ![]const u8 {
        if (self.failed) return error.SessionWriteFailed;
        if (self.next_id == std.math.maxInt(u64)) return error.SessionIdExhausted;
        if (summary.len == 0 or !std.unicode.utf8ValidateSlice(summary)) return error.InvalidCompactionSummary;
        if (first_kept_id) |kept| {
            if (self.find(kept) == null) return error.UnknownSessionEntry;
        }
        const a = self.arena.allocator();
        const id = try std.fmt.allocPrint(a, "{x:0>16}", .{self.next_id});
        const owned_summary = try a.dupe(u8, summary);
        const owned_kept = if (first_kept_id) |k| try a.dupe(u8, k) else null;
        const formatted = try compaction.formatSummaryUserText(a, owned_summary);
        const content = try a.dupe(model.Content, &.{.{ .text = formatted }});
        const synthetic = model.Message{ .role = .user, .content = content };
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.id_index.ensureUnusedCapacity(self.allocator, 1);
        try self.writeRecord(.{
            .type = .compaction,
            .version = 1,
            .id = id,
            .parent_id = self.active_leaf,
            .summary = owned_summary,
            .first_kept_id = owned_kept,
            .tokens_before = tokens_before,
        });
        self.entries.appendAssumeCapacity(.{
            .id = id,
            .parent_id = self.active_leaf,
            .message = synthetic,
            .compaction = .{ .summary = owned_summary, .first_kept_id = owned_kept, .tokens_before = tokens_before },
        });
        self.id_index.putAssumeCapacityNoClobber(id, self.entries.items.len - 1);
        self.next_id += 1;
        self.active_leaf = id;
        return id;
    }

    pub fn branch(self: *Store, target: []const u8) !void {
        const index = self.find(target) orelse return error.UnknownSessionEntry;
        return self.setLeaf(self.entries.items[index].id);
    }
    /// Record the active tip, including null to return to an empty root. Entries
    /// remain append-only; rollback changes only which branch supplies context.
    pub fn setLeaf(self: *Store, target: ?[]const u8) !void {
        const path = try self.pathFrom(self.allocator, target);
        defer self.allocator.free(path);
        try self.writeRecord(.{ .type = .leaf, .id = target });
        self.active_leaf = if (target) |id| self.entries.items[self.find(id).?].id else null;
    }
    pub fn activePath(self: *const Store, allocator: std.mem.Allocator) ![]EntryView {
        return self.pathFrom(allocator, self.active_leaf);
    }
    pub fn projectedActivePath(self: *const Store, allocator: std.mem.Allocator) ![]EntryView {
        return self.projectedPathFrom(allocator, self.active_leaf);
    }
    /// Projects the active branch up to `target`, applying the latest active
    /// compaction entry while preserving the latest system prompt checkpoint.
    pub fn projectedPathFrom(self: *const Store, allocator: std.mem.Allocator, target: ?[]const u8) ![]EntryView {
        const raw = try self.pathFrom(allocator, target);
        var comp_idx: ?usize = null;
        for (raw, 0..) |entry, idx| {
            if (entry.compaction != null) comp_idx = idx;
        }
        const cidx = comp_idx orelse return raw;
        defer allocator.free(raw);
        const comp = raw[cidx].compaction.?;
        const first_kept_idx = if (comp.first_kept_id) |kept_id| blk: {
            if (std.mem.eql(u8, kept_id, raw[cidx].id)) break :blk cidx;
            var found: ?usize = null;
            for (raw[0..cidx], 0..) |entry, idx| {
                if (std.mem.eql(u8, entry.id, kept_id)) {
                    found = idx;
                    break;
                }
            }
            break :blk found orelse return error.InvalidCompactionRange;
        } else cidx;

        var latest_sys: ?usize = null;
        for (raw[0..cidx], 0..) |entry, idx| {
            if (entry.message.role == .system) latest_sys = idx;
        }
        var out: std.ArrayList(EntryView) = .empty;
        errdefer out.deinit(allocator);
        if (latest_sys) |sidx| try out.append(allocator, raw[sidx]);
        try out.append(allocator, raw[cidx]);
        for (raw[first_kept_idx..cidx]) |entry| {
            if (entry.message.role == .system or entry.compaction != null) continue;
            try out.append(allocator, entry);
        }
        for (raw[cidx + 1 ..]) |entry| {
            try out.append(allocator, entry);
        }
        return out.toOwnedSlice(allocator);
    }
    /// Inspect a proposed branch before committing the active-leaf record.
    pub fn pathFrom(self: *const Store, allocator: std.mem.Allocator, target: ?[]const u8) ![]EntryView {
        if (target) |id| _ = self.find(id) orelse return error.UnknownSessionEntry;
        var reverse: std.ArrayList(EntryView) = .empty;
        errdefer reverse.deinit(allocator);
        var cursor = target;
        while (cursor) |id| {
            const index = self.find(id) orelse return error.CorruptSession;
            const entry = self.entries.items[index];
            try reverse.append(allocator, entry);
            cursor = entry.parent_id;
            if (reverse.items.len > self.entries.items.len) return error.SessionCycle;
        }
        std.mem.reverse(EntryView, reverse.items);
        return reverse.toOwnedSlice(allocator);
    }
    fn find(self: *const Store, id: []const u8) ?usize {
        return self.id_index.get(id);
    }
    fn writeRecord(self: *Store, record: Record) !void {
        if (self.failed) return error.SessionWriteFailed;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, record, .{ .emit_null_optional_fields = false });
        defer self.allocator.free(encoded);
        try self.writeEncodedRecord(encoded);
    }
    fn writeEncodedRecord(self: *Store, encoded: []const u8) !void {
        if (self.failed) return error.SessionWriteFailed;
        const file = self.file orelse return;
        try checkRecordSize(encoded.len, self.write_offset);
        const line = try std.mem.concat(self.allocator, u8, &.{ encoded, "\n" });
        defer self.allocator.free(line);
        errdefer self.failed = true;
        try file.writePositionalAll(self.io, line, self.write_offset);
        try file.sync(self.io);
        self.write_offset += line.len;
    }
    fn parse(self: *Store, bytes: []const u8) !void {
        var offset: usize = 0;
        var line_no: usize = 0;
        var header_seen = false;
        while (offset < bytes.len) {
            const lf = std.mem.indexOfScalarPos(u8, bytes, offset, '\n') orelse break;
            line_no += 1;
            self.corrupt_line = line_no;
            const line = std.mem.trimEnd(u8, bytes[offset..lf], "\r");
            if (line.len > max_record_bytes) return error.SessionRecordTooLarge;
            const parsed = std.json.parseFromSlice(Record, self.allocator, line, .{
                .max_value_len = max_record_bytes,
                .parse_numbers = false,
            }) catch return error.CorruptSessionEntry;
            defer parsed.deinit();
            const record = parsed.value;
            if (!std.mem.eql(u8, record.format, "zpi")) return error.UnsupportedSessionVersion;
            switch (record.type) {
                .session, .leaf, .compaction => if (record.version != 1) return error.UnsupportedSessionVersion,
                .message => {
                    if (record.version != 1 and record.version != 2) return error.UnsupportedSessionVersion;
                    if (record.message != null and record.message.?.system_prompt_replace != (record.version == 2)) return error.UnsupportedSystemPromptCheckpointVersion;
                    if (record.message) |message| try model.validateSystemCheckpoint(message);
                },
            }
            switch (record.type) {
                .session => {
                    if (header_seen or line_no != 1 or record.cwd == null) return error.InvalidSessionHeader;
                    self.cwd = try self.arena.allocator().dupe(u8, record.cwd.?);
                    header_seen = true;
                },
                .message => {
                    if (!header_seen) return error.MissingSessionHeader;
                    const id = record.id orelse return error.InvalidSessionEntry;
                    if (self.find(id) != null) return error.DuplicateSessionEntry;
                    const number = std.fmt.parseInt(u64, id, 16) catch return error.InvalidSessionEntry;
                    if (number == std.math.maxInt(u64)) return error.SessionIdExhausted;
                    if (record.parent_id) |parent| if (self.find(parent) == null) return error.UnknownParentEntry;
                    const a = self.arena.allocator();
                    const restored_message = try agent.cloneMessage(a, record.message orelse return error.InvalidSessionEntry);
                    const entry = EntryView{
                        .id = try a.dupe(u8, id),
                        .parent_id = if (record.parent_id) |p| try a.dupe(u8, p) else null,
                        .message = restored_message,
                    };
                    try self.entries.ensureUnusedCapacity(self.allocator, 1);
                    try self.id_index.ensureUnusedCapacity(self.allocator, 1);
                    self.entries.appendAssumeCapacity(entry);
                    self.id_index.putAssumeCapacityNoClobber(entry.id, self.entries.items.len - 1);
                    self.active_leaf = entry.id;
                    self.next_id = @max(self.next_id, number + 1);
                },
                .compaction => {
                    if (!header_seen) return error.MissingSessionHeader;
                    const id = record.id orelse return error.InvalidSessionEntry;
                    if (self.find(id) != null) return error.DuplicateSessionEntry;
                    const number = std.fmt.parseInt(u64, id, 16) catch return error.InvalidSessionEntry;
                    if (number == std.math.maxInt(u64)) return error.SessionIdExhausted;
                    if (record.parent_id) |parent| if (self.find(parent) == null) return error.UnknownParentEntry;
                    const summary = record.summary orelse return error.InvalidSessionEntry;
                    if (summary.len == 0 or !std.unicode.utf8ValidateSlice(summary)) return error.InvalidSessionEntry;
                    if (record.first_kept_id) |kept| {
                        if (!std.mem.eql(u8, kept, id) and self.find(kept) == null) return error.InvalidCompactionRange;
                    }
                    const a = self.arena.allocator();
                    const owned_summary = try a.dupe(u8, summary);
                    const owned_kept = if (record.first_kept_id) |k| try a.dupe(u8, k) else null;
                    const formatted = try compaction.formatSummaryUserText(a, owned_summary);
                    const content = try a.dupe(model.Content, &.{.{ .text = formatted }});
                    const entry = EntryView{
                        .id = try a.dupe(u8, id),
                        .parent_id = if (record.parent_id) |p| try a.dupe(u8, p) else null,
                        .message = .{ .role = .user, .content = content },
                        .compaction = .{
                            .summary = owned_summary,
                            .first_kept_id = owned_kept,
                            .tokens_before = record.tokens_before orelse 0,
                        },
                    };
                    try self.entries.ensureUnusedCapacity(self.allocator, 1);
                    try self.id_index.ensureUnusedCapacity(self.allocator, 1);
                    self.entries.appendAssumeCapacity(entry);
                    self.id_index.putAssumeCapacityNoClobber(entry.id, self.entries.items.len - 1);
                    self.active_leaf = entry.id;
                    self.next_id = @max(self.next_id, number + 1);
                },
                .leaf => {
                    if (!header_seen) return error.MissingSessionHeader;
                    if (record.id) |id| {
                        const index = self.find(id) orelse return error.UnknownSessionEntry;
                        self.active_leaf = self.entries.items[index].id;
                    } else {
                        self.active_leaf = null;
                    }
                },
            }
            offset = lf + 1;
            self.write_offset = offset;
        }
        if (!header_seen) return error.MissingSessionHeader;
        self.corrupt_line = null;
    }
};
