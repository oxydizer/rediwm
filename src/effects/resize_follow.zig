//! A bounded, monotonic follower for interactive client sizes. Sampling is
//! analytic, so refresh rate and configure acknowledgements do not change it.
const std = @import("std");
const Size = @import("../resize.zig").ClientSize;
const Self = @This();

from: [2]f64,
target: Size,
started: i64,

pub fn init(size: Size, now: i64) Self {
    return .{ .from = .{ @floatFromInt(size.width), @floatFromInt(size.height) }, .target = size, .started = now };
}

pub fn retarget(self: *Self, size: Size, now: i64, speed: f32) void {
    if (std.meta.eql(self.target, size)) return;
    self.from = self.sample(now, speed);
    self.target = size;
    self.started = now;
}

fn sample(self: Self, now: i64, speed: f32) [2]f64 {
    const elapsed = @as(f64, @floatFromInt(@max(0, now - self.started))) * speed;
    const remaining = if (speed <= 0 or elapsed >= 800) 0 else @exp(-elapsed / 110);
    const goal = [2]f64{ @floatFromInt(self.target.width), @floatFromInt(self.target.height) };
    return .{ goal[0] + (self.from[0] - goal[0]) * remaining, goal[1] + (self.from[1] - goal[1]) * remaining };
}

pub fn value(self: Self, now: i64, speed: f32) Size {
    const size = self.sample(now, speed);
    return .{ .width = @intFromFloat(@round(size[0])), .height = @intFromFloat(@round(size[1])) };
}

pub fn pending(self: Self, now: i64, speed: f32) bool {
    return !std.meta.eql(self.value(now, speed), self.target);
}

test {
    _ = @import("resize_follow_tests.zig");
}
