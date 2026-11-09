const std = @import("std");
const c = @import("c_gfx");
const theme = @import("../theme.zig");
const paint = @import("../paint.zig");
const highlight = @import("highlight.zig");

test "beveled highlights cut straight corners in Cairo and shell rasters" {
    const saved = theme.global;
    defer theme.global = saved;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 40, 24).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    const box: paint.ClipRect = .{ .x = 2, .y = 2, .w = 36, .h = 20 };
    // These points are inside a rounded corner but outside a 7px bevel.
    for ([_]f32{ 0, 7 }) |bevel| {
        theme.global.app_highlight_bevel = bevel;
        c.cairo_new_path(cr);
        highlight.path(cr, box.x, box.y, box.w, box.h, 5);
        for ([_]f64{ 4.5, 35.5 }) |x| {
            for ([_]f64{ 4.5, 19.5 }) |y| {
                try std.testing.expectEqual(bevel == 0, c.cairo_in_fill(cr, x, y) != 0);
            }
        }
        try std.testing.expect(c.cairo_in_fill(cr, 20, 3) != 0);
        for ([_]f32{ 1, 1.5 }) |scale| {
            var pixels: [60 * 36]u32 = @splat(0);
            var renderer = paint.Renderer.init(&pixels, 60, 36, scale);
            highlight.paint(&renderer, box, .{ .color = .{ 1, 1, 0, 1 }, .radius = 5 });
            const corner: usize = @intFromFloat(@floor(4.5 * scale));
            const face_x: usize = @intFromFloat(20 * scale);
            try std.testing.expectEqual(bevel == 0, pixels[corner * 60 + corner] != 0);
            try std.testing.expect(pixels[corner * 60 + face_x] != 0);
            try std.testing.expectEqual(@as(u32, 0), pixels[0]);
        }
    }
}
