//! Laptop lid switches. Native sessions use the shared power policy, including
//! dock overrides and logind ownership. Legacy/nested sessions retain the
//! previous docked-panel policy and leave undocked suspend to logind.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Input = @import("../Input.zig");
const Output = @import("../Output.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

const log = std.log.scoped(.lid);

pub const Action = @import("config").types.LidAction;

input: *Input,
devices: wl.list.Head(Device, .link) = undefined,
/// Any lid switch reports closed.
closed: bool = false,

const Device = struct {
    owner: *Self,
    device: *wlr.InputDevice,
    closed: bool = false,
    link: wl.list.Link = undefined,
    toggle: wl.Listener(*wlr.Switch.event.Toggle) = .init(handleToggle),
    destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),
};

pub fn init(self: *Self, input: *Input) void {
    self.* = .{ .input = input };
    self.devices.init();
}

pub fn deinit(self: *Self) void {
    while (self.devices.first()) |device| release(device);
}

/// Whether this machine has a lid (Settings shows lid options only then).
pub fn present(self: *Self) bool {
    return !self.devices.empty();
}

pub fn addDevice(self: *Self, device: *wlr.InputDevice) void {
    const tracked = gpa.create(Device) catch {
        log.err("could not track a switch", .{});
        return;
    };
    tracked.* = .{ .owner = self, .device = device };
    device.toSwitch().events.toggle.add(&tracked.toggle);
    device.events.destroy.add(&tracked.destroy);
    self.devices.append(tracked);
}

fn release(tracked: *Device) void {
    tracked.link.remove();
    tracked.toggle.link.remove();
    tracked.destroy.link.remove();
    gpa.destroy(tracked);
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const tracked: *Device = @fieldParentPtr("destroy", listener);
    const self = tracked.owner;
    release(tracked);
    self.update(false);
}

fn handleToggle(listener: *wl.Listener(*wlr.Switch.event.Toggle), event: *wlr.Switch.event.Toggle) void {
    const tracked: *Device = @fieldParentPtr("toggle", listener);
    // Tablet-mode switches have no policy yet.
    if (event.switch_type != .lid) return;
    tracked.closed = event.switch_state == .on;
    tracked.owner.update(true);
}

fn update(self: *Self, act: bool) void {
    var closed = false;
    var it = self.devices.iterator(.forward);
    while (it.next()) |tracked| closed = closed or tracked.closed;
    if (closed == self.closed) return;
    self.closed = closed;
    const server = self.input.server;
    log.info("lid {s}", .{if (closed) "closed" else "opened"});
    // Opening the lid is user activity: wake blanked displays.
    if (!closed) if (server.idle) |im| im.notifyActivity(.lid);
    // Decide before the panel goes off: afterwards it no longer counts.
    const docked = Output.otherDisplayOn(server);
    Output.applyLid(server);
    if (!closed or !act or server.power_policy.enabled()) return;
    switch (if (server.power_policy.enabled()) server.power_policy.lidAction() else server.config.compositor.lid_close) {
        .display_off, .ignore => {},
        .lock => @import("../session/lock.zig").Lock.start(server),
        .@"suspend" => {
            if (server.power_policy.lockOnSuspend(server)) @import("../session/lock.zig").Lock.start(server);
            // Undocked, logind handles the lid itself; asking too could
            // suspend a second time right after resume.
            const owns_lid = if (server.power) |pm| pm.lid_fd != null else false;
            if (docked or owns_lid) if (server.power) |pm| pm.requestSuspendAuto();
        },
    }
}
