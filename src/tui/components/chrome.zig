//! Animated Loader spinner and compact single-line Status Footer components.
const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("../theme.zig");

pub const Phase = enum {
    thinking,
    streaming,
    tool,
    retrying,
    compacting,
};

pub const Loader = struct {
    frame: usize = 0,
    phase: Phase = .streaming,
    detail: [64]u8 = undefined,
    detail_len: usize = 0,
    elapsed_ms: u64 = 0,

    const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const ascii_frames = [_][]const u8{ "|", "/", "-", "\\" };

    pub fn setPhase(self: *Loader, phase: Phase, detail: []const u8) void {
        self.phase = phase;
        const n = @min(detail.len, self.detail.len);
        @memcpy(self.detail[0..n], detail[0..n]);
        self.detail_len = n;
    }

    pub fn tick(self: *Loader, delta_ms: u64) void {
        self.frame +%= 1;
        self.elapsed_ms +|= delta_ms;
    }

    pub fn renderLineAlloc(self: *const Loader, allocator: std.mem.Allocator, th: theme.Theme, max_cols: usize) ![]u8 {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(allocator);

        const icon = if (th.mode == .none)
            ascii_frames[self.frame % ascii_frames.len]
        else
            spinner_frames[self.frame % spinner_frames.len];

        try th.paint(&raw, allocator, theme.Theme.accent, icon);
        try raw.append(allocator, ' ');

        try th.appendOpen(&raw, allocator, theme.Theme.muted);
        switch (self.phase) {
            .thinking => try raw.appendSlice(allocator, "Thinking..."),
            .streaming => try raw.appendSlice(allocator, "Working..."),
            .tool => {
                try raw.appendSlice(allocator, "Running ");
                if (self.detail_len > 0) _ = try terminal.appendClippedText(&raw, allocator, self.detail[0..self.detail_len], 24);
                try raw.appendSlice(allocator, "...");
            },
            .retrying => {
                try raw.appendSlice(allocator, "Retrying");
                if (self.detail_len > 0) {
                    try raw.append(allocator, ' ');
                    _ = try terminal.appendClippedText(&raw, allocator, self.detail[0..self.detail_len], 24);
                }
                try raw.appendSlice(allocator, "...");
            },
            .compacting => try raw.appendSlice(allocator, "Compacting context..."),
        }
        const tenths = self.elapsed_ms / 100;
        if (tenths > 0) {
            try raw.print(allocator, " ({d}.{d}s)", .{ tenths / 10, tenths % 10 });
        }
        try th.appendClose(&raw, allocator);

        var clipped: std.ArrayList(u8) = .empty;
        errdefer clipped.deinit(allocator);
        _ = try terminal.appendTruncatedAnsi(&clipped, allocator, raw.items, max_cols, "...");
        return try clipped.toOwnedSlice(allocator);
    }
};

pub const FooterInfo = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
    thinking_level: []const u8 = "off",
    cwd: []const u8 = "",
    git_branch: []const u8 = "",
    git_branch_buf: [96]u8 = undefined,
    git_branch_len: usize = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    context_tokens: u64 = 0,
    context_window: u32 = 0,
    queued_count: usize = 0,
    steering_count: usize = 0,
    bg_running_count: usize = 0,
    expanded: bool = false,

    pub fn branch(self: *const FooterInfo) []const u8 {
        if (self.git_branch.len > 0) return self.git_branch;
        return self.git_branch_buf[0..self.git_branch_len];
    }

    pub fn setGitBranch(self: *FooterInfo, name: []const u8) void {
        const take = @min(name.len, self.git_branch_buf.len);
        @memcpy(self.git_branch_buf[0..take], name[0..take]);
        self.git_branch_len = take;
    }
};

pub fn detectGitBranch(io: std.Io, cwd: []const u8, out_buf: []u8) usize {
    if (cwd.len == 0 or out_buf.len == 0) return 0;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var head_buf: [512]u8 = undefined;
    var cur: []const u8 = cwd;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const dot_git = std.fmt.bufPrint(&path_buf, "{s}/.git", .{cur}) catch break;
        const st = std.Io.Dir.cwd().statFile(io, dot_git, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                cur = std.fs.path.dirname(cur) orelse break;
                if (cur.len == 0) break;
                continue;
            },
            else => break,
        };
        var head_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const head_path: []const u8 = if (st.kind == .directory)
            (std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{dot_git}) catch break)
        else if (st.kind == .file) blk: {
            const f = std.Io.Dir.cwd().openFile(io, dot_git, .{}) catch break;
            defer f.close(io);
            const n = f.readPositionalAll(io, &head_buf, 0) catch break;
            const line = std.mem.trim(u8, head_buf[0..n], " \t\r\n");
            if (!std.mem.startsWith(u8, line, "gitdir:")) break;
            const raw_gd = std.mem.trim(u8, line["gitdir:".len..], " \t");
            if (raw_gd.len == 0) break;
            if (std.fs.path.isAbsolute(raw_gd)) {
                break :blk std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{raw_gd}) catch break;
            }
            break :blk std.fmt.bufPrint(&head_path_buf, "{s}/{s}/HEAD", .{ cur, raw_gd }) catch break;
        } else break;

        const hf = std.Io.Dir.cwd().openFile(io, head_path, .{}) catch break;
        defer hf.close(io);
        const hn = hf.readPositionalAll(io, &head_buf, 0) catch break;
        const trimmed = std.mem.trim(u8, head_buf[0..hn], " \t\r\n");
        const parsed: []const u8 = if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/"))
            trimmed["ref: refs/heads/".len..]
        else if (std.mem.startsWith(u8, trimmed, "ref: "))
            trimmed["ref: ".len..]
        else if (trimmed.len >= 7)
            trimmed[0..7]
        else
            trimmed;
        if (parsed.len == 0) return 0;
        var take = @min(parsed.len, out_buf.len);
        while (take > 0 and take < parsed.len and (parsed[take] & 0xc0) == 0x80) : (take -= 1) {}
        @memcpy(out_buf[0..take], parsed[0..take]);
        return take;
    }
    return 0;
}

fn formatTokensBuf(buf: []u8, count: u64) []const u8 {
    if (count < 1000) return std.fmt.bufPrint(buf, "{d}", .{count}) catch "";
    if (count < 10000) {
        const tenths = (count % 1000) / 100;
        if (tenths == 0) return std.fmt.bufPrint(buf, "{d}k", .{count / 1000}) catch "";
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ count / 1000, tenths }) catch "";
    }
    if (count < 1_000_000) return std.fmt.bufPrint(buf, "{d}k", .{count / 1000}) catch "";
    const tenths = (count % 1_000_000) / 100_000;
    if (tenths == 0) return std.fmt.bufPrint(buf, "{d}M", .{count / 1_000_000}) catch "";
    return std.fmt.bufPrint(buf, "{d}.{d}M", .{ count / 1_000_000, tenths }) catch "";
}

pub const Footer = struct {
    pub fn renderLinesAlloc(allocator: std.mem.Allocator, th: theme.Theme, info: FooterInfo, max_cols: usize) ![2][]u8 {
        const line1 = try renderTopLineAlloc(allocator, th, info, max_cols);
        errdefer allocator.free(line1);
        const line2 = try renderBottomLineAlloc(allocator, th, info, max_cols);
        return .{ line1, line2 };
    }

    pub fn renderLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, info: FooterInfo, max_cols: usize) ![]u8 {
        const lines = try renderLinesAlloc(allocator, th, info, max_cols);
        defer {
            allocator.free(lines[0]);
            allocator.free(lines[1]);
        }
        return try std.fmt.allocPrint(allocator, "{s}\r\n{s}", .{ lines[0], lines[1] });
    }

    fn renderTopLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, info: FooterInfo, max_cols: usize) ![]u8 {
        var left: std.ArrayList(u8) = .empty;
        defer left.deinit(allocator);
        if (info.cwd.len > 0) {
            try th.appendOpen(&left, allocator, theme.Theme.muted);
            _ = try terminal.appendClippedText(&left, allocator, shortenCwd(info.cwd), 36);
            const br = info.branch();
            if (br.len > 0) {
                try left.appendSlice(allocator, " (");
                _ = try terminal.appendClippedText(&left, allocator, br, 28);
                try left.append(allocator, ')');
            }
            try th.appendClose(&left, allocator);
        }

        var right: std.ArrayList(u8) = .empty;
        defer right.deinit(allocator);
        var has_badge = false;
        if (info.queued_count > 0) {
            try th.appendOpen(&right, allocator, theme.Theme.accent);
            try right.print(allocator, "{d} queued", .{info.queued_count});
            try th.appendClose(&right, allocator);
            has_badge = true;
        }
        if (info.steering_count > 0) {
            if (has_badge) try th.paint(&right, allocator, theme.Theme.muted, " · ");
            try th.appendOpen(&right, allocator, theme.Theme.warn);
            try right.print(allocator, "{d} steer", .{info.steering_count});
            try th.appendClose(&right, allocator);
            has_badge = true;
        }
        if (info.bg_running_count > 0) {
            if (has_badge) try th.paint(&right, allocator, theme.Theme.muted, " · ");
            try th.appendOpen(&right, allocator, theme.Theme.accent);
            try right.print(allocator, "{d} bg", .{info.bg_running_count});
            try th.appendClose(&right, allocator);
            has_badge = true;
        }
        if (info.expanded) {
            if (has_badge) try th.paint(&right, allocator, theme.Theme.muted, " · ");
            try th.paint(&right, allocator, theme.Theme.muted, "expanded");
        }

        return try joinAlignedLineAlloc(allocator, th, left.items, right.items, max_cols);
    }

    fn renderBottomLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, info: FooterInfo, max_cols: usize) ![]u8 {
        var left: std.ArrayList(u8) = .empty;
        defer left.deinit(allocator);
        var has_left = false;
        if (info.input_tokens > 0 or info.output_tokens > 0) {
            var in_buf: [24]u8 = undefined;
            var out_buf: [24]u8 = undefined;
            try th.appendOpen(&left, allocator, theme.Theme.muted);
            try left.print(allocator, "↑{s} ↓{s}", .{
                formatTokensBuf(&in_buf, info.input_tokens),
                formatTokensBuf(&out_buf, info.output_tokens),
            });
            try th.appendClose(&left, allocator);
            has_left = true;
        }
        if (info.context_window > 0) {
            var used_buf: [24]u8 = undefined;
            var win_buf: [24]u8 = undefined;
            const pct = @min(@as(u64, 100), (info.context_tokens *| 100) / info.context_window);
            if (has_left) try th.paint(&left, allocator, theme.Theme.muted, " · ");
            const role = if (pct >= 90) theme.Theme.tool_err else if (pct >= 70) theme.Theme.warn else theme.Theme.muted;
            try th.appendOpen(&left, allocator, role);
            try left.print(allocator, "{s}/{s} ({d}%)", .{
                formatTokensBuf(&used_buf, info.context_tokens),
                formatTokensBuf(&win_buf, info.context_window),
                pct,
            });
            try th.appendClose(&left, allocator);
            has_left = true;
        } else if (info.context_tokens > 0) {
            var used_buf: [24]u8 = undefined;
            if (has_left) try th.paint(&left, allocator, theme.Theme.muted, " · ");
            try th.appendOpen(&left, allocator, theme.Theme.muted);
            try left.print(allocator, "~{s} tok", .{formatTokensBuf(&used_buf, info.context_tokens)});
            try th.appendClose(&left, allocator);
            has_left = true;
        }

        var right: std.ArrayList(u8) = .empty;
        defer right.deinit(allocator);
        if (info.provider.len > 0 or info.model.len > 0) {
            try th.appendOpen(&right, allocator, theme.Theme.muted);
            if (info.provider.len > 0 and info.model.len > 0) {
                _ = try terminal.appendClippedText(&right, allocator, info.provider, 24);
                try right.append(allocator, '/');
                _ = try terminal.appendClippedText(&right, allocator, info.model, 32);
            } else {
                _ = try terminal.appendClippedText(&right, allocator, info.model, 32);
            }
            if (info.thinking_level.len > 0 and !std.mem.eql(u8, info.thinking_level, "off")) {
                try right.appendSlice(allocator, " (");
                _ = try terminal.appendClippedText(&right, allocator, info.thinking_level, 12);
                try right.append(allocator, ')');
            }
            try th.appendClose(&right, allocator);
        }

        return try joinAlignedLineAlloc(allocator, th, left.items, right.items, max_cols);
    }

    fn joinAlignedLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, left: []const u8, right: []const u8, max_cols: usize) ![]u8 {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(allocator);
        const lw = terminal.visibleWidth(left);
        const rw = terminal.visibleWidth(right);
        if (lw > 0 and rw > 0) {
            if (lw + 2 + rw <= max_cols) {
                try raw.appendSlice(allocator, left);
                try raw.appendNTimes(allocator, ' ', max_cols - lw - rw);
                try raw.appendSlice(allocator, right);
            } else {
                try raw.appendSlice(allocator, left);
                try th.paint(&raw, allocator, theme.Theme.muted, " · ");
                try raw.appendSlice(allocator, right);
            }
        } else if (lw > 0) {
            try raw.appendSlice(allocator, left);
        } else if (rw > 0) {
            try raw.appendSlice(allocator, right);
        }

        var clipped: std.ArrayList(u8) = .empty;
        errdefer clipped.deinit(allocator);
        _ = try terminal.appendTruncatedAnsi(&clipped, allocator, raw.items, max_cols, "...");
        return try clipped.toOwnedSlice(allocator);
    }
};

fn shortenCwd(cwd: []const u8) []const u8 {
    if (cwd.len <= 24) return cwd;
    if (std.mem.lastIndexOfScalar(u8, cwd, '/')) |last| {
        if (last > 0) {
            if (std.mem.lastIndexOfScalar(u8, cwd[0..last], '/')) |prev| {
                return cwd[prev + 1 ..];
            }
        }
    }
    return cwd;
}

test "Loader and Footer clip to width and format model, thinking, git branch, usage, and context" {
    const a = std.testing.allocator;
    const th = theme.Theme.init(.ansi16);

    var loader = Loader{};
    loader.setPhase(.tool, "bash");
    loader.tick(400);
    const l_line = try loader.renderLineAlloc(a, th, 40);
    defer a.free(l_line);
    try std.testing.expect(std.mem.indexOf(u8, l_line, "Running bash...") != null);
    try std.testing.expect(std.mem.indexOf(u8, l_line, "0.4s") != null);
    try std.testing.expect(terminal.visibleWidth(l_line) <= 40);

    const lines = try Footer.renderLinesAlloc(a, th, .{
        .provider = "openai",
        .model = "gpt-5",
        .thinking_level = "high",
        .cwd = "/Users/dev/workspace/zpi",
        .git_branch = "feat/tui",
        .input_tokens = 1500,
        .output_tokens = 420,
        .context_tokens = 25000,
        .context_window = 100000,
        .queued_count = 2,
        .bg_running_count = 1,
        .expanded = true,
    }, 80);
    defer {
        a.free(lines[0]);
        a.free(lines[1]);
    }
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "workspace/zpi (feat/tui)") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "2 queued") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "1 bg") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "expanded") != null);
    try std.testing.expect(terminal.visibleWidth(lines[0]) <= 80);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "↑1.5k ↓420") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "25k/100k (25%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "openai/gpt-5 (high)") != null);
    try std.testing.expect(terminal.visibleWidth(lines[1]) <= 80);

    const f_narrow = try Footer.renderLinesAlloc(a, th, .{
        .provider = "openai",
        .model = "gpt-5",
        .cwd = "/Users/dev/workspace/zpi",
        .git_branch = "main",
    }, 18);
    defer {
        a.free(f_narrow[0]);
        a.free(f_narrow[1]);
    }
    try std.testing.expect(terminal.visibleWidth(f_narrow[0]) <= 18);
    try std.testing.expect(terminal.visibleWidth(f_narrow[1]) <= 18);

    const f_warn = try Footer.renderLinesAlloc(a, theme.Theme.init(.truecolor), .{
        .provider = "openai",
        .model = "gpt-5",
        .context_tokens = 75000,
        .context_window = 100000,
    }, 80);
    defer {
        a.free(f_warn[0]);
        a.free(f_warn[1]);
    }
    try std.testing.expect(std.mem.indexOf(u8, f_warn[1], "\x1b[38;2;229;192;123m75k/100k (75%)\x1b[0m") != null);

    const f_crit = try Footer.renderLinesAlloc(a, theme.Theme.init(.truecolor), .{
        .provider = "openai",
        .model = "gpt-5",
        .context_tokens = 95000,
        .context_window = 100000,
    }, 80);
    defer {
        a.free(f_crit[0]);
        a.free(f_crit[1]);
    }
    try std.testing.expect(std.mem.indexOf(u8, f_crit[1], "\x1b[38;2;224;108;117m95k/100k (95%)\x1b[0m") != null);

    // Hermetic Git branch detection works inside parent directories without depending on repo .git.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/nested/sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/feat/hermetic-branch\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const nested = try std.fs.path.resolveAlloc(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo/nested/sub" });
    defer a.free(nested);
    var br_buf: [96]u8 = undefined;
    const blen = detectGitBranch(std.testing.io, nested, &br_buf);
    try std.testing.expectEqualStrings("feat/hermetic-branch", br_buf[0..blen]);
}
