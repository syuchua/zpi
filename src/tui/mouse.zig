//! Xterm SGR mouse reports used by the fullscreen UI.
const std = @import("std");

pub const enable = "\x1b[?1006h\x1b[?1000h";
pub const disable = "\x1b[?1000l\x1b[?1006l";

pub const Event = struct {
    row: usize,
    col: usize,
    kind: enum { left, wheel_up, wheel_down, ignored },

    pub fn parse(final: u8, params: []const u8) ?Event {
        if ((final != 'M' and final != 'm') or params.len == 0 or params[0] != '<') return null;
        var fields = std.mem.splitScalar(u8, params[1..], ';');
        const code = decimal(u8, fields.next() orelse return null) orelse return null;
        const col = decimal(u16, fields.next() orelse return null) orelse return null;
        const row = decimal(u16, fields.next() orelse return null) orelse return null;
        if (fields.next() != null or row == 0 or col == 0) return null;
        return .{ .row = row, .col = col, .kind = if (final == 'm') .ignored else switch (code) {
            0 => .left,
            64 => .wheel_up,
            65 => .wheel_down,
            else => .ignored,
        } };
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
    try std.testing.expect(Event.parse('m', "<0;8;15").?.kind == .ignored);
    try std.testing.expect(Event.parse('M', "<64;1;1").?.kind == .wheel_up);
    try std.testing.expect(Event.parse('M', "<65;1;1").?.kind == .wheel_down);
    for ([_][]const u8{ "5", "<0;0;1", "<0;1;65536", "<0;1;1;2", "<0;+1;1" }) |bad| {
        try std.testing.expect(Event.parse('M', bad) == null);
    }
}
