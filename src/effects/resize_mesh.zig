//! A filled elastic membrane and its glow, built from the same paired outlines.
const ribbon = @import("ribbon.zig");
const border = @import("border.zig");
const outline = @import("resize_outline.zig");
const Polygon = @import("ui").window_shape.Resolved;
pub const Box = outline.Box;
pub const Pull = outline.Pull;
pub const Meshes = struct { fill: ribbon.Geometry = .{}, edge: ribbon.Geometry = .{} };

pub fn build(width: f32, height: f32, target: Box, radius: f32, current_polygon: ?Polygon, target_polygon: ?Polygon, pull: Pull, reach: f32, strength: f32, phase: f32, preset: ribbon.Preset) Meshes {
    var result: Meshes = .{};
    if (strength <= 0 or width <= 0 or height <= 0 or target.width <= 0 or target.height <= 0) return result;
    if (@abs(target.x) < 0.25 and @abs(target.y) < 0.25 and
        @abs(target.width - width) < 0.25 and @abs(target.height - height) < 0.25) return result;
    const points = outline.resolve(width, height, target, radius, current_polygon, target_polygon, pull, preset.quality);
    if (points.len < 3) return result;
    const band = &result.fill;
    band.mesh.edge = 3;
    band.mesh.fade = .{ strength, phase };
    band.mesh.color = preset.color;
    band.mesh.core_color = preset.core_color;
    band.mesh.color[3] *= preset.opacity;
    band.mesh.core_color[3] *= preset.opacity;
    for (0..points.len + 1) |i| {
        const index = i % points.len;
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(points.len));
        const p = points.current[index];
        const q = points.leading[index];
        band.mesh.vertices[i * 2] = .{ p.x, p.y, -1, t };
        band.mesh.vertices[i * 2 + 1] = .{ q.x, q.y, 1, t };
    }
    band.mesh.count = @intCast((points.len + 1) * 2);
    band.enclose();
    result.edge = border.path(points.leading[0..points.len], reach, strength, preset);
    return result;
}

test {
    _ = @import("resize_mesh_tests.zig");
}
