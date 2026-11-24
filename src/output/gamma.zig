//! An external ramp temporarily owns the output's hardware LUT. Both it
//! and Night Light are tested and committed by Output.commitFrameState.
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
pub const Event = wlr.gamma_control.Manager.SetGamma;

pub fn init(server: *Server) !void {
    const manager = wlr.gamma_control.Manager.create(server.wl_server) orelse return error.OutOfMemory;
    manager.events.set_gamma.add(&server.set_gamma);
}

pub fn changed(_: *wl.Listener(*Event), event: *Event) void {
    const output = Output.fromWlr(event.output) orelse {
        if (event.control) |control| control.fail();
        return;
    };
    const color = &output.color;
    if (event.control) |control| {
        // A ramp is written for an SDR signal (docs/plans/hdr.md, D6).
        if (@import("hdr.zig").signal(output)) {
            control.fail();
            return;
        }
        const transform = control.getTransform() orelse {
            control.fail();
            return;
        };
        color.replaceTransform(transform);
        color.external = control;
        color.key = null;
        color.pending = true;
        color.consecutive_failures = 0;
        output.wlr_output.scheduleFrame();
    } else if (color.external != null) {
        color.external = null;
        color.pending = false;
        // Keep the previous transform until retargetOutput replaces it,
        // including an explicit reset when the local settings are neutral.
        refresh(output);
    }
}

/// Reapply the active owner's ramp after a modeset or output wake.
pub fn refresh(output: *Output) void {
    output.color.key = null;
    if (output.color.external != null) {
        output.color.pending = true;
        output.wlr_output.scheduleFrame();
    } else {
        output.server.night_light.retargetOutput(output);
    }
}
