const std = @import("std");
pub const Box = struct { x: i64, y: i64, width: i64, height: i64 };
pub const Point = struct { x: i64, y: i64 };

/// All arithmetic remains wide until converting to Wayland's signed coordinates.
pub fn place(anchor: Box, bounds: Box, width: i32, height: i32) Point {
    const bottom = bounds.y + bounds.height;
    const below = bottom - (anchor.y + anchor.height);
    const above = anchor.y - bounds.y;
    const y = if (below < height and above > below) anchor.y - height else anchor.y + anchor.height;
    return .{
        .x = std.math.clamp(anchor.x, bounds.x, @max(bounds.x, bounds.x + bounds.width - width)),
        .y = std.math.clamp(y, bounds.y, @max(bounds.y, bottom - height)),
    };
}

test "candidate placement below, above, clamped and oversized anchors" {
    const bounds = Box{ .x = 0, .y = 0, .width = 800, .height = 600 };
    try std.testing.expectEqual(Point{ .x = 100, .y = 120 }, place(.{ .x = 100, .y = 100, .width = 4, .height = 20 }, bounds, 200, 40));
    try std.testing.expectEqual(Point{ .x = 100, .y = 540 }, place(.{ .x = 100, .y = 580, .width = 4, .height = 20 }, bounds, 200, 40));
    try std.testing.expectEqual(Point{ .x = 600, .y = 120 }, place(.{ .x = 799, .y = 100, .width = 4, .height = 20 }, bounds, 200, 40));
    try std.testing.expectEqual(Point{ .x = 0, .y = 120 }, place(.{ .x = -30, .y = 100, .width = 4, .height = 20 }, bounds, 200, 40));
    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, place(.{ .x = 0, .y = 0, .width = 10, .height = 1000 }, bounds, 200, 40));
    // The anchor is already projected; candidate size remains unscaled.
    try std.testing.expectEqual(Point{ .x = 70, .y = 84 }, place(.{ .x = 70, .y = 70, .width = 3, .height = 14 }, bounds, 200, 40));
}
