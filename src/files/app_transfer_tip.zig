//! Shared tooltip frame and layout for transfer details.
const std = @import("std");
const ui = @import("ui").cairo;
const text = @import("ui").text;
const theme = @import("ui").theme;
const frame = @import("ui").widgets.dialog;
const c = @import("c.zig").api;
const header = @import("header.zig");

pub const Detail = struct {
    label: []const u8,
    value: []const u8,
};

/// Exact window-coordinate bounds shared by tooltip painting and damage.
pub fn bounds(
    window_w: i32,
    window_h: i32,
    mouse_x: f64,
    mouse_y: f64,
    detail_count: usize,
) ?header.Rect {
    const width: f32 = @min(320, @as(f32, @floatFromInt(window_w)) - 16);
    const height: f32 = 18 + @as(f32, @floatFromInt(detail_count + 1)) * 22;
    if (width <= 0 or @as(f32, @floatFromInt(window_h)) < height + 16) return null;

    const max_x = @max(8, @as(f32, @floatFromInt(window_w)) - width - 8);
    const x = std.math.clamp(@as(f32, @floatCast(mouse_x + 14)), 8, max_x);
    const below = @as(f32, @floatCast(mouse_y + 14));
    const y = std.math.clamp(
        if (below + height <= @as(f32, @floatFromInt(window_h)) - 8)
            below
        else
            @as(f32, @floatCast(mouse_y)) - height - 14,
        8,
        @as(f32, @floatFromInt(window_h)) - height - 8,
    );

    return .{
        .x = x,
        .y = y,
        .w = width,
        .h = height,
    };
}

pub fn render(
    cr: *c.cairo_t,
    window_w: i32,
    window_h: i32,
    mouse_x: f64,
    mouse_y: f64,
    title: []const u8,
    details: []const Detail,
) void {
    const area = bounds(window_w, window_h, mouse_x, mouse_y, details.len) orelse return;
    var layer = ui.Layer.begin(cr, .{
        .x = @floatCast(area.x),
        .y = @floatCast(area.y),
        .w = @floatCast(area.w),
        .h = @floatCast(area.h),
    }) orelse return;
    defer layer.finish();
    var palette = theme.shellPalette();
    palette.fg = theme.global.window_fg;
    layer.renderer.palette = palette;
    frame.paintFrame(&layer.renderer, layer.local());
    layer.renderer.drawText(12, 9, @as(f32, @floatCast(area.w)) - 24, 22, .{
        .content = title,
        .font_size = ui.textSize(),
        .color = palette.fg,
    });
    for (details, 0..) |detail, i| {
        const y = 31 + @as(f32, @floatFromInt(i)) * 22;
        const value_width = text.measureWidthF(
            detail.value,
            .manrope,
            ui.statusSize(),
            layer.renderer.scale,
        ) catch 0;
        const value_x = @max(12, @as(f32, @floatCast(area.w)) - 12 - value_width);
        layer.renderer.drawText(12, y, @max(0, value_x - 20), 22, .{
            .content = detail.label,
            .font_size = ui.statusSize(),
            .color = palette.fg,
        });
        layer.renderer.drawText(value_x, y, value_width + 1, 22, .{
            .content = detail.value,
            .font_size = ui.statusSize(),
            .color = palette.fg,
        });
    }
}
