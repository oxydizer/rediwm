//! Late rendering: start a frame as late as the display allows, so input and
//! client commits made while it waits still reach the vblank it targets.
//!
//! This is the decision model: plain data in, a decision out, no wlroots and no
//! clock of its own, so the timing cases are tested with synthetic timelines.
//! `late.zig` connects it to an `Output`.
//!
//! Only a *stream* of frames gains anything. A lone damage event renders at
//! once and is shown at the next vblank either way, so a frame after idle
//! always runs immediately; the stream it starts is then scheduled against the
//! presentation times the display reports.
//!
//! The deadline is `vblank - estimate - margin`:
//!   * estimate: the worst critical path of the last frames, from the start of
//!     a frame to its commit returning, or to the GPU finishing what that
//!     commit waits on (build time plus the GPU's own elapsed time). Commit
//!     time, the KMS submission, is part of the first.
//!   * margin: never below the configured floor; grows when a frame misses its
//!     vblank (fast) and shrinks only after a long clean run (slow).
//! A miss costs a whole refresh period, so the model is built for consistency:
//! it takes the worst recent cost, not the typical one, and three misses in
//! two seconds hand scheduling back to the normal path for a growing pause.

const std = @import("std");

const ms = std.time.ns_per_ms;

pub const tuning = struct {
    /// Frames measured before the first late start.
    pub const min_samples = 8;
    /// Waits shorter than this just render now.
    pub const min_wait_ns = 1 * ms;
    /// Started later than this fraction of a period is not worth the risk.
    pub const max_budget_percent = 90;
    /// Without GPU timing the estimate misses the GPU tail; cover it.
    pub const unknown_gpu_extra_ns = 2 * ms;
    /// The last present older than this many periods means no stream.
    pub const stale_periods = 2;
    /// A missed vblank grows the margin by half of it, at least this much.
    pub const miss_step_ns = 1 * ms;
    pub const near_miss_step_ns = 250_000;
    pub const decay_step_ns = 250_000;
    /// A clean run this long gives one decay step back.
    pub const decay_after_ns = 4 * std.time.ns_per_s;
    /// This many misses within `trip_window_ns` pause late rendering.
    pub const trip_misses = 3;
    pub const trip_window_ns = 2 * std.time.ns_per_s;
    pub const backoff_min_ns = 2 * std.time.ns_per_s;
    pub const backoff_max_ns = 60 * std.time.ns_per_s;
    /// No pause for this long starts the next one at the minimum again.
    pub const backoff_reset_ns = 120 * std.time.ns_per_s;
};

/// `wlr_output_present_flag`: vsync, and a time from the display's own clock.
/// Anything less (headless, X11) is not a vblank to schedule against.
pub const usable_flags: u32 = 0x1 | 0x2;

pub fn PeakRing(comptime capacity: usize) type {
    return struct {
        values: [capacity]u64 = @splat(0),
        count: usize = 0,
        next: usize = 0,

        pub fn push(self: *@This(), value: u64) void {
            self.values[self.next] = value;
            self.next = (self.next + 1) % capacity;
            self.count +|= 1;
        }

        pub fn len(self: *const @This()) usize {
            return @min(self.count, capacity);
        }

        pub fn peak(self: *const @This()) u64 {
            var result: u64 = 0;
            for (self.values[0..self.len()]) |value| result = @max(result, value);
            return result;
        }
    };
}

pub const Plan = struct {
    /// When to start rendering.
    start_ns: u64,
    /// The vblank this frame is meant to reach.
    vblank_ns: u64,
    estimate_ns: u64,
    margin_ns: u64,
};

pub const Decision = union(enum) {
    /// Render now: nothing to gain, or the timing is not trusted.
    immediate,
    wait: Plan,
};

pub const Present = struct {
    when_ns: u64,
    refresh_ns: u64,
    flags: u32,
    presented: bool,
    commit_seq: u32,
};

/// The frame last committed from a plan, waiting for its presentation.
const Pending = struct {
    commit_seq: u32 = 0,
    vblank_ns: u64 = 0,
    done_ns: u64 = 0,
    margin_ns: u64 = 0,
};

pub const State = struct {
    cost: PeakRing(64) = .{},
    timeline_valid: bool = false,
    last_when_ns: u64 = 0,
    period_ns: u64 = 0,
    margin_ns: u64 = 0,
    floor_ns: u64 = 0,
    last_adjust_ns: u64 = 0,
    pending: Pending = .{},
    recent_misses: [tuning.trip_misses]u64 = @splat(0),
    miss_next: usize = 0,
    fallback_until_ns: u64 = 0,
    backoff_ns: u64 = tuning.backoff_min_ns,
    last_trip_ns: u64 = 0,
    late_frames: u64 = 0,
    misses: u64 = 0,
    near_misses: u64 = 0,
    trips: u64 = 0,

    /// What to do with a frame event arriving at `now`.
    pub fn plan(self: *State, now: u64, floor_ns: u64, gpu_known: bool) Decision {
        self.setFloor(floor_ns);
        if (!self.timeline_valid or self.cost.len() < tuning.min_samples) return .immediate;
        if (now < self.fallback_until_ns) return .immediate;
        // A presentation time ahead of our clock means the clocks disagree.
        if (now + ms < self.last_when_ns) {
            self.invalidate();
            return .immediate;
        }
        const age = now -| self.last_when_ns;
        if (age > tuning.stale_periods * self.period_ns) return .immediate;
        const vblank = self.last_when_ns + (age / self.period_ns + 1) * self.period_ns;
        var budget = self.cost.peak() + self.margin_ns;
        if (!gpu_known) budget += tuning.unknown_gpu_extra_ns;
        if (budget >= self.period_ns * tuning.max_budget_percent / 100) return .immediate;
        const start = vblank - budget;
        if (start < now + tuning.min_wait_ns) return .immediate;
        return .{ .wait = .{ .start_ns = start, .vblank_ns = vblank, .estimate_ns = self.cost.peak(), .margin_ns = self.margin_ns } };
    }

    /// A frame committed. `gpu_peak_ns` is the recent worst GPU elapsed time
    /// (0 when unknown); `from` is the plan it ran from, if any.
    pub fn committed(self: *State, commit_seq: u32, start_ns: u64, built_ns: u64, done_ns: u64, gpu_peak_ns: u64, from: ?Plan) void {
        const cpu = done_ns -| start_ns;
        const gpu = (built_ns -| start_ns) +| gpu_peak_ns;
        const path = @max(cpu, gpu);
        self.cost.push(path);
        self.pending = .{};
        if (from) |p| {
            self.late_frames +|= 1;
            // The frame is ready when the commit has returned and the GPU is done.
            self.pending = .{ .commit_seq = commit_seq, .vblank_ns = p.vblank_ns, .done_ns = start_ns + path, .margin_ns = p.margin_ns };
        }
    }

    /// A presentation report. `fallback_period_ns` is the mode's own period,
    /// used when the report predicts none.
    pub fn presented(self: *State, now: u64, p: Present, fallback_period_ns: u64) void {
        const period = if (p.refresh_ns >= 2 * ms and p.refresh_ns <= 100 * ms) p.refresh_ns else fallback_period_ns;
        if (!p.presented or p.when_ns == 0 or p.flags & usable_flags != usable_flags or
            period < 2 * ms or period > 100 * ms or
            (self.timeline_valid and p.when_ns <= self.last_when_ns))
        {
            self.invalidate();
            return;
        }
        if (self.pending.vblank_ns != 0 and self.pending.commit_seq == p.commit_seq) self.judge(now, p.when_ns, period);
        self.last_when_ns = p.when_ns;
        self.period_ns = period;
        self.timeline_valid = true;
    }

    /// The timeline cannot be trusted until the next usable presentation.
    pub fn invalidate(self: *State) void {
        self.timeline_valid = false;
        self.pending = .{};
    }

    fn judge(self: *State, now: u64, when_ns: u64, period: u64) void {
        const pending = self.pending;
        self.pending = .{};
        const lateness = @as(i64, @intCast(@min(when_ns, std.math.maxInt(i63)))) - @as(i64, @intCast(@min(pending.vblank_ns, std.math.maxInt(i63))));
        const half: i64 = @intCast(period / 2);
        if (lateness > half) return self.miss(now, true);
        // Shown a period early: the prediction itself was wrong.
        if (lateness < -half) return self.miss(now, false);
        const slack = @as(i64, @intCast(@min(pending.vblank_ns, std.math.maxInt(i63)))) - @as(i64, @intCast(@min(pending.done_ns, std.math.maxInt(i63))));
        if (slack < @as(i64, @intCast(pending.margin_ns / 4))) {
            self.near_misses +|= 1;
            self.grow(now, tuning.near_miss_step_ns);
        } else if (now -| self.last_adjust_ns >= tuning.decay_after_ns and self.margin_ns > self.floor_ns) {
            self.margin_ns = @max(self.floor_ns, self.margin_ns -| tuning.decay_step_ns);
            self.last_adjust_ns = now;
        }
    }

    fn miss(self: *State, now: u64, late: bool) void {
        if (late) {
            self.misses +|= 1;
            self.grow(now, @max(tuning.miss_step_ns, self.margin_ns / 2));
        }
        self.recent_misses[self.miss_next] = now;
        self.miss_next = (self.miss_next + 1) % tuning.trip_misses;
        const oldest = self.recent_misses[self.miss_next];
        if (oldest != 0 and now -| oldest <= tuning.trip_window_ns) self.trip(now);
    }

    pub fn trip(self: *State, now: u64) void {
        if (self.last_trip_ns != 0 and now -| self.last_trip_ns > tuning.backoff_reset_ns) self.backoff_ns = tuning.backoff_min_ns;
        self.fallback_until_ns = now + self.backoff_ns;
        self.backoff_ns = @min(self.backoff_ns * 2, tuning.backoff_max_ns);
        self.last_trip_ns = now;
        self.trips +|= 1;
        self.recent_misses = @splat(0);
        self.pending = .{};
    }

    pub fn grow(self: *State, now: u64, step_ns: u64) void {
        self.margin_ns = @min(self.margin_ns + step_ns, self.cap());
        self.last_adjust_ns = now;
    }

    fn cap(self: *const State) u64 {
        return @max(self.floor_ns, self.period_ns / 3);
    }

    fn setFloor(self: *State, floor_ns: u64) void {
        self.floor_ns = floor_ns;
        self.margin_ns = @max(self.margin_ns, floor_ns);
    }
};
