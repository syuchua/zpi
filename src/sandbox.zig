//! Shared OS confinement boundary and child-process environment isolation.
//!
//! Backends:
//!   - macOS: Seatbelt (`/usr/bin/sandbox-exec`) with an explicit default-deny SBPL profile
//!   - Linux: Landlock LSM (ABI v1..v5) + seccomp-bpf network filter via a self-exec trampoline
//!   - Linux fallback: `bwrap` (bubblewrap) when Landlock is unsupported by the kernel
//!
//! Compatibility default: `mode == .off` and `env_isolation == .inherit` preserve
//! existing Zpi behavior with no overhead. When confinement is enabled, missing
//! backend support fails closed (`error.SandboxUnavailable`).
const builtin = @import("builtin");
const std = @import("std");

pub const Mode = enum {
    off,
    read_only,
    workspace_write,

    pub fn parse(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "off")) return .off;
        if (std.mem.eql(u8, value, "read-only")) return .read_only;
        if (std.mem.eql(u8, value, "workspace-write")) return .workspace_write;
        return null;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .off => "off",
            .read_only => "read-only",
            .workspace_write => "workspace-write",
        };
    }
};

pub const Network = enum {
    off,
    on,

    pub fn parse(value: []const u8) ?Network {
        if (std.mem.eql(u8, value, "off")) return .off;
        if (std.mem.eql(u8, value, "on")) return .on;
        return null;
    }
};

pub const Backend = enum {
    auto,
    seatbelt,
    landlock,
    bwrap,

    pub fn parse(value: []const u8) ?Backend {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "seatbelt")) return .seatbelt;
        if (std.mem.eql(u8, value, "landlock")) return .landlock;
        if (std.mem.eql(u8, value, "bwrap")) return .bwrap;
        return null;
    }
};

pub const ResolvedBackend = enum {
    seatbelt,
    landlock,
    bwrap,
};

pub const EnvIsolation = enum {
    inherit,
    strict,

    pub fn parse(value: []const u8) ?EnvIsolation {
        if (std.mem.eql(u8, value, "inherit")) return .inherit;
        if (std.mem.eql(u8, value, "strict")) return .strict;
        return null;
    }
};

pub const Config = struct {
    mode: Mode = .off,
    network: Network = .off,
    backend: Backend = .auto,
    env_isolation: EnvIsolation = .inherit,
    workspace: []const u8 = "",
    /// Additional canonical paths readable by confined child processes (e.g., runtime/SDK dirs).
    extra_read_paths: []const []const u8 = &.{},
    /// Additional canonical paths writable by confined child processes (e.g., git worktree metadata).
    extra_write_paths: []const []const u8 = &.{},
    /// Additional environment variable names explicitly forwarded in `strict` mode.
    env_allow: []const []const u8 = &.{},
    /// Optional isolated HOME / TMPDIR for confined children.
    sandbox_home_dir: ?[]const u8 = null,
    sandbox_tmp_dir: ?[]const u8 = null,
    /// Parent environment map used when constructing allowlisted child environments.
    parent_environ: ?*const std.process.Environ.Map = null,

    pub fn isConfined(self: Config) bool {
        return self.mode != .off;
    }

    pub fn isEnvIsolated(self: Config) bool {
        return self.env_isolation == .strict;
    }
};

/// Minimal allowlist of non-credential runtime environment variables forwarded
/// when `env_isolation == .strict`. Provider API keys, cloud credentials,
/// SSH/GPG sockets, and arbitrary ambient secrets are never forwarded.
pub const default_env_allowlist = [_][]const u8{
    "PATH",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "COLORTERM",
    "NO_COLOR",
    "TZ",
    "USER",
    "LOGNAME",
    "SHELL",
    "DEVELOPER_DIR",
};

/// Sensitive subdirectories/files under a user's real HOME that are explicitly
/// denied read access in Seatbelt profiles as defense-in-depth.
const credential_home_entries = [_][]const u8{
    ".ssh",
    ".aws",
    ".gnupg",
    ".zpi",
    ".pi",
    ".kube",
    ".docker",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".git-credentials",
    ".config/gh",
    ".config/gcloud",
};

pub fn validateEnvVarName(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    for (name) |c| {
        if (c == 0 or c == '=' or c < 0x21 or c > 0x7e) return false;
    }
    return true;
}

/// Resolve `input` relative to `cwd` to a canonical absolute path.
/// When `allow_missing` is true, walks up to the deepest existing ancestor
/// while rejecting any dangling symlink along the way.
pub fn canonicalizePath(
    a: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: []const u8,
    allow_missing: bool,
) ![]u8 {
    if (input.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidPath;
    const resolved = try std.fs.path.resolveAlloc(a, &.{ cwd, input });
    defer a.free(resolved);
    const dir = std.Io.Dir.cwd();
    var ancestor: []const u8 = resolved;
    while (true) {
        const canonical = dir.realPathFileAlloc(io, ancestor, a) catch |err| {
            if (err != error.FileNotFound or !allow_missing) return err;
            // A dangling symlink is not a missing regular path component: reject it
            // rather than reconstructing a path that ignores its symlink target.
            _ = dir.statFile(io, ancestor, .{ .follow_symlinks = false }) catch |stat_err| {
                if (stat_err != error.FileNotFound) return stat_err;
                ancestor = std.fs.path.dirname(ancestor) orelse return error.InvalidPath;
                continue;
            };
            return error.InvalidPath;
        };
        defer a.free(canonical);
        if (ancestor.len == resolved.len) return a.dupe(u8, canonical);
        const rest = std.mem.trimStart(u8, resolved[ancestor.len..], "/");
        if (rest.len == 0) return a.dupe(u8, canonical);
        return std.fs.path.join(a, &.{ canonical, rest });
    }
}

pub fn isWithinSubtree(path: []const u8, root: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or !std.fs.path.isAbsolute(root)) return false;
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return std.mem.eql(u8, root, "/") or path[root.len] == '/';
}

/// Canonical-path boundary check for built-in file tools (`read`, `write`, `edit`, `ls`, `find`, `grep`).
/// When `config.mode == .off`, returns the resolved path without confinement to preserve
/// compatibility defaults. When confinement is active, enforces canonical subtree containment
/// and rejects symlinks escaping the workspace (including dangling symlinks and final-component symlinks on write).
pub fn resolveToolPath(
    a: std.mem.Allocator,
    io: std.Io,
    config: Config,
    cwd: []const u8,
    input: []const u8,
    write_access: bool,
) ![]u8 {
    if (input.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPath;
    if (!config.isConfined()) {
        return std.fs.path.resolveAlloc(a, &.{ cwd, input });
    }
    if (write_access and config.mode == .read_only) return error.SandboxWriteDenied;

    const raw_workspace = if (config.workspace.len > 0) config.workspace else cwd;
    const workspace = try canonicalizePath(a, io, cwd, raw_workspace, false);
    defer a.free(workspace);

    const canonical = try canonicalizePath(a, io, cwd, input, write_access);
    errdefer a.free(canonical);

    // For writes, also reject a final component that is an existing symlink even
    // if its target were inside the workspace.
    if (write_access) {
        const direct = try std.fs.path.resolveAlloc(a, &.{ cwd, input });
        defer a.free(direct);
        if (std.Io.Dir.cwd().statFile(io, direct, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind == .sym_link) return error.PathOutsideWorkspace;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (isWithinSubtree(canonical, workspace)) return canonical;
    if (write_access) {
        for (config.extra_write_paths) |extra| {
            const extra_canon = canonicalizePath(a, io, cwd, extra, false) catch continue;
            defer a.free(extra_canon);
            if (isWithinSubtree(canonical, extra_canon)) return canonical;
        }
    } else {
        for (config.extra_read_paths) |extra| {
            const extra_canon = canonicalizePath(a, io, cwd, extra, false) catch continue;
            defer a.free(extra_canon);
            if (isWithinSubtree(canonical, extra_canon)) return canonical;
        }
    }
    return error.PathOutsideWorkspace;
}

/// Detect an available OS confinement backend for the current host and requested policy.
/// Fails closed (`error.SandboxUnavailable` or `error.SandboxBackendUnsupported`) if
/// confinement cannot be enforced on this host.
pub fn detectBackend(io: std.Io, requested: Backend) !ResolvedBackend {
    if (comptime builtin.target.os.tag == .macos) {
        switch (requested) {
            .auto, .seatbelt => {
                std.Io.Dir.cwd().access(io, "/usr/bin/sandbox-exec", .{ .execute = true }) catch return error.SandboxUnavailable;
                return .seatbelt;
            },
            .landlock, .bwrap => return error.SandboxBackendUnsupported,
        }
    }
    if (comptime builtin.target.os.tag == .linux) {
        switch (requested) {
            .auto => {
                if (linuxLandlockAbiVersion() >= 1) return .landlock;
                if (findBwrap(io) != null) return .bwrap;
                return error.SandboxUnavailable;
            },
            .landlock => {
                if (linuxLandlockAbiVersion() >= 1) return .landlock;
                return error.SandboxUnavailable;
            },
            .bwrap => {
                if (findBwrap(io) != null) return .bwrap;
                return error.SandboxUnavailable;
            },
            .seatbelt => return error.SandboxBackendUnsupported,
        }
    }
    return error.SandboxUnavailable;
}

pub fn findBwrap(io: std.Io) ?[]const u8 {
    inline for (.{ "/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap" }) |candidate| {
        if (std.Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| return candidate else |_| {}
    }
    return null;
}

/// Construct an allowlisted child environment map when `env_isolation == .strict`.
/// Caller owns the returned map and must call `deinit()`.
pub fn buildChildEnviron(
    a: std.mem.Allocator,
    config: Config,
    workspace_canonical: []const u8,
) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(a);
    errdefer out.deinit();

    const parent = config.parent_environ;
    if (config.env_isolation == .inherit) {
        if (parent) |src| {
            var it = src.iterator();
            while (it.next()) |entry| {
                try out.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        return out;
    }

    // Strict allowlist mode: copy ONLY known-safe runtime variables + explicit env_allow.
    if (parent) |src| {
        for (default_env_allowlist) |key| {
            if (src.get(key)) |val| try out.put(key, val);
        }
        for (config.env_allow) |key| {
            if (!validateEnvVarName(key)) return error.InvalidEnvAllowlist;
            if (src.get(key)) |val| try out.put(key, val);
        }
    }
    if (out.get("PATH") == null) {
        try out.put("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin");
    }
    // Always isolate HOME and TMPDIR away from real host credential/temp paths.
    const safe_home = config.sandbox_home_dir orelse workspace_canonical;
    const safe_tmp = config.sandbox_tmp_dir orelse workspace_canonical;
    if (safe_home.len > 0) try out.put("HOME", safe_home);
    if (safe_tmp.len > 0) try out.put("TMPDIR", safe_tmp);
    return out;
}

/// Append a quoted SBPL string literal, rejecting control characters and NULs.
fn appendSbplString(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    if (value.len == 0) return error.InvalidSandboxPath;
    for (value) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidSandboxPath;
    }
    try buf.append(a, '"');
    for (value) |c| {
        if (c == '\\' or c == '"') try buf.append(a, '\\');
        try buf.append(a, c);
    }
    try buf.append(a, '"');
}

/// Build a macOS Seatbelt (SBPL) profile enforcing workspace-write/read-only and network policy.
pub fn buildSeatbeltProfile(
    a: std.mem.Allocator,
    config: Config,
    workspace_canonical: []const u8,
    extra_reads: []const []const u8,
    extra_writes: []const []const u8,
    real_home: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a,
        \\(version 1)
        \\(deny default)
        \\(allow process*)
        \\(allow signal (target same-sandbox))
        \\(allow sysctl-read)
        \\(allow mach-lookup)
        \\(allow ipc-posix-shm-read-data)
        \\(allow file-read-metadata)
        \\(allow file-ioctl)
        \\(allow file-read*
        \\    (literal "/")
        \\    (subpath "/usr")
        \\    (subpath "/bin")
        \\    (subpath "/sbin")
        \\    (subpath "/System")
        \\    (subpath "/Library")
        \\    (subpath "/Applications/Xcode.app/Contents")
        \\    (subpath "/opt/homebrew")
        \\    (subpath "/private/etc")
        \\    (subpath "/etc")
        \\    (subpath "/dev")
        \\    (subpath "/private/var/db")
        \\    (subpath "/private/var/select")
        \\    (subpath "/private/var/run")
        \\    (subpath "/AppleInternal")
        \\
    );
    if (workspace_canonical.len > 0) {
        try buf.appendSlice(a, "    (subpath ");
        try appendSbplString(&buf, a, workspace_canonical);
        try buf.appendSlice(a, ")\n");
    }
    for (extra_reads) |path| {
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) continue;
        try buf.appendSlice(a, "    (subpath ");
        try appendSbplString(&buf, a, path);
        try buf.appendSlice(a, ")\n");
    }
    for (extra_writes) |path| {
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) continue;
        try buf.appendSlice(a, "    (subpath ");
        try appendSbplString(&buf, a, path);
        try buf.appendSlice(a, ")\n");
    }
    try buf.appendSlice(a, ")\n");

    // Defense-in-depth: explicitly deny reading host credential directories under
    // real HOME unless the workspace itself was intentionally placed inside them.
    if (real_home) |home| {
        if (home.len > 0 and std.fs.path.isAbsolute(home)) {
            var any_denied = false;
            for (credential_home_entries) |entry| {
                const full = try std.fs.path.join(a, &.{ home, entry });
                defer a.free(full);
                if (workspace_canonical.len > 0 and (isWithinSubtree(workspace_canonical, full) or isWithinSubtree(full, workspace_canonical))) continue;
                if (!any_denied) {
                    try buf.appendSlice(a, "(deny file-read*\n");
                    any_denied = true;
                }
                try buf.appendSlice(a, "    (subpath ");
                try appendSbplString(&buf, a, full);
                try buf.appendSlice(a, ")\n");
            }
            if (any_denied) try buf.appendSlice(a, ")\n");
        }
    }

    try buf.appendSlice(a,
        \\(allow file-write*
        \\    (literal "/dev/null")
        \\    (literal "/dev/zero")
        \\    (literal "/dev/dtracehelper")
        \\    (regex #"^/private/var/folders/[^/]+/[^/]+/T/xcrun_db")
        \\
    );
    if (config.mode == .workspace_write) {
        if (workspace_canonical.len > 0) {
            try buf.appendSlice(a, "    (subpath ");
            try appendSbplString(&buf, a, workspace_canonical);
            try buf.appendSlice(a, ")\n");
        }
        for (extra_writes) |path| {
            if (path.len == 0 or !std.fs.path.isAbsolute(path)) continue;
            try buf.appendSlice(a, "    (subpath ");
            try appendSbplString(&buf, a, path);
            try buf.appendSlice(a, ")\n");
        }
    }
    try buf.appendSlice(a, ")\n");

    if (config.network == .on) {
        try buf.appendSlice(a, "(allow network*)\n");
    } else {
        try buf.appendSlice(a, "(deny network*)\n");
    }
    return buf.toOwnedSlice(a);
}

/// Build `bwrap` command-line arguments for Linux bubblewrap fallback.
pub fn buildBwrapArgv(
    a: std.mem.Allocator,
    io: std.Io,
    bwrap_exe: []const u8,
    config: Config,
    workspace_canonical: []const u8,
    cwd: []const u8,
    extra_reads: []const []const u8,
    extra_writes: []const []const u8,
    target_argv: []const []const u8,
) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(a);

    try argv.appendSlice(a, &.{
        bwrap_exe,
        "--die-with-parent",
        "--new-session",
    });
    if (config.network == .off) {
        try argv.append(a, "--unshare-net");
    }
    // Mount read-only system runtime trees that exist on this host.
    inline for (.{ "/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt" }) |sys_dir| {
        if (std.Io.Dir.cwd().access(io, sys_dir, .{})) |_| {
            try argv.appendSlice(a, &.{ "--ro-bind", sys_dir, sys_dir });
        } else |_| {}
    }
    try argv.appendSlice(a, &.{ "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp" });

    for (extra_reads) |path| {
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) continue;
        try argv.appendSlice(a, &.{ "--ro-bind", path, path });
    }
    if (workspace_canonical.len > 0) {
        const flag = if (config.mode == .workspace_write) "--bind" else "--ro-bind";
        try argv.appendSlice(a, &.{ flag, workspace_canonical, workspace_canonical });
    }
    if (config.mode == .workspace_write) {
        for (extra_writes) |path| {
            if (path.len == 0 or !std.fs.path.isAbsolute(path)) continue;
            try argv.appendSlice(a, &.{ "--bind", path, path });
        }
    }
    try argv.appendSlice(a, &.{ "--chdir", cwd, "--" });
    try argv.appendSlice(a, target_argv);
    return argv.toOwnedSlice(a);
}

/// Resolve an executable (`argv[0]`) and return an ancestor directory to allow
/// reading if it lives outside standard system directories (for example, nvm Node
/// or a virtualenv Python). Never broadens access to all of `$HOME` or `/`.
fn discoverExecutableRuntimeRoot(
    a: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    parent_env: ?*const std.process.Environ.Map,
    real_home: ?[]const u8,
) !?[]u8 {
    if (exe.len == 0) return null;
    const candidate_path: ?[:0]u8 = blk: {
        if (std.mem.indexOfScalar(u8, exe, '/') != null) {
            break :blk std.Io.Dir.cwd().realPathFileAlloc(io, exe, a) catch null;
        }
        const path_env = if (parent_env) |env| env.get("PATH") else null;
        if (path_env) |paths| {
            var it = std.mem.splitScalar(u8, paths, ':');
            while (it.next()) |dir| {
                if (dir.len == 0) continue;
                const joined = std.fs.path.join(a, &.{ dir, exe }) catch continue;
                defer a.free(joined);
                if (std.Io.Dir.cwd().access(io, joined, .{ .execute = true })) |_| {
                    if (std.Io.Dir.cwd().realPathFileAlloc(io, joined, a)) |real| {
                        break :blk real;
                    } else |_| {}
                } else |_| {}
            }
        }
        break :blk null;
    };
    const resolved = candidate_path orelse return null;
    defer a.free(resolved);

    // Already covered by standard read-only system roots.
    inline for (.{ "/usr/", "/bin/", "/sbin/", "/System/", "/Library/", "/opt/homebrew/", "/Applications/Xcode.app/Contents/" }) |prefix| {
        if (std.mem.startsWith(u8, resolved, prefix)) return null;
    }

    const bin_dir = std.fs.path.dirname(resolved) orelse return null;
    // If executable is in `<prefix>/bin/<exe>`, allow `<prefix>` (e.g., nvm Node
    // prefix so Node can load its sibling `lib/` and `share/` files) as long as
    // `<prefix>` is not `/` or real `$HOME`.
    const root_dir = blk: {
        if (std.mem.eql(u8, std.fs.path.basename(bin_dir), "bin")) {
            if (std.fs.path.dirname(bin_dir)) |prefix| {
                const is_root = std.mem.eql(u8, prefix, "/");
                const is_home = if (real_home) |h| std.mem.eql(u8, prefix, h) else false;
                if (!is_root and !is_home) break :blk prefix;
            }
        }
        break :blk bin_dir;
    };
    if (std.mem.eql(u8, root_dir, "/")) return null;
    if (real_home) |h| if (std.mem.eql(u8, root_dir, h)) return null;
    return try a.dupe(u8, root_dir);
}

pub const SpawnRequest = struct {
    argv: []const []const u8,
    cwd: []const u8,
    pgid: ?std.posix.pid_t = 0,
    stdin: std.process.SpawnOptions.StdIo = .ignore,
    stdout: std.process.SpawnOptions.StdIo = .pipe,
    stderr: std.process.SpawnOptions.StdIo = .ignore,
    /// Per-call extra readable canonical paths (e.g., extension host script, pi-sdk).
    extra_read_paths: []const []const u8 = &.{},
    /// Per-call extra writable canonical paths.
    extra_write_paths: []const []const u8 = &.{},
};

pub const RunRequest = struct {
    argv: []const []const u8,
    cwd: []const u8,
    stdout_limit: std.Io.Limit = .limited(32 * 1024 * 1024),
    stderr_limit: std.Io.Limit = .limited(1024 * 1024),
    extra_read_paths: []const []const u8 = &.{},
    extra_write_paths: []const []const u8 = &.{},
};

const PreparedCommand = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    cwd: []const u8,
    env: ?std.process.Environ.Map,

    fn deinit(self: *PreparedCommand) void {
        if (self.env) |*m| m.deinit();
        self.arena.deinit();
    }
};

fn prepareCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: Config,
    argv: []const []const u8,
    cwd: []const u8,
    call_extra_reads: []const []const u8,
    call_extra_writes: []const []const u8,
) !PreparedCommand {
    if (argv.len == 0) return error.InvalidCommand;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const raw_workspace = if (config.workspace.len > 0) config.workspace else cwd;
    const workspace_canon = if (raw_workspace.len > 0)
        (canonicalizePath(a, io, cwd, raw_workspace, false) catch try a.dupe(u8, raw_workspace))
    else
        "";
    const cwd_canon = canonicalizePath(a, io, cwd, cwd, false) catch try a.dupe(u8, cwd);

    var env_map: ?std.process.Environ.Map = null;
    errdefer if (env_map) |*m| m.deinit();
    if (config.isEnvIsolated()) {
        env_map = try buildChildEnviron(gpa, config, workspace_canon);
    }

    if (!config.isConfined()) {
        return .{
            .arena = arena,
            .argv = argv,
            .cwd = cwd_canon,
            .env = env_map,
        };
    }

    const backend = try detectBackend(io, config.backend);

    const real_home: ?[]const u8 = if (config.parent_environ) |env| env.get("HOME") else null;

    var reads: std.ArrayList([]const u8) = .empty;
    for (config.extra_read_paths) |p| {
        const c = canonicalizePath(a, io, cwd_canon, p, false) catch continue;
        try reads.append(a, c);
    }
    for (call_extra_reads) |p| {
        const c = canonicalizePath(a, io, cwd_canon, p, false) catch continue;
        try reads.append(a, c);
    }
    if (try discoverExecutableRuntimeRoot(a, io, argv[0], config.parent_environ, real_home)) |runtime_root| {
        try reads.append(a, runtime_root);
    }

    var writes: std.ArrayList([]const u8) = .empty;
    for (config.extra_write_paths) |p| {
        const c = canonicalizePath(a, io, cwd_canon, p, false) catch continue;
        try writes.append(a, c);
    }
    for (call_extra_writes) |p| {
        const c = canonicalizePath(a, io, cwd_canon, p, false) catch continue;
        try writes.append(a, c);
    }
    if (config.sandbox_tmp_dir) |d| {
        if (canonicalizePath(a, io, cwd_canon, d, false)) |c| try writes.append(a, c) else |_| {}
    }
    if (config.sandbox_home_dir) |d| {
        if (canonicalizePath(a, io, cwd_canon, d, false)) |c| try writes.append(a, c) else |_| {}
    }

    const wrapped_argv = switch (backend) {
        .seatbelt => blk: {
            const profile = try buildSeatbeltProfile(a, config, workspace_canon, reads.items, writes.items, real_home);
            var out: std.ArrayList([]const u8) = .empty;
            try out.appendSlice(a, &.{ "/usr/bin/sandbox-exec", "-p", profile, "--" });
            try out.appendSlice(a, argv);
            break :blk try out.toOwnedSlice(a);
        },
        .bwrap => blk: {
            const bwrap_exe = findBwrap(io) orelse return error.SandboxUnavailable;
            break :blk try buildBwrapArgv(a, io, bwrap_exe, config, workspace_canon, cwd_canon, reads.items, writes.items, argv);
        },
        .landlock => blk: {
            if (comptime builtin.target.os.tag != .linux) return error.SandboxBackendUnsupported;
            const self_exe = try std.process.executablePathAlloc(io, a);
            const spec_json = try std.json.Stringify.valueAlloc(a, LinuxSandboxSpec{
                .mode = config.mode.name(),
                .network = config.network == .on,
                .workspace = workspace_canon,
                .cwd = cwd_canon,
                .extra_reads = reads.items,
                .extra_writes = writes.items,
            }, .{});
            var out: std.ArrayList([]const u8) = .empty;
            try out.appendSlice(a, &.{ self_exe, internal_exec_flag, spec_json, "--" });
            try out.appendSlice(a, argv);
            break :blk try out.toOwnedSlice(a);
        },
    };

    return .{
        .arena = arena,
        .argv = wrapped_argv,
        .cwd = cwd_canon,
        .env = env_map,
    };
}

pub fn spawn(gpa: std.mem.Allocator, io: std.Io, config: Config, req: SpawnRequest) !std.process.Child {
    var prepared = try prepareCommand(gpa, io, config, req.argv, req.cwd, req.extra_read_paths, req.extra_write_paths);
    defer prepared.deinit();
    return std.process.spawn(io, .{
        .argv = prepared.argv,
        .cwd = .{ .path = prepared.cwd },
        .environ_map = if (prepared.env) |*m| m else null,
        .pgid = req.pgid,
        .stdin = req.stdin,
        .stdout = req.stdout,
        .stderr = req.stderr,
    });
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, config: Config, req: RunRequest) !std.process.RunResult {
    var prepared = try prepareCommand(gpa, io, config, req.argv, req.cwd, req.extra_read_paths, req.extra_write_paths);
    defer prepared.deinit();
    return std.process.run(gpa, io, .{
        .argv = prepared.argv,
        .cwd = .{ .path = prepared.cwd },
        .environ_map = if (prepared.env) |*m| m else null,
        .stdout_limit = req.stdout_limit,
        .stderr_limit = req.stderr_limit,
    });
}

pub const internal_exec_flag = "--zpi-internal-sandbox-exec";

const LinuxSandboxSpec = struct {
    mode: []const u8,
    network: bool,
    workspace: []const u8,
    cwd: []const u8,
    extra_reads: []const []const u8,
    extra_writes: []const []const u8,
};

// -----------------------------------------------------------------------------
// Linux Landlock + seccomp-bpf confinement implementation
// -----------------------------------------------------------------------------

const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1 << 0;
const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;

const LANDLOCK_ACCESS_FS_EXECUTE: u64 = 1 << 0;
const LANDLOCK_ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
const LANDLOCK_ACCESS_FS_READ_FILE: u64 = 1 << 2;
const LANDLOCK_ACCESS_FS_READ_DIR: u64 = 1 << 3;
const LANDLOCK_ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
const LANDLOCK_ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
const LANDLOCK_ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
const LANDLOCK_ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
const LANDLOCK_ACCESS_FS_MAKE_REG: u64 = 1 << 8;
const LANDLOCK_ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
const LANDLOCK_ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
const LANDLOCK_ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
const LANDLOCK_ACCESS_FS_MAKE_SYM: u64 = 1 << 12;
const LANDLOCK_ACCESS_FS_REFER: u64 = 1 << 13;
const LANDLOCK_ACCESS_FS_TRUNCATE: u64 = 1 << 14;
const LANDLOCK_ACCESS_FS_IOCTL_DEV: u64 = 1 << 15;

const LANDLOCK_ACCESS_NET_BIND_TCP: u64 = 1 << 0;
const LANDLOCK_ACCESS_NET_CONNECT_TCP: u64 = 1 << 1;

const LandlockRulesetAttr = extern struct {
    handled_access_fs: u64,
    handled_access_net: u64 = 0,
};

const LandlockPathBeneathAttr = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};

pub fn linuxLandlockAbiVersion() i32 {
    if (comptime builtin.target.os.tag != .linux) return -1;
    const rc = std.os.linux.syscall3(
        .landlock_create_ruleset,
        0,
        0,
        LANDLOCK_CREATE_RULESET_VERSION,
    );
    const signed: isize = @bitCast(rc);
    if (signed < 1) return -1;
    return @intCast(signed);
}

fn linuxAddLandlockPath(ruleset_fd: i32, path: []const u8, access: u64) void {
    if (comptime builtin.target.os.tag != .linux) return;
    if (path.len == 0 or path.len >= 4096) return;
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const O_PATH: u32 = 0o10000000;
    const O_CLOEXEC: u32 = 0o2000000;
    const fd_rc = std.os.linux.syscall4(
        .openat,
        @as(usize, @bitCast(@as(isize, std.os.linux.AT.FDCWD))),
        @intFromPtr(path_z),
        O_PATH | O_CLOEXEC,
        0,
    );
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return;
    defer _ = std.os.linux.close(@intCast(fd));
    var attr: LandlockPathBeneathAttr = .{
        .allowed_access = access,
        .parent_fd = @intCast(fd),
    };
    _ = std.os.linux.syscall4(
        .landlock_add_rule,
        @as(usize, @intCast(ruleset_fd)),
        LANDLOCK_RULE_PATH_BENEATH,
        @intFromPtr(&attr),
        0,
    );
}

const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

fn installLinuxSeccompNetworkDeny() !void {
    if (comptime builtin.target.os.tag != .linux) return;
    // Linux UAPI <linux/audit.h> constants (avoid std.os.linux.AUDIT.ARCH enum bug in Zig 0.17.0).
    const AUDIT_ARCH_X86_64: u32 = 0xC000003E;
    const AUDIT_ARCH_AARCH64: u32 = 0xC00000B7;
    const arch_id: u32 = switch (builtin.target.cpu.arch) {
        .x86_64 => AUDIT_ARCH_X86_64,
        .aarch64 => AUDIT_ARCH_AARCH64,
        else => return error.SandboxBackendUnsupported,
    };
    const socket_nr: u32 = @backingInt(std.os.linux.SYS.socket);
    const BPF_LD: u16 = 0x00;
    const BPF_W: u16 = 0x00;
    const BPF_ABS: u16 = 0x20;
    const BPF_JMP: u16 = 0x05;
    const BPF_JEQ: u16 = 0x10;
    const BPF_K: u16 = 0x00;
    const BPF_RET: u16 = 0x06;

    const offset_nr: u32 = @offsetOf(std.os.linux.SECCOMP.data, "nr");
    const offset_arch: u32 = @offsetOf(std.os.linux.SECCOMP.data, "arch");
    const offset_arg0: u32 = @offsetOf(std.os.linux.SECCOMP.data, "arg0");
    const ret_allow: u32 = std.os.linux.SECCOMP.RET.ALLOW;
    const ret_eperm: u32 = std.os.linux.SECCOMP.RET.ERRNO | @as(u32, @backingInt(std.os.linux.E.PERM));
    const ret_kill: u32 = std.os.linux.SECCOMP.RET.KILL_PROCESS;

    const filter = [_]SockFilter{
        // 0: load arch
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = offset_arch },
        // 1: if arch != expected, kill
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 1, .jf = 0, .k = arch_id },
        // 2: kill on arch mismatch
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_kill },
        // 3: load syscall nr
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = offset_nr },
        // 4: if nr == SYS_socket, inspect arg0 (domain); else jump to allow (idx 10)
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 0, .jf = 5, .k = socket_nr },
        // 5: load arg0 (socket domain, lower 32 bits on little-endian)
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = offset_arg0 },
        // 6: deny AF_INET (2)
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 4, .jf = 0, .k = std.os.linux.AF.INET },
        // 7: deny AF_INET6 (10)
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 3, .jf = 0, .k = std.os.linux.AF.INET6 },
        // 8: deny AF_NETLINK (16)
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 2, .jf = 0, .k = std.os.linux.AF.NETLINK },
        // 9: deny AF_PACKET (17)
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 1, .jf = 0, .k = std.os.linux.AF.PACKET },
        // 10: allow
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_allow },
        // 11: deny with EPERM
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_eperm },
    };

    const prog: SockFprog = .{ .len = filter.len, .filter = &filter };
    const rc = std.os.linux.seccomp(
        std.os.linux.SECCOMP.SET_MODE_FILTER,
        0,
        &prog,
    );
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.SeccompInstallFailed;
}

/// Entrypoint invoked by `src/main.zig` when launched as the Linux confinement
/// self-exec trampoline (`zpi --zpi-internal-sandbox-exec <spec-json> -- <argv...>`).
pub fn execInternalLinuxSandbox(
    a: std.mem.Allocator,
    spec_json: []const u8,
    target_argv: []const [:0]const u8,
    environ: *const std.process.Environ.Map,
) noreturn {
    if (comptime builtin.target.os.tag != .linux) {
        std.process.exit(126);
    }
    execInternalLinuxSandboxImpl(a, spec_json, target_argv, environ) catch {
        std.process.exit(126);
    };
    std.process.exit(126);
}

fn execInternalLinuxSandboxImpl(
    a: std.mem.Allocator,
    spec_json: []const u8,
    target_argv: []const [:0]const u8,
    environ: *const std.process.Environ.Map,
) !void {
    if (comptime builtin.target.os.tag != .linux) return error.SandboxBackendUnsupported;
    if (target_argv.len == 0) return error.InvalidCommand;
    var parsed = try std.json.parseFromSlice(LinuxSandboxSpec, a, spec_json, .{});
    defer parsed.deinit();
    const spec = parsed.value;
    const mode = Mode.parse(spec.mode) orelse return error.InvalidSandboxMode;

    // 1. PR_SET_NO_NEW_PRIVS is required before Landlock and unprivileged seccomp.
    const nnp_rc = std.os.linux.prctl(@backingInt(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (@as(isize, @bitCast(nnp_rc)) < 0) return error.SandboxUnavailable;

    // 2. Apply Landlock filesystem (and ABI v4 TCP network) restrictions.
    const abi = linuxLandlockAbiVersion();
    if (abi < 1) return error.SandboxUnavailable;

    var fs_all: u64 = LANDLOCK_ACCESS_FS_EXECUTE |
        LANDLOCK_ACCESS_FS_WRITE_FILE |
        LANDLOCK_ACCESS_FS_READ_FILE |
        LANDLOCK_ACCESS_FS_READ_DIR |
        LANDLOCK_ACCESS_FS_REMOVE_DIR |
        LANDLOCK_ACCESS_FS_REMOVE_FILE |
        LANDLOCK_ACCESS_FS_MAKE_CHAR |
        LANDLOCK_ACCESS_FS_MAKE_DIR |
        LANDLOCK_ACCESS_FS_MAKE_REG |
        LANDLOCK_ACCESS_FS_MAKE_SOCK |
        LANDLOCK_ACCESS_FS_MAKE_FIFO |
        LANDLOCK_ACCESS_FS_MAKE_BLOCK |
        LANDLOCK_ACCESS_FS_MAKE_SYM;
    if (abi >= 2) fs_all |= LANDLOCK_ACCESS_FS_REFER;
    if (abi >= 3) fs_all |= LANDLOCK_ACCESS_FS_TRUNCATE;
    if (abi >= 5) fs_all |= LANDLOCK_ACCESS_FS_IOCTL_DEV;

    const fs_read: u64 = LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
    var fs_write_file: u64 = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE;
    if (abi >= 3) fs_write_file |= LANDLOCK_ACCESS_FS_TRUNCATE;
    if (abi >= 5) fs_write_file |= LANDLOCK_ACCESS_FS_IOCTL_DEV;

    var attr: LandlockRulesetAttr = .{
        .handled_access_fs = fs_all,
        .handled_access_net = if (!spec.network and abi >= 4) (LANDLOCK_ACCESS_NET_BIND_TCP | LANDLOCK_ACCESS_NET_CONNECT_TCP) else 0,
    };
    const attr_size: usize = if (abi >= 4) @sizeOf(LandlockRulesetAttr) else @sizeOf(u64);
    const ruleset_rc = std.os.linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), attr_size, 0);
    const ruleset_signed: isize = @bitCast(ruleset_rc);
    if (ruleset_signed < 0) return error.SandboxUnavailable;
    const ruleset_fd: i32 = @intCast(ruleset_signed);
    defer _ = std.os.linux.close(ruleset_fd);

    inline for (.{ "/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/dev", "/proc", "/sys", "/opt" }) |sys_dir| {
        linuxAddLandlockPath(ruleset_fd, sys_dir, fs_read);
    }
    linuxAddLandlockPath(ruleset_fd, "/dev/null", fs_write_file);
    linuxAddLandlockPath(ruleset_fd, "/dev/zero", fs_write_file);

    for (spec.extra_reads) |path| linuxAddLandlockPath(ruleset_fd, path, fs_read);
    if (spec.workspace.len > 0) {
        linuxAddLandlockPath(ruleset_fd, spec.workspace, if (mode == .workspace_write) fs_all else fs_read);
    }
    if (mode == .workspace_write) {
        for (spec.extra_writes) |path| linuxAddLandlockPath(ruleset_fd, path, fs_all);
    }

    const restrict_rc = std.os.linux.syscall2(.landlock_restrict_self, @as(usize, @intCast(ruleset_fd)), 0);
    if (@as(isize, @bitCast(restrict_rc)) < 0) return error.SandboxUnavailable;

    // 3. Apply seccomp-bpf network filter when network is off.
    if (!spec.network) {
        try installLinuxSeccompNetworkDeny();
    }

    // 4. chdir to target cwd and exec target program.
    if (spec.cwd.len > 0) {
        const cwd_z = try a.dupeSentinel(u8, spec.cwd, 0);
        defer a.free(cwd_z);
        const chdir_rc = std.os.linux.chdir(cwd_z);
        if (@as(isize, @bitCast(chdir_rc)) < 0) return error.SandboxChdirFailed;
    }

    const argv_ptrs = try a.allocSentinel(?[*:0]const u8, target_argv.len, null);
    for (target_argv, 0..) |arg, idx| argv_ptrs[idx] = arg.ptr;

    const env_block = try environ.createPosixBlock(a, .{});
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env_block.slice.ptr);

    // If argv[0] contains '/', exec directly; otherwise search PATH from environ.
    const exe_name = target_argv[0];
    if (std.mem.indexOfScalar(u8, exe_name, '/') != null) {
        _ = std.os.linux.execve(exe_name.ptr, argv_ptrs.ptr, envp);
        return error.ExecFailed;
    }
    const path_env = environ.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try a.printSentinel("{s}/{s}", .{ dir, exe_name }, 0);
        _ = std.os.linux.execve(candidate.ptr, argv_ptrs.ptr, envp);
    }
    return error.ExecFailed;
}

// -----------------------------------------------------------------------------
// Unit tests
// -----------------------------------------------------------------------------

test "strict child environment allowlist strips secrets and isolates HOME and TMPDIR" {
    const a = std.testing.allocator;
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("TERM", "xterm-256color");
    try parent.put("HOME", "/Users/victim");
    try parent.put("TMPDIR", "/tmp");
    try parent.put("OPENAI_API_KEY", "sk-secret-openai");
    try parent.put("ANTHROPIC_API_KEY", "sk-ant-secret");
    try parent.put("AWS_SECRET_ACCESS_KEY", "aws-secret");
    try parent.put("GITHUB_TOKEN", "ghp_secret");
    try parent.put("CUSTOM_SAFE_FLAG", "yes");

    var env = try buildChildEnviron(a, .{
        .env_isolation = .strict,
        .env_allow = &.{"CUSTOM_SAFE_FLAG"},
        .parent_environ = &parent,
    }, "/workspace/proj");
    defer env.deinit();

    try std.testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("xterm-256color", env.get("TERM").?);
    try std.testing.expectEqualStrings("yes", env.get("CUSTOM_SAFE_FLAG").?);
    try std.testing.expectEqualStrings("/workspace/proj", env.get("HOME").?);
    try std.testing.expectEqualStrings("/workspace/proj", env.get("TMPDIR").?);
    try std.testing.expect(env.get("OPENAI_API_KEY") == null);
    try std.testing.expect(env.get("ANTHROPIC_API_KEY") == null);
    try std.testing.expect(env.get("AWS_SECRET_ACCESS_KEY") == null);
    try std.testing.expect(env.get("GITHUB_TOKEN") == null);
}

test "canonical path checks confine file tools and block symlink escapes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const ws = try std.fs.path.join(a, &.{ root, "ws" });
    defer a.free(ws);
    const outside = try std.fs.path.join(a, &.{ root, "outside" });
    defer a.free(outside);
    try std.Io.Dir.cwd().createDirPath(io, ws);
    try std.Io.Dir.cwd().createDirPath(io, outside);

    const inside_file = try std.fs.path.join(a, &.{ ws, "ok.txt" });
    defer a.free(inside_file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = inside_file, .data = "inside" });

    const secret_file = try std.fs.path.join(a, &.{ outside, "secret.txt" });
    defer a.free(secret_file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = secret_file, .data = "secret" });

    const link_to_secret = try std.fs.path.join(a, &.{ ws, "link-secret.txt" });
    defer a.free(link_to_secret);
    try std.Io.Dir.cwd().symLink(io, secret_file, link_to_secret, .{});

    const dir_link = try std.fs.path.join(a, &.{ ws, "dir-escape" });
    defer a.free(dir_link);
    try std.Io.Dir.cwd().symLink(io, outside, dir_link, .{});

    const dangling = try std.fs.path.join(a, &.{ ws, "dangling.txt" });
    defer a.free(dangling);
    const missing_outside = try std.fs.path.join(a, &.{ outside, "new-secret.txt" });
    defer a.free(missing_outside);
    try std.Io.Dir.cwd().symLink(io, missing_outside, dangling, .{});

    const cfg: Config = .{ .mode = .workspace_write, .workspace = ws };

    // Inside workspace read & new-file write succeed.
    const ok_read = try resolveToolPath(a, io, cfg, ws, "ok.txt", false);
    defer a.free(ok_read);
    try std.testing.expectEqualStrings(inside_file, ok_read);

    const ok_write = try resolveToolPath(a, io, cfg, ws, "sub/new.txt", true);
    defer a.free(ok_write);
    try std.testing.expect(isWithinSubtree(ok_write, ws));

    // Traversal, symlink to outside file, symlinked parent dir, and dangling symlink are all rejected.
    try std.testing.expectError(error.PathOutsideWorkspace, resolveToolPath(a, io, cfg, ws, "../outside/secret.txt", false));
    try std.testing.expectError(error.PathOutsideWorkspace, resolveToolPath(a, io, cfg, ws, "../outside/new.txt", true));
    try std.testing.expectError(error.PathOutsideWorkspace, resolveToolPath(a, io, cfg, ws, "link-secret.txt", false));
    try std.testing.expectError(error.PathOutsideWorkspace, resolveToolPath(a, io, cfg, ws, "link-secret.txt", true));
    try std.testing.expectError(error.PathOutsideWorkspace, resolveToolPath(a, io, cfg, ws, "dir-escape/new.txt", true));
    try std.testing.expectError(error.InvalidPath, resolveToolPath(a, io, cfg, ws, "dangling.txt", true));

    // Read-only mode denies all writes even inside workspace.
    const ro_cfg: Config = .{ .mode = .read_only, .workspace = ws };
    try std.testing.expectError(error.SandboxWriteDenied, resolveToolPath(a, io, ro_cfg, ws, "ok.txt", true));
}

test "seatbelt profile escapes quotes and denies network and credential dirs by default" {
    const a = std.testing.allocator;
    const profile = try buildSeatbeltProfile(
        a,
        .{ .mode = .workspace_write, .network = .off },
        "/workspace/my \"dir\"",
        &.{},
        &.{},
        "/Users/alice",
    );
    defer a.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"/workspace/my \\\"dir\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"/Users/alice/.ssh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"/Users/alice/.zpi\"") != null);
}

test "bwrap argv builder configures read-only and workspace-write with network off" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const argv = try buildBwrapArgv(
        a,
        io,
        "/usr/bin/bwrap",
        .{ .mode = .workspace_write, .network = .off },
        "/ws",
        "/ws",
        &.{"/opt/sdk"},
        &.{},
        &.{ "/bin/sh", "-c", "true" },
    );
    defer a.free(argv);
    try std.testing.expectEqualStrings("/usr/bin/bwrap", argv[0]);
    var saw_unshare_net = false;
    var saw_bind_ws = false;
    for (argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--unshare-net")) saw_unshare_net = true;
        if (std.mem.eql(u8, arg, "--bind") and idx + 1 < argv.len and std.mem.eql(u8, argv[idx + 1], "/ws")) saw_bind_ws = true;
    }
    try std.testing.expect(saw_unshare_net);
    try std.testing.expect(saw_bind_ws);
}

test "macos seatbelt blocks out-of-workspace writes and strips secret env vars" {
    if (comptime builtin.target.os.tag != .macos) return;
    const a = std.testing.allocator;
    const io = std.testing.io;
    if (detectBackend(io, .seatbelt)) |_| {} else |_| return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const ws = try std.fs.path.join(a, &.{ root, "ws" });
    defer a.free(ws);
    const outside = try std.fs.path.join(a, &.{ root, "outside" });
    defer a.free(outside);
    try std.Io.Dir.cwd().createDirPath(io, ws);
    try std.Io.Dir.cwd().createDirPath(io, outside);

    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    try parent.put("OPENAI_API_KEY", "sk-must-not-leak");

    const cfg: Config = .{
        .mode = .workspace_write,
        .network = .off,
        .backend = .seatbelt,
        .env_isolation = .strict,
        .workspace = ws,
        .parent_environ = &parent,
    };

    // 1. In-workspace write succeeds and OPENAI_API_KEY is absent.
    const ok_res = try run(a, io, cfg, .{
        .argv = &.{ "/bin/sh", "-c", "printf '%s' \"${OPENAI_API_KEY:-ABSENT}\" > inside.txt && cat inside.txt" },
        .cwd = ws,
    });
    defer {
        a.free(ok_res.stdout);
        a.free(ok_res.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, ok_res.term);
    try std.testing.expectEqualStrings("ABSENT", ok_res.stdout);

    // 2. Out-of-workspace write is blocked by OS kernel.
    const escape_path = try std.fs.path.join(a, &.{ outside, "escape.txt" });
    defer a.free(escape_path);
    const cmd = try a.print("echo bad > '{s}'", .{escape_path});
    defer a.free(cmd);
    const bad_res = try run(a, io, cfg, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .cwd = ws,
    });
    defer {
        a.free(bad_res.stdout);
        a.free(bad_res.stderr);
    }
    try std.testing.expect(bad_res.term != .exited or bad_res.term.exited != 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, escape_path, .{}));
}
