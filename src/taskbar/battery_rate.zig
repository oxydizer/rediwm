//! Remaining time from how fast the battery's level actually moves.
//!
//! The firmware's present rate (`POWER_NOW`, `CURRENT_NOW`) is a short-window
//! value. One reading per minute tick lands wherever the load happens to be,
//! and on a bursty desktop that is often an idle gap: level / rate then
//! promises hours a real session never gets (and level / rate over a noisy
//! rate skews long even when the gaps are random). The level itself
//! integrates every burst, so the slope of recent readings is the real drain.
//! The reported rate, averaged as power rather than as time, covers the first
//! minutes after a plug change and firmware whose level moves in coarse steps.
const std = @import("std");
const battery = @import("battery.zig");
const Self = @This();

/// Readings older than this no longer shape the estimate.
pub const window_s: f64 = 15 * 60;
/// A longer gap between readings (suspend, an inactive session) starts over:
/// the level barely moves while suspended, which would read as a tiny drain.
pub const max_gap_s: f64 = 3 * 60;
/// The slope needs this much history and this many level changes before it
/// is trusted; a level that moves in 1 % steps needs a few of them.
pub const min_span_s: f64 = 4 * 60;
pub const min_changes: u32 = 3;
const capacity = 64;

pub const Direction = enum { charging, discharging };

const Sample = struct { t: f64, now: f64, rate: ?f64 };

samples: [capacity]Sample = undefined,
len: usize = 0,
direction: ?Direction = null,
unit: ?battery.Level.Unit = null,

pub fn reset(self: *Self) void {
    self.* = .{};
}

pub fn directionOf(state: battery.State) ?Direction {
    if (state.charging) return .charging;
    if (state.discharging) return .discharging;
    return null;
}

/// Records a reading taken at `t` seconds on the boot clock and returns the
/// minutes until empty (discharging) or full (charging), or null when the
/// battery is neither or the level cannot say.
pub fn feed(self: *Self, t: f64, level: ?battery.Level, dir: ?Direction) ?u32 {
    const reading = level orelse return self.clear();
    const d = dir orelse return self.clear();
    if (self.len > 0) {
        const last = self.samples[self.len - 1];
        if (self.direction != d or self.unit != reading.unit or t < last.t or t - last.t > max_gap_s) self.reset();
    }
    self.direction = d;
    self.unit = reading.unit;
    var keep: usize = 0;
    while (keep < self.len and t - self.samples[keep].t > window_s) keep += 1;
    if (self.len - keep == capacity) keep += 1;
    std.mem.copyForwards(Sample, self.samples[0 .. self.len - keep], self.samples[keep..self.len]);
    self.len -= keep;
    self.samples[self.len] = .{ .t = t, .now = reading.now, .rate = reading.rate };
    self.len += 1;

    const rate = self.observedRate() orelse self.reportedRate() orelse return null;
    const remaining = switch (d) {
        .discharging => reading.now,
        .charging => (reading.full orelse return null) - reading.now,
    };
    if (remaining <= 0) return null;
    return battery.minutesFromHours(remaining / rate);
}

fn clear(self: *Self) ?u32 {
    self.reset();
    return null;
}

/// Least-squares slope of the level over the window, per hour, positive in
/// the direction of travel.
fn observedRate(self: *const Self) ?f64 {
    const samples = self.samples[0..self.len];
    if (samples.len < 2 or samples[samples.len - 1].t - samples[0].t < min_span_s) return null;
    var changes: u32 = 0;
    for (samples[1..], samples[0 .. samples.len - 1]) |b, a| {
        if (b.now != a.now) changes += 1;
    }
    if (changes < min_changes) return null;
    const n: f64 = @floatFromInt(samples.len);
    var mean_t: f64 = 0;
    var mean_level: f64 = 0;
    for (samples) |s| {
        mean_t += s.t / n;
        mean_level += s.now / n;
    }
    var cov: f64 = 0;
    var variance: f64 = 0;
    for (samples) |s| {
        cov += (s.t - mean_t) * (s.now - mean_level);
        variance += (s.t - mean_t) * (s.t - mean_t);
    }
    if (variance <= 0) return null;
    const per_hour = cov / variance * 3600;
    const travel = if (self.direction == .discharging) -per_hour else per_hour;
    return if (travel > 0 and std.math.isFinite(travel)) travel else null;
}

/// Mean of the firmware's present rates over the window.
fn reportedRate(self: *const Self) ?f64 {
    var sum: f64 = 0;
    var count: f64 = 0;
    for (self.samples[0..self.len]) |s| if (s.rate) |r| {
        sum += r;
        count += 1;
    };
    return if (count > 0 and sum > 0) sum / count else null;
}

test {
    _ = @import("battery_rate_tests.zig");
}
