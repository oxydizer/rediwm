//! Search-field caret motion with deadline-only blinking and glide frames.
const std = @import("std");
const input = @import("ui").input;
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 1.5, h: f32 = 18 };
/// How far the line holding the caret is from rest while lines glide after an
/// edit (`reflow.zig`): the caret rides along, solid, instead of animating itself.
pub const Shift = struct { dx: f32 = 0, dy: f32 = 0, active: bool = false };
pub const Caret = struct {
    motion: input.Caret = .{},
    /// Where the caret is drawn; `rest` is where it sits once lines stop moving.
    box: Rect = .{},
    rest: Rect = .{},
    visible: bool = false,
    deadline_ms: ?i64 = null,

    pub fn update(self: *Caret, now: i64, active: bool, restart: bool, target: Rect, snap: bool, shift: Shift) bool {
        const previous = self.box;
        const was_visible = self.visible;
        if (restart) self.motion.noteEdit(now);
        // A different line, viewport or field must never sweep through text.
        if (snap or !active or target.y != self.rest.y or target.h != self.rest.h) self.motion.snap = true;
        self.motion.track(now, target.x);
        self.rest = target;
        self.box = target;
        self.box.x = self.motion.offset(now) + shift.dx;
        self.box.y = target.y + shift.dy;
        self.visible = active and (shift.active or self.motion.visible(now));
        self.deadline_ms = null;
        if (active) {
            if (shift.active or self.motion.moving(now)) {
                self.deadline_ms = now + 8;
            } else if (input.caret_config.blink_ms >= 2 and !self.motion.blinkExpired(now)) {
                const half: i64 = @intCast(input.caret_config.blink_ms / 2);
                const origin = self.motion.last_edit_ms;
                self.deadline_ms = origin + (@divFloor(@max(0, now - origin), half) + 1) * half;
                if (input.caret_config.blink_timeout_s > 0) self.deadline_ms = @min(self.deadline_ms.?, origin + @as(i64, input.caret_config.blink_timeout_s) * 1000);
            }
        }
        return was_visible != self.visible or (self.visible and !std.meta.eql(previous, self.box));
    }
    pub fn timeout(self: Caret, now: i64, other: c_int) c_int {
        const deadline = self.deadline_ms orelse return other;
        const remaining: c_int = @intCast(std.math.clamp(deadline - now, 0, std.math.maxInt(c_int)));
        return if (other < 0) remaining else @min(remaining, other);
    }
};

test "caret glides like search, snaps lines and bursts, and stops waking on blur and idle" {
    var caret: Caret = .{};
    const target: Rect = .{ .x = 10, .y = 40 };
    try std.testing.expect(caret.update(100, true, true, target, true, .{}));
    try std.testing.expectEqual(@as(c_int, 530), caret.timeout(100, -1));
    try std.testing.expect(caret.update(630, true, false, target, false, .{}));
    try std.testing.expect(!caret.visible);
    var next = target;
    next.x = 30;
    _ = caret.update(700, true, true, next, false, .{});
    _ = caret.update(720, true, false, next, false, .{});
    try std.testing.expect(caret.box.x > 10 and caret.box.x < 30);
    try std.testing.expect(caret.visible);
    try std.testing.expect(caret.timeout(720, -1) <= 8);
    next.x = 40;
    _ = caret.update(730, true, true, next, false, .{});
    try std.testing.expectEqual(next.x, caret.box.x); // repeat burst catches up
    next.y = 60;
    next.x = 10;
    _ = caret.update(900, true, true, next, false, .{});
    try std.testing.expectEqual(next, caret.box);
    _ = caret.update(10_900, true, false, next, false, .{});
    try std.testing.expect(caret.visible and caret.deadline_ms == null);
    _ = caret.update(10_901, false, true, next, false, .{});
    try std.testing.expect(!caret.visible and caret.deadline_ms == null);
}

test "a caret riding a gliding line follows it, stays solid and wakes the loop" {
    var caret: Caret = .{};
    const target: Rect = .{ .x = 16, .y = 60 };
    _ = caret.update(100, true, true, target, true, .{});
    // Enter at the end of a line: the line starts far right and one row up.
    _ = caret.update(2000, true, true, target, false, .{ .dx = 200, .dy = -18, .active = true });
    try std.testing.expectEqual(@as(f32, 216), caret.box.x);
    try std.testing.expectEqual(@as(f32, 42), caret.box.y);
    try std.testing.expect(caret.visible);
    try std.testing.expect(caret.timeout(2000, -1) <= 8);
    // The line arrives; the caret rests on its target and blinks again.
    _ = caret.update(2100, true, false, target, false, .{});
    try std.testing.expectEqual(target, caret.box);
    try std.testing.expect(caret.timeout(2100, -1) > 8);
}

test "disabled blink is solid and zero idle timeout blinks indefinitely" {
    const saved = input.caret_config;
    defer input.caret_config = saved;
    input.caret_config.blink_ms = 0;
    var caret: Caret = .{};
    _ = caret.update(100, true, true, .{}, true, .{});
    try std.testing.expect(caret.visible and caret.deadline_ms == null);
    input.caret_config = .{ .blink_timeout_s = 0 };
    _ = caret.update(0, true, true, .{}, true, .{});
    _ = caret.update(106_530, true, false, .{}, false, .{});
    try std.testing.expect(!caret.visible and caret.deadline_ms != null);
}
