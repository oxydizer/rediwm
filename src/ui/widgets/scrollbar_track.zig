//! Static hatching in track-local coordinates: scrolling never animates it.
const scrollbar = @import("scrollbar.zig");
const paint_mod = @import("../paint.zig");
const sdf = @import("../sdf.zig");
const Color = @import("../text.zig").Color;

pub fn paint(r: *paint_mod.Renderer, l: scrollbar.Look) void {
    const box = l.track;
    r.fillRect(box.x, box.y, box.w, box.h, .{ .color = l.track_fill, .radius = l.track_radius });
    if (l.track_stripe[3] <= 0 or l.stripe_period <= 0 or l.stripe_width <= 0) return;
    const period = l.stripe_period;
    const half_width = @min(l.stripe_width, period) / 2;
    const normal = @sqrt(1 + l.stripe_slope * l.stripe_slope);
    const s = r.scale;
    var left = box.x;
    var top = box.y;
    var right = box.x + box.w;
    var bottom = box.y + box.h;
    if (r.effectiveClip()) |clip| {
        left = @max(left, clip.x);
        top = @max(top, clip.y);
        right = @min(right, clip.x + clip.w);
        bottom = @min(bottom, clip.y + clip.h);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, left * s)));
    const y0: i32 = @intFromFloat(@floor(@max(0, top * s)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), right * s)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), bottom * s)));
    const color: Color = .{ .r = l.track_stripe[0], .g = l.track_stripe[1], .b = l.track_stripe[2], .a = l.track_stripe[3] };
    var solid: u32 = 0;
    paint_mod.blendPixel(&solid, color, 1);
    // Away from the rounded ends the channel's edge is a straight side: a pixel
    // this far inside both sides is wholly covered, with no distance to work out.
    const radius = @min(l.track_radius, @min(box.w, box.h) / 2);
    const clear = 0.5 / s + 1e-3;
    r.clean = false;
    var py = y0;
    while (py < y1) : (py += 1) {
        const y = (@as(f32, @floatFromInt(py)) + 0.5) / s - box.y;
        const side_y = @abs(y - box.h / 2) - box.h / 2;
        var px = x0;
        while (px < x1) : (px += 1) {
            const x = (@as(f32, @floatFromInt(px)) + 0.5) / s - box.x;
            const along = if (l.axis == .vertical) y else x;
            const across = if (l.axis == .vertical) x else y;
            const stripe = sdf.coverage((@abs(phase(across * l.stripe_slope + along, period) - period / 2) - half_width) * s / normal);
            if (stripe <= 0) continue;
            const side_x = @abs(x - box.w / 2) - box.w / 2;
            const inside = side_x <= -clear and side_y <= -clear and !(side_x > -radius and side_y > -radius);
            const cover = if (inside) stripe else stripe * sdf.coverage(sdf.sdRoundedBox(x, y, 0, 0, box.w, box.h, l.track_radius) * s);
            if (cover <= 0) continue;
            const pixel = &r.pixels[@intCast(py * r.width + px)];
            if (cover >= 1 and color.a >= 1) pixel.* = solid else paint_mod.blendPixel(pixel, color, cover);
        }
    }
}

/// `@mod(v, period)`, without the soft-float remainder a baseline x86_64 build
/// calls for it: the quotient's whole part, then the exact remainder in f64.
fn phase(v: f32, period: f32) f32 {
    if (!(v >= 0) or v / period > 1e9) return @mod(v, period);
    const whole: f64 = @floatFromInt(@as(i64, @intFromFloat(v / period)));
    var rem = @as(f64, v) - whole * @as(f64, period);
    if (rem < 0) rem += period else if (rem >= period) rem -= period;
    return @floatCast(rem);
}

test "the hatching matches a raster that works out every pixel" {
    const std = @import("std");
    for ([_]f32{ 0.37, 4.2, 9.999, 10, 10.001, 123.456, 9999.5 }) |v| {
        for ([_]f32{ 10, 3.3, 0.7 }) |period| try std.testing.expectEqual(@mod(v, period), phase(v, period));
    }
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        for ([_]scrollbar.Axis{ .vertical, .horizontal }) |axis| {
            for ([_][4]f32{ .{ 0.2, 0.3, 0.4, 1 }, .{ 0.2, 0.3, 0.4, 0.5 } }) |stripe| {
                const track: scrollbar.Rect = if (axis == .vertical) .{ .x = 3.25, .y = 2, .w = 8, .h = 60 } else .{ .x = 2, .y = 3.25, .w = 60, .h = 8 };
                const look: scrollbar.Look = .{ .track = track, .track_radius = 3.5, .track_color = @splat(0), .track_fill = .{ 0.1, 0.1, 0.1, 1 }, .track_stripe = stripe, .stripe_period = 10, .stripe_width = 5, .stripe_slope = 1, .rect = track, .radius = 3, .color = @splat(1), .axis = axis, .highlight = @splat(0), .shine = 0, .glow = 0 };
                var got: [140 * 140]u32 = @splat(0);
                var want: [140 * 140]u32 = @splat(0);
                var renderer = paint_mod.Renderer.init(&got, 140, 140, scale);
                paint(&renderer, look);
                var reference = paint_mod.Renderer.init(&want, 140, 140, scale);
                reference.fillRect(track.x, track.y, track.w, track.h, .{ .color = look.track_fill, .radius = look.track_radius });
                for (0..140) |py| for (0..140) |px| {
                    const x = (@as(f32, @floatFromInt(px)) + 0.5) / scale - track.x;
                    const y = (@as(f32, @floatFromInt(py)) + 0.5) / scale - track.y;
                    if (x < -1 or y < -1 or x > track.w + 1 or y > track.h + 1) continue;
                    const edge = sdf.coverage(sdf.sdRoundedBox(x, y, 0, 0, track.w, track.h, look.track_radius) * scale);
                    const along = if (axis == .vertical) y else x;
                    const across = if (axis == .vertical) x else y;
                    const hatch = sdf.coverage((@abs(@mod(across + along, 10) - 5) - 2.5) * scale / @sqrt(2.0));
                    if (edge * hatch > 0) paint_mod.blendPixel(&want[py * 140 + px], .{ .r = stripe[0], .g = stripe[1], .b = stripe[2], .a = stripe[3] }, edge * hatch);
                };
                try std.testing.expectEqualSlices(u32, &want, &got);
            }
        }
    }
}
