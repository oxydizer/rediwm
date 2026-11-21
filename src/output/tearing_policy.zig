//! Tearing backoff: how an output reacts when the driver refuses an
//! asynchronous page flip. Plain data and a caller-supplied clock, so the
//! cases are tested without wlroots; `tearing.zig` connects it to an `Output`.
//!
//! A refused flip only makes that frame synchronous. Atomic async flips may
//! change nothing but the primary plane's buffer, so single frames fail for
//! passing reasons (a cursor move the pre-check could not see, a buffer
//! modifier the driver cannot flip asynchronously). A long run of refusals
//! means the driver will not take this kind of buffer at all: then attempts
//! stop for a while, since each one costs an extra test commit, and resume
//! by themselves with a growing pause. No timer: the next client commit after
//! the pause tries again.
//!
//! A driver that refuses the first whole run without ever taking one flip
//! cannot tear here at all (i915 refuses any atomic async commit that carries
//! the cursor plane, which wlroots 0.20 always writes): attempts stop for the
//! session (`gaveUp`). A fixed kernel takes the first run and never gives up.

const std = @import("std");

const s = std.time.ns_per_s;

pub const tuning = struct {
    /// Refusals in a row before attempts pause.
    pub const failures_before_pause = 30;
    pub const first_pause_ns = 2 * s;
    pub const max_pause_ns = 30 * s;
};

pub const Backoff = struct {
    failures: u16 = 0,
    /// Zero when not paused.
    paused_until_ns: u64 = 0,
    next_pause_ns: u64 = tuning.first_pause_ns,
    /// An asynchronous flip went through at least once this session.
    ever_succeeded: bool = false,
    /// A run of refusals paused attempts at least once.
    ever_paused: bool = false,

    /// Whether attempts are paused at `now`. Ending a pause clears it, so
    /// callers can skip the clock read while `paused_until_ns` is zero.
    pub fn paused(self: *Backoff, now_ns: u64) bool {
        if (self.paused_until_ns == 0) return false;
        if (now_ns < self.paused_until_ns) return true;
        self.paused_until_ns = 0;
        return false;
    }

    /// An asynchronous flip went through: start over.
    pub fn succeeded(self: *Backoff) void {
        self.ever_succeeded = true;
        self.failures = 0;
        self.next_pause_ns = tuning.first_pause_ns;
    }

    /// The driver refused an asynchronous flip. Returns the pause this
    /// refusal starts, if any.
    pub fn failed(self: *Backoff, now_ns: u64) ?u64 {
        self.failures += 1;
        if (self.failures < tuning.failures_before_pause) return null;
        self.failures = 0;
        self.ever_paused = true;
        const pause = self.next_pause_ns;
        self.paused_until_ns = now_ns + pause;
        self.next_pause_ns = @min(pause * 2, tuning.max_pause_ns);
        return pause;
    }

    /// The driver refused a whole run before taking any flip: it cannot tear.
    pub fn gaveUp(self: *const Backoff) bool {
        return self.ever_paused and !self.ever_succeeded;
    }
};

test "isolated refusals never pause" {
    var b: Backoff = .{};
    for (0..1000) |i| {
        for (0..tuning.failures_before_pause - 1) |_| try std.testing.expectEqual(null, b.failed(i));
        b.succeeded();
        try std.testing.expect(!b.paused(i));
    }
}

test "a driver that never takes a flip gives up after the first run" {
    var b: Backoff = .{};
    for (0..tuning.failures_before_pause - 1) |_| _ = b.failed(0);
    try std.testing.expect(!b.gaveUp());
    _ = b.failed(0);
    try std.testing.expect(b.gaveUp());

    // One success before the first pause: later runs only back off.
    var ok: Backoff = .{};
    ok.succeeded();
    for (0..tuning.failures_before_pause * 3) |_| _ = ok.failed(0);
    try std.testing.expect(!ok.gaveUp());
}

test "a run of refusals pauses, resumes and backs off" {
    var b: Backoff = .{};
    b.succeeded();
    var now: u64 = 1000;
    for (0..tuning.failures_before_pause - 1) |_| try std.testing.expectEqual(null, b.failed(now));
    try std.testing.expectEqual(@as(?u64, tuning.first_pause_ns), b.failed(now));
    try std.testing.expect(b.paused(now));
    try std.testing.expect(b.paused(now + tuning.first_pause_ns - 1));
    now += tuning.first_pause_ns;
    try std.testing.expect(!b.paused(now));
    try std.testing.expectEqual(@as(u64, 0), b.paused_until_ns);

    // Still refused after the pause: the next one is longer, up to the cap.
    var expected: u64 = tuning.first_pause_ns;
    for (0..8) |_| {
        expected = @min(expected * 2, tuning.max_pause_ns);
        for (0..tuning.failures_before_pause - 1) |_| _ = b.failed(now);
        try std.testing.expectEqual(@as(?u64, expected), b.failed(now));
        now += expected;
    }

    // One success resets the backoff.
    b.succeeded();
    for (0..tuning.failures_before_pause - 1) |_| _ = b.failed(now);
    try std.testing.expectEqual(@as(?u64, tuning.first_pause_ns), b.failed(now));
}
