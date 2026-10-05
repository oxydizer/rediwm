// Coordinates within one space and logical-to-device raster sizes.
// Use World.toWorld/toLayout when crossing the desktop camera transform.

pub const Vec2 = struct {
    x: f64,
    y: f64,

    /// Truncates toward zero, matching `@intFromFloat` on the cursor-grab path.
    pub fn toI32(self: Vec2) struct { x: i32, y: i32 } {
        return .{
            .x = @intFromFloat(self.x),
            .y = @intFromFloat(self.y),
        };
    }
};

/// Layout/scene point relative to an integer origin (frame, taskbar, …).
pub fn toLocal(lx: f64, ly: f64, origin_x: i32, origin_y: i32) Vec2 {
    return .{
        .x = lx - @as(f64, @floatFromInt(origin_x)),
        .y = ly - @as(f64, @floatFromInt(origin_y)),
    };
}

/// Logical pixels to device pixels, never rounding down to nothing.
pub fn devicePixels(logical: i32, scale: f32) i32 {
    const pixels: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * scale));
    return @max(pixels, 1);
}
