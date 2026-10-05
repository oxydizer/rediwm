//! Retained menu geometry uses the same measure/arrange passes as shell chrome.
const ui = @import("ui").layout;
const appearance = @import("ui").context_menu;
pub const Menu = struct {
    root: ui.Widget = .{ .kind = .container, .direction = .column },
    rows: [8]ui.Widget = undefined,
    count: usize = 0,
    pub fn separatorBefore(icon: bool, row: usize) bool {
        return if (icon) row == 2 or row == 6 else row == 4 or row == 6;
    }
    pub fn height(count: usize, icon: bool) i32 {
        var result: i32 = @intCast(count * appearance.row_height + 2 * appearance.padding);
        for (0..count) |i| {
            if (separatorBefore(icon, i)) result += appearance.separator_space;
        }
        return result;
    }
    pub fn layout(self: *Menu, x: i32, y: i32, count: usize, icon: bool) void {
        self.count = @min(count, self.rows.len);
        for (self.rows[0..self.count], 0..) |*row, i| row.* = .{
            .kind = .container,
            .width = .{ .percent = 1 },
            // Fixed layout sizes include the margin; keep the painted row 32px high.
            .height = .{ .fixed = appearance.row_height + @as(f32, if (separatorBefore(icon, i)) appearance.separator_space else 0) },
            .margin = .{ .top = if (separatorBefore(icon, i)) appearance.separator_space else 0 },
        };
        const h: f32 = @floatFromInt(height(self.count, icon));
        self.root.padding = ui.Edges.all(appearance.padding);
        self.root.width = .{ .fixed = appearance.width };
        self.root.height = .{ .fixed = h };
        self.root.children = self.rows[0..self.count];
        self.root.linkParents();
        @import("ui").measure.measure(&self.root, appearance.width, h);
        @import("ui").arrange.arrange(&self.root, @floatFromInt(x), @floatFromInt(y), appearance.width, h);
    }
    pub fn hit(self: *Menu, x: f64, y: f64) ?usize {
        for (self.rows[0..self.count], 0..) |*row, i| if (row.contains(@floatCast(x), @floatCast(y))) return i;
        return null;
    }
};
