//! Static hatching in track-local coordinates: scrolling never animates it.
const scrollbar = @import("scrollbar.zig");
const paint_mod = @import("../paint.zig");
const sdf = @import("../sdf.zig");

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
    const color = l.track_stripe;
    r.clean = false;
    var py = y0;
    while (py < y1) : (py += 1) {
        const y = (@as(f32, @floatFromInt(py)) + 0.5) / s - box.y;
        var px = x0;
        while (px < x1) : (px += 1) {
            const x = (@as(f32, @floatFromInt(px)) + 0.5) / s - box.x;
            const edge = sdf.coverage(sdf.sdRoundedBox(x, y, 0, 0, box.w, box.h, l.track_radius) * s);
            const along = if (l.axis == .vertical) y else x;
            const across = if (l.axis == .vertical) x else y;
            const phase = @mod(across * l.stripe_slope + along, period);
            const stripe = sdf.coverage((@abs(phase - period / 2) - half_width) * s / normal);
            if (edge * stripe > 0) paint_mod.blendPixel(&r.pixels[@intCast(py * r.width + px)], .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, edge * stripe);
        }
    }
}
