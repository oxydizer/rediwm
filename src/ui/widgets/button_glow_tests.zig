//! The separable proximity-glow painter against the per-pixel formula it replaced.

const std = @import("std");
const button = @import("button.zig");
const theme = @import("../theme.zig");
const paint_mod = @import("../paint.zig");
const Renderer = paint_mod.Renderer;
const Rect = button.Rect;

fn glowNear(px: f32, py: f32, edge_x: f32, edge_y: f32, reach: f32) f32 {
    const distance = std.math.hypot(px - edge_x, py - edge_y);
    if (!(distance < reach)) return 0;
    const n = 1 - distance / reach;
    return n * n * (3 - 2 * n);
}

/// The original painter: eight exponentials per covered pixel.
fn reference(r: *Renderer, box: Rect, radius: f32, pointer_x: f32, pointer_y: f32) void {
    const t = r.palette.?;
    const cr = std.math.clamp(radius, 0, 0.5 * @min(box.w, box.h));
    const reach = t.border_glow_reach;
    const ex = std.math.clamp(pointer_x, cr, box.w - cr);
    const ey = std.math.clamp(pointer_y, cr, box.h - cr);
    const Edge = struct { x: f32, y: f32, near: f32, vertical: bool, negative: bool };
    const edges = [_]Edge{
        .{ .x = ex, .y = 0, .near = glowNear(pointer_x, pointer_y, ex, 0, reach), .vertical = false, .negative = true },
        .{ .x = box.w, .y = ey, .near = glowNear(pointer_x, pointer_y, box.w, ey, reach), .vertical = true, .negative = false },
        .{ .x = ex, .y = box.h, .near = glowNear(pointer_x, pointer_y, ex, box.h, reach), .vertical = false, .negative = false },
        .{ .x = 0, .y = ey, .near = glowNear(pointer_x, pointer_y, 0, ey, reach), .vertical = true, .negative = true },
    };
    const s = r.scale;
    var dx0 = box.x * s;
    var dy0 = box.y * s;
    var dx1 = (box.x + box.w) * s;
    var dy1 = (box.y + box.h) * s;
    if (r.effectiveClip()) |clip| {
        dx0 = @max(dx0, clip.x * s);
        dy0 = @max(dy0, clip.y * s);
        dx1 = @min(dx1, (clip.x + clip.w) * s);
        dy1 = @min(dy1, (clip.y + clip.h) * s);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, dx0)));
    const y0: i32 = @intFromFloat(@floor(@max(0, dy0)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), dx1)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), dy1)));
    const red = paint_mod.toColor(t.border_glow);
    const dark = paint_mod.toColor(.{ 0, 0, 0, t.border_glow[3] * 0.35 });
    var py = y0;
    while (py < y1) : (py += 1) {
        const sy = @as(f32, @floatFromInt(py)) + 0.5;
        const ly = sy / s;
        var px = x0;
        while (px < x1) : (px += 1) {
            const sx = @as(f32, @floatFromInt(px)) + 0.5;
            const lx = sx / s;
            const coverage = paint_mod.sdf.coverage(paint_mod.sdf.sdRoundedBox(sx, sy, box.x * s, box.y * s, box.w * s, box.h * s, radius * s));
            if (coverage <= 0) continue;
            var near_alpha: f32 = 0;
            var far_alpha: f32 = 0;
            for (edges) |edge| {
                if (edge.near <= 0) continue;
                const along = if (edge.vertical) ly - box.y else lx - box.x;
                const anchor = if (edge.vertical) edge.y else edge.x;
                const ratio = (along - anchor) / t.border_glow_length;
                const falloff = @exp(-2 * ratio * ratio);
                const near_depth = if (edge.vertical)
                    (if (edge.negative) lx - box.x else box.x + box.w - lx)
                else
                    (if (edge.negative) ly - box.y else box.y + box.h - ly);
                const far_depth = if (edge.vertical)
                    (if (edge.negative) box.x + box.w - lx else lx - box.x)
                else
                    (if (edge.negative) box.y + box.h - ly else ly - box.y);
                near_alpha = @max(near_alpha, edge.near * falloff * @exp(-@max(0, near_depth) / t.border_glow_depth) * coverage);
                far_alpha = @max(far_alpha, edge.near * falloff * @exp(-@max(0, far_depth) / t.border_glow_depth) * coverage);
            }
            const index: usize = @intCast(py * r.width + px);
            if (near_alpha > 0) paint_mod.blendPixel(&r.pixels[index], red, near_alpha);
            if (far_alpha > 0) paint_mod.blendPixel(&r.pixels[index], dark, far_alpha);
        }
    }
}

fn fillNoise(pixels: []u32) void {
    for (pixels, 0..) |*pixel, i| pixel.* = @as(u32, @truncate(i *% 2654435761)) | 0xff000000;
}

test "separable proximity glow is bit-identical to the per-pixel formula" {
    const allocator = std.testing.allocator;
    const width = 700;
    const height = 120;
    const got = try allocator.alloc(u32, width * height);
    defer allocator.free(got);
    const want = try allocator.alloc(u32, width * height);
    defer allocator.free(want);

    var palette: theme.Theme = .{};
    palette.border_glow_reach = 56;
    palette.border_glow_length = 72;
    palette.border_glow_depth = 3;

    // Wide enough at 2x to cross the painter's column chunks; small and
    // rounded enough for the corner clamps; clipped and unclipped.
    const boxes = [_]Rect{
        .{ .x = 3.25, .y = 2.5, .w = 300, .h = 40 },
        .{ .x = 20, .y = 10, .w = 36, .h = 24 },
        .{ .x = 0, .y = 0, .w = 12, .h = 50 },
    };
    const pointers = [_][2]f32{ .{ -10, 12 }, .{ 150, -20 }, .{ 18, 20 }, .{ 310, 45 }, .{ 5, 5 }, .{ -40, -40 } };
    for ([_]f32{ 0.6, 1, 0.08 }) |strength| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        palette.border_glow[3] = strength;
        for (boxes) |box| for ([_]f32{ 0, 6, 100 }) |radius| for (pointers) |pointer| for ([_]bool{ false, true }) |clipped| {
            const distance = std.math.hypot(@max(0, @max(-pointer[0], pointer[0] - box.w)), @max(0, @max(-pointer[1], pointer[1] - box.h)));
            fillNoise(got);
            fillNoise(want);
            var a = Renderer.init(got, width, height, scale);
            var b = Renderer.init(want, width, height, scale);
            a.palette = palette;
            b.palette = palette;
            if (clipped) {
                a.clip = .{ .x = box.x + 4.5, .y = box.y + 1, .w = box.w * 0.6, .h = box.h };
                b.clip = a.clip;
            }
            button.paintProximityGlowAt(&a, box, radius, distance, pointer[0], pointer[1]);
            reference(&b, box, radius, pointer[0], pointer[1]);
            try std.testing.expectEqualSlices(u32, want, got);
        };
    };
}

test "glow visibility follows the setting and every strength key" {
    var t: theme.Theme = .{};
    try std.testing.expect(button.proximityGlowVisible(t));
    t.button_hover_glow_enabled = false;
    try std.testing.expect(!button.proximityGlowVisible(t));
    t = .{};
    t.border_glow[3] = 0;
    try std.testing.expect(!button.proximityGlowVisible(t));
    t = .{};
    t.border_glow_reach = 0;
    try std.testing.expect(!button.proximityGlowVisible(t));
}
