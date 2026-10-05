//! X11 uses integer pixels, even when its rendering factor is fractional.
const std = @import("std");

pub fn surfacePosition(value: i32, factor: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(value)) * factor));
}

// Floor requested sizes so converting the committed size back with ceil does
// not grow a window by one logical pixel on each resize/restore cycle.
pub fn surfaceLength(value: i32, factor: f64) i32 {
    return @intFromFloat(@floor(@as(f64, @floatFromInt(value)) * factor + 1e-9));
}

pub fn worldLength(value: i32, factor: f64) i32 {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(value)) / factor - 1e-9));
}

pub fn worldFloor(value: i32, factor: f64) i32 {
    return @intFromFloat(@floor(@as(f64, @floatFromInt(value)) / factor + 1e-9));
}

test "fractional X11 sizes round trip without cumulative growth" {
    for (10..41) |tenth| {
        const factor = @as(f64, @floatFromInt(tenth)) / 10;
        for (1..2001) |size| {
            const logical: i32 = @intCast(size);
            try std.testing.expectEqual(logical, worldLength(surfaceLength(logical, factor), factor));
        }
    }
    try std.testing.expectEqual(@as(i32, -3), worldFloor(-3, 1.1));
    try std.testing.expectEqual(@as(i32, -141), surfacePosition(-128, 1.1));
}
