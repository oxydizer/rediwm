//! Shapes the Transfers icon and panel draw that `ui` has no primitive for:
//! a progress ring, stroked glyphs on a 24-unit grid and a speed graph.
//! Logical coordinates in, coverage-blended device pixels out, inside the
//! renderer's clip.
const std = @import("std");
const paint = @import("ui").paint;

const Box = struct { x0: usize, y0: usize, x1: usize, y1: usize };

/// The device pixels of a logical box, clamped to the buffer and the clip.
fn pixelsOf(r: *const paint.Renderer, x: f32, y: f32, w: f32, h: f32) ?Box {
    var left = x;
    var top = y;
    var right = x + w;
    var bottom = y + h;
    if (r.effectiveClip()) |clip| {
        left = @max(left, clip.x);
        top = @max(top, clip.y);
        right = @min(right, clip.x + clip.w);
        bottom = @min(bottom, clip.y + clip.h);
    }
    const x0 = paint.clampToInt(@floor(left * r.scale), 0, r.width);
    const y0 = paint.clampToInt(@floor(top * r.scale), 0, r.height);
    const x1 = paint.clampToInt(@ceil(right * r.scale), 0, r.width);
    const y1 = paint.clampToInt(@ceil(bottom * r.scale), 0, r.height);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x0 = @intCast(x0), .y0 = @intCast(y0), .x1 = @intCast(x1), .y1 = @intCast(y1) };
}

fn blend(r: *paint.Renderer, px: usize, py: usize, color: [4]f32, coverage: f32) void {
    if (coverage <= 0) return;
    r.clean = false;
    const pixel = &r.pixels[py * @as(usize, @intCast(r.width)) + px];
    paint.blendPixel(pixel, .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, @min(coverage, 1));
}

/// A circle outline, and over it the clockwise arc from twelve o'clock for
/// `fraction` of the way round, with round ends.
pub fn ring(r: *paint.Renderer, cx: f32, cy: f32, radius: f32, thickness: f32, fraction: ?f32, track: [4]f32, arc: [4]f32) void {
    const reach = radius + thickness;
    const box = pixelsOf(r, cx - reach, cy - reach, reach * 2, reach * 2) orelse return;
    const sweep = (fraction orelse 0) * 2 * std.math.pi;
    const half = thickness / 2;
    // The arc's ends, for the round caps.
    const end_x = cx + radius * @sin(sweep);
    const end_y = cy - radius * @cos(sweep);
    for (box.y0..box.y1) |py| {
        const y = (@as(f32, @floatFromInt(py)) + 0.5) / r.scale - cy;
        for (box.x0..box.x1) |px| {
            const x = (@as(f32, @floatFromInt(px)) + 0.5) / r.scale - cx;
            const band = @abs(@sqrt(x * x + y * y) - radius) - half;
            blend(r, px, py, track, 0.5 - band * r.scale);
            if (fraction == null or sweep <= 0) continue;
            var angle = std.math.atan2(x, -y);
            if (angle < 0) angle += 2 * std.math.pi;
            var d = if (angle <= sweep) band else std.math.inf(f32);
            d = @min(d, @sqrt(x * x + (y + radius) * (y + radius)) - half);
            const ex = x + cx - end_x;
            const ey = y + cy - end_y;
            d = @min(d, @sqrt(ex * ex + ey * ey) - half);
            blend(r, px, py, arc, 0.5 - d * r.scale);
        }
    }
}

/// Line segments `{x0, y0, x1, y1}` on a 24-unit grid, scaled into a
/// `size`-square at (x, y) and stroked `width` grid units wide, round ends.
pub fn strokes(r: *paint.Renderer, x: f32, y: f32, size: f32, segments: []const [4]f32, width: f32, color: [4]f32) void {
    const unit = size / 24;
    const box = pixelsOf(r, x, y, size, size) orelse return;
    const half = width * unit / 2;
    for (box.y0..box.y1) |py| {
        const ly = (@as(f32, @floatFromInt(py)) + 0.5) / r.scale;
        for (box.x0..box.x1) |px| {
            const lx = (@as(f32, @floatFromInt(px)) + 0.5) / r.scale;
            var d = std.math.inf(f32);
            for (segments) |s| d = @min(d, segmentDistance(lx, ly, x + s[0] * unit, y + s[1] * unit, x + s[2] * unit, y + s[3] * unit));
            blend(r, px, py, color, 0.5 - (d - half) * r.scale);
        }
    }
}

fn segmentDistance(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 == 0) 0 else std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    const qx = ax + dx * t - px;
    const qy = ay + dy * t - py;
    return @sqrt(qx * qx + qy * qy);
}

pub const arrow_down = [_][4]f32{ .{ 12, 5, 12, 19 }, .{ 6, 13, 12, 19 }, .{ 18, 13, 12, 19 } };
/// The arrow inside the tray ring, smaller to clear it.
pub const ring_arrow = [_][4]f32{ .{ 12, 7.5, 12, 16.5 }, .{ 8.5, 13, 12, 16.5 }, .{ 15.5, 13, 12, 16.5 } };
pub const ring_pause = [_][4]f32{ .{ 10, 8.5, 10, 15.5 }, .{ 14, 8.5, 14, 15.5 } };

/// The newest samples of a speed history as an area graph: a line, a fill
/// fading downwards, scaled so `top` reaches the box's top. `samples` is
/// oldest first; fewer than the box's `slots` are drawn at its right end.
pub const Graph = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    slots: usize,
    top: u64,
    line: [4]f32,
    line_width: f32 = 1.5,
    fill_alpha: f32 = 0.28,
};

pub fn graph(r: *paint.Renderer, g: Graph, samples: []const u64) void {
    if (samples.len == 0 or g.top == 0 or g.slots < 2) return;
    const box = pixelsOf(r, g.x, g.y - g.line_width, g.w, g.h + g.line_width) orelse return;
    const step = g.w / @as(f32, @floatFromInt(g.slots - 1));
    const first_x = g.x + g.w - step * @as(f32, @floatFromInt(samples.len - 1));
    const top: f32 = @floatFromInt(g.top);
    const bottom = g.y + g.h;
    for (box.x0..box.x1) |px| {
        const lx = (@as(f32, @floatFromInt(px)) + 0.5) / r.scale;
        if (lx < first_x - 0.5 / r.scale) continue;
        // The line's height here, and its slope for an even stroke width.
        const pos = if (samples.len == 1) 0 else std.math.clamp((lx - first_x) / step, 0, @as(f32, @floatFromInt(samples.len - 1)));
        const i: usize = @intFromFloat(@floor(pos));
        const j = @min(i + 1, samples.len - 1);
        const frac = pos - @floor(pos);
        const a = valueY(g, samples[i], top);
        const b = valueY(g, samples[j], top);
        const line_y = a + (b - a) * frac;
        const slope = (b - a) / step;
        const stretch = @sqrt(1 + slope * slope);
        for (box.y0..box.y1) |py| {
            const ly = (@as(f32, @floatFromInt(py)) + 0.5) / r.scale;
            if (ly > line_y and ly < bottom) {
                const depth = (ly - line_y) / @max(1, bottom - line_y);
                var fill = g.line;
                fill[3] *= g.fill_alpha * (1 - depth * 0.85);
                blend(r, px, py, fill, std.math.clamp((ly - line_y) * r.scale, 0, 1));
            }
            const d = @abs(ly - line_y) / stretch - g.line_width / 2;
            blend(r, px, py, g.line, 0.5 - d * r.scale);
        }
    }
}

fn valueY(g: Graph, value: u64, top: f32) f32 {
    const v = @min(@as(f32, @floatFromInt(value)) / top, 1);
    return g.y + g.h - v * g.h;
}

/// A dashed horizontal hairline, the graphs' grid and average.
pub fn dashes(r: *paint.Renderer, x: f32, y: f32, w: f32, color: [4]f32) void {
    var at = x;
    while (at < x + w) : (at += 6) r.fillRect(at, y, @min(3, x + w - at), 1, .{ .color = color });
}
