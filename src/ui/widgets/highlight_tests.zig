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

/// Every pixel from its distance, as `fillBeveled` shades the ones near an edge.
fn referenceBeveled(pixels: []u32, width: usize, height: usize, scale: f32, box: paint.ClipRect, style: @import("../layout.zig").RectStyle, wanted: f32) void {
    const bevel = @min(wanted, @min(box.w, box.h) / 2);
    for (0..height) |py| {
        const y = @abs((@as(f32, @floatFromInt(py)) + 0.5) / scale - box.y - box.h / 2);
        for (0..width) |px| {
            const x = @abs((@as(f32, @floatFromInt(px)) + 0.5) / scale - box.x - box.w / 2);
            const distance = @max(@max(x - box.w / 2, y - box.h / 2), (x + y - box.w / 2 - box.h / 2 + bevel) / std.math.sqrt2);
            const outer = paint.sdf.coverage(distance * scale);
            const inner = paint.sdf.coverage((distance + style.border_width) * scale);
            const fill = style.color;
            paint.blendPixel(&pixels[py * width + px], .{ .r = fill[0], .g = fill[1], .b = fill[2], .a = fill[3] }, outer);
            const border = style.border_color;
            paint.blendPixel(&pixels[py * width + px], .{ .r = border[0], .g = border[1], .b = border[2], .a = border[3] }, @max(0, outer - inner));
        }
    }
}

test "a beveled fill's interior runs match the per-pixel raster" {
    const styles = [_]@import("../layout.zig").RectStyle{
        .{ .color = .{ 0.1, 0.2, 0.3, 1 }, .border_width = 1, .border_color = .{ 1, 0.9, 0, 1 } },
        .{ .color = .{ 0.1, 0.2, 0.3, 0.6 }, .border_width = 2.5, .border_color = .{ 1, 0.9, 0, 0.7 } },
        .{ .color = .{ 0, 0, 0, 0 }, .border_width = 3, .border_color = .{ 1, 0.2, 0, 1 } },
        .{ .color = .{ 0.4, 0.4, 0.4, 1 } },
    };
    const boxes = [_]paint.ClipRect{ .{ .x = 3, .y = 2, .w = 70, .h = 40 }, .{ .x = 0.5, .y = 1.25, .w = 21, .h = 9 }, .{ .x = -4, .y = 30, .w = 60, .h = 30 } };
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        for (styles) |style| {
            for (boxes) |box| {
                for ([_]f32{ 3, 7, 16, 40 }) |bevel| {
                    var got: [120 * 100]u32 = @splat(0x80402010);
                    var want: [120 * 100]u32 = @splat(0x80402010);
                    var renderer = paint.Renderer.init(&got, 120, 100, scale);
                    highlight.fillBeveled(&renderer, box, style, bevel);
                    referenceBeveled(&want, 120, 100, scale, box, style, bevel);
                    try std.testing.expectEqualSlices(u32, &want, &got);
                }
            }
        }
    }
}
