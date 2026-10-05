const std = @import("std");
pub const width = 96;
pub const height = 112; // 8 + 56 + 8 + 2*16 + 8: two readable label lines.
pub const margin = 24;
pub const Cell = struct { col: i32 = 0, row: i32 = 0 };
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32 = width,
    h: i32 = height,
    pub fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= @as(f64, @floatFromInt(r.x)) and y >= @as(f64, @floatFromInt(r.y)) and x < @as(f64, @floatFromInt(r.x + r.w)) and y < @as(f64, @floatFromInt(r.y + r.h));
    }
    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
    }
};
pub const Grid = struct {
    w: i32,
    h: i32,
    bottom: i32 = 64,
    top: i32 = 0,
    pub fn rows(g: Grid) i32 {
        return @max(1, @divFloor(g.h - margin - g.top - g.bottom, height));
    }
    pub fn cols(g: Grid) i32 {
        return @max(1, @divFloor(g.w - 2 * margin, width));
    }
    pub fn rect(g: Grid, position: Cell) Rect {
        return .{ .x = g.w - margin - (position.col + 1) * width, .y = g.top + margin + position.row * height };
    }
    pub fn snap(g: Grid, x: f64, y: f64) Cell {
        return .{ .col = std.math.clamp(@as(i32, @intFromFloat(@floor((@as(f64, @floatFromInt(g.w - margin)) - x) / width))), 0, g.cols() - 1), .row = std.math.clamp(@as(i32, @intFromFloat(@floor((y - @as(f64, @floatFromInt(g.top + margin))) / height))), 0, g.rows() - 1) };
    }
    pub fn cell(g: Grid, index: usize) Cell {
        const n: i32 = @intCast(index);
        return .{ .col = @divFloor(n, g.rows()), .row = @mod(n, g.rows()) };
    }
};
test "grid flows down then left and avoids the panel" {
    const g = Grid{ .w = 1280, .h = 720 };
    try std.testing.expectEqual(Cell{ .col = 1, .row = 0 }, g.cell(@intCast(g.rows())));
    const r = g.rect(.{ .row = g.rows() - 1 });
    try std.testing.expect(r.y + r.h <= 720 - 64);
    try std.testing.expectEqual(Cell{}, g.snap(1240, 40));
    const top = Grid{ .w = 1280, .h = 720, .top = 64, .bottom = 0 };
    try std.testing.expectEqual(g.rows(), top.rows());
    const first = top.rect(.{});
    try std.testing.expect(first.y >= 64);
    try std.testing.expectEqual(Cell{}, top.snap(@floatFromInt(first.x + 10), @floatFromInt(first.y + 10)));
    try std.testing.expect(top.rect(.{ .row = top.rows() - 1 }).y + height <= top.h);
}
