const std = @import("std");
const wp = @import("wayland").client.wp;
const wl = @import("wayland").client.wl;

pub fn now() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

pub const Clock = struct {
    media: i64 = 0,
    anchor: i64 = 0,
    running: bool = false,

    pub fn position(self: Clock, t: i64) i64 {
        return self.media +| (if (self.running) t - self.anchor else 0);
    }
    pub fn set(self: *Clock, pts: i64, t: i64, running: bool) void {
        self.* = .{ .media = pts, .anchor = t, .running = running };
    }
};

pub const Pacing = struct {
    timer: ?*wp.CommitTimerV1 = null,
    submitted_until: i64 = 0,
    presentation: ?*wp.Presentation = null,
    pending: ?*wp.PresentationFeedback = null,
    monotonic: bool = false,
    sent: i64 = 0,
    phase: ?i64 = null,
    refresh: i64 = 0,
    lead: i64 = 0,

    pub fn deadline(self: Pacing, due: i64) i64 {
        const phase = self.phase orelse return due -| self.lead;
        // First refresh at or after the media deadline.
        const delta = @mod(@as(i128, phase) - due, self.refresh);
        return (due +| @as(i64, @intCast(delta))) -| self.lead;
    }

    // Null means this picture can reach the upcoming refresh. The player
    // consumes all such pictures and attaches only the newest.
    pub fn waitUntil(self: Pacing, pts: i64, media: i64, t: i64, use_timer: bool) ?i64 {
        const target = t +| (pts -| media);
        const due = if (use_timer) self.submitAt(target) else self.deadline(target);
        return if (due > t) due else null;
    }

    pub fn timed(self: Pacing) bool {
        return self.timer != null and self.monotonic;
    }

    /// One future picture at a time. Bound its lead even on a slow output:
    /// an already submitted timestamp cannot be cancelled by a seek.
    fn submitAt(self: Pacing, target: i64) i64 {
        const period = if (self.refresh > 0) self.refresh else std.time.ns_per_s / 60;
        return @max(self.submitted_until, target -| @min(period, 20 * std.time.ns_per_ms));
    }

    pub fn timestamp(self: *Pacing, target: i64) void {
        const ns: u64 = @intCast(@max(0, target));
        const sec = ns / std.time.ns_per_s;
        self.timer.?.setTimestamp(@intCast(sec >> 32), @truncate(sec), @intCast(ns % std.time.ns_per_s));
        self.submitted_until = target;
    }

    pub fn request(self: *Pacing, surface: *wl.Surface) void {
        const manager = self.presentation orelse return;
        if (self.pending != null) return;
        const feedback = manager.feedback(surface) catch return;
        self.pending = feedback;
        self.sent = now();
        feedback.setListener(*Pacing, event, self);
    }
    pub fn clockId(_: *wp.Presentation, ev: wp.Presentation.Event, self: *Pacing) void {
        self.monotonic = ev.clock_id.clk_id == @backingInt(std.posix.CLOCK.MONOTONIC);
    }
    fn event(feedback: *wp.PresentationFeedback, ev: wp.PresentationFeedback.Event, self: *Pacing) void {
        switch (ev) {
            .sync_output => return,
            .discarded => {},
            .presented => |f| {
                self.phase = null;
                self.refresh = f.refresh;
                self.lead = self.refresh;
                if (self.monotonic and self.refresh > 0) {
                    const seconds = (@as(u64, f.tv_sec_hi) << 32) | f.tv_sec_lo;
                    const pts: i64 = @intCast(seconds * std.time.ns_per_s + f.tv_nsec);
                    self.phase = pts;
                    self.lead = std.math.clamp(pts - self.sent, self.refresh, 3 * self.refresh);
                }
            },
        }
        feedback.destroy();
        self.pending = null;
    }
};

test "pause freezes media time, resume rebases and deadlines target refresh" {
    var clock: Clock = .{};
    clock.set(1200, 100, true);
    try std.testing.expectEqual(1220, clock.position(120));
    clock.set(clock.position(120), 120, false);
    try std.testing.expectEqual(1220, clock.position(900));
    clock.set(clock.position(900), 900, true);
    try std.testing.expectEqual(1230, clock.position(910));
    const pacing: Pacing = .{ .phase = 15, .refresh = 10, .lead = 10 };
    try std.testing.expectEqual(15, pacing.deadline(25));
    try std.testing.expectEqual(25, pacing.deadline(26));
    try std.testing.expectEqual(null, pacing.waitUntil(1005, 1000, 25, false));
    try std.testing.expectEqual(null, pacing.waitUntil(1010, 1000, 25, false));
    try std.testing.expectEqual(35, pacing.waitUntil(1011, 1000, 25, false).?);
}

test "timed playback bounds future commitments and control latency" {
    const ms = std.time.ns_per_ms;
    var pacing: Pacing = .{ .refresh = 16 * ms, .submitted_until = 100 * ms };
    try std.testing.expectEqual(100 * ms, pacing.submitAt(105 * ms));
    try std.testing.expectEqual(124 * ms, pacing.submitAt(140 * ms));
    pacing.refresh = 100 * ms;
    try std.testing.expectEqual(120 * ms, pacing.submitAt(140 * ms));
}
