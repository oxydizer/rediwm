//! Tests for the late-render decision model (`late_render.zig`), on synthetic
//! 60 Hz timelines.

const std = @import("std");
const late_render = @import("late_render.zig");
const State = late_render.State;
const Plan = late_render.Plan;
const Present = late_render.Present;
const Decision = late_render.Decision;
const tuning = late_render.tuning;
const usable_flags = late_render.usable_flags;

const ms = std.time.ns_per_ms;
const testing = std.testing;
const hz60: u64 = 16_666_667;
const hw: u32 = usable_flags | 0x4;

fn report(when: u64, seq: u32) Present {
    return .{ .when_ns = when, .refresh_ns = hz60, .flags = hw, .presented = true, .commit_seq = seq };
}

/// A 60 Hz timeline with `n` clean streaming frames of `cost` ns behind it;
/// returns the last presentation time.
fn warmed(state: *State, n: usize, cost: u64) u64 {
    var when: u64 = 1_000 * ms;
    for (0..n) |i| {
        when += hz60;
        const start = when - hz60 + 100_000;
        state.committed(@intCast(i), start, start + cost / 2, start + cost, 0, null);
        state.presented(when, report(when, @intCast(i)), hz60);
    }
    return when;
}

/// Commits a planned frame that finishes `finish_ns` after its start and is
/// shown at `shown`.
fn planned(state: *State, plan: Plan, seq: u32, finish_ns: u64, shown: u64) void {
    state.committed(seq, plan.start_ns, plan.start_ns + finish_ns / 2, plan.start_ns + finish_ns, 0, plan);
    state.presented(shown, report(shown, seq), hz60);
}

test "a frame without a trusted timeline or enough history renders now" {
    var state = State{};
    try testing.expectEqual(Decision.immediate, state.plan(5_000 * ms, 2 * ms, true));
    const few = warmed(&state, tuning.min_samples - 1, 2 * ms);
    try testing.expectEqual(Decision.immediate, state.plan(few + 100_000, 2 * ms, true));
    state = State{};
    const when = warmed(&state, 20, 2 * ms);
    var unusable = report(when + hz60, 99);
    unusable.flags = 0;
    state.presented(when + hz60, unusable, hz60);
    try testing.expectEqual(Decision.immediate, state.plan(when + hz60 + 100_000, 2 * ms, true));
}

test "a stream is scheduled against the next vblank, worst cost plus margin" {
    var state = State{};
    const when = warmed(&state, 20, 3 * ms);
    const now = when + 200_000;
    const d = state.plan(now, 2 * ms, true);
    try testing.expectEqual(when + hz60, d.wait.vblank_ns);
    try testing.expectEqual(3 * ms, d.wait.estimate_ns);
    try testing.expectEqual(2 * ms, d.wait.margin_ns);
    try testing.expectEqual(when + hz60 - 5 * ms, d.wait.start_ns);
    // Unknown GPU time adds its allowance.
    try testing.expectEqual(when + hz60 - 7 * ms, state.plan(now, 2 * ms, false).wait.start_ns);
}

test "the estimate follows the worst recent frame, not the typical one" {
    var state = State{};
    var when = warmed(&state, 30, 2 * ms);
    state.committed(100, when, when + ms, when + 6 * ms, 0, null);
    when += hz60;
    state.presented(when, report(when, 100), hz60);
    try testing.expectEqual(6 * ms, state.plan(when + 100_000, 2 * ms, true).wait.estimate_ns);
}

test "the GPU's tail counts, not just the CPU's time" {
    var state = State{};
    var when = warmed(&state, 30, 1 * ms);
    // The CPU is done in 1.2 ms; the commit waits for a GPU busy 4 ms after the build.
    state.committed(100, when, when + 1 * ms, when + 1_200_000, 4 * ms, null);
    when += hz60;
    state.presented(when, report(when, 100), hz60);
    try testing.expectEqual(5 * ms, state.plan(when + 100_000, 2 * ms, true).wait.estimate_ns);
}

test "frames after idle and frames with no room to wait render now" {
    var state = State{};
    const when = warmed(&state, 20, 3 * ms);
    try testing.expectEqual(Decision.immediate, state.plan(when + 3 * hz60, 2 * ms, true));
    // Already inside the late window: the target has passed.
    try testing.expectEqual(Decision.immediate, state.plan(when + hz60 - 4 * ms, 2 * ms, true));
    // A budget of most of the period gains nothing.
    var heavy = State{};
    const heavy_when = warmed(&heavy, 20, 14 * ms);
    try testing.expectEqual(Decision.immediate, heavy.plan(heavy_when + 100_000, 2 * ms, true));
}

test "a missed vblank grows the margin; repeated misses pause late rendering and back off" {
    var state = State{};
    var when = warmed(&state, 20, 3 * ms);
    var seq: u32 = 200;
    for (0..3) |i| {
        const p = state.plan(when + 100_000, 2 * ms, true).wait;
        when = p.vblank_ns + hz60; // shown a period late
        planned(&state, p, seq, 3 * ms, when);
        seq += 1;
        if (i < 2) {
            try testing.expect(state.margin_ns > 2 * ms);
            try testing.expectEqual(@as(u64, 0), state.trips);
        }
    }
    try testing.expectEqual(@as(u64, 3), state.misses);
    try testing.expectEqual(@as(u64, 1), state.trips);
    try testing.expectEqual(Decision.immediate, state.plan(when + 100_000, 2 * ms, true));
    try testing.expectEqual(when + tuning.backoff_min_ns, state.fallback_until_ns);
    try testing.expectEqual(2 * tuning.backoff_min_ns, state.backoff_ns);
}

test "a pause ends, keeps the margin it learned, and the next pause is longer" {
    var state = State{};
    var when = warmed(&state, 20, 3 * ms);
    _ = state.plan(when + 100_000, 2 * ms, true);
    state.grow(when, ms);
    const learned = state.margin_ns;
    state.trip(when);
    try testing.expectEqual(Decision.immediate, state.plan(when + 100_000, 2 * ms, true));
    when += tuning.backoff_min_ns + hz60;
    state.presented(when, report(when, 1), hz60);
    try testing.expect(state.plan(when + 100_000, 2 * ms, true) == .wait);
    try testing.expectEqual(learned, state.margin_ns);
    state.trip(when);
    try testing.expectEqual(when + 2 * tuning.backoff_min_ns, state.fallback_until_ns);
    // Left alone long enough, the next pause starts short again.
    state.trip(when + tuning.backoff_reset_ns + 1);
    try testing.expectEqual(when + tuning.backoff_reset_ns + 1 + tuning.backoff_min_ns, state.fallback_until_ns);
}

test "a near miss nudges the margin up and a long clean run gives it back" {
    var state = State{};
    var when = warmed(&state, 20, 3 * ms);
    var p = state.plan(when + 100_000, 2 * ms, true).wait;
    when = p.vblank_ns;
    // The commit returned 0.2 ms before the vblank it made.
    planned(&state, p, 300, p.vblank_ns - 200_000 - p.start_ns, when);
    try testing.expectEqual(@as(u64, 1), state.near_misses);
    const raised = state.margin_ns;
    try testing.expect(raised > 2 * ms);
    for (0..400) |i| {
        p = state.plan(when + 100_000, 2 * ms, true).wait;
        when = p.vblank_ns;
        planned(&state, p, @intCast(400 + i), 3 * ms, when);
    }
    try testing.expect(state.margin_ns < raised);
    try testing.expect(state.margin_ns >= 2 * ms);
    try testing.expectEqual(@as(u64, 0), state.trips);
}

test "the margin never leaves its floor and cap" {
    var state = State{};
    _ = warmed(&state, 20, 3 * ms);
    _ = state.plan(1_020 * ms, 5 * ms, true);
    try testing.expectEqual(5 * ms, state.margin_ns);
    state.grow(1, 100 * ms);
    try testing.expectEqual(@max(5 * ms, hz60 / 3), state.margin_ns);
}

test "an unusable presentation report invalidates the timeline until a good one" {
    var state = State{};
    var when = warmed(&state, 20, 3 * ms);
    var not_presented = report(when + hz60, 1);
    not_presented.presented = false;
    var no_time = report(0, 1);
    no_time.when_ns = 0;
    var no_vsync = report(when + hz60, 1);
    no_vsync.flags = 0x1;
    var no_refresh = report(when + hz60, 1);
    no_refresh.refresh_ns = 0;
    for ([_]Present{ not_presented, no_time, no_vsync, report(when - 1, 1), no_refresh }) |bad| {
        state.presented(when + hz60, bad, 0);
        try testing.expect(!state.timeline_valid);
        try testing.expectEqual(Decision.immediate, state.plan(when + hz60 + 100_000, 2 * ms, true));
        state.presented(when + hz60, report(when + hz60, 1), hz60);
        when += hz60;
        try testing.expect(state.timeline_valid);
    }
}

test "a clock that disagrees with the display's does not schedule" {
    var state = State{};
    const when = warmed(&state, 20, 3 * ms);
    try testing.expectEqual(Decision.immediate, state.plan(when - 5 * ms, 2 * ms, true));
    try testing.expect(!state.timeline_valid);
}

test "a frame shown a period early counts toward a pause but does not grow the margin" {
    var state = State{};
    const when = warmed(&state, 20, 3 * ms);
    const p = state.plan(when + 100_000, 2 * ms, true).wait;
    const before = state.margin_ns;
    planned(&state, p, 400, 3 * ms, p.vblank_ns - hz60 + 1);
    try testing.expectEqual(before, state.margin_ns);
    try testing.expectEqual(@as(u64, 0), state.misses);
    try testing.expect(state.recent_misses[0] != 0);
}

test "slack is measured to when the GPU is done, not just the commit" {
    var state = State{};
    const when = warmed(&state, 20, 3 * ms);
    const p = state.plan(when + 100_000, 2 * ms, true).wait;
    // The commit returns early, but the GPU finishes 0.2 ms before the vblank.
    state.committed(500, p.start_ns, p.start_ns + ms, p.start_ns + 2 * ms, p.vblank_ns - 200_000 - (p.start_ns + ms), p);
    state.presented(p.vblank_ns, report(p.vblank_ns, 500), hz60);
    try testing.expectEqual(@as(u64, 1), state.near_misses);
}
