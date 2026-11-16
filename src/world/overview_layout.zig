//! Balanced rows of aspect-preserving previews. Short rows are centred and
//! extra windows go in the bottom rows: four is 2+2, five is 2+3. Margins and
//! gaps are kept small so the previews fill as much of the output as they can.
const std = @import("std");

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn contains(self: Rect, x: f64, y: f64) bool {
        return x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
};

pub fn place(count: usize, index: usize, bounds: Rect, width: f64, height: f64) Rect {
    if (count == 0 or index >= count or bounds.width <= 0 or bounds.height <= 0 or width <= 0 or height <= 0)
        return .{};
    const columns: usize = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(count)))));
    const rows = std.math.divCeil(usize, count, columns) catch unreachable;
    const short = count / rows;
    const long_rows = count % rows;
    var row: usize = 0;
    var column = index;
    while (row + 1 < rows) : (row += 1) {
        const items = short + @intFromBool(row >= rows - long_rows);
        if (column < items) break;
        column -= items;
    }
    const items = short + @intFromBool(row >= rows - long_rows);
    const padding = @min(16, @min(bounds.width, bounds.height) * 0.02);
    const available_w = bounds.width - padding * 2;
    const available_h = bounds.height - padding * 2;
    const cols: f64 = @floatFromInt(columns);
    const lines: f64 = @floatFromInt(rows);
    const gap = @min(12, @min(available_w / (cols * 8), available_h / (lines * 8)));
    const cell_w = (available_w - gap * (cols - 1)) / cols;
    const cell_h = (available_h - gap * (lines - 1)) / lines;
    const x = bounds.x + padding + (available_w - (@as(f64, @floatFromInt(items)) * (cell_w + gap) - gap)) / 2 + @as(f64, @floatFromInt(column)) * (cell_w + gap);
    const y = bounds.y + padding + @as(f64, @floatFromInt(row)) * (cell_h + gap);
    const scale = @min(1, @min(cell_w / width, cell_h / height));
    const w = width * scale;
    const h = height * scale;
    return .{ .x = x + (cell_w - w) / 2, .y = y + (cell_h - h) / 2, .width = w, .height = h };
}

test {
    _ = @import("overview_layout_tests.zig");
}
