//! A single border shimmer on connection, driven by the normal frame clock.
const std = @import("std");
const anim = @import("ui").anim;
const battery = @import("battery.zig");

pub const Highlight = struct {
    sweep: anim.Anim = .{ .to = 1 },

    pub fn update(self: *Highlight, previous: battery.State, next: battery.State, now_ms: i64) void {
        if (next.percent == null or !next.plugged) {
            self.sweep = .{ .to = 1 };
        } else if (!previous.plugged) {
            self.sweep = .initDuration(0, 1, now_ms, 1100, .flip_bezier);
        }
    }
};

/// The sweep's band along the frame; the badge artwork owns the shape.
pub const intensity = @import("ui").widgets.battery.shimmerIntensity;

test "connection shimmer plays once, cancels on unplug, and can restart" {
    var h: Highlight = .{};
    const unplugged: battery.State = .{ .percent = 82 };
    const plugged: battery.State = .{ .percent = 82, .plugged = true };
    try std.testing.expect(h.sweep.settled(100));
    h.update(unplugged, plugged, 100);
    try std.testing.expect(!h.sweep.settled(650));
    const before = h.sweep.value(650);
    h.update(plugged, .{ .percent = 83, .plugged = true }, 650);
    try std.testing.expectEqual(before, h.sweep.value(650));
    try std.testing.expect(h.sweep.settled(1200));
    try std.testing.expectEqual(@as(f32, 0), intensity(h.sweep.value(1200), 112, 112));
    h.update(plugged, unplugged, 700);
    try std.testing.expectEqual(@as(f32, 1), h.sweep.value(700));
    h.update(unplugged, plugged, 800);
    try std.testing.expect(!h.sweep.settled(900));
    h.update(plugged, .{}, 950);
    try std.testing.expect(h.sweep.settled(950));
}

test "shimmer travels left to right and respects reduced motion" {
    try std.testing.expect(intensity(0.2, 9, 112) > intensity(0.2, 100, 112));
    try std.testing.expect(intensity(0.8, 100, 112) > intensity(0.8, 9, 112));
    anim.setReducedMotion(true);
    defer anim.setReducedMotion(false);
    var h: Highlight = .{};
    h.update(.{ .percent = 50 }, .{ .percent = 50, .plugged = true }, 100);
    try std.testing.expect(h.sweep.settled(100));
    try std.testing.expectEqual(@as(f32, 0), intensity(h.sweep.value(100), 56, 112));
}
