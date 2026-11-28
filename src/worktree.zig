//! Git worktree isolation for parallel subagents.
//!
//! Each isolated subagent receives its own detached git worktree under a private
//! base directory, allowing concurrent file edits without racing on the parent
//! working tree. Parent `.git` metadata stays read-only inside the child sandbox
//! so confined children cannot alter hooks, config, or refs.
const std = @import("std");
const sandbox = @import("sandbox");

pub const max_diff_bytes: usize = 16 * 1024;
pub const max_changed_files: usize = 64;

pub const RepoInfo = struct {
    repo_root: []u8,
    git_common_dir: []u8,
    head_commit: []u8,

    pub fn deinit(self: *RepoInfo, a: std.mem.Allocator) void {
        a.free(self.repo_root);
        a.free(self.git_common_dir);
        a.free(self.head_commit);
        self.* = undefined;
    }
};

pub const Worktree = struct {
    repo_root: []u8,
    git_common_dir: []u8,
    head_commit: []u8,
    path: []u8,

    pub fn deinit(self: *Worktree, a: std.mem.Allocator) void {
        a.free(self.repo_root);
        a.free(self.git_common_dir);
        a.free(self.head_commit);
        a.free(self.path);
        self.* = undefined;
    }
};

pub const Summary = struct {
    isolated: bool = true,
    head: []const u8,
    changed_files: []const []const u8,
    diff: []const u8 = "",
    diff_truncated: bool = false,
    preserved: bool = false,
    path: ?[]const u8 = null,
};

fn runGit(a: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "git", "-C", cwd });
    try argv.appendSlice(a, args);
    return std.process.run(a, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
}

fn trimmedLine(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn isValidCommitHex(hex: []const u8) bool {
    if (hex.len < 40 or hex.len > 64) return false;
    for (hex) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Verify `cwd` is inside a git repository with a valid HEAD commit and return
/// canonical repo root, common `.git` dir, and HEAD commit hash.
pub fn verifyGitRepo(a: std.mem.Allocator, io: std.Io, cwd: []const u8) !RepoInfo {
    const top = runGit(a, io, cwd, &.{ "rev-parse", "--show-toplevel" }) catch return error.WorktreeRequiresGitRepository;
    defer {
        a.free(top.stdout);
        a.free(top.stderr);
    }
    if (!top.term.success()) return error.WorktreeRequiresGitRepository;
    const raw_root = trimmedLine(top.stdout);
    if (raw_root.len == 0) return error.WorktreeRequiresGitRepository;
    const repo_root = try sandbox.canonicalizePath(a, io, cwd, raw_root, false);
    errdefer a.free(repo_root);

    const common = runGit(a, io, repo_root, &.{ "rev-parse", "--git-common-dir" }) catch return error.WorktreeRequiresGitRepository;
    defer {
        a.free(common.stdout);
        a.free(common.stderr);
    }
    if (!common.term.success()) return error.WorktreeRequiresGitRepository;
    const raw_common = trimmedLine(common.stdout);
    if (raw_common.len == 0) return error.WorktreeRequiresGitRepository;
    const git_common_dir = try sandbox.canonicalizePath(a, io, repo_root, raw_common, false);
    errdefer a.free(git_common_dir);

    const head = runGit(a, io, repo_root, &.{ "rev-parse", "--verify", "HEAD" }) catch return error.WorktreeRequiresGitRepository;
    defer {
        a.free(head.stdout);
        a.free(head.stderr);
    }
    if (!head.term.success()) return error.WorktreeRequiresGitRepository;
    const raw_head = trimmedLine(head.stdout);
    if (!isValidCommitHex(raw_head)) return error.WorktreeRequiresGitRepository;
    const head_commit = try a.dupe(u8, raw_head);

    return .{
        .repo_root = repo_root,
        .git_common_dir = git_common_dir,
        .head_commit = head_commit,
    };
}

fn sanitizeLabel(buf: []u8, raw: []const u8) []const u8 {
    var len: usize = 0;
    for (raw) |c| {
        if (len >= buf.len) break;
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            buf[len] = c;
            len += 1;
        } else if (len > 0 and buf[len - 1] != '-') {
            buf[len] = '-';
            len += 1;
        }
    }
    if (len == 0) {
        @memcpy(buf[0..5], "child");
        return buf[0..5];
    }
    return buf[0..len];
}

/// Create a detached worktree at `repo.head_commit` under `base_dir`.
/// Callers should serialize calls per repository with a mutex so concurrent
/// subagents never race on `.git/worktrees` locks.
pub fn create(
    a: std.mem.Allocator,
    io: std.Io,
    repo: RepoInfo,
    base_dir: []const u8,
    label: []const u8,
) !Worktree {
    try std.Io.Dir.cwd().createDirPath(io, base_dir);
    var label_buf: [24]u8 = undefined;
    const safe_label = sanitizeLabel(&label_buf, label);
    var rand_bytes: [6]u8 = undefined;
    io.random(&rand_bytes);
    const leaf = try a.print("zpi-wt-{s}-{x}", .{ safe_label, &rand_bytes });
    defer a.free(leaf);
    const raw_wt_path = try std.fs.path.join(a, &.{ base_dir, leaf });
    defer a.free(raw_wt_path);

    const added = try runGit(a, io, repo.repo_root, &.{ "worktree", "add", "--detach", raw_wt_path, repo.head_commit });
    defer {
        a.free(added.stdout);
        a.free(added.stderr);
    }
    if (!added.term.success()) return error.WorktreeCreateFailed;

    const wt_path = try sandbox.canonicalizePath(a, io, repo.repo_root, raw_wt_path, false);
    errdefer a.free(wt_path);
    const repo_root = try a.dupe(u8, repo.repo_root);
    errdefer a.free(repo_root);
    const git_common_dir = try a.dupe(u8, repo.git_common_dir);
    errdefer a.free(git_common_dir);
    const head_commit = try a.dupe(u8, repo.head_commit);

    return .{
        .repo_root = repo_root,
        .git_common_dir = git_common_dir,
        .head_commit = head_commit,
        .path = wt_path,
    };
}

/// Inspect changed files and bounded unified diff inside `wt`.
/// Allocations are owned by `a` (typically a child arena).
pub fn inspect(a: std.mem.Allocator, io: std.Io, wt: Worktree, preserved: bool) !Summary {
    const status = try runGit(a, io, wt.path, &.{ "status", "--porcelain=v1", "-uall" });
    defer {
        a.free(status.stdout);
        a.free(status.stderr);
    }
    var files: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, status.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len <= 3) continue;
        if (files.items.len >= max_changed_files) break;
        const entry = std.mem.trim(u8, line[3..], " \t\r");
        if (entry.len == 0) continue;
        try files.append(a, try a.dupe(u8, entry));
    }

    const diff_res = try runGit(a, io, wt.path, &.{ "diff", "--no-color", wt.head_commit });
    defer {
        a.free(diff_res.stdout);
        a.free(diff_res.stderr);
    }
    var diff_len = @min(diff_res.stdout.len, max_diff_bytes);
    while (diff_len > 0 and diff_len < diff_res.stdout.len and (diff_res.stdout[diff_len] & 0xc0) == 0x80) {
        diff_len -= 1;
    }
    const truncated = diff_len < diff_res.stdout.len;

    return .{
        .isolated = true,
        .head = try a.dupe(u8, wt.head_commit),
        .changed_files = try files.toOwnedSlice(a),
        .diff = try a.dupe(u8, diff_res.stdout[0..diff_len]),
        .diff_truncated = truncated,
        .preserved = preserved,
        .path = if (preserved) try a.dupe(u8, wt.path) else null,
    };
}

/// Remove a worktree cleanly and prune stale administrative metadata.
pub fn remove(a: std.mem.Allocator, io: std.Io, wt: Worktree) void {
    if (runGit(a, io, wt.repo_root, &.{ "worktree", "remove", "--force", wt.path })) |res| {
        a.free(res.stdout);
        a.free(res.stderr);
    } else |_| {}
    std.Io.Dir.cwd().deleteTree(io, wt.path) catch {};
    if (runGit(a, io, wt.repo_root, &.{ "worktree", "prune" })) |res| {
        a.free(res.stdout);
        a.free(res.stderr);
    } else |_| {}
}

test "worktree lifecycle isolates concurrent edits without modifying parent repo" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root_z);
    const repo_dir = try std.fs.path.join(a, &.{ root_z, "repo" });
    defer a.free(repo_dir);
    const wt_base = try std.fs.path.join(a, &.{ root_z, "worktrees" });
    defer a.free(wt_base);
    try std.Io.Dir.cwd().createDirPath(io, repo_dir);

    // Initialize a minimal git repo with one commit.
    inline for (.{
        &[_][]const u8{"init"},
        &[_][]const u8{ "config", "user.email", "test@example.com" },
        &[_][]const u8{ "config", "user.name", "Test" },
    }) |args| {
        const r = try runGit(a, io, repo_dir, args);
        a.free(r.stdout);
        a.free(r.stderr);
        try std.testing.expect(r.term.success());
    }
    const target = try std.fs.path.join(a, &.{ repo_dir, "shared.txt" });
    defer a.free(target);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "original\n" });
    inline for (.{
        &[_][]const u8{ "add", "shared.txt" },
        &[_][]const u8{ "commit", "-m", "initial" },
    }) |args| {
        const r = try runGit(a, io, repo_dir, args);
        a.free(r.stdout);
        a.free(r.stderr);
        try std.testing.expect(r.term.success());
    }

    var info = try verifyGitRepo(a, io, repo_dir);
    defer info.deinit(a);

    var wt1 = try create(a, io, info, wt_base, "worker-a");
    defer {
        remove(a, io, wt1);
        wt1.deinit(a);
    }
    var wt2 = try create(a, io, info, wt_base, "worker-b");
    defer {
        remove(a, io, wt2);
        wt2.deinit(a);
    }

    const f1 = try std.fs.path.join(a, &.{ wt1.path, "shared.txt" });
    defer a.free(f1);
    const f2 = try std.fs.path.join(a, &.{ wt2.path, "shared.txt" });
    defer a.free(f2);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f1, .data = "edit-a\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f2, .data = "edit-b\n" });

    // Parent working tree remains untouched.
    const parent_data = try std.Io.Dir.cwd().readFileAlloc(io, target, a, .limited(1024));
    defer a.free(parent_data);
    try std.testing.expectEqualStrings("original\n", parent_data);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const s1 = try inspect(arena.allocator(), io, wt1, false);
    const s2 = try inspect(arena.allocator(), io, wt2, false);
    try std.testing.expectEqual(@as(usize, 1), s1.changed_files.len);
    try std.testing.expectEqualStrings("shared.txt", s1.changed_files[0]);
    try std.testing.expect(std.mem.indexOf(u8, s1.diff, "+edit-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2.diff, "+edit-b") != null);
}
