//! RediOS display-density policy. Pixel dimensions are the selected mode,
//! before output transform; physical dimensions are wlroots' EDID millimetres.
const std = @import("std");

pub fn calculate(width: i32, height: i32, width_mm: i32, height_mm: i32) f32 {
    if (width <= 0 or height <= 0 or width_mm <= 0 or height_mm <= 0) return 1;
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const mw: f64 = @floatFromInt(width_mm);
    const mh: f64 = @floatFromInt(height_mm);
    const diagonal = @sqrt(mw * mw + mh * mh) / 25.4;
    const dpi = @sqrt(w * w + h * h) / diagonal;
    // Broken EDIDs sometimes report centimetres as millimetres, or a size
    // unrelated to the panel. Do not turn that into a 3x desktop.
    if (diagonal < 3 or diagonal > 120 or dpi < 40 or dpi > 1000) return 1;
    const baseline: f64 = if (diagonal <= 17) 130 else if (diagonal <= 21) 115 else 96;
    return @floatCast(std.math.clamp(@round(dpi / baseline * 4) / 4, 1, 3));
}

test "RediOS density tiers and invalid EDID fallback" {
    try std.testing.expectEqual(@as(f32, 1.5), calculate(2560, 1600, 339, 212));
    try std.testing.expectEqual(@as(f32, 1.25), calculate(1920, 1080, 294, 166));
    try std.testing.expectEqual(@as(f32, 1.25), calculate(2560, 1440, 598, 336));
    try std.testing.expectEqual(@as(f32, 1), calculate(1920, 1080, 531, 299));
    try std.testing.expectEqual(@as(f32, 1), calculate(3840, 2160, 0, 0));
    try std.testing.expectEqual(@as(f32, 1), calculate(3840, 2160, 60, 34));
    try std.testing.expectEqual(@as(f32, 1), calculate(0, 0, 600, 340));
    try std.testing.expectEqual(@as(f32, 3), calculate(7680, 4320, 300, 170));
}
