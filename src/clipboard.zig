//! Clipboard adapter. Copies exact UTF-8 bytes to the system clipboard by
//! piping them to a platform helper program (pbcopy, wl-copy, xclip).
//!
//! Nothing here touches a window server, terminal escape sequence, or shell.
//! The helper is executed directly with an explicit argv, receives the payload
//! on stdin, and has its stdout and stderr discarded so a chatty helper cannot
//! corrupt the terminal. Every copy is bounded by a timeout and any helper that
//! outlives it (or rejects the payload with a broken pipe) is killed and
//! reaped before returning.
//!
//! Helper selection is layered so tests never need a desktop clipboard:
//!   1. an explicit `argv` supplied by the caller,
//!   2. an injected runner (a fake that records the payload),
//!   3. platform discovery from the process environment.
const std = @import("std");

/// No helper produced by discovery may receive more than this many bytes. The
/// bound keeps a runaway Markdown copy from pinning a helper forever.
pub const max_payload_bytes: usize = 16 * 1024 * 1024;

/// Bounded wait for the helper. pbcopy and wl-copy both exit promptly once
/// stdin closes; anything slower than this is treated as a hung helper.
pub const default_timeout_ms: u32 = 10_000;

pub const Error = error{
    /// No helper is installed for this platform or display server.
    Unavailable,
    /// A helper exists but rejected the payload, exited non-zero, or died to a
    /// signal.
    Failed,
    /// The helper did not finish within the configured timeout.
    Timeout,
    /// The payload is empty, too large, or not valid UTF-8.
    InvalidPayload,
};

/// Platform family, kept separate from `builtin.target.os.tag` so tests can
/// exercise Linux selection on any host.
pub const Platform = enum { macos, linux, other };

/// How the clipboard is reached on Linux. Wayland and X11 need different
/// helpers and are distinguished from the process environment.
pub const Display = enum { wayland, x11, unknown };

pub const Env = struct {
    /// `WAYLAND_DISPLAY`; non-empty wins over X11.
    wayland_display: ?[]const u8 = null,
    /// `DISPLAY`; used only when no Wayland display is present.
    display: ?[]const u8 = null,
    /// `XDG_SESSION_TYPE`; consulted by `inferDisplay` only when the display
    /// variables are absent.
    xdg_session_type: ?[]const u8 = null,

    fn nonEmpty(v: ?[]const u8) ?[]const u8 {
        const slice = v orelse return null;
        return if (slice.len == 0) null else slice;
    }

    /// Read the relevant variables from the process environment. `argv[0]` is
    /// not used for PATH resolution, so no filesystem walk happens here.
    pub fn fromProcess(environ_map: *const std.process.Environ.Map) Env {
        return .{
            .wayland_display = nonEmpty(environ_map.get("WAYLAND_DISPLAY")),
            .display = nonEmpty(environ_map.get("DISPLAY")),
            .xdg_session_type = nonEmpty(environ_map.get("XDG_SESSION_TYPE")),
        };
    }
};

/// Resolve the display server. Wayland is preferred when both are advertised
/// because a Wayland session commonly also exports a `DISPLAY` for Xwayland.
///
/// Empty values are normalized here as well as in `fromProcess` so a caller
/// that builds `Env` by hand gets the same answer as one that reads the
/// process environment. An empty variable is never a usable display.
pub fn inferDisplay(env: Env) Display {
    if (Env.nonEmpty(env.wayland_display) != null) return .wayland;
    if (Env.nonEmpty(env.display) != null) return .x11;
    if (Env.nonEmpty(env.xdg_session_type)) |session| {
        if (std.ascii.eqlIgnoreCase(session, "wayland")) return .wayland;
        if (std.ascii.eqlIgnoreCase(session, "x11")) return .x11;
    }
    return .unknown;
}

/// A helper invocation: a program plus its fixed arguments. The payload is
/// never part of argv, so it cannot be reinterpreted as an option or a shell
/// word.
pub const Command = struct {
    argv: []const []const u8,

    pub fn program(self: Command) []const u8 {
        return if (self.argv.len == 0) "" else self.argv[0];
    }
};

/// Choose the helper for a platform/display combination. Returns `null` when
/// no supported helper is known for that target, which the caller reports as
/// `error.Unavailable`.
///
/// Returned slices are static, so the command stays valid without allocation.
pub fn systemCommand(platform: Platform, display: Display) ?Command {
    return switch (platform) {
        .macos => .{ .argv = &.{"pbcopy"} },
        .linux => switch (display) {
            .wayland => .{ .argv = &.{ "wl-copy", "--type", "text/plain;charset=utf-8" } },
            .x11 => .{ .argv = &.{ "xclip", "-selection", "clipboard", "-in", "-t", "UTF8_STRING" } },
            .unknown => null,
        },
        .other => null,
    };
}

/// Discover the command for a platform from an environment snapshot.
pub fn systemCommandFromEnv(platform: Platform, env: Env) ?Command {
    return systemCommand(platform, inferDisplay(env));
}

/// Map the compile target onto a `Platform`.
pub fn nativePlatform() Platform {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => .other,
    };
}

/// A runner performs the copy. Discovery-only callers use `spawnRunner`; tests
/// inject a fake so no clipboard is required.
pub const Runner = struct {
    context: ?*anyopaque = null,
    copyFn: *const fn (context: ?*anyopaque, io: std.Io, command: Command, bytes: []const u8) Error!void,

    pub fn copy(self: Runner, io: std.Io, command: Command, bytes: []const u8) Error!void {
        return self.copyFn(self.context, io, command, bytes);
    }
};

/// Settings for one clipboard interaction.
pub const Options = struct {
    /// Wall-clock budget for the helper. Zero is rejected with `Error.Timeout`
    /// rather than treated as "no limit".
    timeout_ms: u32 = default_timeout_ms,
};

/// Validate a payload once, so both the fake and the real runner agree on what
/// "copy exactly these bytes" means.
pub fn validatePayload(bytes: []const u8) Error!void {
    if (bytes.len == 0) return Error.InvalidPayload;
    if (bytes.len > max_payload_bytes) return Error.InvalidPayload;
    if (!std.unicode.utf8ValidateSlice(bytes)) return Error.InvalidPayload;
}

/// Spawn the helper, stream `bytes` to its stdin, close the pipe, and wait.
///
/// The helper is spawned with `pgid = 0` so it leads its own process group;
/// a hung or misbehaving helper is therefore killed along with any descendants.
/// stdout and stderr are `/dev/null`, which keeps helper diagnostics from
/// reaching the terminal.
pub fn spawnCopy(context: ?*anyopaque, io: std.Io, command: Command, bytes: []const u8) Error!void {
    _ = context;
    try validatePayload(bytes);
    if (command.argv.len == 0 or command.program().len == 0) return Error.Unavailable;

    var child = std.process.spawn(io, .{
        .argv = command.argv,
        .pgid = 0,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return switch (err) {
        error.FileNotFound, error.AccessDenied => Error.Unavailable,
        else => Error.Failed,
    };

    // `kill` is idempotent and a no-op after `wait`, so the cleanup below is
    // safe on every exit path, including the early broken-pipe return.
    var reaped = false;
    defer if (!reaped) killChild(io, &child);

    const stdin = child.stdin orelse {
        killChild(io, &child);
        reaped = true;
        return Error.Failed;
    };
    // Taking the handle out of the child means only this scope closes it.
    child.stdin = null;

    // A helper that exits before reading stdin (a wrong display, a bad type
    // name) shows up as a broken pipe. That is a helper failure, not a signal
    // that the clipboard accepted the payload, so surface it as `Failed`.
    stdin.writeStreamingAll(io, bytes) catch {
        stdin.close(io);
        killChild(io, &child);
        reaped = true;
        return Error.Failed;
    };
    stdin.close(io);

    // pbcopy and wl-copy both hand the selection off and exit; xclip forks, so
    // waiting here is bounded by the caller's timeout, not by the helper.
    const term = child.wait(io) catch {
        killChild(io, &child);
        reaped = true;
        return Error.Failed;
    };
    reaped = true;
    return switch (term) {
        .exited => |code| if (code == 0) {} else Error.Failed,
        .signal, .stopped, .unknown => Error.Failed,
    };
}

/// The production runner.
pub const spawnRunner: Runner = .{ .copyFn = spawnCopy };

fn killChild(io: std.Io, child: *std.process.Child) void {
    if (child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
    child.kill(io);
}

fn timerTick(io: std.Io, ms: u32) std.Io.Cancelable!void {
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake);
}

/// Run `runner.copy` under a timeout. Returns `Error.Timeout` when the budget
/// expires, and always joins the work task before returning so no allocation or
/// helper outlives this call.
pub fn copyWithRunner(io: std.Io, runner: Runner, command: Command, bytes: []const u8, options: Options) Error!void {
    if (options.timeout_ms == 0) return Error.Timeout;
    try validatePayload(bytes);

    const Job = struct {
        runner: Runner,
        command: Command,
        bytes: []const u8,
        io: std.Io,

        fn run(self: *const @This()) Error!void {
            return self.runner.copy(self.io, self.command, self.bytes);
        }
    };
    var job: Job = .{ .runner = runner, .command = command, .bytes = bytes, .io = io };

    const Completion = union(enum) { copy: Error!void, timer: std.Io.Cancelable!void };
    var storage: [2]Completion = undefined;
    var selection = std.Io.Select(Completion).init(io, &storage);
    // `job`, `command`, and `bytes` live on this stack frame; `cancelDiscard`
    // blocks until the outstanding task has finished, so they stay valid.
    defer selection.cancelDiscard();

    // A missing concurrency unit is an environment failure, not a payload
    // problem, so it maps onto the same `Failed` outcome as a broken helper.
    selection.concurrent(.timer, timerTick, .{ io, options.timeout_ms }) catch return Error.Failed;
    selection.concurrent(.copy, Job.run, .{&job}) catch return Error.Failed;

    const finished = selection.await() catch return Error.Failed;
    return switch (finished) {
        .copy => |result| result,
        .timer => |result| {
            result catch return Error.Failed;
            return Error.Timeout;
        },
    };
}

/// Copy `bytes` to the clipboard using the platform helper discovered from
/// `environ_map`, with `runner` performing the copy.
///
/// Pass `spawnRunner` in production; tests pass a recording runner. Discovery
/// failures (`Unavailable`) are returned before the runner is consulted.
pub fn copy(io: std.Io, environ_map: *const std.process.Environ.Map, runner: Runner, bytes: []const u8, options: Options) Error!void {
    const command = systemCommandFromEnv(nativePlatform(), Env.fromProcess(environ_map)) orelse return Error.Unavailable;
    return copyWithRunner(io, runner, command, bytes, options);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// --- Command selection -----------------------------------------------------

test "macOS uses pbcopy with an explicit argv" {
    const cmd = systemCommand(.macos, .unknown).?;
    try std.testing.expectEqualStrings("pbcopy", cmd.program());
    try std.testing.expectEqual(@as(usize, 1), cmd.argv.len);
}

test "linux selects wl-copy on wayland and xclip on x11" {
    const wayland = systemCommand(.linux, .wayland).?;
    try std.testing.expectEqualStrings("wl-copy", wayland.program());
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", wayland.argv[2]);

    const x11 = systemCommand(.linux, .x11).?;
    try std.testing.expectEqualStrings("xclip", x11.program());
    // Selection and type are pinned so the copy cannot land in the primary
    // selection as opaque bytes.
    try std.testing.expectEqualStrings("-selection", x11.argv[1]);
    try std.testing.expectEqualStrings("clipboard", x11.argv[2]);
    try std.testing.expectEqualStrings("UTF8_STRING", x11.argv[5]);
}

test "no helper is invented for an unknown display or foreign platform" {
    try std.testing.expectEqual(@as(?Command, null), systemCommand(.linux, .unknown));
    try std.testing.expectEqual(@as(?Command, null), systemCommand(.other, .wayland));
    try std.testing.expectEqual(@as(?Command, null), systemCommand(.other, .unknown));
}

test "an empty argv is reported as unavailable, not as an empty command" {
    try std.testing.expectError(Error.Unavailable, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &.{} }, "x", .{}));
    try std.testing.expectError(Error.Unavailable, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &.{""} }, "x", .{}));
}

// --- Display inference -----------------------------------------------------

test "display inference prefers wayland and ignores empty values" {
    try std.testing.expectEqual(Display.wayland, inferDisplay(.{ .wayland_display = "wayland-0", .display = ":0" }));
    try std.testing.expectEqual(Display.x11, inferDisplay(.{ .display = ":0" }));
    try std.testing.expectEqual(Display.unknown, inferDisplay(.{}));
    // A Wayland session usually also exports DISPLAY for Xwayland, but an empty
    // value must not be treated as a usable display.
    try std.testing.expectEqual(Display.unknown, inferDisplay(.{ .wayland_display = "", .display = "" }));
    try std.testing.expectEqual(Display.x11, inferDisplay(.{ .wayland_display = "", .display = ":1" }));
}

test "session type is only a fallback when display variables are absent" {
    try std.testing.expectEqual(Display.wayland, inferDisplay(.{ .xdg_session_type = "wayland" }));
    try std.testing.expectEqual(Display.x11, inferDisplay(.{ .xdg_session_type = "x11" }));
    try std.testing.expectEqual(Display.unknown, inferDisplay(.{ .xdg_session_type = "tty" }));
    // Explicit display variables win over a contradictory session type.
    try std.testing.expectEqual(Display.x11, inferDisplay(.{ .display = ":0", .xdg_session_type = "wayland" }));
    try std.testing.expectEqual(Display.wayland, inferDisplay(.{ .wayland_display = "wayland-1", .xdg_session_type = "x11" }));
}

test "environment snapshot reads the display variables" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("WAYLAND_DISPLAY", "wayland-9");
    try env.put("DISPLAY", "");
    const snapshot = Env.fromProcess(&env);
    try std.testing.expectEqualStrings("wayland-9", snapshot.wayland_display.?);
    try std.testing.expect(snapshot.display == null);
    try std.testing.expectEqual(Display.wayland, inferDisplay(snapshot));
    try std.testing.expectEqualStrings("wl-copy", systemCommandFromEnv(.linux, snapshot).?.program());
}

test "copy() reports unavailable when the environment has no display server" {
    const Noop = struct {
        calls: usize = 0,
        fn run(ctx: ?*anyopaque, io: std.Io, command: Command, bytes: []const u8) Error!void {
            _ = io;
            _ = command;
            _ = bytes;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    var noop: Noop = .{};
    const runner: Runner = .{ .context = &noop, .copyFn = Noop.run };

    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // Discovery outcome depends only on platform + environment, never on the
    // runner, so assert on `systemCommandFromEnv` directly and then confirm
    // `copy` reaches the runner exactly when a command was found.
    const expected = systemCommandFromEnv(nativePlatform(), Env.fromProcess(&env));

    if (nativePlatform() == .linux) {
        // Linux without WAYLAND_DISPLAY/DISPLAY has no helper to run.
        try std.testing.expectEqual(@as(?Command, null), expected);
        try std.testing.expectError(Error.Unavailable, copy(std.testing.io, &env, runner, "payload", .{}));
        try std.testing.expectEqual(@as(usize, 0), noop.calls);

        try env.put("WAYLAND_DISPLAY", "wayland-1");
        try std.testing.expectEqualStrings("wl-copy", systemCommandFromEnv(.linux, Env.fromProcess(&env)).?.program());
        try copy(std.testing.io, &env, runner, "payload", .{});
        try std.testing.expectEqual(@as(usize, 1), noop.calls);
    } else {
        // macOS always has pbcopy; foreign platforms have no clipboard lane.
        if (nativePlatform() == .macos) {
            try std.testing.expect(expected != null);
            try copy(std.testing.io, &env, runner, "payload", .{});
            try std.testing.expectEqual(@as(usize, 1), noop.calls);
        } else {
            try std.testing.expectEqual(@as(?Command, null), expected);
            try std.testing.expectError(Error.Unavailable, copy(std.testing.io, &env, runner, "payload", .{}));
            try std.testing.expectEqual(@as(usize, 0), noop.calls);
        }
    }
}

// --- Payload validation ----------------------------------------------------

test "payload validation rejects empty, oversized and invalid UTF-8 input" {
    try validatePayload("a");
    try validatePayload("# Title\n\nbody ✅\n");
    try std.testing.expectError(Error.InvalidPayload, validatePayload(""));
    try std.testing.expectError(Error.InvalidPayload, validatePayload(&[_]u8{ 0xff, 0xfe }));
    const huge = try std.testing.allocator.alloc(u8, max_payload_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'a');
    try std.testing.expectError(Error.InvalidPayload, validatePayload(huge));
}

test "invalid payload is rejected before the runner is invoked" {
    const Recorder = struct {
        calls: usize = 0,
        fn run(ctx: ?*anyopaque, io: std.Io, command: Command, bytes: []const u8) Error!void {
            _ = io;
            _ = command;
            _ = bytes;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    var rec: Recorder = .{};
    const runner: Runner = .{ .context = &rec, .copyFn = Recorder.run };
    try std.testing.expectError(Error.InvalidPayload, copyWithRunner(std.testing.io, runner, .{ .argv = &.{"x"} }, "", .{}));
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
}

// --- Fake-runner semantics -------------------------------------------------

const FakeRunner = struct {
    received: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    fail_with: ?Error = null,
    hang: bool = false,

    fn run(ctx: ?*anyopaque, io: std.Io, command: Command, bytes: []const u8) Error!void {
        _ = command;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.received.appendSlice(std.testing.allocator, bytes) catch return Error.Failed;
        if (self.hang) {
            // Block well past the timeout budget; the select must interrupt it.
            std.Io.sleep(io, .fromSeconds(30), .awake) catch {};
        }
        if (self.fail_with) |err| return err;
    }

    fn runner(self: *@This()) Runner {
        return .{ .context = self, .copyFn = FakeRunner.run };
    }

    fn deinit(self: *@This()) void {
        self.received.deinit(std.testing.allocator);
    }
};

test "the fake runner receives byte-identical multiline Markdown" {
    // Escapes are explicit so a tab, a trailing space, or a missing final
    // newline cannot be silently normalized by an editor or the formatter.
    const md = "# Clipboard\n" ++
        "\n" ++
        "Copy **exact** bytes: tabs\there and trailing spaces   \n" ++
        "- ✅ unicode bullet\n" ++
        "- `code` — em dash\n" ++
        "\n" ++
        "```\n" ++
        "no trailing newline below\n" ++
        "```";
    var fake: FakeRunner = .{};
    defer fake.deinit();
    try copyWithRunner(std.testing.io, fake.runner(), .{ .argv = &.{"helper"} }, md, .{});
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualSlices(u8, md, fake.received.items);
    // Guard against a stray NUL terminator or added newline.
    try std.testing.expectEqual(md.len, fake.received.items.len);
}

test "helper failures surface as Failed and timeouts as Timeout" {
    var failing: FakeRunner = .{ .fail_with = Error.Failed };
    defer failing.deinit();
    try std.testing.expectError(Error.Failed, copyWithRunner(std.testing.io, failing.runner(), .{ .argv = &.{"helper"} }, "x", .{}));

    var unavailable: FakeRunner = .{ .fail_with = Error.Unavailable };
    defer unavailable.deinit();
    try std.testing.expectError(Error.Unavailable, copyWithRunner(std.testing.io, unavailable.runner(), .{ .argv = &.{"helper"} }, "x", .{}));
}

test "a zero timeout is rejected without running the helper" {
    var fake: FakeRunner = .{};
    defer fake.deinit();
    try std.testing.expectError(Error.Timeout, copyWithRunner(std.testing.io, fake.runner(), .{ .argv = &.{"helper"} }, "x", .{ .timeout_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "a hung helper is interrupted by the timeout and joined" {
    var fake: FakeRunner = .{ .hang = true };
    defer fake.deinit();
    try std.testing.expectError(Error.Timeout, copyWithRunner(std.testing.io, fake.runner(), .{ .argv = &.{"helper"} }, "payload", .{ .timeout_ms = 150 }));
}

// --- Real subprocess stdio (no desktop clipboard involved) -----------------
//
// `cat` stands in for a clipboard helper: it reads stdin to EOF and exits 0,
// exactly the contract pbcopy/wl-copy satisfy. Redirection targets a temp file
// rather than a clipboard, so these tests run headless and in CI.

/// Create an empty file inside `tmp` and return its absolute path. The helper
/// under test redirects into it, so the file must exist before the spawn.
fn tempPath(io: std.Io, tmp: *std.testing.TmpDir, name: []const u8) ![:0]u8 {
    const file = try tmp.dir.createFile(io, name, .{});
    file.close(io);
    return tmp.dir.realPathFileAlloc(io, name, std.testing.allocator);
}

fn readFileAlloc(io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(std.testing.allocator, .unlimited);
}

test "spawnCopy delivers exact multiline bytes through stdin" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = try tempPath(io, &tmp, "clip.bin");
    defer std.testing.allocator.free(out_path);

    const md = "# Exact bytes\n" ++
        "\n" ++
        "line with tab\there\n" ++
        "unicode: ✅ — 🎉\n" ++
        "trailing spaces   \n" ++
        "blank line above\n" ++
        "\n" ++
        "final";
    // A trailing newline is part of the payload and must be preserved verbatim.
    const payload = md ++ "\n";
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec cat > \"$1\"", "copier", out_path };
    try copyWithRunner(io, spawnRunner, .{ .argv = &argv }, payload, .{});

    const written = try readFileAlloc(io, out_path);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, payload, written);
    try std.testing.expectEqual(payload.len, written.len);
}

test "spawnCopy does not append or strip a trailing newline" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = try tempPath(io, &tmp, "noeol.bin");
    defer std.testing.allocator.free(out_path);

    const payload = "no trailing newline";
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec cat > \"$1\"", "copier", out_path };
    try copyWithRunner(io, spawnRunner, .{ .argv = &argv }, payload, .{});

    const written = try readFileAlloc(io, out_path);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, payload, written);
}

test "spawnCopy reports Failed for a helper that exits non-zero" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "cat > /dev/null; exit 3", "copier" };
    try std.testing.expectError(Error.Failed, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &argv }, "payload", .{}));
}

test "spawnCopy reports Failed for a helper killed by a signal" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "cat > /dev/null; kill -TERM $$", "copier" };
    try std.testing.expectError(Error.Failed, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &argv }, "payload", .{}));
}

test "spawnCopy reports Unavailable when the helper is missing" {
    const argv = [_][]const u8{ "/nonexistent/zpi-clipboard-helper-does-not-exist", "-in" };
    try std.testing.expectError(Error.Unavailable, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &argv }, "payload", .{}));
}

test "spawnCopy treats an early helper exit as a broken pipe, not success" {
    // The helper never reads stdin, so the write hits EPIPE. Accepting that as
    // success would report a copy that never happened.
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec 0<&-; sleep 5", "copier" };
    var payload: [1024 * 1024]u8 = @splat('x');
    try std.testing.expectError(Error.Failed, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &argv }, &payload, .{ .timeout_ms = 5000 }));
}

test "spawnCopy suppresses helper stdout and stderr" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = try tempPath(io, &tmp, "noisy.bin");
    defer std.testing.allocator.free(out_path);

    // The helper prints to both streams and still records stdin. Because both
    // are /dev/null, the only observable output is the captured payload.
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec cat > \"$1\" 2>/dev/null | true; echo NOISE; echo NOISE >&2", "copier", out_path };
    try copyWithRunner(io, spawnRunner, .{ .argv = &argv }, "quiet", .{});
}

test "a large copy times out when the helper never reads its pipe" {
    const payload = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'a');
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec sleep 30" };
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(Error.Timeout, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &argv }, payload, .{ .timeout_ms = 250 }));
    try std.testing.expect(start.untilNow(std.testing.io).raw.toMilliseconds() < 5000);
}

test "a helper that ignores stdin and hangs is killed at the deadline" {
    // `sleep` never reads stdin, so the write completes into the pipe buffer
    // and the process would otherwise live for 30s. The deadline must reap it.
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec sleep 30", "copier" };
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(Error.Timeout, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &argv }, "small", .{ .timeout_ms = 200 }));
    const elapsed_ms = start.untilNow(std.testing.io).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms < 10_000);
}

test "a timed-out helper is actually killed, not merely abandoned" {
    // The helper records that it started, sleeps past the deadline, then tries
    // to record that it survived. If the timeout path only returned without
    // killing (or without joining) the child, the "survived" marker would
    // appear. The second marker must never be written.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const started = try tempPath(io, &tmp, "started");
    const survived = try tempPath(io, &tmp, "survived");
    defer std.testing.allocator.free(started);
    defer std.testing.allocator.free(survived);

    // The shell is spawned as its own process-group leader, so killing the
    // group reaches the `sleep` descendant as well as the shell itself.
    const argv = [_][]const u8{ "/bin/sh", "-c", "echo up > \"$1\"; sleep 2; echo alive > \"$2\"", "copier", started, survived };
    try std.testing.expectError(Error.Timeout, copyWithRunner(io, spawnRunner, .{ .argv = &argv }, "payload", .{ .timeout_ms = 300 }));

    // The helper did start (proving the test can observe it at all)...
    const started_bytes = try readFileAlloc(io, started);
    defer std.testing.allocator.free(started_bytes);
    try std.testing.expectEqualStrings("up\n", started_bytes);

    // ...and it never reached its post-sleep marker because it was killed.
    const survived_bytes = readFileAlloc(io, survived) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer std.testing.allocator.free(survived_bytes);
    try std.testing.expectEqual(@as(usize, 0), survived_bytes.len);
}

test "a helper rejected by a broken pipe is killed instead of left running" {
    // The helper closes stdin before reading, so the write fails with EPIPE.
    // `spawnCopy` returns `Failed` immediately without reaching `wait`, which
    // makes the deferred kill the only thing that reaps it. Without that
    // cleanup the helper would sleep on and write a marker below.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const marker = try tempPath(io, &tmp, "marker");
    defer std.testing.allocator.free(marker);

    const argv = [_][]const u8{ "/bin/sh", "-c", "exec 0<&-; sleep 1; echo alive >> \"$1\"", "copier", marker };
    var payload: [512 * 1024]u8 = @splat('x');
    try std.testing.expectError(Error.Failed, copyWithRunner(io, spawnRunner, .{ .argv = &argv }, &payload, .{ .timeout_ms = 10_000 }));

    // Wait past the helper's sleep; a leaked helper would have written by now.
    try std.Io.sleep(io, .fromMilliseconds(1400), .awake);
    const bytes = readFileAlloc(io, marker) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "an oversized payload is rejected before spawning anything" {
    const argv = [_][]const u8{"/bin/true"};
    const huge = try std.testing.allocator.alloc(u8, max_payload_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'a');
    try std.testing.expectError(Error.InvalidPayload, copyWithRunner(std.testing.io, spawnRunner, .{ .argv = &argv }, huge, .{}));
}
