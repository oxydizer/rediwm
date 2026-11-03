//! An elastic perimeter: fixed edges stay on the live window, while the grabbed
//! corner (or point on an edge) pulls the adjacent sides toward the target.
const std = @import("std");
const ribbon = @import("ribbon.zig");
const Polygon = @import("ui").window_shape.Resolved;
const Point = ribbon.Point;
pub const Box = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Pull = struct {
    edges: @import("../resize.zig").Edges,
    // Fractional grab position on the original window, for a single-edge drag.
    anchor: Point = .{ .x = 0.5, .y = 0.5 },
};
pub const Outline = struct {
    current: [63]Point = undefined,
    leading: [63]Point = undefined,
    len: usize = 0,

    fn append(self: *Outline, p: Point, q: Point, width: f32, height: f32, radius: f32, pull: Pull) void {
        const u = fraction(p.x, width, radius);
        const v = fraction(p.y, height, radius);
        const e = pull.edges;
        const horizontal = e.left or e.right;
        const vertical = e.top or e.bottom;
        // Use the transverse coordinate for the pull, not a shared XY weight:
        // this keeps motion along an edge monotonic even during a deep shrink.
        const wx = if (!horizontal) 0 else if (vertical)
            square(if (e.top) 1 - v else v)
        else
            bell(v, fraction(pull.anchor.y * height, height, radius));
        const wy = if (!vertical) 0 else if (horizontal)
            square(if (e.left) 1 - u else u)
        else
            bell(u, fraction(pull.anchor.x * width, width, radius));
        const leading: Point = .{ .x = p.x + (q.x - p.x) * wx, .y = p.y + (q.y - p.y) * wy };
        if (self.len > 0 and std.meta.eql(self.current[self.len - 1], p) and std.meta.eql(self.leading[self.len - 1], leading)) return;
        std.debug.assert(self.len < self.current.len);
        self.current[self.len] = p;
        self.leading[self.len] = leading;
        self.len += 1;
    }
};

pub fn resolve(width: f32, height: f32, target: Box, radius: f32, current_polygon: ?Polygon, target_polygon: ?Polygon, pull: Pull, quality: @import("config").effects.Quality) Outline {
    var result: Outline = .{};
    if ((pull.edges.left and pull.edges.right) or (pull.edges.top and pull.edges.bottom)) return result;
    if (current_polygon) |a| {
        const b = target_polygon orelse return result;
        if (a.count != b.count or a.count < 3) return result;
        const budget: usize = switch (quality) {
            .low => 31,
            .balanced => 59,
            .high => 63,
        };
        const steps = @max(1, budget / a.count);
        for (0..a.count) |i| {
            const next = (i + 1) % a.count;
            for (0..steps) |j| {
                const t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(steps));
                const p = mix(polyPoint(a, i), polyPoint(a, next), t);
                var q = mix(polyPoint(b, i), polyPoint(b, next), t);
                q.x += target.x;
                q.y += target.y;
                result.append(p, q, width, height, 0, pull);
            }
        }
    } else rounded(&result, width, height, target, radius, pull, quality);
    return result;
}

fn rounded(result: *Outline, width: f32, height: f32, target: Box, radius: f32, pull: Pull, quality: @import("config").effects.Quality) void {
    const r = std.math.clamp(radius, 0, @min(width, height) / 2);
    const tr = std.math.clamp(radius, 0, @min(target.width, target.height) / 2);
    const arc_steps: usize = switch (quality) {
        .low => 2,
        .balanced => 4,
        .high => 5,
    };
    const corner_grab = (pull.edges.left or pull.edges.right) and (pull.edges.top or pull.edges.bottom);
    var target_radii: [4]f32 = @splat(tr);
    if (corner_grab) {
        const dx = target.x + (if (pull.edges.right) target.width - width else 0);
        const dy = target.y + (if (pull.edges.bottom) target.height - height else 0);
        const strain = std.math.clamp(std.math.hypot(dx, dy) / @max(1, r * 4), 0, 1);
        const corner: usize = if (pull.edges.right) (if (pull.edges.top) @as(usize, 0) else 1) else (if (pull.edges.bottom) @as(usize, 2) else 3);
        // The pulled corner becomes a point under tension, returning to the
        // window's radius as the real size catches up.
        target_radii[corner] *= 1 - strain * strain * (3 - 2 * strain);
    }
    const curve_steps: usize = (if (quality == .low) @as(usize, 10) else 20) * (if (corner_grab) @as(usize, 1) else 2);
    const curved = [4]bool{ pull.edges.right, pull.edges.bottom, pull.edges.left, pull.edges.top };
    for (0..4) |corner| {
        for (0..arc_steps + 1) |step| {
            const angle = (@as(f32, @floatFromInt(corner)) - 1 + @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(arc_steps))) * std.math.pi / 2;
            const p = arc(width, height, r, corner, angle);
            const q = translated(arc(target.width, target.height, target_radii[corner], corner, angle), target);
            result.append(p, q, width, height, r, pull);
        }
        const angle = @as(f32, @floatFromInt(corner)) * std.math.pi / 2;
        const next = (corner + 1) % 4;
        const a = arc(width, height, r, corner, angle);
        const b = arc(width, height, r, next, angle);
        const ta = translated(arc(target.width, target.height, target_radii[corner], corner, angle), target);
        const tb = translated(arc(target.width, target.height, target_radii[next], next, angle), target);
        const steps: usize = if (curved[corner]) curve_steps else 1;
        for (1..steps) |step| {
            var t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            if (!corner_grab) {
                // Include the exact grab point, even if it is off-centre.
                const at = switch (corner) {
                    0 => fraction(pull.anchor.y * height, height, r),
                    1 => 1 - fraction(pull.anchor.x * width, width, r),
                    2 => 1 - fraction(pull.anchor.y * height, height, r),
                    else => fraction(pull.anchor.x * width, width, r),
                };
                t = if (t <= 0.5) at * t * 2 else at + (1 - at) * (t - 0.5) * 2;
            }
            result.append(mix(a, b, t), mix(ta, tb, t), width, height, r, pull);
        }
    }
}

fn arc(width: f32, height: f32, radius: f32, corner: usize, angle: f32) Point {
    return .{ .x = (if (corner < 2) width - radius else radius) + @cos(angle) * radius, .y = (if (corner == 0 or corner == 3) radius else height - radius) + @sin(angle) * radius };
}

fn polyPoint(poly: Polygon, i: usize) Point {
    return .{ .x = @floatCast(poly.points[i][0]), .y = @floatCast(poly.points[i][1]) };
}

fn translated(p: Point, target: Box) Point {
    return .{ .x = p.x + target.x, .y = p.y + target.y };
}

fn mix(a: Point, b: Point, t: f32) Point {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

fn fraction(value: f32, extent: f32, radius: f32) f32 {
    return std.math.clamp((value - radius) / @max(1, extent - 2 * radius), 0, 1);
}

fn square(x: f32) f32 {
    return x * x;
}

fn bell(value: f32, at: f32) f32 {
    return square(if (value <= at) value / @max(0.001, at) else (1 - value) / @max(0.001, 1 - at));
}
