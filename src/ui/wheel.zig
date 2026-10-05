// Mouse-wheel acceleration: a fast run of notches moves further per notch.
// Shared by the shell's scroll containers and the notches forwarded to
// clients (`input/client_wheel.zig`), so both feel the same.
const std = @import("std");

pub const Accel = struct {
    /// 0 turns acceleration off; larger ramps harder once past the floor.
    gain: f32 = 1.0,
    /// Cap on the per-notch multiplier.
    max: f32 = 5.0,
};

/// Process-wide, like `theme.global`; pushed from `[input]`.
pub var accel: Accel = .{};

/// The rate estimate is a leaky integral of notches with this time constant.
/// Each notch reads it *before* adding itself, so the first of a run is 1x
/// and isolated clicks never accelerate.
const rate_tau_ms: f32 = 100;
/// Notches/s below which there is no acceleration: deliberate clicking,
/// including a whole detent's burst of high-resolution partial notches.
const rate_floor: f32 = 8;
/// Notches/s above the floor that add 1x at gain 1.
const rate_span: f32 = 6;
/// High-resolution wheels split a detent into fragments this close together;
/// they share the detent's multiplier instead of counting each other.
const burst_gap_ms: i64 = 20;

/// One wheel run's speed. Keep one per thing being scrolled, per axis.
pub const Rate = struct {
    /// Notches/s, decayed to `ms`.
    rate: f32 = 0,
    ms: i64 = 0,
    dir: f32 = 0,
    /// The multiplier the current detent was given, and how much of that
    /// detent (in notches) has arrived as high-resolution fragments.
    boost: f32 = 1,
    burst: f32 = 0,

    /// Per-notch distance multiplier for `notches` (signed, fractional for
    /// high-resolution wheels) arriving at `now_ms`. Measures notches over
    /// time, not events: a detent split into four quarters is one notch.
    pub fn multiplier(self: *Rate, notches: f32, now_ms: i64) f32 {
        const dir: f32 = if (notches < 0) -1 else 1;
        const elapsed = @max(0, now_ms - self.ms);
        const same_detent = dir == self.dir and elapsed < burst_gap_ms and self.burst < 1;
        var rate = self.rate * @exp(-@as(f32, @floatFromInt(elapsed)) / rate_tau_ms);
        // Turning around starts a new run.
        if (dir != self.dir) rate = 0;
        self.rate = rate + @abs(notches) * 1000 / rate_tau_ms;
        self.ms = now_ms;
        self.dir = dir;
        if (same_detent) {
            self.burst += @abs(notches);
            return self.boost;
        }
        self.burst = @abs(notches);
        const cfg = accel;
        const extra = cfg.gain * @max(0, rate - rate_floor) / rate_span;
        self.boost = std.math.clamp(1 + extra, 1, @max(1, cfg.max));
        return self.boost;
    }
};
