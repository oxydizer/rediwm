//! Adaptive sync (VRR) on an `Output`: the `[[outputs]] adaptive_sync` mode
//! applied through `vrr_policy.zig`, decided before each frame and carried by
//! that frame's commit, never a separate one.
//!
//! A driver that cannot switch VRR_ENABLED without a modeset fails the test
//! commit. `auto` then stops switching on this output and mode (reported as
//! `needs_modeset`, Settings recommends Always or Off); an explicit `always`
//! or `off` is applied with a modeset of the current mode. A switch the
//! driver refuses, or enabling that comes back disabled, is remembered per
//! mode.

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const game = @import("game.zig");
const policy = @import("vrr_policy.zig");
const stats = @import("../ipc/stats.zig");
const log = std.log.scoped(.output);

pub const Mode = policy.Mode;

const ModeKey = struct { width: i32 = 0, height: i32 = 0, refresh: i32 = 0 };

pub const State = struct {
    debounce: policy.Debounce = .{},
    /// The adaptive sync state the next commit requests.
    pending: ?bool = null,
    /// `auto` cannot switch here without a modeset (this mode).
    needs_modeset: bool = false,
    /// Switching failed in this mode even with a modeset, or enabling came
    /// back off: no more attempts until the mode or the setting changes.
    refused: bool = false,
    /// The display mode and setting the two flags above belong to.
    key: ModeKey = .{},
    mode: Mode = .auto,
    timer: ?*wl.EventSource = null,
};

/// The configured mode for this output.
pub fn mode(output: *Output) Mode {
    return if (Output.configured(output.server, output.wlr_output)) |config| config.adaptive_sync else .auto;
}

pub fn supported(output: *Output) bool {
    return output.wlr_output.adaptive_sync_supported;
}

pub fn active(output: *Output) bool {
    return output.wlr_output.adaptive_sync_status == .enabled;
}

/// What the setting asks for now, whether or not the display can.
pub fn wanted(output: *Output) bool {
    const server = output.server;
    return policy.wanted(.{
        .mode = mode(output),
        .game = game.window(output) != null,
        .blocked = server.greeter_mode or output.power_off or !output.wlr_output.enabled,
    });
}

/// Before a frame: decides whether its commit changes adaptive sync, and
/// returns true if so (the frame must then commit).
pub fn prepare(output: *Output) bool {
    const state = &output.vrr;
    const wlr_output = output.wlr_output;
    const key: ModeKey = .{ .width = wlr_output.width, .height = wlr_output.height, .refresh = wlr_output.refresh };
    const configured = mode(output);
    if (!std.meta.eql(key, state.key) or configured != state.mode) {
        state.* = .{ .timer = state.timer, .key = key, .mode = configured };
    }
    state.pending = null;
    if (state.refused or (configured == .auto and state.needs_modeset)) return false;
    const want = wanted(output) and (supported(output) or active(output));
    const step = state.debounce.step(want, active(output), stats.nowNs());
    if (step.wake_ns) |due| arm(output, due);
    state.pending = step.apply;
    return state.pending != null;
}

/// Puts the decided change on the frame state, if the driver takes it.
pub fn apply(output: *Output, state: *wlr.Output.State) void {
    const enable = output.vrr.pending orelse return;
    output.vrr.pending = null;
    const wlr_output = output.wlr_output;
    var copy = state.*;
    copy.setAdaptiveSyncEnabled(enable);
    if (wlr_output.testState(&copy)) {
        state.setAdaptiveSyncEnabled(enable);
        return;
    }
    const name = wlr_output.name;
    if (output.vrr.mode == .auto) {
        output.vrr.needs_modeset = true;
        log.info("output '{s}': adaptive sync cannot be switched without a modeset; Automatic leaves it {s}", .{ name, if (active(output)) "on" else "off" });
        return;
    }
    // An explicit choice may cost a modeset: commit the current mode with it.
    if (wlr_output.current_mode) |current| {
        copy.setMode(current);
        if (wlr_output.testState(&copy)) {
            state.setMode(current);
            state.setAdaptiveSyncEnabled(enable);
            log.info("output '{s}': adaptive sync {s} with a modeset", .{ name, if (enable) "on" else "off" });
            return;
        }
    }
    // Stop for this mode either way: each retry costs two test commits.
    output.vrr.refused = true;
    log.warn("output '{s}': the driver refused to turn adaptive sync {s} in this mode", .{ name, if (enable) "on" else "off" });
}

/// A frame state was committed.
pub fn committed(output: *Output, state: *const wlr.Output.State) void {
    if (!state.committed.adaptive_sync_enabled) return;
    if (state.adaptive_sync_enabled and !active(output)) {
        output.vrr.refused = true;
        log.warn("output '{s}': adaptive sync was requested but stays off in this mode", .{output.wlr_output.name});
        return;
    }
    log.debug("output '{s}': adaptive sync {s}", .{ output.wlr_output.name, if (active(output)) "on" else "off" });
}

/// Wakes the output when a delayed change falls due (no frames may come).
fn arm(output: *Output, due_ns: u64) void {
    const timer = output.vrr.timer orelse blk: {
        const source = output.server.wl_server.getEventLoop().addTimer(*Output, onTimer, output) catch return;
        output.vrr.timer = source;
        break :blk source;
    };
    const now = stats.nowNs();
    const delay_ms: i32 = @intCast(@min((due_ns -| now) / std.time.ns_per_ms + 1, std.math.maxInt(i32)));
    timer.timerUpdate(delay_ms) catch {};
}

fn onTimer(output: *Output) c_int {
    output.wlr_output.scheduleFrame();
    return 0;
}

pub fn deinit(output: *Output) void {
    if (output.vrr.timer) |source| source.remove();
    output.vrr.timer = null;
}
