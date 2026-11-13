//! Balanced rows of aspect-preserving previews. Short rows are centred and
//! extra windows go in the bottom rows: four is 2+2, five is 2+3.
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

pub const Placement = struct { frame: Rect, label: Rect };

pub fn place(count: usize, index: usize, bounds: Rect, width: f64, height: f64, label_height: f64) Placement {
    if (count == 0 or index >= count or bounds.width <= 0 or bounds.height <= 0 or width <= 0 or height <= 0)
        return .{ .frame = .{}, .label = .{} };
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
    const padding = @min(40, @min(bounds.width, bounds.height) * 0.05);
    const available_w = bounds.width - padding * 2;
    const available_h = bounds.height - padding * 2;
    const cols: f64 = @floatFromInt(columns);
    const lines: f64 = @floatFromInt(rows);
    const gap = @min(24, @min(available_w / (cols * 4), available_h / (lines * 4)));
    const cell_w = (available_w - gap * (cols - 1)) / cols;
    const cell_h = (available_h - gap * (lines - 1)) / lines;
    const caption = @min(label_height, cell_h / 4);
    const caption_gap = @min(8, cell_h / 10);
    const preview_h = cell_h - caption - caption_gap;
    const x = bounds.x + padding + (available_w - (@as(f64, @floatFromInt(items)) * (cell_w + gap) - gap)) / 2 + @as(f64, @floatFromInt(column)) * (cell_w + gap);
    const y = bounds.y + padding + @as(f64, @floatFromInt(row)) * (cell_h + gap);
    const scale = @min(1, @min(cell_w / width, preview_h / height));
    const w = width * scale;
    const h = height * scale;
    return .{
        .frame = .{ .x = x + (cell_w - w) / 2, .y = y + (preview_h - h) / 2, .width = w, .height = h },
        .label = .{ .x = x, .y = y + preview_h + caption_gap, .width = cell_w, .height = caption },
    };
}

test {
    _ = @import("overview_layout_tests.zig");
}
