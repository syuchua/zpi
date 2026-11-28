//! Redacted, explicitly configured JSONL audit sink.
const std = @import("std");
const builtin = @import("builtin");
const security = @import("security");

pub fn isPrivateFile(file: std.Io.File, stat: std.Io.File.Stat) bool {
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return false;
    if (comptime builtin.os.tag == .linux) {
        var metadata: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(file.handle, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true }, &metadata);
        return rc == 0 and metadata.mask.UID and metadata.uid == std.os.linux.geteuid();
    }
    if (comptime builtin.os.tag == .macos or builtin.os.tag.isBSD()) {
        var metadata: std.c.Stat = undefined;
        return std.c.fstat(file.handle, &metadata) == 0 and metadata.uid == std.c.geteuid();
    }
    return false;
}

pub fn formatTimestamp(a: std.mem.Allocator, unix_seconds: u64) ![]u8 {
    if (unix_seconds > 253_402_300_799) return error.InvalidAuditTime;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = unix_seconds };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    const year: u16 = year_day.year;
    const month: u8 = @intCast(month_day.month.numeric());
    const day: u8 = @as(u8, month_day.day_index) + 1;
    const hour: u8 = @intCast(day_seconds.getHoursIntoDay());
    const minute: u8 = @intCast(day_seconds.getMinutesIntoHour());
    const second: u8 = @intCast(day_seconds.getSecondsIntoMinute());
    const result = try a.alloc(u8, 20);
    result[4] = '-';
    result[7] = '-';
    result[10] = 'T';
    result[13] = ':';
    result[16] = ':';
    result[19] = 'Z';
    writeDigits(result[0..4], year);
    writeDigits(result[5..7], month);
    writeDigits(result[8..10], day);
    writeDigits(result[11..13], hour);
    writeDigits(result[14..16], minute);
    writeDigits(result[17..19], second);
    return result;
}

fn writeDigits(destination: []u8, value: anytype) void {
    var n: u64 = @intCast(value);
    for (0..destination.len) |i| {
        const index = destination.len - 1 - i;
        destination[index] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
}

pub const Event = struct {
    event: enum { authorization, operation },
    parent_id: ?u64 = null,
    source: security.Source,
    capability: security.Capability,
    target_kind: security.TargetKind,
    mode: security.Mode,
    decision: security.Decision,
    outcome: security.Outcome,
    policy_source: security.PolicySource,
    reason: []const u8,
};

pub const Sink = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File = null,
    run_id: [16]u8 = @splat(0),
    end_offset: u64 = 0,
    next_id: u64 = 1,
    mutex: std.Io.Mutex = .init,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Sink {
        if (path == null) return .{ .allocator = allocator, .io = io };
        if (path.?.len == 0 or !std.unicode.utf8ValidateSlice(path.?) or std.mem.indexOfScalar(u8, path.?, 0) != null) return error.InvalidAuditPath;
        const handle = try std.posix.openat(std.Io.Dir.cwd().handle, path.?, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0o600);
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (!isPrivateFile(file, stat)) return error.InvalidAuditFile;
        if (!try file.tryLock(io, .exclusive)) return error.AuditLogBusy;
        const length = try file.length(io);
        if (length > 0) {
            var last: [1]u8 = undefined;
            if (try file.readPositionalAll(io, &last, length - 1) != 1 or last[0] != '\n') return error.IncompleteAuditLog;
        }
        var sink: Sink = .{ .allocator = allocator, .io = io, .file = file, .end_offset = length };
        io.random(&sink.run_id);
        return sink;
    }

    pub fn enabled(self: *const Sink) bool {
        return self.file != null;
    }

    pub fn deinit(self: *Sink) void {
        if (self.file) |file| file.close(self.io);
        self.* = undefined;
    }

    pub fn append(self: *Sink, event: Event) !?u64 {
        const file = self.file orelse return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failed) return error.AuditLogFailed;
        if (self.next_id == std.math.maxInt(u64)) return error.AuditIdExhausted;
        const id = self.next_id;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const timestamp = try formatTimestamp(self.allocator, @intCast(@max(0, now)));
        defer self.allocator.free(timestamp);
        var run_buf: [32]u8 = undefined;
        const run_id = try std.fmt.bufPrint(&run_buf, "{x}", .{&self.run_id});
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = "zpi.audit.v1",
            .event = event.event,
            .runId = run_id,
            .eventId = id,
            .parentId = event.parent_id,
            .time = timestamp,
            .source = event.source,
            .capability = event.capability.name(),
            .target = .{ .kind = event.target_kind, .summary = "" },
            .mode = event.mode,
            .decision = event.decision,
            .outcome = event.outcome,
            .policySource = event.policy_source,
            .reason = event.reason,
        }, .{});
        defer self.allocator.free(encoded);
        errdefer self.failed = true;
        try file.writePositionalAll(self.io, encoded, self.end_offset);
        try file.writePositionalAll(self.io, "\n", self.end_offset + encoded.len);
        try file.sync(self.io);
        self.end_offset += encoded.len + 1;
        self.next_id += 1;
        return id;
    }
};

test "audit JSON excludes request data and appends records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "audit.jsonl" });
    defer std.testing.allocator.free(path);
    const denied: Event = .{
        .event = .authorization,
        .source = .builtin_tool,
        .capability = .filesystem_write,
        .target_kind = .path,
        .mode = .secure,
        .decision = .deny,
        .outcome = .denied,
        .policy_source = .validation,
        .reason = "missing-grant",
    };
    const first_run = blk: {
        var sink = try Sink.init(std.testing.allocator, std.testing.io, path);
        defer sink.deinit();
        try std.testing.expectError(error.AuditLogBusy, Sink.init(std.testing.allocator, std.testing.io, path));
        try std.testing.expectEqual(@as(?u64, 1), try sink.append(denied));
        try std.testing.expectEqual(@as(?u64, 2), try sink.append(denied));
        break :blk sink.run_id;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "zpi.audit.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "filesystem.write") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "missing-grant") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "arguments") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);

    var reopened = try Sink.init(std.testing.allocator, std.testing.io, path);
    defer reopened.deinit();
    try std.testing.expect(!std.mem.eql(u8, &first_run, &reopened.run_id));
    try std.testing.expectEqual(@as(?u64, 1), try reopened.append(denied));
    const appended = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(appended);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, appended, "\"schema\":\"zpi.audit.v1\""));
    try std.testing.expect(std.mem.startsWith(u8, appended, bytes));
    try std.testing.expect(std.mem.indexOf(u8, appended, "\"eventId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, appended, "\"eventId\":2") != null);
}

test "audit authorization and operation events preserve decision linkage and scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "schema-audit.jsonl" });
    defer std.testing.allocator.free(path);
    var sink = try Sink.init(std.testing.allocator, std.testing.io, path);
    defer sink.deinit();
    const authorization_id = (try sink.append(.{
        .event = .authorization,
        .source = .rpc,
        .capability = .rpc_control,
        .target_kind = .request,
        .mode = .secure,
        .decision = .allow,
        .outcome = .allowed,
        .policy_source = .invocation,
        .reason = "explicit-grant",
    })).?;
    _ = try sink.append(.{
        .event = .operation,
        .parent_id = authorization_id,
        .source = .rpc,
        .capability = .rpc_control,
        .target_kind = .request,
        .mode = .secure,
        .decision = .allow,
        .outcome = .unknown,
        .policy_source = .invocation,
        .reason = "unknown",
    });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const authorization = (try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{}));
    defer authorization.deinit();
    const operation = (try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{}));
    defer operation.deinit();
    try std.testing.expectEqualStrings("rpc", authorization.value.object.get("source").?.string);
    try std.testing.expectEqualStrings("invocation", authorization.value.object.get("policySource").?.string);
    try std.testing.expectEqualStrings("allow", authorization.value.object.get("decision").?.string);
    try std.testing.expectEqual(@as(i64, 1), authorization.value.object.get("eventId").?.integer);
    try std.testing.expectEqual(@as(i64, 2), operation.value.object.get("eventId").?.integer);
    try std.testing.expectEqualStrings(authorization.value.object.get("runId").?.string, operation.value.object.get("runId").?.string);
    try std.testing.expectEqual(authorization.value.object.get("eventId").?.integer, operation.value.object.get("parentId").?.integer);
    try std.testing.expectEqualStrings("unknown", operation.value.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("unknown", operation.value.object.get("reason").?.string);
}

test "audit timestamps use RFC3339 UTC" {
    const timestamp = try formatTimestamp(std.testing.allocator, 1_704_164_645);
    defer std.testing.allocator.free(timestamp);
    try std.testing.expectEqualStrings("2024-01-02T03:04:05Z", timestamp);
}
