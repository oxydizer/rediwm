//! Deadline-driven blink: hold solid while editing, stop waking after inactivity.
const std = @import("std");
pub const Blink = struct {
    cycle_ms: u32 = 1060,
    idle_ms: u32 = 10_000,
    origin_ms: i64 = 0,
    visible: bool = false,
    deadline_ms: ?i64 = null,

    pub fn update(self: *Blink, now: i64, active: bool, restart: bool) bool {
        if (restart) self.origin_ms = now;
        const previous = self.visible;
        self.deadline_ms = null;
        self.visible = active;
        const elapsed = @max(0, now - self.origin_ms);
        const half: i64 = @intCast(self.cycle_ms / 2);
        if (active and half > 0 and (self.idle_ms == 0 or elapsed < self.idle_ms)) {
            self.visible = @mod(@divFloor(elapsed, half), 2) == 0;
            self.deadline_ms = self.origin_ms + (@divFloor(elapsed, half) + 1) * half;
            if (self.idle_ms > 0) self.deadline_ms = @min(self.deadline_ms.?, self.origin_ms + self.idle_ms);
        }
        return previous != self.visible;
    }
    pub fn timeout(self: Blink, now: i64, other: c_int) c_int {
        const deadline = self.deadline_ms orelse return other;
        const remaining: c_int = @intCast(std.math.clamp(deadline - now, 0, std.math.maxInt(c_int)));
        return if (other < 0) remaining else @min(remaining, other);
    }
};

test "blink deadlines reset on activity and stop on blur and idle" {
    var b: Blink = .{};
    try std.testing.expect(b.update(100, true, true));
    try std.testing.expectEqual(@as(c_int, 530), b.timeout(100, -1));
    try std.testing.expect(b.update(630, true, false));
    try std.testing.expect(!b.visible);
    try std.testing.expect(b.update(700, true, true));
    try std.testing.expect(b.visible);
    try std.testing.expectEqual(@as(c_int, 10), b.timeout(700, 10));
    _ = b.update(10_700, true, false);
    try std.testing.expect(b.visible and b.deadline_ms == null);
    _ = b.update(10_701, false, true);
    try std.testing.expect(!b.visible and b.deadline_ms == null);
}
test "disabled blink is solid and zero idle timeout blinks indefinitely" {
    var b: Blink = .{ .cycle_ms = 0 };
    _ = b.update(100, true, true);
    try std.testing.expect(b.visible and b.deadline_ms == null);
    b = .{ .idle_ms = 0 };
    _ = b.update(0, true, true);
    _ = b.update(106_530, true, false);
    try std.testing.expect(!b.visible and b.deadline_ms != null);
}
