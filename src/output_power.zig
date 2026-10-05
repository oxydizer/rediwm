//! wlr-output-power-management-v1: wlopm and swayidle's `output off`. A
//! client's `off` darkens the output through the idle-blank path and holds it
//! there (`Output.power_off`): idle wake and inhibitors leave it dark until a
//! client turns it back on. The one exception is input while no output is
//! lit (`wakeIfAllDark`), since nothing on screen could turn them back on.
//! wlroots sends `mode` from each output commit, so idle blanking reports
//! `off` too.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("Server.zig");
const Output = @import("Output.zig");
const gpa = @import("main.zig").gpa;

const log = std.log.scoped(.output_power);

pub const Manager = struct {
    manager: *wlr.OutputPowerManagerV1,
    set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) = .init(handleSetMode),

    pub fn create(server: *Server) !*Manager {
        const self = try gpa.create(Manager);
        errdefer gpa.destroy(self);
        self.* = .{ .manager = try wlr.OutputPowerManagerV1.create(server.wl_server) };
        self.manager.events.set_mode.add(&self.set_mode);
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.set_mode.link.remove();
        gpa.destroy(self);
    }

    fn handleSetMode(_: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode), event: *wlr.OutputPowerManagerV1.event.SetMode) void {
        const output = Output.fromWlr(event.output) orelse return;
        switch (event.mode) {
            .off => setOn(output, false),
            .on => setOn(output, true),
            _ => {},
        }
    }
};

fn setOn(output: *Output, on: bool) void {
    if (on) {
        output.power_off = false;
        _ = output.setIdleBlanked(false);
    } else {
        // A disabled output or failed commit leaves nothing to hold dark.
        output.power_off = output.setIdleBlanked(true);
        if (!output.power_off) return;
    }
    log.info("{s}: turned {s} by client", .{ output.wlr_output.name, if (on) "on" else "off" });
}

/// Called on input: if clients turned off every output that isn't disabled,
/// wake those, as the user has no other way back.
pub fn wakeIfAllDark(server: *Server) void {
    var any_off = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.wlr_output.enabled) return;
        any_off = any_off or output.power_off;
    }
    if (!any_off) return;
    it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.power_off) setOn(output, true);
    }
}
