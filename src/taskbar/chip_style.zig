//! Shared taskbar/window-tab pill: one set of colours and edge pixels.
const theme = @import("ui").theme;
const chrome = @import("../chrome.zig");

pub fn Look(comptime C: type) type {
    return struct { fill: C, border: C };
}
pub fn look(comptime C: type, active: bool, attention: bool, hover: f32, press: f32) Look(C) {
    const idle = if (active) C.fromRgba(theme.global.taskbar_hover).scaled(2.8) else C.fromRgba(theme.global.taskbar_surface);
    const hovered = C.fromRgba(theme.global.taskbar_hover).scaled(if (active) 3.6 else 2.0);
    return .{
        .fill = C.fromRgba(theme.global.surface_hover).scaled(press).over(C.lerp(idle, hovered, hover)),
        .border = if (attention) C.fromRgba(theme.global.danger).scaled(2.5 + 0.8 * hover + press) else C.fromRgba(theme.global.taskbar_border).scaled(if (active) 2.2 + 0.6 * hover + 0.8 * press else 1 + hover + 0.8 * press),
    };
}

pub fn pixel(comptime C: type, px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, radius: f32, scale: f32, fill: C, border: C) C {
    const clear: C = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const cov = coverage(chrome.sdRoundedBox(px, py, x, y, w, h, radius), scale);
    if (cov <= 0) return clear;
    const inner = coverage(chrome.sdRoundedBox(px, py, x + 1, y + 1, w - 2, h - 2, @max(0, radius - 1)), scale);
    return C.lerp(border, fill, inner).scaled(cov).over(clear);
}
fn coverage(distance: f32, scale: f32) f32 {
    return @max(0, @min(1, 0.5 - distance * scale));
}
