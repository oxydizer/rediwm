//! Frame timing trace for scheduling measurements (`-Dframe-trace=true`).
//!
//! Every `runFrame` logs one `F` line and every presentation one `P` line,
//! both with CLOCK_MONOTONIC nanoseconds, so `tests/frame_latency.py` can pair
//! them by `cseq`:
//!
//!   F  ev     the output's frame event arrived (0: run without one)
//!      start  `runFrame` began        built  scene state built (render submitted)
//!      done   commit returned         d1/d2  first/last content damage since the previous frame
//!      late   1 when late rendering deferred it, then vexp (the vblank it aimed
//!             for), est (worst recent cost) and mrg (safety margin) in ns
//!   P  when   the display's presentation time   now  when we heard of it
//!      vseq   retrace counter   refresh  predicted period   flags  `wlr_output_present_flag`
//!
//! Without the option nothing here is compiled in.

const std = @import("std");
const wlr = @import("wlroots");
const stats = @import("../ipc/stats.zig");
const late_render = @import("late_render.zig");

pub const enabled = @import("trace").frame_trace;
const log = std.log.scoped(.frame_trace);

extern fn rediwm_trace_take_damage(output: *wlr.Output, last_ns: *u64) u64;

const max_outputs = 8;
var slots: [max_outputs]struct { output: ?*wlr.Output = null, event_ns: u64 = 0 } = @splat(.{});

fn slotFor(output: *wlr.Output) ?*@TypeOf(slots[0]) {
    for (&slots) |*slot| {
        if (slot.output == output or slot.output == null) {
            slot.output = output;
            return slot;
        }
    }
    return null;
}

pub fn frameEvent(output: *wlr.Output) void {
    if (!enabled) return;
    if (slotFor(output)) |slot| slot.event_ns = stats.nowNs();
}

/// One `runFrame`: its stage times, logged when it ends. The clock is read
/// only when `active`: the trace is compiled in, or late rendering feeds on
/// the times.
pub const Frame = struct {
    start: u64,
    active: bool = enabled,
    built: u64 = 0,
    done: u64 = 0,
    /// Null when the frame committed nothing (skipped, captured or failed).
    commit_seq: ?u32 = null,
    /// The plan this frame was deferred by, if it was.
    plan: ?late_render.Plan = null,

    pub fn markBuilt(self: *Frame) void {
        if (self.active) self.built = stats.nowNs();
    }

    pub fn markCommitted(self: *Frame, commit_seq: ?u32) void {
        if (!self.active) return;
        self.done = stats.nowNs();
        self.commit_seq = commit_seq;
    }

    pub fn finish(self: *const Frame, output: *wlr.Output) void {
        if (!enabled) return;
        var last: u64 = 0;
        const first = rediwm_trace_take_damage(output, &last);
        var event_ns: u64 = 0;
        if (slotFor(output)) |slot| {
            event_ns = slot.event_ns;
            slot.event_ns = 0;
        }
        const plan = self.plan orelse late_render.Plan{ .start_ns = 0, .vblank_ns = 0, .estimate_ns = 0, .margin_ns = 0 };
        log.info("F out={s} ev={d} start={d} built={d} done={d} d1={d} d2={d} cseq={d} commit={d} late={d} vexp={d} est={d} mrg={d}", .{
            output.name,                  event_ns,        self.start,   self.built, self.done, first, last,
            self.commit_seq orelse 0,     @intFromBool(self.commit_seq != null),
            @intFromBool(self.plan != null), plan.vblank_ns, plan.estimate_ns, plan.margin_ns,
        });
    }
};

pub fn presented(event: *const wlr.Output.event.Present) void {
    if (!enabled) return;
    const when: u64 = @as(u64, @intCast(@max(event.when.sec, 0))) *% 1_000_000_000 +% @as(u64, @intCast(@max(event.when.nsec, 0)));
    log.info("P out={s} cseq={d} presented={d} when={d} now={d} vseq={d} refresh={d} flags={d}", .{
        event.output.name, event.commit_seq, @intFromBool(event.presented), when, stats.nowNs(), event.seq, event.refresh, event.flags,
    });
}
