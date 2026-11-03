//! Stable trailing-side selection. Small diagonal changes must not reset trails.
const std = @import("std");
const Self = @This();

value: u2 = 0,
x: f32 = 0,
y: f32 = 0,
initialized: bool = false,

pub fn update(self: *Self, dx: f32, dy: f32) bool {
    const distance = std.math.hypot(dx, dy);
    if (distance < 0.5) return false;
    // Average over a short distance, independent of event and refresh rates.
    // No clock advances this filter when the pointer is stationary.
    const blend = if (self.initialized) 1 - @exp(-distance / 12) else 1;
    self.x += (dx / distance - self.x) * blend;
    self.y += (dy / distance - self.y) * blend;
    const horizontal = @abs(self.x) >= @abs(self.y);
    const next: u2 = if (horizontal) (if (self.x >= 0) @as(u2, 0) else 1) else (if (self.y >= 0) @as(u2, 2) else 3);
    if (self.initialized and horizontal != (self.value < 2)) {
        const previous_axis = if (self.value < 2) @abs(self.x) else @abs(self.y);
        const next_axis = if (horizontal) @abs(self.x) else @abs(self.y);
        if (next_axis < previous_axis * 1.4) return false;
    }
    self.initialized = true;
    const changed = self.value != next;
    self.value = next;
    return changed;
}

test {
    _ = @import("move_heading_tests.zig");
}
