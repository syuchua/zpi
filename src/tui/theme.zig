//! Terminal color capability detection and semantic palette roles.
//! Respects `NO_COLOR`, `TERM=dumb`, `COLORTERM`, and 256-color terminal hints.
const std = @import("std");

pub const ColorMode = enum {
    none,
    ansi16,
    ansi256,
    truecolor,
};

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const ColorSpec = struct {
    ansi16_fg: u8,
    ansi16_bg: u8 = 49,
    ansi256: u8,
    rgb: Rgb,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    reverse: bool = false,
    background: bool = false,
};

pub const Theme = struct {
    mode: ColorMode = .ansi16,

    pub const accent = ColorSpec{ .ansi16_fg = 36, .ansi256 = 81, .rgb = .{ .r = 103, .g = 212, .b = 242 } };
    pub const muted = ColorSpec{ .ansi16_fg = 90, .ansi256 = 245, .rgb = .{ .r = 148, .g = 154, .b = 166 }, .dim = true };
    pub const border = ColorSpec{ .ansi16_fg = 90, .ansi256 = 240, .rgb = .{ .r = 88, .g = 96, .b = 110 }, .dim = true };
    pub const user_badge = ColorSpec{ .ansi16_fg = 36, .ansi256 = 117, .rgb = .{ .r = 132, .g = 204, .b = 248 }, .bold = true };
    pub const user_panel = ColorSpec{ .ansi16_fg = 39, .ansi16_bg = 44, .ansi256 = 24, .rgb = .{ .r = 25, .g = 43, .b = 61 }, .background = true };
    pub const thinking = ColorSpec{ .ansi16_fg = 90, .ansi256 = 246, .rgb = .{ .r = 156, .g = 163, .b = 175 }, .dim = true, .italic = true };
    pub const tool_header = ColorSpec{ .ansi16_fg = 33, .ansi256 = 180, .rgb = .{ .r = 229, .g = 192, .b = 123 }, .bold = true };
    pub const warn = ColorSpec{ .ansi16_fg = 33, .ansi256 = 214, .rgb = .{ .r = 229, .g = 192, .b = 123 } };
    pub const tool_ok = ColorSpec{ .ansi16_fg = 32, .ansi256 = 114, .rgb = .{ .r = 152, .g = 195, .b = 121 } };
    pub const tool_err = ColorSpec{ .ansi16_fg = 31, .ansi256 = 203, .rgb = .{ .r = 224, .g = 108, .b = 117 } };
    pub const diff_add = ColorSpec{ .ansi16_fg = 32, .ansi256 = 114, .rgb = .{ .r = 152, .g = 195, .b = 121 } };
    pub const diff_del = ColorSpec{ .ansi16_fg = 31, .ansi256 = 203, .rgb = .{ .r = 224, .g = 108, .b = 117 } };
    pub const diff_hunk = ColorSpec{ .ansi16_fg = 36, .ansi256 = 75, .rgb = .{ .r = 97, .g = 175, .b = 239 } };
    pub const md_heading = ColorSpec{ .ansi16_fg = 36, .ansi256 = 81, .rgb = .{ .r = 103, .g = 212, .b = 242 }, .bold = true };
    pub const md_code = ColorSpec{ .ansi16_fg = 33, .ansi256 = 180, .rgb = .{ .r = 229, .g = 192, .b = 123 } };
    pub const md_quote = ColorSpec{ .ansi16_fg = 90, .ansi256 = 245, .rgb = .{ .r = 148, .g = 154, .b = 166 }, .italic = true };
    pub const selection = ColorSpec{ .ansi16_fg = 39, .ansi256 = 255, .rgb = .{ .r = 255, .g = 255, .b = 255 }, .reverse = true };
    pub const bold_only = ColorSpec{ .ansi16_fg = 39, .ansi256 = 255, .rgb = .{ .r = 255, .g = 255, .b = 255 }, .bold = true };

    pub fn init(mode: ColorMode) Theme {
        return .{ .mode = mode };
    }

    pub fn detect(environ: ?*const std.process.Environ.Map, supports_ansi: bool) ColorMode {
        if (!supports_ansi) return .none;
        if (environ) |env| {
            if (env.get("NO_COLOR")) |no_color| {
                if (no_color.len > 0) return .none;
            }
            if (env.get("TERM")) |term| {
                if (std.mem.eql(u8, term, "dumb")) return .none;
                if (std.mem.indexOf(u8, term, "256color") != null) {
                    if (env.get("COLORTERM")) |ct| {
                        if (std.mem.indexOf(u8, ct, "truecolor") != null or std.mem.indexOf(u8, ct, "24bit") != null) {
                            return .truecolor;
                        }
                    }
                    return .ansi256;
                }
            }
            if (env.get("COLORTERM")) |ct| {
                if (std.mem.indexOf(u8, ct, "truecolor") != null or std.mem.indexOf(u8, ct, "24bit") != null) {
                    return .truecolor;
                }
            }
        }
        return .ansi16;
    }

    pub fn appendOpen(self: Theme, out: *std.ArrayList(u8), a: std.mem.Allocator, spec: ColorSpec) !void {
        if (self.mode == .none) return;
        try out.appendSlice(a, "\x1b[");
        var first = true;
        if (spec.reverse) {
            try out.append(a, '7');
            first = false;
        }
        if (spec.bold) {
            if (!first) try out.append(a, ';');
            try out.append(a, '1');
            first = false;
        }
        if (spec.dim) {
            if (!first) try out.append(a, ';');
            try out.append(a, '2');
            first = false;
        }
        if (spec.italic) {
            if (!first) try out.append(a, ';');
            try out.append(a, '3');
            first = false;
        }
        if (spec.ansi16_fg != 39) {
            if (!first) try out.append(a, ';');
            switch (self.mode) {
                .none => unreachable,
                .ansi16 => try out.print(a, "{d}", .{spec.ansi16_fg}),
                .ansi256 => try out.print(a, "38;5;{d}", .{spec.ansi256}),
                .truecolor => try out.print(a, "38;2;{d};{d};{d}", .{ spec.rgb.r, spec.rgb.g, spec.rgb.b }),
            }
            first = false;
        }
        if (spec.background) {
            if (!first) try out.append(a, ';');
            switch (self.mode) {
                .none => unreachable,
                .ansi16 => try out.print(a, "{d}", .{if (spec.ansi16_bg < 10) spec.ansi16_bg + 40 else spec.ansi16_bg}),
                .ansi256 => try out.print(a, "48;5;{d}", .{spec.ansi256}),
                .truecolor => try out.print(a, "48;2;{d};{d};{d}", .{ spec.rgb.r, spec.rgb.g, spec.rgb.b }),
            }
        }
        try out.append(a, 'm');
    }

    pub fn appendClose(self: Theme, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        if (self.mode == .none) return;
        try out.appendSlice(a, "\x1b[0m");
    }

    pub fn paint(self: Theme, out: *std.ArrayList(u8), a: std.mem.Allocator, spec: ColorSpec, text: []const u8) !void {
        if (text.len == 0) return;
        try self.appendOpen(out, a, spec);
        try out.appendSlice(a, text);
        try self.appendClose(out, a);
    }
};

test "Theme.detect respects NO_COLOR, TERM=dumb, 256color, and truecolor" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    try std.testing.expectEqual(ColorMode.none, Theme.detect(&env, false));
    try std.testing.expectEqual(ColorMode.ansi16, Theme.detect(&env, true));

    try env.put("TERM", "xterm-256color");
    try std.testing.expectEqual(ColorMode.ansi256, Theme.detect(&env, true));

    try env.put("COLORTERM", "truecolor");
    try std.testing.expectEqual(ColorMode.truecolor, Theme.detect(&env, true));

    try env.put("NO_COLOR", "1");
    try std.testing.expectEqual(ColorMode.none, Theme.detect(&env, true));

    try env.put("NO_COLOR", "");
    try env.put("TERM", "dumb");
    try std.testing.expectEqual(ColorMode.none, Theme.detect(&env, true));
}

test "Theme.paint emits expected SGR across color modes" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try Theme.init(.none).paint(&out, a, Theme.accent, "ok");
    try std.testing.expectEqualStrings("ok", out.items);

    out.clearRetainingCapacity();
    try Theme.init(.ansi16).paint(&out, a, Theme.accent, "ok");
    try std.testing.expectEqualStrings("\x1b[36mok\x1b[0m", out.items);

    out.clearRetainingCapacity();
    try Theme.init(.ansi256).paint(&out, a, Theme.accent, "ok");
    try std.testing.expectEqualStrings("\x1b[38;5;81mok\x1b[0m", out.items);

    out.clearRetainingCapacity();
    try Theme.init(.truecolor).paint(&out, a, Theme.accent, "ok");
    try std.testing.expectEqualStrings("\x1b[38;2;103;212;242mok\x1b[0m", out.items);
}
