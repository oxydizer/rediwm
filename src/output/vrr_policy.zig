//! Variable refresh policy: whether an output should run at a variable rate,
//! and when a change is made. Plain data and a caller-supplied clock, so the
//! cases are tested without wlroots; `vrr.zig` connects it to an `Output`.
//!
//! `auto` turns adaptive sync on while a game fills the output and off
//! otherwise; `always` keeps it on (the desktop then runs at a variable rate
//! too, which makes some panels flicker at their minimum rate); `off` never.
//! Turning on is immediate. Turning off waits `off_delay_ns`, so Alt+Tab to a
//! chat window and back does not toggle twice.

const std = @import("std");

pub const Mode = @import("config").output_config.AdaptiveSync;

pub const off_delay_ns: u64 = 500 * std.time.ns_per_ms;

pub const Inputs = struct {
    mode: Mode,
    /// A game fills the output (`game.zig`).
    game: bool,
    /// The greeter, or an output that is off: never variable.
    blocked: bool,
};

/// What the configuration asks for now, whether or not the display can.
pub fn wanted(in: Inputs) bool {
    if (in.blocked) return false;
    return switch (in.mode) {
        .off => false,
        .always => true,
        .auto => in.game,
    };
}

pub const Step = struct {
    /// The state to request on the next commit, or null to leave it.
    apply: ?bool = null,
    /// When to look again for a delayed change (a monotonic time).
    wake_ns: ?u64 = null,
};

pub const Debounce = struct {
    /// When wanting off began while on; zero when not waiting.
    off_since_ns: u64 = 0,

    pub fn step(self: *Debounce, want: bool, active: bool, now_ns: u64) Step {
        if (want == active) {
            self.off_since_ns = 0;
            return .{};
        }
        if (want) {
            self.off_since_ns = 0;
            return .{ .apply = true };
        }
        if (self.off_since_ns == 0) self.off_since_ns = now_ns;
        const due = self.off_since_ns + off_delay_ns;
        if (now_ns >= due) {
            self.off_since_ns = 0;
            return .{ .apply = false };
        }
        return .{ .wake_ns = due };
    }
};

test "wanted follows the mode, the game and the greeter" {
    try std.testing.expect(!wanted(.{ .mode = .off, .game = true, .blocked = false }));
    try std.testing.expect(wanted(.{ .mode = .always, .game = false, .blocked = false }));
    try std.testing.expect(wanted(.{ .mode = .auto, .game = true, .blocked = false }));
    try std.testing.expect(!wanted(.{ .mode = .auto, .game = false, .blocked = false }));
    try std.testing.expect(!wanted(.{ .mode = .always, .game = true, .blocked = true }));
}

test "turning on is immediate, turning off waits and a return cancels it" {
    const ms = std.time.ns_per_ms;
    var d: Debounce = .{};
    try std.testing.expectEqual(@as(?bool, true), d.step(true, false, 1000 * ms).apply);
    try std.testing.expectEqual(Step{}, d.step(true, true, 1001 * ms));

    // The game loses focus: off is only due after the delay.
    var s = d.step(false, true, 2000 * ms);
    try std.testing.expectEqual(@as(?bool, null), s.apply);
    try std.testing.expectEqual(@as(?u64, 2500 * ms), s.wake_ns);
    s = d.step(false, true, 2300 * ms);
    try std.testing.expectEqual(@as(?u64, 2500 * ms), s.wake_ns);
    // Focus comes back in time: nothing changes, and the wait is forgotten.
    try std.testing.expectEqual(Step{}, d.step(true, true, 2400 * ms));
    s = d.step(false, true, 3000 * ms);
    try std.testing.expectEqual(@as(?u64, 3500 * ms), s.wake_ns);
    try std.testing.expectEqual(@as(?bool, false), d.step(false, true, 3500 * ms).apply);
    try std.testing.expectEqual(@as(u64, 0), d.off_since_ns);
    try std.testing.expectEqual(Step{}, d.step(false, false, 3600 * ms));
}
