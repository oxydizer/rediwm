//! When an output carries an HDR10 signal, and
//! how a refusal is remembered. Pure, so the decisions are unit-tested;
//! `hdr.zig` applies them to the output and its frame state.

const std = @import("std");

pub const Inputs = struct {
    /// `hdr.linearWanted`: the setting is on and the output blends in linear light.
    linear: bool,
    /// A DRM output: only those can carry the signal.
    drm: bool,
    /// The display and driver take PQ and BT.2020 (wlroots' supported_* bits).
    supported: bool,
    /// On and lit (not blanked or turned off by a client).
    lit: bool,
};

/// What a refusal is remembered for: the display mode and the setting.
pub const Key = struct {
    width: i32 = 0,
    height: i32 = 0,
    refresh: i32 = 0,
    on: bool = false,
};

pub const State = struct {
    key: Key = .{},
    /// The driver would not take the signal in this mode: no more attempts
    /// until the mode or the setting changes.
    refused: bool = false,
    /// Commits that carried a switch on and failed, in a row.
    failures: u8 = 0,
    /// The switch this frame's commit carries: on, off, or none.
    pending: ?bool = null,
};

pub fn wanted(in: Inputs) bool {
    return in.linear and in.drm and in.supported and in.lit;
}

/// Before a frame: the switch its commit should carry, if any.
pub fn step(state: *State, key: Key, in: Inputs, active: bool) ?bool {
    if (!std.meta.eql(key, state.key)) state.* = .{ .key = key };
    state.pending = null;
    const want = wanted(in) and !state.refused;
    if (want == active) return null;
    state.pending = want;
    return want;
}

/// The test commit for the switch on failed in every format.
pub fn refuse(state: *State) void {
    state.refused = true;
    state.pending = null;
}

/// A commit that carried `pending` was made; `active` is what the output
/// reports afterwards. A switch on that the driver accepts but does not show,
/// or that fails twice, is refused for this mode. A switch off is retried
/// until it holds: the output must not stay in HDR against the setting.
pub fn committed(state: *State, success: bool, active: bool) void {
    const asked = state.pending orelse return;
    state.pending = null;
    if (success and active == asked) {
        state.failures = 0;
        return;
    }
    if (!asked) return;
    state.failures +|= 1;
    if (success or state.failures >= 2) state.refused = true;
}

const on: Inputs = .{ .linear = true, .drm = true, .supported = true, .lit = true };
const mode: Key = .{ .width = 3840, .height = 2160, .refresh = 60000, .on = true };

test "the signal needs the setting, DRM, support and a lit output" {
    try std.testing.expect(wanted(on));
    inline for (.{ "linear", "drm", "supported", "lit" }) |field| {
        var in = on;
        @field(in, field) = false;
        try std.testing.expect(!wanted(in));
    }
}

test "a switch is carried until the output reports it" {
    var s: State = .{};
    try std.testing.expectEqual(@as(?bool, true), step(&s, mode, on, false));
    committed(&s, true, true);
    try std.testing.expectEqual(@as(?bool, null), step(&s, mode, on, true));
    var off = on;
    off.linear = false;
    try std.testing.expectEqual(@as(?bool, false), step(&s, .{ .width = 3840, .height = 2160, .refresh = 60000 }, off, true));
    committed(&s, true, false);
    try std.testing.expectEqual(@as(?bool, null), step(&s, .{ .width = 3840, .height = 2160, .refresh = 60000 }, off, false));
}

test "a refusal holds for the mode and setting, and lifts when either changes" {
    var s: State = .{};
    _ = step(&s, mode, on, false);
    refuse(&s);
    try std.testing.expectEqual(@as(?bool, null), step(&s, mode, on, false));
    var other = mode;
    other.refresh = 120000;
    try std.testing.expectEqual(@as(?bool, true), step(&s, other, on, false));
    refuse(&s);
    var toggled = other;
    toggled.on = false;
    _ = step(&s, toggled, on, false);
    try std.testing.expectEqual(@as(?bool, true), step(&s, other, on, false));
}

test "failed or ignored switches on are refused; a switch off keeps trying" {
    var s: State = .{};
    _ = step(&s, mode, on, false);
    committed(&s, false, false);
    try std.testing.expect(!s.refused);
    _ = step(&s, mode, on, false);
    committed(&s, false, false);
    try std.testing.expect(s.refused);
    // Accepted but not shown: refused at once.
    var t: State = .{};
    _ = step(&t, mode, on, false);
    committed(&t, true, false);
    try std.testing.expect(t.refused);
    // Off fails: still asked next frame.
    var u: State = .{ .key = mode };
    var off = on;
    off.lit = false;
    try std.testing.expectEqual(@as(?bool, false), step(&u, mode, off, true));
    committed(&u, false, true);
    try std.testing.expect(!u.refused);
    try std.testing.expectEqual(@as(?bool, false), step(&u, mode, off, true));
}
