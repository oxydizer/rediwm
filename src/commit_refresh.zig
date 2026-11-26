//! Estimate the safe part of a fixed-refresh DRM frame from hardware presentation
//! feedback. Near a vblank boundary, wait for the timestamp itself.
const std = @import("std");
const wlr = @import("wlroots");
const Refresh = @This();
const ms = std.time.ns_per_ms;
const guard = ms / 2;

phase: u64 = 0,
period: u64 = 0,

pub fn presented(self: *Refresh, event: *const wlr.Output.event.Present) void {
    const flags = @import("output/late_render.zig").usable_flags;
    if (!event.presented or event.flags & flags != flags or event.refresh < 2 * ms or
        event.refresh > 100 * ms or event.when.sec < 0)
    {
        self.* = .{};
        return;
    }
    self.* = .{
        .phase = @as(u64, @intCast(event.when.sec)) * std.time.ns_per_s + @as(u64, @intCast(event.when.nsec)),
        .period = @intCast(event.refresh),
    };
}

/// Earliest time to prepare the frame containing target. Both edges of the
/// predicted refresh interval have a guard for timestamp and phase variation.
pub fn wakeAt(self: Refresh, now: u64, target: u64) u64 {
    if (self.period == 0 or now < self.phase or target <= now or target - self.phase > 4 * self.period) return target;
    const intervals = (target - self.phase + guard - 1) / self.period;
    return @min(target, self.phase + intervals * self.period + guard);
}

test "fixed refresh scheduling leaves a guard on both sides of a vblank" {
    const r: Refresh = .{ .phase = 100 * ms, .period = 16 * ms };
    try std.testing.expectEqual(116 * ms + guard, r.wakeAt(110 * ms, 120 * ms));
    try std.testing.expectEqual(116 * ms, r.wakeAt(101 * ms, 116 * ms));
    try std.testing.expectEqual(100 * ms + guard, r.wakeAt(103 * ms, 115 * ms));
    try std.testing.expectEqual(200 * ms, r.wakeAt(175 * ms, 200 * ms));
    try std.testing.expectEqual(120 * ms, (Refresh{}).wakeAt(101 * ms, 120 * ms));
    try std.testing.expectEqual(std.math.maxInt(u64), r.wakeAt(110 * ms, std.math.maxInt(u64)));
}
