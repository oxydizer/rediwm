const std = @import("std");
/// Narrowest a cell gets. Cells stretch evenly to fill the output, so the
/// icons at both edges sit the same distance from them whatever the width.
pub const width = 96;
pub const height = 112; // 8 + 56 + 8 + 2*16 + 8: two readable label lines.
/// Cells carry their own padding (8 above the icon, 20 beside it), so only a
/// little margin is needed above the first row to match the sides.
pub const top_margin = 12;
/// Width held back when counting columns. It no longer shows as a gap, but
/// the count decides where saved icon positions (counted from the right) sit.
const reserve = 32;
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
        return @max(1, @divFloor(g.h - top_margin - g.top - g.bottom, height));
    }
    pub fn cols(g: Grid) i32 {
        return @max(1, @divFloor(g.w - reserve, width));
    }
    /// Column `position.col` counts from the right edge. The columns share the
    /// whole width, so neighbouring cells differ by at most a pixel.
    pub fn rect(g: Grid, position: Cell) Rect {
        const n = g.cols();
        const from_left = n - 1 - position.col;
        const x0 = @divFloor(from_left * g.w, n);
        const x1 = @divFloor((from_left + 1) * g.w, n);
        return .{ .x = x0, .w = x1 - x0, .y = g.top + top_margin + position.row * height };
    }
    pub fn snap(g: Grid, x: f64, y: f64) Cell {
        const n = g.cols();
        const from_left: i32 = @intFromFloat(@floor(x * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(@max(1, g.w)))));
        const row: i32 = @intFromFloat(@floor((y - @as(f64, @floatFromInt(g.top + top_margin))) / height));
        return .{ .col = n - 1 - std.math.clamp(from_left, 0, n - 1), .row = std.math.clamp(row, 0, g.rows() - 1) };
    }
    pub fn cell(g: Grid, index: usize) Cell {
        const n: i32 = @intCast(index);
        return .{ .col = @divFloor(n, g.rows()), .row = @mod(n, g.rows()) };
    }
};
test "the columns fill the whole width, so both edges get the same gap" {
    var w: i32 = 1024;
    while (w <= 3840) : (w += 7) {
        const g = Grid{ .w = w, .h = 1080 };
        const left = g.rect(.{ .col = g.cols() - 1 });
        const right = g.rect(.{});
        try std.testing.expectEqual(@as(i32, 0), left.x);
        try std.testing.expectEqual(w, right.x + right.w);
        var col: i32 = 0;
        while (col < g.cols()) : (col += 1) {
            const r = g.rect(.{ .col = col });
            try std.testing.expect(r.w >= width);
            // Column col lies immediately left of column col-1: no gaps, no overlap.
            if (col > 0) try std.testing.expectEqual(g.rect(.{ .col = col - 1 }).x, r.x + r.w);
            // The 56px icon sits centred: the gap to the edge stays modest at any width.
            try std.testing.expect(@divTrunc(r.w - 56, 2) <= 28);
        }
    }
}
test "icons start close to the top-left corner" {
    const g = Grid{ .w = 1536, .h = 864 };
    const home = g.rect(.{ .col = g.cols() - 1, .row = 0 });
    try std.testing.expect(@divTrunc(home.w - 56, 2) <= 28); // left gap to the icon
    try std.testing.expect(home.y + 8 <= 24); // top gap to the icon
}
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
