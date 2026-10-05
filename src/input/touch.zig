//! Touchscreens. A touch on a client that binds wl_touch goes to it as
//! touch; anything else (shell UI, window chrome, clients without wl_touch,
//! the lock, dialogs, menus) drives the pointer with the first finger, so it
//! gets exactly the mouse's policy. Further fingers during emulation are
//! dropped.
//!
//! Touchscreens are mapped to the output they report (libinput's WL_OUTPUT
//! udev property), otherwise to the built-in panel: a laptop's touchscreen
//! must not stretch across an external monitor.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Input = @import("../Input.zig");
const Output = @import("../Output.zig");
const scene_data = @import("../scene_data.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

const log = std.log.scoped(.touch);

const max_points = 16;

input: *Input,
devices: wl.list.Head(Device, .link) = undefined,
points: [max_points]Point = undefined,
point_count: usize = 0,
/// The touch id driving the emulated pointer.
emulating: ?i32 = null,

down: wl.Listener(*wlr.Touch.event.Down) = .init(handleDown),
up: wl.Listener(*wlr.Touch.event.Up) = .init(handleUp),
motion: wl.Listener(*wlr.Touch.event.Motion) = .init(handleMotion),
cancel: wl.Listener(*wlr.Touch.event.Cancel) = .init(handleCancel),
frame: wl.Listener(void) = .init(handleFrame),

const Point = struct {
    id: i32,
    device: *wlr.InputDevice,
    route: union(enum) {
        /// Sent as wl_touch; coordinates stay relative to the pressed surface.
        client: Input.SurfaceAnchor,
        /// Drives the pointer.
        pointer,
        /// Swallowed: an extra finger during emulation, or the touch that
        /// woke blanked displays.
        ignored,
    },
};

const Device = struct {
    owner: *Self,
    device: *wlr.InputDevice,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),
};

pub fn init(self: *Self, input: *Input) void {
    self.* = .{ .input = input };
    self.devices.init();
    const cursor = input.cursor;
    cursor.events.touch_down.add(&self.down);
    cursor.events.touch_up.add(&self.up);
    cursor.events.touch_motion.add(&self.motion);
    cursor.events.touch_cancel.add(&self.cancel);
    cursor.events.touch_frame.add(&self.frame);
}

pub fn deinit(self: *Self) void {
    self.down.link.remove();
    self.up.link.remove();
    self.motion.link.remove();
    self.cancel.link.remove();
    self.frame.link.remove();
    while (self.devices.first()) |device| release(device);
}

pub fn addDevice(self: *Self, device: *wlr.InputDevice) void {
    const tracked = gpa.create(Device) catch {
        log.err("could not track a touch device", .{});
        return;
    };
    tracked.* = .{ .owner = self, .device = device };
    device.events.destroy.add(&tracked.destroy);
    self.devices.append(tracked);
    self.input.cursor.attachInputDevice(device);
    self.mapDevice(device);
}

/// Re-maps every touchscreen after the outputs change.
pub fn remap(self: *Self) void {
    var it = self.devices.iterator(.forward);
    while (it.next()) |tracked| self.mapDevice(tracked.device);
}

fn mapDevice(self: *Self, device: *wlr.InputDevice) void {
    const touch = device.toTouch();
    const wanted: ?[]const u8 = if (touch.output_name[0] != 0) std.mem.span(touch.output_name) else null;
    var target: ?*Output = null;
    var it = self.input.server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (!output.isAvailable()) continue;
        const name = std.mem.span(output.wlr_output.name);
        if (wanted) |w| {
            if (std.mem.eql(u8, name, w)) target = output;
        } else if (target == null and Output.isBuiltinPanel(name)) {
            target = output;
        }
    }
    self.input.cursor.mapInputToOutput(device, if (target) |t| t.wlr_output else null);
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const tracked: *Device = @fieldParentPtr("destroy", listener);
    const self = tracked.owner;
    // Its up events will never arrive.
    var i: usize = self.point_count;
    while (i > 0) {
        i -= 1;
        // Cancelling a client's touch can end several points at once.
        if (i >= self.point_count) continue;
        if (self.points[i].device == tracked.device) self.endPoint(i, 0, true);
    }
    release(tracked);
    self.input.updateCapabilities();
}

fn release(tracked: *Device) void {
    tracked.link.remove();
    tracked.destroy.link.remove();
    gpa.destroy(tracked);
}

fn find(self: *Self, id: i32) ?usize {
    for (self.points[0..self.point_count], 0..) |point, i| if (point.id == id) return i;
    return null;
}

fn handleDown(listener: *wl.Listener(*wlr.Touch.event.Down), event: *wlr.Touch.event.Down) void {
    const self: *Self = @fieldParentPtr("down", listener);
    const input = self.input;
    const server = input.server;
    @import("../startup.zig").markFirstInput();
    if (self.find(event.touch_id)) |stale| self.endPoint(stale, event.time_msec, true);
    if (self.point_count == max_points) return;

    var point: Point = .{ .id = event.touch_id, .device = event.device, .route = .ignored };
    defer {
        self.points[self.point_count] = point;
        self.point_count += 1;
    }
    if (server.idle) |im| {
        if (im.state != .active) {
            // Like a mouse button, the waking touch does nothing else.
            im.notifyActivity(.touch);
            return;
        }
        im.notifyActivity(.touch);
    }

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    input.cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);
    if (self.emulating == null and input.directInputReachesClients()) {
        const hit = scene_data.hitTest(server, lx, ly);
        if (input.clientTarget(hit, lx, ly)) |target| {
            if (bindsTouch(input.seat, target.surface)) {
                input.focusForPress(hit);
                if (input.seat.touchNotifyDown(target.surface, event.time_msec, event.touch_id, target.sx, target.sy) != 0) {
                    point.route = .{ .client = target.anchor };
                    return;
                }
            }
        }
    }
    // Only one finger drives the pointer, and not while fingers are on a client.
    if (self.emulating != null or input.seat.touchNumPoints() > 0) return;
    self.emulating = event.touch_id;
    point.route = .pointer;
    input.layoutMotion(event.device, lx, ly, event.time_msec);
    input.processButton(event.device, Input.btn_left, .pressed, event.time_msec);
    input.seat.pointerNotifyFrame();
}

fn bindsTouch(seat: *wlr.Seat, surface: *wlr.Surface) bool {
    const client = seat.clientForWlClient(surface.resource.getClient()) orelse return false;
    return !client.touches.empty();
}

fn handleUp(listener: *wl.Listener(*wlr.Touch.event.Up), event: *wlr.Touch.event.Up) void {
    const self: *Self = @fieldParentPtr("up", listener);
    const index = self.find(event.touch_id) orelse return;
    if (self.points[index].route != .ignored) {
        if (self.input.server.idle) |im| im.notifyActivity(.touch);
    }
    self.endPoint(index, event.time_msec, false);
}

fn handleMotion(listener: *wl.Listener(*wlr.Touch.event.Motion), event: *wlr.Touch.event.Motion) void {
    const self: *Self = @fieldParentPtr("motion", listener);
    const input = self.input;
    const index = self.find(event.touch_id) orelse return;
    const point = self.points[index];
    if (point.route == .ignored) return;
    if (input.server.idle) |im| im.notifyActivity(.touch);
    var lx: f64 = undefined;
    var ly: f64 = undefined;
    input.cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);
    switch (point.route) {
        .client => |anchor| {
            const local = anchor.local(input, lx, ly);
            input.seat.touchNotifyMotion(event.time_msec, event.touch_id, local.x, local.y);
        },
        .pointer => {
            input.layoutMotion(event.device, lx, ly, event.time_msec);
            input.seat.pointerNotifyFrame();
        },
        .ignored => {},
    }
}

fn handleCancel(listener: *wl.Listener(*wlr.Touch.event.Cancel), event: *wlr.Touch.event.Cancel) void {
    const self: *Self = @fieldParentPtr("cancel", listener);
    const index = self.find(event.touch_id) orelse return;
    self.endPoint(index, event.time_msec, true);
}

fn handleFrame(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("frame", listener);
    self.input.seat.touchNotifyFrame();
}

/// Lifts a finger: a client gets up (or cancel), the emulated pointer a release.
fn endPoint(self: *Self, index: usize, time_msec: u32, cancelled: bool) void {
    const input = self.input;
    const point = self.points[index];
    self.points[index] = self.points[self.point_count - 1];
    self.point_count -= 1;
    switch (point.route) {
        .client => {
            if (cancelled) {
                if (input.seat.touchGetPoint(point.id)) |wlr_point| {
                    input.seat.touchNotifyCancel(wlr_point.client);
                    // Cancel ends every touch of that client.
                    var i: usize = self.point_count;
                    while (i > 0) {
                        i -= 1;
                        if (self.points[i].route == .client and input.seat.touchGetPoint(self.points[i].id) == null) {
                            self.points[i] = self.points[self.point_count - 1];
                            self.point_count -= 1;
                        }
                    }
                }
            } else {
                _ = input.seat.touchNotifyUp(time_msec, point.id);
            }
        },
        .pointer => {
            self.emulating = null;
            input.processButton(point.device, Input.btn_left, .released, time_msec);
            input.seat.pointerNotifyFrame();
        },
        .ignored => {},
    }
}
