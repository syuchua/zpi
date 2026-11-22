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
    context_tokens: u64 = 0,
    context_window: u32 = 0,
    queued_count: usize = 0,
    expanded: bool = false,
};

pub const Footer = struct {
    pub fn renderLineAlloc(allocator: std.mem.Allocator, th: theme.Theme, info: FooterInfo, max_cols: usize) ![]u8 {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(allocator);

        try th.appendOpen(&raw, allocator, theme.Theme.muted);
        if (info.provider.len > 0 and info.model.len > 0) {
            _ = try terminal.appendClippedText(&raw, allocator, info.provider, 24);
            try raw.append(allocator, '/');
            _ = try terminal.appendClippedText(&raw, allocator, info.model, 32);
        } else if (info.model.len > 0) {
            _ = try terminal.appendClippedText(&raw, allocator, info.model, 32);
        }
        if (info.thinking_level.len > 0 and !std.mem.eql(u8, info.thinking_level, "off")) {
            try raw.appendSlice(allocator, " (");
            _ = try terminal.appendClippedText(&raw, allocator, info.thinking_level, 12);
            try raw.append(allocator, ')');
        }
        if (info.context_window > 0) {
            const pct = @min(@as(u64, 100), (info.context_tokens *| 100) / info.context_window);
            if (pct >= 90) {
                try th.appendClose(&raw, allocator);
                try th.appendOpen(&raw, allocator, theme.Theme.tool_err);
                try raw.print(allocator, " · {d}% ctx", .{pct});
                try th.appendClose(&raw, allocator);
                try th.appendOpen(&raw, allocator, theme.Theme.muted);
            } else if (pct >= 70) {
                try th.appendClose(&raw, allocator);
                try th.appendOpen(&raw, allocator, theme.Theme.warn);
                try raw.print(allocator, " · {d}% ctx", .{pct});
                try th.appendClose(&raw, allocator);
                try th.appendOpen(&raw, allocator, theme.Theme.muted);
            } else {
                try raw.print(allocator, " · {d}% ctx", .{pct});
            }
        } else if (info.context_tokens > 0) {
            try raw.print(allocator, " · ~{d} tok", .{info.context_tokens});
        }
        if (info.queued_count > 0) {
            try raw.print(allocator, " · {d} queued", .{info.queued_count});
        }
        if (info.expanded) {
            try raw.appendSlice(allocator, " · expanded");
        }
        if (info.cwd.len > 0) {
            try raw.appendSlice(allocator, " · ");
            const short_cwd = shortenCwd(info.cwd);
            _ = try terminal.appendClippedText(&raw, allocator, short_cwd, 32);
        }
        try th.appendClose(&raw, allocator);

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

test "Loader and Footer clip to width and format model, thinking, context, and queue" {
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

    const f_line = try Footer.renderLineAlloc(a, th, .{
        .provider = "openai",
        .model = "gpt-5",
        .thinking_level = "high",
        .cwd = "/Users/dev/workspace/zpi",
        .context_tokens = 25000,
        .context_window = 100000,
        .queued_count = 2,
        .expanded = true,
    }, 80);
    defer a.free(f_line);
    try std.testing.expect(std.mem.indexOf(u8, f_line, "openai/gpt-5 (high)") != null);
    try std.testing.expect(std.mem.indexOf(u8, f_line, "25% ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, f_line, "2 queued") != null);
    try std.testing.expect(std.mem.indexOf(u8, f_line, "expanded") != null);
    try std.testing.expect(terminal.visibleWidth(f_line) <= 80);

    const f_narrow = try Footer.renderLineAlloc(a, th, .{
        .provider = "openai",
        .model = "gpt-5",
        .cwd = "/Users/dev/workspace/zpi",
    }, 18);
    defer a.free(f_narrow);
    try std.testing.expect(terminal.visibleWidth(f_narrow) <= 18);

    const f_warn = try Footer.renderLineAlloc(a, theme.Theme.init(.truecolor), .{
        .provider = "openai",
        .model = "gpt-5",
        .context_tokens = 75000,
        .context_window = 100000,
    }, 80);
    defer a.free(f_warn);
    try std.testing.expect(std.mem.indexOf(u8, f_warn, "\x1b[38;2;229;192;123m · 75% ctx\x1b[0m") != null);

    const f_crit = try Footer.renderLineAlloc(a, theme.Theme.init(.truecolor), .{
        .provider = "openai",
        .model = "gpt-5",
        .context_tokens = 95000,
        .context_window = 100000,
    }, 80);
    defer a.free(f_crit);
    try std.testing.expect(std.mem.indexOf(u8, f_crit, "\x1b[38;2;224;108;117m · 95% ctx\x1b[0m") != null);
}
