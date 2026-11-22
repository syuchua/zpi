//! Native background task manager and tools (`bg_run`, `bg_status`, `bg_logs`, `bg_kill`).
//! Persists logs and metadata under `<cwd>/.pi/tasks/<run-dir>/`, manages child process
//! groups cleanly, and delivers completion notifications via a registered wake interrupt.
const builtin = @import("builtin");
const std = @import("std");
const agent = @import("agent");
const model = @import("model");

pub const max_log_bytes: usize = 32 * 1024 * 1024;
pub const max_logs_read_bytes: usize = 50 * 1024;
pub const default_logs_read_bytes: usize = 16 * 1024;
pub const default_timeout_seconds: usize = 3600;
pub const max_timeout_seconds: usize = 86400;

pub const Status = enum {
    running,
    completed,
    failed,
    killed,
    timed_out,

    pub fn isTerminal(self: Status) bool {
        return self != .running;
    }
};

pub const Notification = struct {
    task_id: []u8,
    task_name: []u8,
    status: Status,
    text: []u8,
    trigger: bool,

    pub fn deinit(self: *Notification, a: std.mem.Allocator) void {
        a.free(self.task_id);
        a.free(self.task_name);
        a.free(self.text);
    }
};

pub const Task = struct {
    manager: *Manager,
    id: []u8,
    name: []u8,
    command: []u8,
    description: ?[]u8,
    output_path: []u8,
    meta_path: []u8,
    status: Status = .running,
    pid: std.posix.pid_t = 0,
    exit_code: ?i32 = null,
    signal: ?u32 = null,
    started_ms: i64,
    finished_ms: ?i64 = null,
    output_bytes: usize = 0,
    truncated: bool = false,
    notify_on_completion: bool = true,
    trigger_on_completion: bool = true,
    timeout_seconds: usize = default_timeout_seconds,
    kill_requested: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    child: std.process.Child,
    output_file: ?std.Io.File = null,
    thread: ?std.Thread = null,

    fn deinit(self: *Task, a: std.mem.Allocator) void {
        if (self.output_file) |f| f.close(self.manager.io);
        a.free(self.id);
        a.free(self.name);
        a.free(self.command);
        if (self.description) |d| a.free(d);
        a.free(self.output_path);
        a.free(self.meta_path);
        a.destroy(self);
    }
};

pub const WakeHook = struct {
    context: *anyopaque,
    trigger: *const fn (*anyopaque) void,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
    run_dir: ?[]u8 = null,
    mutex: std.Io.Mutex = .init,
    next_id: u64 = 1,
    tasks: std.ArrayList(*Task) = .empty,
    notifications: std.ArrayList(Notification) = .empty,
    wake_hook: ?WakeHook = null,
    shutting_down: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !*Manager {
        const self = try allocator.create(Manager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .cwd = try allocator.dupe(u8, if (cwd.len > 0) cwd else "."),
        };
        return self;
    }

    pub fn deinit(self: *Manager) void {
        const alloc = self.allocator;
        self.shutting_down.store(true, .release);

        var handles: std.ArrayList(std.Thread) = .empty;
        defer handles.deinit(alloc);

        self.mutex.lockUncancelable(self.io);
        for (self.tasks.items) |task| {
            if (task.status == .running) {
                task.kill_requested.store(true, .release);
                if (task.pid > 0) {
                    std.posix.kill(-task.pid, .KILL) catch {};
                }
            }
            if (task.thread) |th| {
                handles.append(alloc, th) catch {};
                task.thread = null;
            }
        }
        self.mutex.unlock(self.io);

        for (handles.items) |th| th.join();

        for (self.tasks.items) |task| task.deinit(alloc);
        self.tasks.deinit(alloc);
        for (self.notifications.items) |*n| n.deinit(alloc);
        self.notifications.deinit(alloc);
        if (self.run_dir) |d| alloc.free(d);
        alloc.free(self.cwd);
        alloc.destroy(self);
    }

    pub fn setWakeHook(self: *Manager, hook: ?WakeHook) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wake_hook = hook;
    }

    pub fn runningCount(self: *Manager) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.tasks.items) |t| if (t.status == .running) {
            count += 1;
        };
        return count;
    }

    pub fn popNotifications(self: *Manager, allocator: std.mem.Allocator) ![]Notification {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.notifications.items.len == 0) return try allocator.alloc(Notification, 0);
        const out = try allocator.alloc(Notification, self.notifications.items.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*n| n.deinit(allocator);
            allocator.free(out);
        }
        for (self.notifications.items) |n| {
            out[built] = .{
                .task_id = try allocator.dupe(u8, n.task_id),
                .task_name = try allocator.dupe(u8, n.task_name),
                .status = n.status,
                .text = try allocator.dupe(u8, n.text),
                .trigger = n.trigger,
            };
            built += 1;
        }
        for (self.notifications.items) |*n| n.deinit(self.allocator);
        self.notifications.clearRetainingCapacity();
        return out;
    }

    fn ensureRunDirLocked(self: *Manager) ![]const u8 {
        if (self.run_dir) |d| return d;
        var rand_bytes: [4]u8 = undefined;
        self.io.random(&rand_bytes);
        const pid: u32 = @intCast(if (builtin.os.tag == .linux) std.os.linux.getpid() else std.c.getpid());
        const dir = try std.fmt.allocPrint(self.allocator, "{s}/.pi/tasks/zpi-{d}-{x}", .{
            std.mem.trimEnd(u8, self.cwd, "/"),
            pid,
            rand_bytes,
        });
        errdefer self.allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
        self.run_dir = dir;
        return dir;
    }

    pub fn startTask(
        self: *Manager,
        task_cwd: []const u8,
        name: []const u8,
        command: []const u8,
        description: ?[]const u8,
        timeout_seconds: usize,
        notify_on_completion: bool,
        trigger_on_completion: bool,
    ) !*Task {
        if (std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidCommand;
        if (name.len == 0 or name.len > 80) return error.InvalidTaskName;
        if (timeout_seconds == 0 or timeout_seconds > max_timeout_seconds) return error.InvalidTimeout;

        const effective_cwd = if (task_cwd.len > 0) task_cwd else self.cwd;

        self.mutex.lockUncancelable(self.io);
        var unlock_needed = true;
        errdefer if (unlock_needed) self.mutex.unlock(self.io);

        const dir = try self.ensureRunDirLocked();
        const id = try std.fmt.allocPrint(self.allocator, "bg_{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        self.next_id += 1;

        const output_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.output", .{ dir, id });
        errdefer self.allocator.free(output_path);
        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ dir, id });
        errdefer self.allocator.free(meta_path);

        const out_file = try std.Io.Dir.cwd().createFile(self.io, output_path, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        errdefer {
            out_file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, output_path) catch {};
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_cmd = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_cmd);
        const owned_desc = if (description) |d| try self.allocator.dupe(u8, d) else null;
        errdefer if (owned_desc) |d| self.allocator.free(d);

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", "exec /bin/sh -c \"$1\" 2>&1", "zpi-bg", command },
            .cwd = .{ .path = effective_cwd },
            .pgid = 0,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const pid = child.id orelse {
            child.kill(self.io);
            return error.ChildSpawnFailed;
        };

        const task = try self.allocator.create(Task);
        errdefer {
            std.posix.kill(-pid, .KILL) catch {};
            child.kill(self.io);
            self.allocator.destroy(task);
        }
        task.* = .{
            .manager = self,
            .id = id,
            .name = owned_name,
            .command = owned_cmd,
            .description = owned_desc,
            .output_path = output_path,
            .meta_path = meta_path,
            .pid = pid,
            .started_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds(),
            .notify_on_completion = notify_on_completion,
            .trigger_on_completion = trigger_on_completion,
            .timeout_seconds = timeout_seconds,
            .child = child,
            .output_file = out_file,
        };
        try self.tasks.append(self.allocator, task);
        try writeMetaFile(self.allocator, self.io, task);

        task.thread = try std.Thread.spawn(.{}, monitorTask, .{task});
        self.mutex.unlock(self.io);
        unlock_needed = false;
        return task;
    }

    fn findTaskLocked(self: *const Manager, prefix: []const u8) !*Task {
        var exact: ?*Task = null;
        var match: ?*Task = null;
        var match_count: usize = 0;
        for (self.tasks.items) |t| {
            if (std.mem.eql(u8, t.id, prefix)) {
                exact = t;
                break;
            }
            if (std.mem.startsWith(u8, t.id, prefix)) {
                match = t;
                match_count += 1;
            }
        }
        if (exact) |e| return e;
        if (match_count == 1) return match.?;
        if (match_count > 1) return error.AmbiguousTaskId;
        return error.UnknownTaskId;
    }

    pub fn formatStatusAlloc(self: *Manager, a: std.mem.Allocator, task_id_opt: ?[]const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();

        if (task_id_opt) |tid| {
            const task = try self.findTaskLocked(tid);
            try appendTaskLine(&out, a, task, now_ms);
            return try out.toOwnedSlice(a);
        }

        if (self.tasks.items.len == 0) {
            try out.appendSlice(a, "No background tasks.");
            return try out.toOwnedSlice(a);
        }
        for (self.tasks.items, 0..) |task, idx| {
            if (idx > 0) try out.append(a, '\n');
            try appendTaskLine(&out, a, task, now_ms);
        }
        return try out.toOwnedSlice(a);
    }

    pub fn readLogsAlloc(self: *Manager, a: std.mem.Allocator, task_id: []const u8, tail: bool, max_bytes_raw: usize) ![]u8 {
        const max_bytes = @min(@max(@as(usize, 1), max_bytes_raw), max_logs_read_bytes);
        var path_copy: []u8 = undefined;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const task = try self.findTaskLocked(task_id);
            path_copy = try a.dupe(u8, task.output_path);
        }
        defer a.free(path_copy);

        const file = std.Io.Dir.cwd().openFile(self.io, path_copy, .{}) catch |err| switch (err) {
            error.FileNotFound => return try a.dupe(u8, "(no output yet)"),
            else => return err,
        };
        defer file.close(self.io);

        const total_len_u64 = try file.length(self.io);
        if (total_len_u64 == 0) return try a.dupe(u8, "(no output yet)");
        const total_len: usize = @intCast(@min(total_len_u64, @as(u64, max_log_bytes)));

        if (total_len <= max_bytes) {
            const buf = try a.alloc(u8, total_len);
            defer a.free(buf);
            const n = try file.readPositionalAll(self.io, buf, 0);
            return try sanitizeUtf8Lossy(a, buf[0..n]);
        }

        const start_off: u64 = if (tail) @intCast(total_len - max_bytes) else 0;
        const buf = try a.alloc(u8, max_bytes);
        defer a.free(buf);
        const n = try file.readPositionalAll(self.io, buf, start_off);
        const slice = buf[0..n];

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        if (tail) {
            var s: usize = 0;
            while (s < slice.len and (slice[s] & 0xc0) == 0x80) : (s += 1) {}
            const safe = try sanitizeUtf8Lossy(a, slice[s..]);
            defer a.free(safe);
            try out.print(a, "[Showing last {d} of {d} bytes. Full output: {s}]\n{s}", .{ safe.len, total_len, path_copy, safe });
        } else {
            var e: usize = slice.len;
            while (e > 0 and e < slice.len and (slice[e] & 0xc0) == 0x80) : (e -= 1) {}
            const safe = try sanitizeUtf8Lossy(a, slice[0..e]);
            defer a.free(safe);
            try out.print(a, "{s}\n[Showing first {d} of {d} bytes. Full output: {s}]", .{ safe, safe.len, total_len, path_copy });
        }
        return try out.toOwnedSlice(a);
    }

    pub fn killTask(self: *Manager, task_id: []const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const task = try self.findTaskLocked(task_id);
        if (task.status != .running) return error.TaskAlreadyFinished;
        task.kill_requested.store(true, .release);
        if (task.pid > 0) {
            std.posix.kill(-task.pid, .TERM) catch {};
        }
        return task.id;
    }
};

fn appendTaskLine(out: *std.ArrayList(u8), a: std.mem.Allocator, task: *const Task, now_ms: i64) !void {
    const end_ms = task.finished_ms orelse now_ms;
    const elapsed_ms = @max(@as(i64, 0), end_ms - task.started_ms);
    try out.print(a, "{s}  {s}  [{s}]  {d}.{d}s  {d}B", .{
        task.id,
        task.name,
        @tagName(task.status),
        @divTrunc(elapsed_ms, 1000),
        @divTrunc(@mod(elapsed_ms, 1000), 100),
        task.output_bytes,
    });
    if (task.exit_code) |code| {
        try out.print(a, "  exit={d}", .{code});
    } else if (task.signal) |sig| {
        try out.print(a, "  sig={d}", .{sig});
    }
    try out.print(a, "  output={s}", .{task.output_path});
}

fn monitorTask(task: *Task) void {
    const mgr = task.manager;
    const io = mgr.io;
    const stdout = task.child.stdout;
    const deadline_ms = task.started_ms + @as(i64, @intCast(task.timeout_seconds)) * 1000;
    var term_sent_ms: ?i64 = null;
    var file_offset: u64 = 0;

    if (stdout) |out_pipe| {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = out_pipe.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        var buf: [4096]u8 = undefined;
        while (true) {
            const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            if (mgr.shutting_down.load(.acquire) or task.kill_requested.load(.acquire)) {
                if (term_sent_ms == null) {
                    if (task.pid > 0) std.posix.kill(-task.pid, .TERM) catch {};
                    term_sent_ms = now_ms;
                } else if (now_ms - term_sent_ms.? >= 250) {
                    if (task.pid > 0) std.posix.kill(-task.pid, .KILL) catch {};
                }
            } else if (now_ms >= deadline_ms) {
                task.timed_out.store(true, .release);
                if (term_sent_ms == null) {
                    if (task.pid > 0) std.posix.kill(-task.pid, .TERM) catch {};
                    term_sent_ms = now_ms;
                } else if (now_ms - term_sent_ms.? >= 250) {
                    if (task.pid > 0) std.posix.kill(-task.pid, .KILL) catch {};
                }
            }

            poll_fds[0].revents = 0;
            const ready = std.posix.poll(&poll_fds, 50) catch 0;
            if (ready > 0 and (poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                const n = out_pipe.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => break,
                };
                if (n == 0) break;
                if (file_offset < max_log_bytes) {
                    const take: usize = @min(n, max_log_bytes - @as(usize, @intCast(file_offset)));
                    if (task.output_file) |of| {
                        of.writePositionalAll(io, buf[0..take], file_offset) catch {};
                    }
                    file_offset += take;
                    mgr.mutex.lockUncancelable(io);
                    task.output_bytes = @intCast(file_offset);
                    if (take < n) task.truncated = true;
                    mgr.mutex.unlock(io);
                } else {
                    mgr.mutex.lockUncancelable(io);
                    task.truncated = true;
                    mgr.mutex.unlock(io);
                }
            } else if (term_sent_ms != null and now_ms - term_sent_ms.? >= 400) {
                if (task.pid > 0) std.posix.kill(-task.pid, .KILL) catch {};
            }
        }
    }

    if (task.output_file) |of| {
        of.close(io);
        task.output_file = null;
    }

    const waited = task.child.wait(io) catch null;
    const finished_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();

    var wake_to_call: ?WakeHook = null;
    {
        mgr.mutex.lockUncancelable(io);
        defer mgr.mutex.unlock(io);

        task.finished_ms = finished_ms;
        if (waited) |term| switch (term) {
            .exited => |code| task.exit_code = @intCast(code),
            .signal => |sig| task.signal = @intCast(@backingInt(sig)),
            .stopped, .unknown => {},
        };

        if (task.kill_requested.load(.acquire)) {
            task.status = .killed;
        } else if (task.timed_out.load(.acquire)) {
            task.status = .timed_out;
        } else if (task.exit_code) |code| {
            task.status = if (code == 0) .completed else .failed;
        } else {
            task.status = .failed;
        }

        writeMetaFile(mgr.allocator, io, task) catch {};

        if (task.notify_on_completion and !mgr.shutting_down.load(.acquire)) {
            const note = formatNotification(mgr.allocator, task) catch null;
            if (note) |text| {
                const tid = mgr.allocator.dupe(u8, task.id) catch null;
                const tname = mgr.allocator.dupe(u8, task.name) catch null;
                if (tid != null and tname != null) {
                    mgr.notifications.append(mgr.allocator, .{
                        .task_id = tid.?,
                        .task_name = tname.?,
                        .status = task.status,
                        .text = text,
                        .trigger = task.trigger_on_completion,
                    }) catch {
                        mgr.allocator.free(tid.?);
                        mgr.allocator.free(tname.?);
                        mgr.allocator.free(text);
                    };
                    wake_to_call = mgr.wake_hook;
                } else {
                    if (tid) |x| mgr.allocator.free(x);
                    if (tname) |x| mgr.allocator.free(x);
                    mgr.allocator.free(text);
                }
            }
        }
    }

    if (wake_to_call) |wh| wh.trigger(wh.context);
}

fn formatNotification(a: std.mem.Allocator, task: *const Task) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "<background-task-notification>\n");
    try out.print(a, "  <task-id>{s}</task-id>\n", .{task.id});
    try out.print(a, "  <task-name>{s}</task-name>\n", .{task.name});
    try out.print(a, "  <status>{s}</status>\n", .{@tagName(task.status)});
    if (task.exit_code) |code| {
        try out.print(a, "  <exit-code>{d}</exit-code>\n", .{code});
    } else if (task.signal) |sig| {
        try out.print(a, "  <signal>{d}</signal>\n", .{sig});
    }
    try out.print(a, "  <output-file>{s}</output-file>\n", .{task.output_path});
    try out.print(a, "  <summary>Background task \"{s}\" {s}</summary>\n", .{ task.name, @tagName(task.status) });
    try out.appendSlice(a, "</background-task-notification>");
    return try out.toOwnedSlice(a);
}

fn writeMetaFile(a: std.mem.Allocator, io: std.Io, task: *const Task) !void {
    const Meta = struct {
        id: []const u8,
        name: []const u8,
        command: []const u8,
        status: []const u8,
        pid: i64,
        exit_code: ?i32,
        signal: ?u32,
        started_ms: i64,
        finished_ms: ?i64,
        output_path: []const u8,
        output_bytes: usize,
        notify_on_completion: bool,
        trigger_on_completion: bool,
    };
    const encoded = try std.json.Stringify.valueAlloc(a, Meta{
        .id = task.id,
        .name = task.name,
        .command = task.command,
        .status = @tagName(task.status),
        .pid = @intCast(task.pid),
        .exit_code = task.exit_code,
        .signal = task.signal,
        .started_ms = task.started_ms,
        .finished_ms = task.finished_ms,
        .output_path = task.output_path,
        .output_bytes = task.output_bytes,
        .notify_on_completion = task.notify_on_completion,
        .trigger_on_completion = task.trigger_on_completion,
    }, .{ .whitespace = .indent_2 });
    defer a.free(encoded);

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, task.meta_path, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, encoded, 0);
    try atomic.file.writePositionalAll(io, "\n", encoded.len);
    try atomic.replace(io);
}

pub fn executeBgRun(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) !agent.ToolResult {
    const mgr: *Manager = @ptrCast(@alignCast(context orelse return error.MissingBgManager));
    try validateKeys(args, &.{ "name", "command", "description", "timeoutSeconds", "notifyOnCompletion", "triggerOnCompletion" });
    const name = try reqString(args, "name");
    const command = try reqString(args, "command");
    const description = if (args.object.get("description")) |v| switch (v) {
        .string => |s| s,
        else => return error.ExpectedString,
    } else null;
    const timeout_sec = try positiveInt(args, "timeoutSeconds", default_timeout_seconds, max_timeout_seconds);
    const notify = try boolOpt(args, "notifyOnCompletion", true);
    const trigger = try boolOpt(args, "triggerOnCompletion", true);
    if (trigger and !notify) return error.TriggerRequiresNotify;

    const task = try mgr.startTask(ctx.cwd, name, command, description, timeout_sec, notify, trigger);
    mgr.mutex.lockUncancelable(ctx.io);
    const tid = try ctx.allocator.dupe(u8, task.id);
    const tname = try ctx.allocator.dupe(u8, task.name);
    const tpath = try ctx.allocator.dupe(u8, task.output_path);
    const tpid = task.pid;
    mgr.mutex.unlock(ctx.io);

    var details: std.json.ObjectMap = .empty;
    try details.put(ctx.allocator, "taskId", .{ .string = tid });
    try details.put(ctx.allocator, "name", .{ .string = tname });
    try details.put(ctx.allocator, "status", .{ .string = "running" });
    try details.put(ctx.allocator, "pid", .{ .integer = @intCast(tpid) });
    try details.put(ctx.allocator, "outputPath", .{ .string = tpath });

    return .{
        .text = try std.fmt.allocPrint(ctx.allocator, "Started background task {s} ({s}, pid={d})\nOutput: {s}", .{ tid, tname, tpid, tpath }),
        .details = .{ .object = details },
    };
}

pub fn executeBgStatus(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) !agent.ToolResult {
    const mgr: *Manager = @ptrCast(@alignCast(context orelse return error.MissingBgManager));
    try validateKeys(args, &.{"taskId"});
    const tid: ?[]const u8 = if (args.object.get("taskId")) |v| switch (v) {
        .string => |s| if (s.len > 0) s else return error.InvalidTaskId,
        else => return error.ExpectedString,
    } else null;

    const text = mgr.formatStatusAlloc(ctx.allocator, tid) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(ctx.allocator, "bg_status failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    return .{ .text = text };
}

pub fn executeBgLogs(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) !agent.ToolResult {
    const mgr: *Manager = @ptrCast(@alignCast(context orelse return error.MissingBgManager));
    try validateKeys(args, &.{ "taskId", "tail", "maxBytes" });
    const tid = try reqString(args, "taskId");
    const tail = try boolOpt(args, "tail", true);
    const max_bytes = try positiveInt(args, "maxBytes", default_logs_read_bytes, max_logs_read_bytes);

    const text = mgr.readLogsAlloc(ctx.allocator, tid, tail, max_bytes) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(ctx.allocator, "bg_logs failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    return .{ .text = text };
}

pub fn executeBgKill(context: ?*anyopaque, ctx: agent.ToolContext, args: std.json.Value) !agent.ToolResult {
    const mgr: *Manager = @ptrCast(@alignCast(context orelse return error.MissingBgManager));
    try validateKeys(args, &.{"taskId"});
    const tid = try reqString(args, "taskId");

    const killed_id = mgr.killTask(tid) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(ctx.allocator, "bg_kill failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    return .{ .text = try std.fmt.allocPrint(ctx.allocator, "Requested termination for background task {s}", .{killed_id}) };
}

fn validateKeys(args: std.json.Value, allowed: []const []const u8) !void {
    if (args != .object) return error.ExpectedObject;
    for (args.object.keys()) |k| {
        var ok = false;
        for (allowed) |ak| if (std.mem.eql(u8, k, ak)) {
            ok = true;
            break;
        };
        if (!ok) return error.UnknownArgument;
    }
}

fn reqString(args: std.json.Value, key: []const u8) ![]const u8 {
    if (args != .object) return error.ExpectedObject;
    const v = args.object.get(key) orelse return error.MissingArgument;
    if (v != .string or v.string.len == 0) return error.ExpectedString;
    return v.string;
}

fn boolOpt(args: std.json.Value, key: []const u8, fallback: bool) !bool {
    const v = args.object.get(key) orelse return fallback;
    return switch (v) {
        .bool => |b| b,
        else => error.ExpectedBoolean,
    };
}

fn positiveInt(args: std.json.Value, key: []const u8, fallback: usize, max_val: usize) !usize {
    const v = args.object.get(key) orelse return fallback;
    const n = switch (v) {
        .integer => v.integer,
        else => return error.ExpectedPositiveInteger,
    };
    if (n <= 0 or n > max_val) return error.OutOfRange;
    return @intCast(n);
}

fn sanitizeUtf8Lossy(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            try out.append(a, '?');
            i += 1;
            continue;
        };
        if (i + len <= raw.len and std.unicode.utf8ValidateSlice(raw[i .. i + len])) {
            try out.appendSlice(a, raw[i .. i + len]);
            i += len;
        } else {
            try out.append(a, '?');
            i += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

test "bg_run, bg_status, bg_logs, bg_kill persist .pi/tasks files and fire wake hook" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_root = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd_root);
    const work_dir = try std.fs.path.resolveAlloc(a, &.{ cwd_root, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(work_dir);

    var wake_intr = try model.Interrupt.init();
    defer wake_intr.deinit(io);
    const WakeWrap = struct {
        fn trig(ctx: *anyopaque) void {
            const i: *model.Interrupt = @ptrCast(@alignCast(ctx));
            i.trigger();
        }
    };

    const mgr = try Manager.init(a, io, work_dir);
    defer mgr.deinit();
    mgr.setWakeHook(.{ .context = &wake_intr, .trigger = WakeWrap.trig });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ctx = agent.ToolContext{ .allocator = arena.allocator(), .io = io, .cwd = work_dir };

    // 1. Start fast task and wait for wake interrupt + notification.
    const run_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"name\":\"quick echo\",\"command\":\"printf 'hello-bg-1\\nhello-bg-2\\n'\"}", .{});
    const run_res = try executeBgRun(mgr, ctx, run_args.value);
    const tid = run_res.details.?.object.get("taskId").?.string;
    const out_path = run_res.details.?.object.get("outputPath").?.string;
    try std.testing.expect(std.mem.indexOf(u8, out_path, ".pi/tasks/") != null);

    try wake_intr.cancel().wait(io);
    const notes = try mgr.popNotifications(a);
    defer {
        for (notes) |*n| @constCast(n).deinit(a);
        a.free(notes);
    }
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqual(Status.completed, notes[0].status);
    try std.testing.expect(std.mem.indexOf(u8, notes[0].text, "<background-task-notification>") != null);
    try std.testing.expect(std.mem.indexOf(u8, notes[0].text, "quick echo") != null);

    const logs_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"taskId\":\"{s}\",\"tail\":true,\"maxBytes\":512}}", .{tid}), .{});
    const logs_res = try executeBgLogs(mgr, ctx, logs_args.value);
    try std.testing.expect(std.mem.indexOf(u8, logs_res.text, "hello-bg-1") != null);

    // Verify metadata JSON file was atomically updated to completed on disk.
    const meta_path = try std.fmt.allocPrint(arena.allocator(), "{s}.json", .{out_path[0 .. out_path.len - ".output".len]});
    const meta_bytes = try std.Io.Dir.cwd().readFileAlloc(io, meta_path, arena.allocator(), .limited(16 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, meta_bytes, "\"status\": \"completed\"") != null);

    // 2. Start slow task and kill process group cleanly via bg_kill.
    wake_intr.reset();
    const slow_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"name\":\"slow sleeper\",\"command\":\"sleep 30\"}", .{});
    const slow_res = try executeBgRun(mgr, ctx, slow_args.value);
    const slow_id = slow_res.details.?.object.get("taskId").?.string;
    try std.testing.expectEqual(@as(usize, 1), mgr.runningCount());

    const kill_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{{\"taskId\":\"{s}\"}}", .{slow_id}), .{});
    const kill_res = try executeBgKill(mgr, ctx, kill_args.value);
    try std.testing.expect(!kill_res.is_error);

    try wake_intr.cancel().wait(io);
    const notes2 = try mgr.popNotifications(a);
    defer {
        for (notes2) |*n| @constCast(n).deinit(a);
        a.free(notes2);
    }
    try std.testing.expectEqual(@as(usize, 1), notes2.len);
    try std.testing.expectEqual(Status.killed, notes2[0].status);
    try std.testing.expectEqual(@as(usize, 0), mgr.runningCount());
}
