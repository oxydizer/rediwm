//! Shared tooltip frame and layout for transfer details.
const std = @import("std");
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const frame = @import("ui").widgets.dialog;
const c = @import("c.zig").api;

pub fn render(
    cr: *c.cairo_t,
    window_w: i32,
    window_h: i32,
    mouse_x: f64,
    mouse_y: f64,
    title: []const u8,
    details: []const []const u8,
) void {
    const width: f32 = @min(320, @as(f32, @floatFromInt(window_w)) - 16);
    const height: f32 = 18 + @as(f32, @floatFromInt(details.len + 1)) * 22;
    if (width <= 0 or @as(f32, @floatFromInt(window_h)) < height + 16) return;

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

    var layer = ui.Layer.begin(cr, .{ .x = x, .y = y, .w = width, .h = height }) orelse return;
    defer layer.finish();
    var palette = theme.shellPalette();
    palette.fg = theme.global.window_fg;
    layer.renderer.palette = palette;
    frame.paintFrame(&layer.renderer, layer.local());
    layer.renderer.drawText(12, 9, width - 24, 22, .{
        .content = title,
        .font_size = ui.textSize(),
        .color = palette.fg,
    });
    for (details, 0..) |detail, i| {
        layer.renderer.drawText(12, 31 + @as(f32, @floatFromInt(i)) * 22, width - 24, 22, .{
            .content = detail,
            .font_size = ui.statusSize(),
            .color = palette.fg,
        });
    }
}
