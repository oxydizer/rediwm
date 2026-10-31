//! Late rendering on an `Output`: connects `late_render.State` to the frame
//! loop. Off unless `[compositor] late_render` is set; with it off every entry
//! point returns before touching anything, and frames run as they always did.
//!
//! A frame event that finds work to do and a trusted presentation timeline is
//! not rendered at once. Frame callbacks go out right then, so clients draw
//! during the wait and their commits join the frame, and `late_timer` starts
//! `runFrame` at the planned time. Further frame events are ignored while it
//! waits: they are only damage asking for a frame it is about to produce.

const std = @import("std");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const late_render = @import("late_render.zig");
const stats = @import("../ipc/stats.zig");
const log = std.log.scoped(.late_render);

pub fn enabled(output: *const Output) bool {
    const server = output.server;
    return server.config.compositor.late_render and output.late_timer != null and !server.greeter_mode;
}

fn floorNs(output: *const Output) u64 {
    const margin_ms: f64 = output.server.config.compositor.late_render_margin_ms;
    return @intFromFloat(@round(margin_ms * std.time.ns_per_ms));
}

/// Called for a frame event. True: a frame is deferred (frame callbacks are
/// sent, the timer is armed); false: render now.
pub fn tryDefer(output: *Output) bool {
    if (!enabled(output) or !output.late.timeline_valid) return false;
    const wlr_output = output.wlr_output;
    if (!wlr_output.enabled or output.power_off or wlr_output.adaptive_sync_status == .enabled or output.tearingAllowed()) return false;
    const server = output.server;
    const scene_output = server.scene_outputs.get(wlr_output) orelse return false;
    // Only a frame that will change something is worth waiting for.
    if (!output.late_animating and output.commitIsRedundant(scene_output)) return false;

    const now = stats.nowNs();
    server.keepGpuTimer(now);
    const gpu_known = server.gpu_timer != null and server.gpu_recent.len() >= late_render.tuning.min_samples;
    const plan = switch (output.late.plan(now, floorNs(output), gpu_known)) {
        .immediate => return false,
        .wait => |p| p,
    };
    // Whole milliseconds, rounded down: starting early costs a little
    // freshness, starting late could cost the vblank.
    const delay_ms: c_int = @intCast(@max(1, (plan.start_ns - now) / std.time.ns_per_ms));
    output.late_timer.?.timerUpdate(delay_ms) catch return false;
    output.late_armed = true;
    output.late_plan = plan;
    output.sendFrameDone();
    return true;
}

/// `late_timer`: the deferred frame's time has come.
pub fn fire(output: *Output) c_int {
    output.late_armed = false;
    const wlr_output = output.wlr_output;
    if (!wlr_output.enabled) {
        output.late_plan = null;
    } else if (wlr_output.frame_pending) {
        output.late_plan = null;
        wlr_output.scheduleFrame();
    } else {
        output.runFrame();
    }
    return 0;
}

/// The plan of the frame `runFrame` is starting, if it was deferred.
pub fn takePlan(output: *Output) ?late_render.Plan {
    const plan = output.late_plan;
    output.late_plan = null;
    return plan;
}

/// A frame committed; its stage times feed the cost estimate.
pub fn noteCommitted(output: *Output, commit_seq: u32, start_ns: u64, built_ns: u64, done_ns: u64, plan: ?late_render.Plan) void {
    if (!enabled(output)) return;
    output.late.committed(commit_seq, start_ns, built_ns, done_ns, output.server.gpu_recent.peak(), plan);
}

/// The display reported a presentation: the timeline, and the verdict on a
/// deferred frame's deadline.
pub fn notePresent(output: *Output, event: *const wlr.Output.event.Present) void {
    if (!enabled(output)) return;
    const refresh_ns: u64 = if (event.refresh > 0) @intCast(event.refresh) else 0;
    const when_ns = @as(u64, @intCast(@max(event.when.sec, 0))) *% std.time.ns_per_s +% @as(u64, @intCast(@max(event.when.nsec, 0)));
    const trips = output.late.trips;
    output.late.presented(stats.nowNs(), .{
        .when_ns = when_ns,
        .refresh_ns = refresh_ns,
        .flags = event.flags,
        .presented = event.presented,
        .commit_seq = event.commit_seq,
    }, output.refreshPeriodNs());
    if (output.late.trips != trips) {
        log.warn("{s}: late rendering paused for {d} ms after repeated missed deadlines (margin now {d:.2} ms)", .{
            output.wlr_output.name,
            (output.late.fallback_until_ns -| stats.nowNs()) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(output.late.margin_ns)) / std.time.ns_per_ms,
        });
    }
}

/// A mode change or similar: the old timeline says nothing about the new one.
pub fn reset(output: *Output) void {
    output.late.invalidate();
}
