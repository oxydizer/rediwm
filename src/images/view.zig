const std = @import("std");
pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    pub fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }
};
pub const View = struct {
    rotation: u2 = 0,
    fitting: bool = true,
    zoom: f64 = 1,
    pan_x: f64 = 0,
    pan_y: f64 = 0,
    pub fn reset(self: *View) void {
        self.* = .{};
    }
    pub fn dimensions(self: View, w: f64, h: f64) [2]f64 {
        return if (self.rotation % 2 == 0) .{ w, h } else .{ h, w };
    }
    pub fn scale(self: View, box: Rect, w: f64, h: f64) f64 {
        const d = self.dimensions(w, h);
        return if (self.fitting) @min(box.w / d[0], box.h / d[1]) else self.zoom;
    }
    pub fn clamp(self: *View, box: Rect, w: f64, h: f64) void {
        const d = self.dimensions(w, h);
        const z = self.scale(box, w, h);
        const dx = @max(0, (d[0] * z - box.w) / 2);
        const dy = @max(0, (d[1] * z - box.h) / 2);
        self.pan_x = std.math.clamp(self.pan_x, -dx, dx);
        self.pan_y = std.math.clamp(self.pan_y, -dy, dy);
    }
    pub fn zoomAt(self: *View, factor: f64, x: f64, y: f64, box: Rect, w: f64, h: f64) void {
        const old = self.scale(box, w, h);
        self.zoom = std.math.clamp(old * factor, 0.01, 32);
        const ratio = self.zoom / old;
        self.pan_x = (x - box.x - box.w / 2) * (1 - ratio) + self.pan_x * ratio;
        self.pan_y = (y - box.y - box.h / 2) * (1 - ratio) + self.pan_y * ratio;
        self.fitting = false;
        self.clamp(box, w, h);
    }
};
test "rotation fit and pointer-anchored zoom" {
    const box = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var v: View = .{};
    try std.testing.expectEqual(@as(f64, 0.5), v.scale(box, 800, 400));
    v.rotation = 1;
    try std.testing.expectEqual(@as(f64, 0.375), v.scale(box, 800, 400));
    v.reset();
    v.zoomAt(2, 250, 150, box, 800, 400);
    try std.testing.expectEqual(@as(f64, 1), v.zoom);
    try std.testing.expectEqual(@as(f64, -50), v.pan_x);
    v.pan_y = 10000;
    v.clamp(box, 800, 400);
    try std.testing.expectEqual(@as(f64, 50), v.pan_y);
    v.reset();
    try std.testing.expect(v.fitting);
}
