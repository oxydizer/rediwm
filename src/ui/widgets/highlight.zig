//! Shared highlight geometry for Cairo app rows and shell navigation rows.
const std = @import("std");
const c = @import("c_gfx");
const theme = @import("../theme.zig");
const paint_mod = @import("../paint.zig");
const layout = @import("../layout.zig");
const Color = @import("../text.zig").Color;

pub fn path(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const bevel = @min(theme.global.app_highlight_bevel, @min(w, h) / 2);
    c.cairo_new_sub_path(cr);
    if (bevel > 0) {
        c.cairo_move_to(cr, x + bevel, y);
        c.cairo_line_to(cr, x + w - bevel, y);
        c.cairo_line_to(cr, x + w, y + bevel);
        c.cairo_line_to(cr, x + w, y + h - bevel);
        c.cairo_line_to(cr, x + w - bevel, y + h);
        c.cairo_line_to(cr, x + bevel, y + h);
        c.cairo_line_to(cr, x, y + h - bevel);
        c.cairo_line_to(cr, x, y + bevel);
    } else {
        const r = @min(radius, @min(w, h) / 2);
        c.cairo_arc(cr, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
        c.cairo_arc(cr, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
        c.cairo_arc(cr, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
        c.cairo_arc(cr, x + r, y + r, r, std.math.pi, 3 * std.math.pi / 2.0);
    }
    c.cairo_close_path(cr);
}

pub fn paint(r: *paint_mod.Renderer, box: paint_mod.ClipRect, style: layout.RectStyle) void {
    const bevel = (r.palette orelse theme.global).app_highlight_bevel;
    if (bevel <= 0) {
        r.fillRect(box.x, box.y, box.w, box.h, style);
        return;
    }
    fillBeveled(r, box, style, bevel);
}

/// A box with straight 45-degree corners `bevel` long (capped at half its
/// shorter side), filled and bordered like `Renderer.fillRect`.
pub fn fillBeveled(r: *paint_mod.Renderer, box: paint_mod.ClipRect, style: layout.RectStyle, wanted: f32) void {
    if (box.w <= 0 or box.h <= 0) return;
    const bevel = @min(wanted, @min(box.w, box.h) / 2);
    var clip = box;
    if (r.effectiveClip()) |limit| clip = paint_mod.intersectClip(clip, limit);
    const s = r.scale;
    const x0: i32 = @intFromFloat(@floor(@max(0, clip.x * s)));
    const y0: i32 = @intFromFloat(@floor(@max(0, clip.y * s)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), (clip.x + clip.w) * s)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), (clip.y + clip.h) * s)));
    const half_w = box.w / 2;
    const half_h = box.h / 2;
    r.clean = false;
    const fill: Color = .{ .r = style.color[0], .g = style.color[1], .b = style.color[2], .a = style.color[3] };
    const border: Color = .{ .r = style.border_color[0], .g = style.border_color[1], .b = style.border_color[2], .a = style.border_color[3] };
    // Pixels this far inside every edge are the fill alone, at full coverage:
    // one run per row, with no distance to work out. An opaque fill stores one
    // packed colour there and a clear one (an outline) leaves the run untouched.
    const inner = style.border_width + 0.5 / s + 1e-3;
    var solid: u32 = 0;
    paint_mod.blendPixel(&solid, fill, 1);
    var py = y0;
    while (py < y1) : (py += 1) {
        const y = @abs((@as(f32, @floatFromInt(py)) + 0.5) / s - box.y - half_h);
        const row: usize = @intCast(py * r.width);
        // Half the width of the run about the box's centre; negative on a row
        // with none (within the border of the top or bottom edge).
        const reach = if (y <= half_h - inner) @min(half_w - inner, half_w + half_h - bevel - inner * std.math.sqrt2 - y) else -1;
        const centre = (box.x + half_w) * s;
        const run_x0 = if (reach >= 0) std.math.clamp(@as(i32, @intFromFloat(@ceil(centre - reach * s - 0.5))), x0, x1) else x1;
        const run_x1 = if (reach >= 0) std.math.clamp(@as(i32, @intFromFloat(@floor(centre + reach * s - 0.5))) + 1, run_x0, x1) else x1;
        var px = x0;
        while (px < x1) : (px += 1) {
            if (px == run_x0 and run_x1 > run_x0) {
                const run = r.pixels[row + @as(usize, @intCast(run_x0)) .. row + @as(usize, @intCast(run_x1))];
                if (fill.a >= 1) {
                    @memset(run, solid);
                } else if (fill.a > 0) {
                    for (run) |*pixel| paint_mod.blendPixel(pixel, fill, 1);
                }
                px = run_x1 - 1;
                continue;
            }
            const x = @abs((@as(f32, @floatFromInt(px)) + 0.5) / s - box.x - half_w);
            const distance = @max(@max(x - half_w, y - half_h), (x + y - half_w - half_h + bevel) / std.math.sqrt2);
            const outer = paint_mod.sdf.coverage(distance * s);
            if (outer <= 0) continue;
            const inside = paint_mod.sdf.coverage((distance + style.border_width) * s);
            const index = row + @as(usize, @intCast(px));
            if (fill.a > 0) paint_mod.blendPixel(&r.pixels[index], fill, outer);
            if (outer > inside and border.a > 0) paint_mod.blendPixel(&r.pixels[index], border, outer - inside);
        }
    }
}

test {
    _ = @import("highlight_tests.zig");
}
