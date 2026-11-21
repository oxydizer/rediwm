//! Tearing on an `Output`: asynchronous page flips for a game window
//! (`game.zig`) that asks for them with the `wp_tearing_control_v1` hint
//! `async`, while `[compositor] allow_tearing` is on. Refused flips fall back
//! to a synchronous flip for that frame; `tearing_policy.zig` decides when a
//! run of refusals pauses attempts.

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const game = @import("game.zig");
const tearing_policy = @import("tearing_policy.zig");
const stats = @import("../ipc/stats.zig");
const extra_protocols = @import("../extra_protocols.zig");
const log = std.log.scoped(.output);

pub const State = struct {
    backoff: tearing_policy.Backoff = .{},
    /// The last committed buffer was flipped asynchronously.
    active: bool = false,
    idle: ?*wl.EventSource = null,
};

/// The policy alone: a game window on this output asks to tear and nothing
/// forbids it. Refusals by the driver do not change this (`allowed` does).
pub fn wanted(output: *Output) bool {
    const server = output.server;
    if (!server.config.compositor.allow_tearing or server.locker != null or server.polkit_dialog != null or
        server.greeter_mode or output.power_off or !output.wlr_output.enabled) return false;
    const top = game.window(output) orelse return false;
    return extra_protocols.rediwm_protocols_tearing(server.extra_protocols, top.surface());
}

/// Whether this output tries asynchronous flips now: wanted, and not paused
/// after a run of refusals.
pub fn allowed(output: *Output) bool {
    if (!wanted(output)) return false;
    const backoff = &output.tearing.backoff;
    return backoff.paused_until_ns == 0 or !backoff.paused(stats.nowNs());
}

/// Whether this frame may flip asynchronously at all. Atomic async flips may
/// change only the primary plane's buffer, so a frame that also changes the
/// mode, colour, image description or hardware cursor would be refused:
/// flip it synchronously without spending a test commit.
pub fn frameCanTear(output: *Output, state: *const wlr.Output.State) bool {
    const c = state.committed;
    if (!c.buffer or c.mode or c.enabled or c.scale or c.transform or c.adaptive_sync_enabled or
        c.render_format or c.color_transform or c.image_description) return false;
    return std.meta.eql(Output.CursorState.of(output.wlr_output), output.committed_cursor);
}

/// The driver refused an asynchronous flip (test or commit).
pub fn refused(output: *Output) void {
    stats.global_stats.tearing_refused_flips +%= 1;
    const pause = output.tearing.backoff.failed(stats.nowNs()) orelse return;
    // Once per run: later pauses of the same run are only debug noise.
    if (pause == tearing_policy.tuning.first_pause_ns) {
        log.info("output '{s}': {d} asynchronous page flips refused in a row; tearing paused, retrying with backoff", .{
            output.wlr_output.name, tearing_policy.tuning.failures_before_pause,
        });
    } else {
        log.debug("output '{s}': tearing paused for {d} ms", .{ output.wlr_output.name, pause / std.time.ns_per_ms });
    }
}

/// A frame state was committed.
pub fn committed(output: *Output, state: *const wlr.Output.State) void {
    if (!state.committed.buffer) return;
    output.tearing.active = state.tearing_page_flip;
    if (state.tearing_page_flip) {
        output.tearing.backoff.succeeded();
        stats.global_stats.tearing_async_flips +%= 1;
    }
}

// A client commit can render before the next vblank when the previous flip is
// complete. Coalesce commits at idle, after wlroots has updated scene damage.
pub fn queue(output: *Output) void {
    if (output.tearing.idle != null or !allowed(output)) return;
    output.tearing.idle = output.server.wl_server.getEventLoop().addIdle(*Output, onIdle, output) catch null;
}

fn onIdle(output: *Output) void {
    output.tearing.idle = null;
    if (!allowed(output) or output.wlr_output.frame_pending or output.vblank_armed) return;
    output.runFrame();
}

pub fn deinit(output: *Output) void {
    if (output.tearing.idle) |source| source.remove();
    output.tearing.idle = null;
}
