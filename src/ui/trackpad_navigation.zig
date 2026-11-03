//! Classifies horizontal finger scrolling as app navigation.
const std = @import("std");

pub const Direction = enum { back, forward };

pub const Result = struct {
    direction: ?Direction,
    horizontal_delta: f64,
};

pub const Gesture = struct {
    horizontal: f64 = 0,
    vertical: f64 = 0,

    pub const minimum_horizontal_distance: f64 = 80.0;
    pub const horizontal_dominance: f64 = 1.5;

    pub fn reset(self: *Gesture) void {
        self.* = .{};
    }

    /// Accumulates one finger-source axis delta.
    pub fn add(self: *Gesture, horizontal_axis: bool, delta: f64) void {
        if (horizontal_axis) {
            self.horizontal += delta;
        } else {
            self.vertical += delta;
        }
    }

    /// A vertical stop clears a vertical-only gesture. A horizontal stop
    /// classifies the complete movement and returns its original delta so
    /// callers can preserve ordinary horizontal scrolling when it is not
    /// a navigation gesture.
    pub fn stop(self: *Gesture, horizontal_axis: bool) ?Result {
        if (!horizontal_axis) {
            if (self.horizontal == 0) self.vertical = 0;
            return null;
        }

        const horizontal = self.horizontal;
        const direction: ?Direction = if (
            @abs(horizontal) >= minimum_horizontal_distance and
                @abs(horizontal) > @abs(self.vertical) * horizontal_dominance
        )
            (if (horizontal < 0) .back else .forward)
        else
            null;

        self.reset();
        return .{
            .direction = direction,
            .horizontal_delta = horizontal,
        };
    }
};

test "rightward finger movement navigates back" {
    var gesture: Gesture = .{};
    gesture.add(true, -110);
    gesture.add(false, 12);
    const result = gesture.stop(true).?;
    try std.testing.expectEqual(Direction.back, result.direction.?);
}

test "leftward finger movement navigates forward" {
    var gesture: Gesture = .{};
    gesture.add(true, 105);
    const result = gesture.stop(true).?;
    try std.testing.expectEqual(Direction.forward, result.direction.?);
}

test "short horizontal movement remains scrolling" {
    var gesture: Gesture = .{};
    gesture.add(true, 50);
    const result = gesture.stop(true).?;
    try std.testing.expectEqual(@as(?Direction, null), result.direction);
    try std.testing.expectEqual(@as(f64, 50), result.horizontal_delta);
}

test "vertical-dominant movement remains scrolling" {
    var gesture: Gesture = .{};
    gesture.add(true, -100);
    gesture.add(false, 90);
    const result = gesture.stop(true).?;
    try std.testing.expectEqual(@as(?Direction, null), result.direction);
}

test "vertical-only stop does not contaminate the next gesture" {
    var gesture: Gesture = .{};
    gesture.add(false, 140);
    try std.testing.expect(gesture.stop(false) == null);
    gesture.add(true, -100);
    const result = gesture.stop(true).?;
    try std.testing.expectEqual(Direction.back, result.direction.?);
}
