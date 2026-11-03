//! Outward glow following the frame outline, using the optional ribbon pass.
const std = @import("std");
const ribbon = @import("ribbon.zig");
const shape = @import("ui").window_shape;

pub fn mesh(width: f32, height: f32, radius: f32, polygon: ?shape.Resolved, reach: f32, strength: f32, preset: ribbon.Preset) ribbon.Geometry {
    var result: ribbon.Geometry = .{};
    if (width <= 0 or height <= 0 or reach <= 0 or strength <= 0) return result;
    result.mesh.edge = 1;
    result.mesh.color = preset.color;
    result.mesh.core_color = preset.core_color;
    result.mesh.color[3] *= preset.opacity;
    result.mesh.core_color[3] *= preset.opacity;
    if (polygon) |poly| {
        var area: f64 = 0;
        for (poly.points[0..poly.count], 0..) |p, i| {
            const next = poly.points[(i + 1) % poly.count];
            area += p[0] * next[1] - next[0] * p[1];
        }
        const winding: f32 = if (area >= 0) 1 else -1;
        for (poly.points[0..poly.count], 0..) |p, i| {
            const prev = poly.points[(i + poly.count - 1) % poly.count];
            const next = poly.points[(i + 1) % poly.count];
            const a = normal(p[0] - prev[0], p[1] - prev[1], winding);
            const b = normal(next[0] - p[0], next[1] - p[1], winding);
            // Bound miters at acute corners so glow and damage stay local.
            const divisor = @max(0.5, 1 + a[0] * b[0] + a[1] * b[1]);
            pair(&result, @floatCast(p[0]), @floatCast(p[1]), (a[0] + b[0]) / divisor, (a[1] + b[1]) / divisor, reach, strength);
        }
    } else {
        const r = std.math.clamp(radius, 0, @min(width, height) / 2);
        const centers = [4][2]f32{ .{ width - r, r }, .{ width - r, height - r }, .{ r, height - r }, .{ r, r } };
        for (centers, 0..) |center, corner| {
            for (0..9) |step| {
                const angle = (@as(f32, @floatFromInt(corner)) - 1 + @as(f32, @floatFromInt(step)) / 8) * (std.math.pi / 2.0);
                const nx = @cos(angle);
                const ny = @sin(angle);
                pair(&result, center[0] + nx * r, center[1] + ny * r, nx, ny, reach, strength);
            }
        }
    }
    // Close the strip with exactly the first pair, avoiding a seam at the join.
    result.mesh.vertices[result.mesh.count] = result.mesh.vertices[0];
    result.mesh.vertices[result.mesh.count + 1] = result.mesh.vertices[1];
    result.mesh.count += 2;
    result.enclose();
    return result;
}

fn normal(dx: f64, dy: f64, winding: f32) [2]f32 {
    const length = @max(0.001, std.math.hypot(dx, dy));
    return .{ @as(f32, @floatCast(dy / length)) * winding, -@as(f32, @floatCast(dx / length)) * winding };
}

/// A glow centred on the fill's outer perimeter, with a small inward overlap.
/// Unlike a window frame this edge has no solid ring underneath its glow.
pub fn path(source: []const ribbon.Point, reach: f32, strength: f32, preset: ribbon.Preset) ribbon.Geometry {
    var result: ribbon.Geometry = .{};
    if (source.len < 3 or source.len > 63 or reach <= 0 or strength <= 0) return result;
    var unique: [63]ribbon.Point = undefined;
    var len: usize = 0;
    for (source) |point| {
        if (len > 0 and near(unique[len - 1], point)) continue;
        unique[len] = point;
        len += 1;
    }
    if (len > 1 and near(unique[0], unique[len - 1])) len -= 1;
    if (len < 3) return result;
    const points = unique[0..len];
    result.mesh.edge = 1;
    result.mesh.color = preset.color;
    result.mesh.core_color = preset.core_color;
    result.mesh.color[3] *= preset.opacity;
    result.mesh.core_color[3] *= preset.opacity;
    var area: f64 = 0;
    for (points, 0..) |p, i| {
        const next = points[(i + 1) % points.len];
        area += @as(f64, p.x) * next.y - @as(f64, next.x) * p.y;
    }
    const winding: f32 = if (area >= 0) 1 else -1;
    for (points, 0..) |p, i| {
        const prev = points[(i + points.len - 1) % points.len];
        const next = points[(i + 1) % points.len];
        const a = normal(p.x - prev.x, p.y - prev.y, winding);
        const b = normal(next.x - p.x, next.y - p.y, winding);
        const divisor = @max(0.5, 1 + a[0] * b[0] + a[1] * b[1]);
        const nx = (a[0] + b[0]) / divisor;
        const ny = (a[1] + b[1]) / divisor;
        const inward = @min(3, reach * 0.15);
        const at = result.mesh.count;
        result.mesh.vertices[at] = .{ p.x - nx * inward, p.y - ny * inward, -inward / reach, strength };
        result.mesh.vertices[at + 1] = .{ p.x + nx * reach, p.y + ny * reach, 1, strength };
        result.mesh.count += 2;
    }
    result.mesh.vertices[result.mesh.count] = result.mesh.vertices[0];
    result.mesh.vertices[result.mesh.count + 1] = result.mesh.vertices[1];
    result.mesh.count += 2;
    result.enclose();
    return result;
}

fn near(a: ribbon.Point, b: ribbon.Point) bool {
    return @abs(a.x - b.x) < 0.001 and @abs(a.y - b.y) < 0.001;
}

fn pair(result: *ribbon.Geometry, x: f32, y: f32, nx: f32, ny: f32, reach: f32, strength: f32) void {
    const i = result.mesh.count;
    result.mesh.vertices[i] = .{ x, y, 0, strength };
    result.mesh.vertices[i + 1] = .{ x + nx * reach, y + ny * reach, 1, strength };
    result.mesh.count += 2;
}
