//! Drawing tablets. Over a client that binds tablet-v2 (Krita, GIMP, most
//! GTK and Qt apps) a pen is sent as a tablet tool with pressure and tilt;
//! everywhere else it drives the pointer: the tip is the left button, the
//! first two barrel buttons right and middle. A pressed tip stays with the
//! surface it went down on. Pads (the tablet's own buttons, rings and
//! strips) follow the surface the pen last entered.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Input = @import("../Input.zig");
const scene_data = @import("../scene_data.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

const log = std.log.scoped(.tablet);

// linux/input-event-codes.h
const btn_stylus: u32 = 0x14b;
const btn_stylus2: u32 = 0x14c;

input: *Input,
/// tablet-v2; without it every tool emulates the pointer.
manager: ?*wlr.TabletManagerV2 = null,
tablets: wl.list.Head(Tablet, .link) = undefined,
pads: wl.list.Head(Pad, .link) = undefined,

axis: wl.Listener(*wlr.Tablet.event.Axis) = .init(handleAxis),
proximity: wl.Listener(*wlr.Tablet.event.Proximity) = .init(handleProximity),
tip: wl.Listener(*wlr.Tablet.event.Tip) = .init(handleTip),
button: wl.Listener(*wlr.Tablet.event.Button) = .init(handleButton),

const Tablet = struct {
    owner: *Self,
    device: *wlr.InputDevice,
    v2: ?*wlr.TabletV2Tablet,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(*wlr.InputDevice) = .init(tabletDestroyed),
};

const Pad = struct {
    owner: *Self,
    v2: *wlr.TabletV2TabletPad,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(*wlr.InputDevice) = .init(padDestroyed),
    button: wl.Listener(*wlr.TabletPad.event.Button) = .init(padButton),
    ring: wl.Listener(*wlr.TabletPad.event.Ring) = .init(padRing),
    strip: wl.Listener(*wlr.TabletPad.event.Strip) = .init(padStrip),
};

/// One pen, eraser or puck, reachable through `wlr.TabletTool.data`.
const Tool = struct {
    owner: *Self,
    wlr_tool: *wlr.TabletTool,
    v2: ?*wlr.TabletV2TabletTool = null,
    route: enum { none, client, pointer } = .none,
    /// Surface-local mapping of the client surface under the tool.
    anchor: ?Input.SurfaceAnchor = null,
    tip_down: bool = false,
    /// The press that woke blanked displays; its release is swallowed too.
    tip_swallowed: bool = false,
    /// Emulated right/middle buttons held.
    held_buttons: u2 = 0,
    device: ?*wlr.InputDevice = null,
    tilt_x: f64 = 0,
    tilt_y: f64 = 0,
    set_cursor: wl.Listener(*wlr.TabletV2TabletTool.event.SetCursor) = .init(setCursor),
    destroy: wl.Listener(*wlr.TabletTool) = .init(toolDestroyed),

    /// Mice and lenses move the cursor relatively, like a mouse.
    fn relative(tool: *const Tool) bool {
        return tool.wlr_tool.type == .mouse or tool.wlr_tool.type == .lens;
    }
};

pub fn init(self: *Self, input: *Input) void {
    self.* = .{ .input = input };
    self.tablets.init();
    self.pads.init();
    // The display owns the manager; soft-fail like other optional globals.
    self.manager = wlr.TabletManagerV2.create(input.server.wl_server) catch |err| blk: {
        log.warn("could not create tablet-v2 manager: {}", .{err});
        break :blk null;
    };
    const cursor = input.cursor;
    cursor.events.tablet_tool_axis.add(&self.axis);
    cursor.events.tablet_tool_proximity.add(&self.proximity);
    cursor.events.tablet_tool_tip.add(&self.tip);
    cursor.events.tablet_tool_button.add(&self.button);
}

pub fn deinit(self: *Self) void {
    self.axis.link.remove();
    self.proximity.link.remove();
    self.tip.link.remove();
    self.button.link.remove();
    while (self.tablets.first()) |tablet| releaseTablet(tablet);
    while (self.pads.first()) |pad| releasePad(pad);
}

pub fn addTablet(self: *Self, device: *wlr.InputDevice) void {
    const tablet = gpa.create(Tablet) catch {
        log.err("could not track a tablet", .{});
        return;
    };
    const v2: ?*wlr.TabletV2Tablet = if (self.manager) |manager|
        manager.createTabletV2Tablet(self.input.seat, device) catch null
    else
        null;
    tablet.* = .{ .owner = self, .device = device, .v2 = v2 };
    device.events.destroy.add(&tablet.destroy);
    self.tablets.append(tablet);
    self.input.cursor.attachInputDevice(device);
}

pub fn addPad(self: *Self, device: *wlr.InputDevice) void {
    const manager = self.manager orelse return;
    const pad = gpa.create(Pad) catch {
        log.err("could not track a tablet pad", .{});
        return;
    };
    const v2 = manager.createTabletV2TabletPad(self.input.seat, device) catch {
        gpa.destroy(pad);
        return;
    };
    pad.* = .{ .owner = self, .v2 = v2 };
    const wlr_pad = device.toTabletPad();
    device.events.destroy.add(&pad.destroy);
    wlr_pad.events.button.add(&pad.button);
    wlr_pad.events.ring.add(&pad.ring);
    wlr_pad.events.strip.add(&pad.strip);
    self.pads.append(pad);
}

fn tabletDestroyed(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    releaseTablet(@fieldParentPtr("destroy", listener));
}

fn releaseTablet(tablet: *Tablet) void {
    tablet.link.remove();
    tablet.destroy.link.remove();
    gpa.destroy(tablet);
}

fn padDestroyed(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    releasePad(@fieldParentPtr("destroy", listener));
}

fn releasePad(pad: *Pad) void {
    pad.link.remove();
    pad.destroy.link.remove();
    pad.button.link.remove();
    pad.ring.link.remove();
    pad.strip.link.remove();
    gpa.destroy(pad);
}

fn padButton(listener: *wl.Listener(*wlr.TabletPad.event.Button), event: *wlr.TabletPad.event.Button) void {
    const pad: *Pad = @fieldParentPtr("button", listener);
    if (pad.owner.input.server.idle) |im| im.notifyActivity(.tablet);
    _ = pad.v2.notifyMode(event.group, event.mode, event.time_msec);
    pad.v2.notifyButton(event.button, event.time_msec, event.state);
}

fn padRing(listener: *wl.Listener(*wlr.TabletPad.event.Ring), event: *wlr.TabletPad.event.Ring) void {
    const pad: *Pad = @fieldParentPtr("ring", listener);
    if (pad.owner.input.server.idle) |im| im.notifyActivity(.tablet);
    pad.v2.notifyRing(event.ring, event.position, event.source == .finger, event.time_msec);
}

fn padStrip(listener: *wl.Listener(*wlr.TabletPad.event.Strip), event: *wlr.TabletPad.event.Strip) void {
    const pad: *Pad = @fieldParentPtr("strip", listener);
    if (pad.owner.input.server.idle) |im| im.notifyActivity(.tablet);
    pad.v2.notifyStrip(event.strip, event.position, event.source == .finger, event.time_msec);
}

fn findTablet(self: *Self, device: *wlr.InputDevice) ?*Tablet {
    var it = self.tablets.iterator(.forward);
    while (it.next()) |tablet| if (tablet.device == device) return tablet;
    return null;
}

fn toolFor(self: *Self, wlr_tool: *wlr.TabletTool) ?*Tool {
    if (wlr_tool.data) |data| return @ptrCast(@alignCast(data));
    const tool = gpa.create(Tool) catch return null;
    tool.* = .{ .owner = self, .wlr_tool = wlr_tool };
    // Before the v2 tool exists: its own destroy listener must run after ours,
    // which still unhooks set_cursor from it.
    wlr_tool.events.destroy.add(&tool.destroy);
    wlr_tool.data = tool;
    if (self.manager) |manager| {
        tool.v2 = manager.createTabletV2TabletTool(self.input.seat, wlr_tool) catch null;
    }
    if (tool.v2) |v2| v2.events.set_cursor.add(&tool.set_cursor) else tool.set_cursor.link.init();
    return tool;
}

fn toolDestroyed(listener: *wl.Listener(*wlr.TabletTool), wlr_tool: *wlr.TabletTool) void {
    const tool: *Tool = @fieldParentPtr("destroy", listener);
    tool.owner.leaveClient(tool);
    tool.owner.leavePointer(tool, 0);
    tool.set_cursor.link.remove();
    tool.destroy.link.remove();
    wlr_tool.data = null;
    gpa.destroy(tool);
}

/// A client asks for a cursor image while the tool is over its surface.
fn setCursor(listener: *wl.Listener(*wlr.TabletV2TabletTool.event.SetCursor), event: *wlr.TabletV2TabletTool.event.SetCursor) void {
    const tool: *Tool = @fieldParentPtr("set_cursor", listener);
    const input = tool.owner.input;
    if (tool.route != .client or input.server.locker != null or input.server.polkit_dialog != null) return;
    const focused = (tool.v2 orelse return).focused_surface orelse return;
    if (event.seat_client.client != focused.resource.getClient()) return;
    input.default_cursor_applied = false;
    input.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    input.cursor_source = if (event.surface != null) .surface else .hidden;
    input.cursor_name = null;
}

fn handleAxis(listener: *wl.Listener(*wlr.Tablet.event.Axis), event: *wlr.Tablet.event.Axis) void {
    const self: *Self = @fieldParentPtr("axis", listener);
    const tool = self.toolFor(event.tool) orelse return;
    const tablet = self.findTablet(event.device) orelse return;
    if (self.input.server.idle) |im| im.notifyActivity(.tablet);
    const axes = event.updated_axes;
    if (axes.x or axes.y) {
        self.moveTool(tablet, tool, event.device, if (axes.x) event.x else std.math.nan(f64), if (axes.y) event.y else std.math.nan(f64), event.dx, event.dy, event.time_msec);
    }
    if (axes.tilt_x) tool.tilt_x = event.tilt_x;
    if (axes.tilt_y) tool.tilt_y = event.tilt_y;
    if (tool.route != .client) return;
    const v2 = tool.v2 orelse return;
    if (axes.pressure) v2.notifyPressure(event.pressure);
    if (axes.distance) v2.notifyDistance(event.distance);
    if (axes.tilt_x or axes.tilt_y) v2.notifyTilt(tool.tilt_x, tool.tilt_y);
    if (axes.rotation) v2.notifyRotation(event.rotation);
    if (axes.slider) v2.notifySlider(event.slider);
    if (axes.wheel) v2.notifyWheel(event.wheel_delta, 0);
}

fn handleProximity(listener: *wl.Listener(*wlr.Tablet.event.Proximity), event: *wlr.Tablet.event.Proximity) void {
    const self: *Self = @fieldParentPtr("proximity", listener);
    const tool = self.toolFor(event.tool) orelse return;
    const tablet = self.findTablet(event.device) orelse return;
    if (event.state == .out) {
        self.leaveClient(tool);
        self.leavePointer(tool, event.time_msec);
        tool.route = .none;
        return;
    }
    if (self.input.server.idle) |im| im.notifyActivity(.tablet);
    if (tool.relative()) {
        self.moveTool(tablet, tool, event.device, std.math.nan(f64), std.math.nan(f64), 0, 0, event.time_msec);
    } else {
        self.moveTool(tablet, tool, event.device, event.x, event.y, 0, 0, event.time_msec);
    }
}

fn handleTip(listener: *wl.Listener(*wlr.Tablet.event.Tip), event: *wlr.Tablet.event.Tip) void {
    const self: *Self = @fieldParentPtr("tip", listener);
    const input = self.input;
    const tool = self.toolFor(event.tool) orelse return;
    const tablet = self.findTablet(event.device) orelse return;
    if (event.state == .down) {
        if (input.server.idle) |im| {
            if (im.state != .active) {
                im.notifyActivity(.tablet);
                tool.tip_swallowed = true;
                return;
            }
            im.notifyActivity(.tablet);
        }
        if (tool.route == .none) self.moveTool(tablet, tool, event.device, event.x, event.y, 0, 0, event.time_msec);
        tool.tip_down = true;
        switch (tool.route) {
            .client => {
                input.focusForPress(scene_data.hitTest(input.server, input.cursor.x, input.cursor.y));
                if (tool.v2) |v2| v2.notifyDown();
            },
            else => {
                tool.route = .pointer;
                tool.device = event.device;
                input.processButton(event.device, Input.btn_left, .pressed, event.time_msec);
                input.seat.pointerNotifyFrame();
            },
        }
        return;
    }
    if (tool.tip_swallowed) {
        tool.tip_swallowed = false;
        return;
    }
    if (!tool.tip_down) return;
    tool.tip_down = false;
    switch (tool.route) {
        .client => {
            if (tool.v2) |v2| v2.notifyUp();
            // Lifted over another surface: hand the tool to it now.
            self.moveTool(tablet, tool, event.device, std.math.nan(f64), std.math.nan(f64), 0, 0, event.time_msec);
        },
        .pointer => {
            input.processButton(event.device, Input.btn_left, .released, event.time_msec);
            input.seat.pointerNotifyFrame();
        },
        .none => {},
    }
}

fn handleButton(listener: *wl.Listener(*wlr.Tablet.event.Button), event: *wlr.Tablet.event.Button) void {
    const self: *Self = @fieldParentPtr("button", listener);
    const input = self.input;
    const tool = self.toolFor(event.tool) orelse return;
    if (input.server.idle) |im| im.notifyActivity(.tablet);
    if (tool.route == .client) {
        if (tool.v2) |v2| v2.notifyButton(event.button, event.state);
        return;
    }
    const bit: u2 = switch (event.button) {
        btn_stylus => 1,
        btn_stylus2 => 2,
        else => return,
    };
    const pressed = event.state == .pressed;
    // Presses before proximity-in, or releases for presses sent to a client.
    if (pressed == (tool.held_buttons & bit != 0)) return;
    tool.held_buttons ^= bit;
    tool.route = .pointer;
    tool.device = event.device;
    input.processButton(event.device, pointerButton(bit), if (pressed) .pressed else .released, event.time_msec);
    input.seat.pointerNotifyFrame();
}

fn pointerButton(bit: u2) u32 {
    return if (bit == 1) Input.btn_right else Input.btn_middle;
}

/// Moves the tool to normalized tablet coordinates (NaN keeps an axis), or
/// by a relative delta for mice and lenses, and routes it to what is there.
fn moveTool(self: *Self, tablet: *Tablet, tool: *Tool, device: *wlr.InputDevice, x: f64, y: f64, dx: f64, dy: f64, time_msec: u32) void {
    const input = self.input;
    var lx: f64 = undefined;
    var ly: f64 = undefined;
    if (tool.relative()) {
        lx = input.cursor.x + dx;
        ly = input.cursor.y + dy;
    } else {
        input.cursor.absoluteToLayoutCoords(device, x, y, &lx, &ly);
    }

    // A pressed tip or button stays with where it went down.
    if (tool.route == .client and tool.tip_down) {
        _ = input.cursor.warpClosest(device, lx, ly);
        if (tool.anchor) |anchor| {
            const local = anchor.local(input, input.cursor.x, input.cursor.y);
            if (tool.v2) |v2| v2.notifyMotion(local.x, local.y);
        }
        return;
    }
    if (tool.route == .pointer and (tool.tip_down or tool.held_buttons != 0)) {
        input.layoutMotion(device, lx, ly, time_msec);
        input.seat.pointerNotifyFrame();
        return;
    }

    if (tool.v2 != null and tablet.v2 != null and input.directInputReachesClients()) {
        const hit = scene_data.hitTest(input.server, lx, ly);
        if (input.clientTarget(hit, lx, ly)) |target| {
            if (target.surface.acceptsTabletV2(tablet.v2.?)) {
                const v2 = tool.v2.?;
                // The pen, not the emulated pointer, is on this client now.
                if (tool.route == .pointer) input.seat.pointerClearFocus();
                _ = input.cursor.warpClosest(device, lx, ly);
                const entering = v2.focused_surface != target.surface;
                v2.notifyProximityIn(tablet.v2.?, target.surface);
                v2.notifyMotion(target.sx, target.sy);
                if (entering) {
                    var pads = self.pads.iterator(.forward);
                    while (pads.next()) |pad| _ = pad.v2.notifyEnter(tablet.v2.?, target.surface);
                }
                tool.anchor = target.anchor;
                tool.route = .client;
                return;
            }
        }
    }
    self.leaveClient(tool);
    tool.route = .pointer;
    tool.device = device;
    input.layoutMotion(device, lx, ly, time_msec);
    input.seat.pointerNotifyFrame();
}

fn leaveClient(self: *Self, tool: *Tool) void {
    if (tool.route != .client) return;
    tool.route = .none;
    tool.anchor = null;
    if (tool.v2) |v2| {
        if (tool.tip_down) v2.notifyUp();
        v2.notifyProximityOut();
    }
    tool.tip_down = false;
    // The client's tablet cursor is no longer its to show.
    const input = self.input;
    if (input.cursor_source == .surface or input.cursor_source == .hidden) {
        input.seat.pointerClearFocus();
        input.setDefaultCursor();
    }
}

/// Releases whatever the tool holds down on the emulated pointer.
fn leavePointer(self: *Self, tool: *Tool, time_msec: u32) void {
    if (tool.route != .pointer) return;
    const input = self.input;
    const device = tool.device;
    const released = tool.tip_down or tool.held_buttons != 0;
    if (tool.tip_down) {
        tool.tip_down = false;
        input.processButton(device, Input.btn_left, .released, time_msec);
    }
    inline for (.{ 1, 2 }) |bit| {
        if (tool.held_buttons & bit != 0) input.processButton(device, pointerButton(bit), .released, time_msec);
    }
    tool.held_buttons = 0;
    if (released) input.seat.pointerNotifyFrame();
}
