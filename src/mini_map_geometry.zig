//! Pure world ↔ mini-map geometry. Map coordinates start at the grid edge.
const std = @import("std");
const camera = @import("camera.zig");
pub const Position = @import("config").types.MiniMapPosition;
pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    pub fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }
};
pub const Map = struct {
    world: Rect,
    width: f64,
    height: f64,
    scale: f64,
    pub fn init(bounds: camera.Bounds, zoom: f64, max_w: f64, max_h: f64) Map {
        const w = @max(bounds.width + 2 * bounds.max_x, bounds.width / zoom);
        const h = @max(bounds.height + 2 * bounds.max_y, bounds.height / zoom);
        const scale = @min(max_w / @max(1, w), max_h / @max(1, h));
        return .{ .world = .{ .x = bounds.origin_x + (bounds.width - w) / 2, .y = bounds.origin_y + (bounds.height - h) / 2, .w = w, .h = h }, .width = w * scale, .height = h * scale, .scale = scale };
    }
    pub fn project(m: Map, r: Rect) Rect {
        return .{ .x = (r.x - m.world.x) * m.scale, .y = (r.y - m.world.y) * m.scale, .w = r.w * m.scale, .h = r.h * m.scale };
    }
    pub fn point(m: Map, x: f64, y: f64) camera.Vec {
        return .{ .x = m.world.x + x / m.scale, .y = m.world.y + y / m.scale };
    }
    pub fn viewport(m: Map, cam: camera.Camera, bounds: camera.Bounds, output: Rect) Rect {
        const p = cam.toWorld(bounds, output.x, output.y);
        return m.project(.{ .x = p.x, .y = p.y, .w = output.w / cam.zoom(), .h = output.h / cam.zoom() });
    }
    pub fn drag(m: Map, cam: camera.Camera, bounds: camera.Bounds, output: Rect, x: f64, y: f64, anchor: camera.Vec) camera.Camera {
        const p = m.point(x - anchor.x, y - anchor.y);
        var result = cam;
        result.offset_x = p.x - bounds.origin_x - (output.x - bounds.origin_x) / cam.zoom();
        result.offset_y = p.y - bounds.origin_y - (output.y - bounds.origin_y) / cam.zoom();
        result.clamp(bounds);
        return result;
    }
};

test "map drag round trips at negative origins and fractional zoom" {
    const b = camera.computeGridBounds(-1920, -200, 3200, 1080, 4, 2);
    const out: Rect = .{ .x = -1920, .y = -200, .w = 1920, .h = 1080 };
    const cam: camera.Camera = .{ .offset_x = 123, .offset_y = -321, .zoom_value = 0.85 };
    const m = Map.init(b, cam.zoom(), 220, 140);
    const v = m.viewport(cam, b, out);
    const anchor: camera.Vec = .{ .x = v.w / 3, .y = v.h / 4 };
    const same = m.drag(cam, b, out, v.x + anchor.x, v.y + anchor.y, anchor);
    try std.testing.expectApproxEqAbs(cam.offset_x, same.offset_x, 0.000001);
    try std.testing.expectApproxEqAbs(cam.offset_y, same.offset_y, 0.000001);
    const moved = m.drag(cam, b, out, v.x + anchor.x + 10, v.y + anchor.y, anchor);
    try std.testing.expectApproxEqAbs(cam.offset_x + 10 / m.scale, moved.offset_x, 0.000001);
    const clamped = m.drag(cam, b, out, 10000, -10000, anchor);
    const limits = camera.offsetLimits(b, cam.zoom());
    try std.testing.expectEqual(limits.hi_x, clamped.offset_x);
    try std.testing.expectEqual(limits.lo_y, clamped.offset_y);
}

test "map fits odd even narrow and expanded canvases and large viewports" {
    for ([_]u32{ 1, 2, 3, 10 }) |cols| {
        var b = camera.computeGridBounds(0, 0, 1280, 720, cols, 1);
        for ([_]f64{ 0.25, 0.85, 1, 2 }) |z| {
            const m = Map.init(b, z, 220, 140);
            try std.testing.expect(m.width <= 220.000001 and m.height <= 140.000001);
            var cam: camera.Camera = .{ .zoom_value = z };
            cam.clamp(b);
            const v = m.viewport(cam, b, .{ .x = 0, .y = 0, .w = 1280, .h = 720 });
            try std.testing.expect(v.x >= -0.000001 and v.y >= -0.000001);
            try std.testing.expect(v.x + v.w <= m.width + 0.000001);
            try std.testing.expect(v.y + v.h <= m.height + 0.000001);
        }
        b.max_x += 5000;
        const m = Map.init(b, 1, 220, 140);
        try std.testing.expectEqual(b.width + 2 * b.max_x, m.world.w);
    }
}
