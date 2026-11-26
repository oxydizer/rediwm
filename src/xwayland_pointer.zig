//! X11 uses one root window stack even when two Wayland outputs show separate
//! workspaces. A root stacking change and wl_pointer events travel on different
//! sockets. Wait for the XWM marker before sending input, and for X to consume
//! a button before sending a later pointer position or restack.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Xwayland = @import("Xwayland.zig");
const Top = @import("Toplevel.zig");
const Surface = @import("wlroots").Surface;
const scene = @import("scene_data.zig");
const Self = @This();
const gpa = @import("main.zig").gpa;

// A queued native event can outlive the original wl_surface and even another
// allocation at its address. Its destroy listener invalidates every queued use.
const NativeSurface = struct {
    surface: ?*Surface,
    x11: bool,
    next: ?*NativeSurface,
    destroy: wl.Listener(*Surface) = .init(destroyed),

    fn destroyed(listener: *wl.Listener(*Surface), _: *Surface) void {
        const ref: *NativeSurface = @fieldParentPtr("destroy", listener);
        ref.destroy.link.remove();
        ref.surface = null;
    }
};

const Target = struct {
    id: u64,
    workspace: u8,
    sx: f64,
    sy: f64,

    native: ?struct { ref: *NativeSurface, x: f64, y: f64 } = null,

    fn independent(target: Target) bool {
        const n = target.native orelse return false;
        return !n.ref.x11;
    }

    fn live(target: Target, xw: *Xwayland) ?*Surface {
        if (target.native) |n| {
            const surface = switch (scene.hitTest(xw.server, n.x, n.y)) {
                .surface => |h| h.surface,
                .layer => |h| h.surface,
                .xwayland_unmanaged => |h| h.surface,
                .input_popup => |h| h.surface,
                else => return null,
            };
            return if (surface == n.ref.surface) surface else null;
        }
        const top = xw.server.findToplevelById(target.id) orelse return null;
        if (!top.in_world or top.closing or top.backend_gone or top.backend != .xwayland or
            top.workspace_id != target.workspace or !top.frame_tree.node.enabled or
            !@import("window_tabs.zig").visible(top)) return null;
        return top.surface();
    }
};

const Button = struct { code: u32, state: wl.Pointer.ButtonState };
const Event = struct { target: Target, time: u32, button: ?Button = null };

events: std.ArrayList(Event) = .empty,
marker: ?u32 = null,
button_ack: ?Button = null,
button_target: u64 = 0,
// Device-side grab until release, independent of when X actually receives it.
grab: ?Target = null,
held: u32 = 0,
forwarded: u32 = 0,
forwarded_id: u64 = 0,
repick: ?u32 = null,
native_surfaces: ?*NativeSurface = null,
native_deadline: ?*wl.EventSource = null,

fn nativeTarget(self: *Self, xw: *Xwayland, surface: *Surface, sx: f64, sy: f64) ?Target {
    var ref = self.native_surfaces;
    while (ref) |item| : (ref = item.next) {
        if (item.surface == surface) break;
    }
    if (ref == null) {
        const item = gpa.create(NativeSurface) catch return null;
        // An override-redirect X popup also uses this weak-reference path,
        // but its input must still be cancelled if its X server stalls.
        const xclient = if (xw.wlr_xwayland.server) |server| server.client else null;
        item.* = .{ .surface = surface, .next = self.native_surfaces, .x11 = xclient == surface.resource.getClient() };
        surface.events.destroy.add(&item.destroy);
        self.native_surfaces = item;
        ref = item;
    }
    return .{ .id = 0, .workspace = 0, .sx = sx, .sy = sy, .native = .{
        .ref = ref.?,
        .x = xw.server.input.cursor.x,
        .y = xw.server.input.cursor.y,
    } };
}

fn clearNativeSurfaces(self: *Self) void {
    while (self.native_surfaces) |ref| {
        self.native_surfaces = ref.next;
        if (ref.surface != null) ref.destroy.link.remove();
        gpa.destroy(ref);
    }
}

fn cancelDeadline(self: *Self) void {
    if (self.native_deadline) |source| source.remove();
    self.native_deadline = null;
}

fn hasNativeEvents(self: *const Self) bool {
    for (self.events.items) |event| if (event.target.independent()) return true;
    return false;
}

fn nativeExpired(xw: *Xwayland) c_int {
    xw.pointer_queue.resumeNative(xw);
    return 0;
}

/// A slow or disconnected X server cannot hold the Wayland seat indefinitely.
/// Keep the order of live native events and discard undelivered X events.
pub fn resumeNative(self: *Self, xw: *Xwayland) void {
    self.cancelDeadline();
    if (!self.hasNativeEvents() or xw.server.shutting_down) return self.reset(xw);
    self.balance(xw);
    self.button_ack = null;
    self.marker = null;
    xw.pointer_workspace = 0;
    if (self.grab) |target| if (!target.independent()) {
        self.grab = null;
        self.held = 0;
    };
    var kept: usize = 0;
    for (self.events.items) |event| if (event.target.independent()) {
        self.events.items[kept] = event;
        kept += 1;
    };
    self.events.shrinkRetainingCapacity(kept);
    self.drain(xw);
}

fn balance(self: *Self, xw: *Xwayland) void {
    if (self.forwarded == 0) return;
    const seat = xw.server.input.seat;
    var held = self.forwarded;
    self.forwarded = 0;
    // A seat focus change resets its button state. Only balance buttons
    // remaining at the same target after a cancelled queued release.
    const top = xw.server.findToplevelById(self.forwarded_id) orelse return;
    if (seat.pointer_state.focused_surface == null or seat.pointer_state.focused_surface != top.surface()) return;
    while (held != 0) {
        const bit = @ctz(held);
        held &= held - 1;
        _ = seat.pointerNotifyButton(@truncate(@as(u64, @intCast(Top.nowMs()))), 272 + @as(u32, bit), .released);
    }
    seat.pointerNotifyFrame();
}

pub fn reset(self: *Self, xw: *Xwayland) void {
    self.cancelDeadline();
    self.balance(xw);
    self.clearNativeSurfaces();
    self.events.deinit(gpa);
    self.* = .{};
}

fn competing(xw: *Xwayland, workspace: u8) bool {
    var it = xw.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.workspace_id != workspace and top.backend == .xwayland and !top.backend_gone and
            top.in_world and !top.closing and @import("window_tabs.zig").visible(top)) return true;
    }
    return false;
}

fn queued(self: *const Self) bool {
    return self.marker != null or self.button_ack != null or self.events.items.len != 0;
}

pub fn motion(self: *Self, xw: *Xwayland, top: *Top, sx: f64, sy: f64, time: u32) bool {
    if (!xw.server.world.workspaces.active or top.backend != .xwayland or !xw.input_fence.canFence()) return false;
    if (!self.queued()) {
        if (xw.pointer_workspace == top.workspace_id) return false;
        if (!competing(xw, top.workspace_id)) {
            xw.preferWorkspace(top.workspace_id);
            return false;
        }
    }
    self.enqueue(xw, .{ .target = .{ .id = top.id, .workspace = top.workspace_id, .sx = sx, .sy = sy }, .time = time });
    return true;
}

/// Supersede bare X hover immediately. An accepted tap retains its position
/// in the stream; when it is complete, re-evaluate the actual cursor target.
pub fn leave(self: *Self, time: u32) bool {
    if (!self.queued()) return false;
    self.repick = time;
    if (self.events.getLastOrNull()) |event| if (event.button == null) {
        _ = self.events.pop();
    };
    return self.events.items.len > 0 or self.button_ack != null;
}

pub fn otherMotion(self: *Self, xw: *Xwayland, surface: *Surface, sx: f64, sy: f64, time: u32) bool {
    if (!self.leave(time)) return false;
    const target = self.nativeTarget(xw, surface, sx, sy) orelse {
        self.resumeNative(xw);
        return false;
    };
    self.enqueue(xw, .{ .target = target, .time = time });
    return true;
}

pub fn otherPress(self: *Self, xw: *Xwayland, surface: *Surface, sx: f64, sy: f64, time: u32, code: u32) bool {
    if (!self.queued() or buttonBit(code) == 0) return false;
    const target = self.nativeTarget(xw, surface, sx, sy) orelse {
        self.resumeNative(xw);
        return false;
    };
    self.grab = target;
    self.held |= buttonBit(code);
    self.enqueue(xw, .{ .target = target, .time = time, .button = .{ .code = code, .state = .pressed } });
    return true;
}

pub fn press(self: *Self, xw: *Xwayland, top: *Top, sx: f64, sy: f64, time: u32, code: u32) bool {
    if (!xw.server.world.workspaces.active or top.backend != .xwayland or !xw.input_fence.canFence() or
        (!self.queued() and !competing(xw, top.workspace_id))) return false;
    const bit = buttonBit(code);
    if (bit == 0) return false;
    const target = Target{ .id = top.id, .workspace = top.workspace_id, .sx = sx, .sy = sy };
    self.grab = target;
    self.held |= bit;
    self.enqueue(xw, .{ .target = target, .time = time, .button = .{ .code = code, .state = .pressed } });
    return true;
}

fn buttonBit(code: u32) u32 {
    return if (code >= 272 and code < 304) @as(u32, 1) << @intCast(code - 272) else 0;
}

pub fn grabMotion(self: *Self, xw: *Xwayland, sx: f64, sy: f64, time: u32) bool {
    var target = self.grab orelse return false;
    target.sx = sx;
    target.sy = sy;
    self.grab = target;
    self.enqueue(xw, .{ .target = target, .time = time });
    return true;
}

pub fn release(self: *Self, xw: *Xwayland, time: u32, code: u32) bool {
    const bit = buttonBit(code);
    if (self.held & bit == 0) return false;
    const target = self.grab orelse return false;
    self.held &= ~bit;
    if (self.held == 0) self.grab = null;
    self.enqueue(xw, .{ .target = target, .time = time, .button = .{ .code = code, .state = .released } });
    return true;
}

fn enqueue(self: *Self, xw: *Xwayland, event: Event) void {
    const len = self.events.items.len;
    if (len > 0 and event.button == null and self.events.items[len - 1].button == null) {
        self.events.items[len - 1] = event;
    } else {
        // A stalled X server must not accumulate an unbounded input history.
        if (len >= 512) {
            self.reset(xw);
            xw.server.input.seat.pointerNotifyClearFocus();
            return;
        }
        self.events.append(gpa, event) catch {
            self.reset(xw);
            xw.server.input.seat.pointerNotifyClearFocus();
            return;
        };
    }
    self.drain(xw);
    if (event.target.native != null and self.native_deadline == null and self.hasNativeEvents()) {
        // A single deadline from the first native event, never extended by
        // later motion. A healthy XWM acknowledges within a local round trip.
        self.native_deadline = xw.server.wl_server.getEventLoop().addTimer(*Xwayland, nativeExpired, xw) catch return self.resumeNative(xw);
        self.native_deadline.?.timerUpdate(100) catch self.resumeNative(xw);
    }
}

fn drain(self: *Self, xw: *Xwayland) void {
    const server = xw.server;
    if (!server.world.workspaces.active or server.locker != null or server.polkit_dialog != null) {
        self.reset(xw);
        return;
    }
    const input = &server.input;
    defer {
        if (self.native_deadline != null and !self.hasNativeEvents()) self.cancelDeadline();
        if (self.events.items.len == 0 and self.grab == null) self.clearNativeSurfaces();
    }
    while (self.marker == null and self.button_ack == null and self.events.items.len > 0) {
        const event = self.events.items[0];
        const surface = event.target.live(xw) orelse {
            _ = self.events.orderedRemove(0);
            continue;
        };
        if (event.target.native == null and xw.pointer_workspace != event.target.workspace) {
            xw.preferWorkspace(event.target.workspace);
            self.marker = xw.input_fence.submit(xw);
            if (self.marker != null) return;
            self.reset(xw);
            return;
        }
        _ = self.events.orderedRemove(0);
        input.seat.pointerNotifyEnter(surface, event.target.sx, event.target.sy);
        input.seat.pointerNotifyMotion(event.time, event.target.sx, event.target.sy);
        // Xwayland consumes the coordinates on the frame before the button.
        input.seat.pointerNotifyFrame();
        if (event.button) |b| {
            if (input.seat.pointerNotifyButton(event.time, b.code, b.state) != 0 and event.target.native == null) {
                const bit = buttonBit(b.code);
                if (b.state == .pressed) self.forwarded |= bit else self.forwarded &= ~bit;
                self.forwarded_id = event.target.id;
                self.button_ack = b;
                self.button_target = event.target.id;
            }
            input.seat.pointerNotifyFrame();
        }
    }
    if (!self.queued()) if (self.repick) |time| {
        self.repick = null;
        input.processCursorMotion(time);
        input.seat.pointerNotifyFrame();
    };
}

pub fn markerDone(self: *Self, xw: *Xwayland, serial: u32) void {
    if (self.marker != serial) return;
    self.marker = null;
    self.drain(xw);
}

pub fn buttonDone(self: *Self, xw: *Xwayland, code: u32, pressed: bool) void {
    const b = self.button_ack orelse return;
    if (b.code != code or (b.state == .pressed) != pressed) return;
    self.button_ack = null;
    self.drain(xw);
}

pub fn forget(self: *Self, xw: *Xwayland, id: u64) void {
    var i = self.events.items.len;
    while (i > 0) {
        i -= 1;
        if (self.events.items[i].target.id == id) _ = self.events.orderedRemove(i);
    }
    if (self.forwarded_id == id) self.balance(xw);
    if (self.button_ack != null and self.button_target == id) self.button_ack = null;
    self.drain(xw);
}
