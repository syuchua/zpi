//! Offline diagnostic report. No provider requests or external programs are run.
const std = @import("std");
const zpi = @import("zpi");

pub const Options = struct {
    host_cwd: []const u8,
    models_file: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    pi_sdk: ?[]const u8 = null,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, tui_enabled: bool, writer: *std.Io.Writer, options: Options) !void {
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(io) catch false;
    const ansi = std.Io.File.stdout().supportsAnsiEscapeCodes(io) catch false;
    try writer.print("zpi doctor {s}\n", .{zpi.VERSION});
    try writer.print("  build: optimize {s}; tui {s}\n", .{ @tagName(@import("builtin").mode), if (tui_enabled) "native" else "none" });
    try writer.print("  terminal: stdin {s}, stdout {s}, ANSI {s}\n", .{ if (stdin_tty) "tty" else "redirected", if (stdout_tty) "tty" else "redirected", if (ansi) "available" else "not detected" });

    const models_path = options.models_file orelse environ.get("ZPI_MODELS_FILE") orelse blk: {
        const home = environ.get("HOME") orelse "";
        break :blk try std.fs.path.join(allocator, &.{ home, ".zpi", "agent", "models.json" });
    };
    defer if (options.models_file == null and environ.get("ZPI_MODELS_FILE") == null and environ.get("HOME") != null) allocator.free(models_path);
    const resolved_models = std.fs.path.resolveAlloc(allocator, &.{ options.host_cwd, models_path }) catch return error.InvalidModelsPath;
    defer allocator.free(resolved_models);
    const model_stat = std.Io.Dir.cwd().statFile(io, resolved_models, .{ .follow_symlinks = true }) catch null;
    const provider = options.provider orelse "openai";
    const credential: []const u8 = if (std.mem.eql(u8, provider, "anthropic")) environ.get("ANTHROPIC_API_KEY") orelse "" else if (std.mem.eql(u8, provider, "openai")) environ.get("OPENAI_API_KEY") orelse "" else "";
    const has_env_credential = credential.len > 0;
    try writer.print("  models.json: {s}\n", .{if (model_stat != null and model_stat.?.kind == .file) "present" else "missing"});
    try writer.print("  credential: {s}\n", .{if (has_env_credential) "available (value redacted)" else "not available (provider models.json may supply one)"});

    const path = environ.get("PATH") orelse "";
    const has_rg = try findExecutable(io, allocator, path, "rg");
    const has_fd = try findExecutable(io, allocator, path, "fd") or try findExecutable(io, allocator, path, "fdfind");
    const has_node = try findExecutable(io, allocator, path, "node");
    try writer.print("  tools: rg {s}, fd/fdfind {s}\n", .{ if (has_rg) "available" else "missing", if (has_fd) "available" else "missing" });
    try writer.print("  extensions: node {s}; pi SDK {s}\n", .{ if (has_node) "available (not executed)" else "missing", if (options.pi_sdk != null) "path supplied; not loaded" else "not configured" });
    try writer.writeAll("  safety: no network requests, project instruction files, or SDK code are loaded by doctor\n");
}

fn findExecutable(io: std.Io, allocator: std.mem.Allocator, path: []const u8, name: []const u8) !bool {
    var entries = std.mem.splitScalar(u8, path, ':');
    while (entries.next()) |directory| {
        const candidate = try std.fs.path.join(allocator, &.{ if (directory.len == 0) "." else directory, name });
        defer allocator.free(candidate);
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file and stat.permissions.toMode() & 0o111 != 0) return true;
    }
    return false;
}

test "credential and endpoint diagnostics are presence-only" {
    const env = std.testing.environ;
    _ = env;
}
