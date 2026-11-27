//! Xterm SGR mouse reports used by the fullscreen UI.
const std = @import("std");

pub const enable = "\x1b[?1006h\x1b[?1002h";
pub const disable = "\x1b[?1002l\x1b[?1006l";

pub const Kind = enum { left, left_motion, left_release, wheel_up, wheel_down, ignored };

pub const Event = struct {
    row: usize,
    col: usize,
    kind: Kind,

    pub fn parse(final: u8, params: []const u8) ?Event {
        if ((final != 'M' and final != 'm') or params.len == 0 or params[0] != '<') return null;
        var fields = std.mem.splitScalar(u8, params[1..], ';');
        const code = decimal(u8, fields.next() orelse return null) orelse return null;
        const col = decimal(u16, fields.next() orelse return null) orelse return null;
        const row = decimal(u16, fields.next() orelse return null) orelse return null;
        if (fields.next() != null or row == 0 or col == 0) return null;
        const kind: Kind = if (final == 'm' and (code == 0 or code == 3))
            .left_release
        else if (final == 'M') switch (code) {
            0 => .left,
            32 => .left_motion,
            64 => .wheel_up,
            65 => .wheel_down,
            else => .ignored,
        } else .ignored;
        return .{ .row = row, .col = col, .kind = kind };
    }
};

fn decimal(comptime T: type, field: []const u8) ?T {
    if (field.len == 0) return null;
    for (field) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(T, field, 10) catch null;
}

test "SGR reports identify presses, releases and wheel directions" {
    const click = Event.parse('M', "<0;8;15").?;
    try std.testing.expectEqual(@as(usize, 15), click.row);
    try std.testing.expectEqual(@as(usize, 8), click.col);
    try std.testing.expect(click.kind == .left);
    try std.testing.expect(Event.parse('m', "<0;8;15").?.kind == .left_release);
    try std.testing.expect(Event.parse('m', "<3;8;15").?.kind == .left_release);
    try std.testing.expect(Event.parse('m', "<1;8;15").?.kind == .ignored);
    try std.testing.expect(Event.parse('M', "<32;8;15").?.kind == .left_motion);
    try std.testing.expect(Event.parse('M', "<64;1;1").?.kind == .wheel_up);
    try std.testing.expect(Event.parse('M', "<65;1;1").?.kind == .wheel_down);
    for ([_][]const u8{ "5", "<0;0;1", "<0;1;65536", "<0;1;1;2", "<0;+1;1" }) |bad| {
        try std.testing.expect(Event.parse('M', bad) == null);
    }
}
