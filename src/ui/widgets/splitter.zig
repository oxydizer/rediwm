//! A vertical pane divider with a wider pointer target than its painted line.
const theme = @import("../theme.zig");
pub const Rect = @import("field.zig").Rect;

pub const Geometry = struct {
    x: f64,
    y: f64,
    h: f64,

    pub fn contains(self: Geometry, x: f64, y: f64) bool {
        return @abs(x - self.x) <= 4 and y >= self.y and y < self.y + self.h;
    }

    pub fn line(self: Geometry, engaged: bool) Rect {
        const width: f32 = if (engaged) 2 else 1;
        return .{ .x = @as(f32, @floatCast(self.x)) - width, .y = @floatCast(self.y), .w = width, .h = @floatCast(self.h) };
    }
};

pub fn color(engaged: bool) [4]f32 {
    return if (engaged) theme.shellPalette().accent else theme.global.app_item_border;
}

pub const Drag = struct {
    origin: f64,
    width: i32,

    pub fn widthAt(self: Drag, x: f64, minimum: i32, maximum: i32) i32 {
        const value = @as(f64, @floatFromInt(self.width)) + x - self.origin;
        return @intFromFloat(@round(@min(@max(value, @as(f64, @floatFromInt(minimum))), @as(f64, @floatFromInt(maximum)))));
    }
};
