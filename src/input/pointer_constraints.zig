//! zwp_relative_pointer_v1 and zwp_pointer_constraints_v1: raw motion deltas
//! and pointer lock/confinement, which mouse-look in games needs natively and
//! through Xwayland (X11 grabs, raw input and pointer warps are built on
//! them). wlroots owns the protocol objects; this module owns the activation
//! policy and applies the active constraint to cursor motion.
//!
//! A constraint is active only while its surface holds both pointer and
//! keyboard focus and motion reaches the client (no compositor grab, pan,
//! selector, menu, shell panel or lock). Any focus change deactivates it,
//! which is also how the user escapes a locked game. Deactivating a oneshot constraint
//! destroys it; a persistent one re-activates when the pointer next moves
//! inside its region with focus restored.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Input = @import("../Input.zig");
const scene_data = @import("../scene_data.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

input: *Input,
relative: *wlr.RelativePointerManagerV1,
manager: *wlr.PointerConstraintsV1,
active: ?*wlr.PointerConstraintV1 = null,
new_constraint: wl.Listener(*wlr.PointerConstraintV1) = .init(newConstraint),
keyboard_focus: wl.Listener(*wlr.Seat.event.KeyboardFocusChange) = .init(keyboardFocusChanged),
pointer_focus: wl.Listener(*wlr.Seat.event.PointerFocusChange) = .init(pointerFocusChanged),

/// Listeners for one wlroots constraint, reachable through its `data`.
/// A constraint without one (allocation failed) never activates.
const Constraint = struct {
    owner: *Self,
    wlr_constraint: *wlr.PointerConstraintV1,
    set_region: wl.Listener(void) = .init(setRegion),
    destroy: wl.Listener(*wlr.PointerConstraintV1) = .init(destroyed),

    fn release(constraint: *Constraint) void {
        constraint.set_region.link.remove();
        constraint.destroy.link.remove();
        constraint.wlr_constraint.data = null;
        gpa.destroy(constraint);
    }
};

/// How far the cursor may move after the active constraint is applied.
pub const Motion = struct { dx: f64, dy: f64 };

pub fn init(self: *Self, input: *Input) !void {
    // The display owns and frees both globals.
    const relative = try wlr.RelativePointerManagerV1.create(input.server.wl_server);
    const manager = try wlr.PointerConstraintsV1.create(input.server.wl_server);
    self.* = .{ .input = input, .relative = relative, .manager = manager };
    manager.events.new_constraint.add(&self.new_constraint);
    input.seat.keyboard_state.events.focus_change.add(&self.keyboard_focus);
    input.seat.pointer_state.events.focus_change.add(&self.pointer_focus);
}

/// Runs before the seat is destroyed; constraints still alive are freed
/// with the display later and must not reach this (then freed) state.
pub fn deinit(self: *Self) void {
    self.new_constraint.link.remove();
    self.keyboard_focus.link.remove();
    self.pointer_focus.link.remove();
    self.active = null;
    var it = self.manager.constraints.iterator(.forward);
    while (it.next()) |wlr_constraint| {
        const data = wlr_constraint.data orelse continue;
        const constraint: *Constraint = @ptrCast(@alignCast(data));
        constraint.release();
    }
}

/// Sends motion to the pointer-focused client's relative-pointer objects and
/// returns the cursor move the active constraint allows: unchanged, clamped
/// to a confinement region, or null while locked. Deltas are in layout
/// pixels, unscaled by camera or window zoom, as raw input should be.
pub fn clientMotion(self: *Self, time_msec: u32, dx: f64, dy: f64, unaccel_dx: f64, unaccel_dy: f64) ?Motion {
    // Catches states that take motion from the client without changing
    // seat focus (the screenshot selector, a tray menu, a desktop grab).
    self.sync();
    const input = self.input;
    if ((dx != 0 or dy != 0 or unaccel_dx != 0 or unaccel_dy != 0) and input.motionReachesClient()) {
        self.relative.sendRelativeMotion(input.seat, @as(u64, time_msec) * 1000, dx, dy, unaccel_dx, unaccel_dy);
    }
    const constraint = self.active orelse return .{ .dx = dx, .dy = dy };
    return switch (constraint.type) {
        .locked => null,
        .confined => self.confine(constraint, dx, dy),
    };
}

/// Re-decides which constraint, if any, is active. Cheap: a walk over the
/// (usually empty) constraint list with no hit test.
pub fn sync(self: *Self) void {
    const wanted = self.candidate();
    if (self.active == wanted) return;
    self.deactivate();
    if (wanted) |constraint| {
        self.active = constraint;
        constraint.sendActivated();
    }
}

fn candidate(self: *Self) ?*wlr.PointerConstraintV1 {
    const input = self.input;
    if (!input.motionReachesClient()) return null;
    // Shell panels take keys without moving seat focus. The cursor must be
    // free to reach them; clientMotion's sync releases it on first motion.
    if (input.open_start_menu != null or input.open_power_menu != null or
        input.open_wifi != null or input.open_battery != null or input.open_calendar != null) return null;
    const seat = input.seat;
    const surface = seat.pointer_state.focused_surface orelse return null;
    // Requiring keyboard focus too means Alt+Tab or a click elsewhere always
    // releases a game's lock, even one whose window fills the output.
    const keyboard = seat.keyboard_state.focused_surface orelse return null;
    if (keyboard != surface.getRootSurface()) return null;
    const constraint = self.manager.constraintForSurface(surface, seat) orelse return null;
    if (constraint.data == null) return null;
    if (constraint == self.active) return constraint;
    // Activation waits until the pointer is inside the region; from then on
    // a confinement keeps it there and a lock holds it still.
    const x = std.math.lossyCast(c_int, @floor(seat.pointer_state.sx));
    const y = std.math.lossyCast(c_int, @floor(seat.pointer_state.sy));
    if (!constraint.region.containsPoint(x, y, null)) return null;
    return constraint;
}

fn deactivate(self: *Self) void {
    const constraint = self.active orelse return;
    self.active = null;
    self.warpToHint(constraint);
    // Destroys a oneshot constraint, running `destroyed` synchronously.
    constraint.sendDeactivated();
}

fn confine(self: *Self, constraint: *wlr.PointerConstraintV1, dx: f64, dy: f64) Motion {
    const at = self.surfacePoint(constraint.surface) orelse {
        // The window moved out from under the cursor or something now
        // covers it; release rather than trap the cursor over other content.
        self.deactivate();
        return .{ .dx = dx, .dy = dy };
    };
    var x: f64 = undefined;
    var y: f64 = undefined;
    if (!wlr.region.confine(&constraint.region, at.sx, at.sy, at.sx + dx / at.scale, at.sy + dy / at.scale, &x, &y)) {
        // The region shrank away from the pointer; it re-activates on entry.
        self.deactivate();
        return .{ .dx = dx, .dy = dy };
    }
    return .{ .dx = (x - at.sx) * at.scale, .dy = (y - at.sy) * at.scale };
}

const SurfacePoint = struct { sx: f64, sy: f64, scale: f64 };

/// Where the cursor falls on `surface`, and layout pixels per surface-local
/// unit there: camera zoom × window depth ÷ Xwayland scale (see
/// Input.rememberPointerGrab for the same correspondence).
fn surfacePoint(self: *Self, surface: *wlr.Surface) ?SurfacePoint {
    const server = self.input.server;
    const zoom = server.world.camera.zoom();
    switch (scene_data.hitTest(server, self.input.cursor.x, self.input.cursor.y)) {
        .surface => |hit| if (hit.surface == surface) return .{
            .sx = hit.sx,
            .sy = hit.sy,
            .scale = zoom * hit.toplevel.worldScale() / hit.toplevel.surfaceScale(),
        },
        .xwayland_unmanaged => |hit| if (hit.surface == surface) return .{
            .sx = hit.sx,
            .sy = hit.sy,
            .scale = zoom / server.xwaylandScale(),
        },
        else => {},
    }
    return null;
}

/// A lock's cursor hint is where the client drew its own cursor while
/// locked; put the real one there on release. Xwayland emulates X11 pointer
/// warps this way. Uses the last hit's correspondence rather than a hit test,
/// since this also runs while the surface is being destroyed.
fn warpToHint(self: *Self, constraint: *wlr.PointerConstraintV1) void {
    if (constraint.type != .locked or !constraint.current.cursor_hint.enabled) return;
    const input = self.input;
    if (input.seat.pointer_state.focused_surface != constraint.surface) return;
    const sx = constraint.current.cursor_hint.x;
    const sy = constraint.current.cursor_hint.y;
    const x = std.math.lossyCast(c_int, @floor(sx));
    const y = std.math.lossyCast(c_int, @floor(sy));
    if (!constraint.region.containsPoint(x, y, null)) return;
    const point = input.focusedSurfaceToLayout(sx, sy);
    if (input.cursor.warp(null, point.x, point.y)) input.seat.pointerWarp(sx, sy);
}

fn newConstraint(listener: *wl.Listener(*wlr.PointerConstraintV1), wlr_constraint: *wlr.PointerConstraintV1) void {
    const self: *Self = @fieldParentPtr("new_constraint", listener);
    const constraint = gpa.create(Constraint) catch return;
    constraint.* = .{ .owner = self, .wlr_constraint = wlr_constraint };
    wlr_constraint.data = constraint;
    wlr_constraint.events.set_region.add(&constraint.set_region);
    wlr_constraint.events.destroy.add(&constraint.destroy);
    self.sync();
}

fn setRegion(listener: *wl.Listener(void)) void {
    const constraint: *Constraint = @fieldParentPtr("set_region", listener);
    constraint.owner.sync();
}

fn destroyed(listener: *wl.Listener(*wlr.PointerConstraintV1), wlr_constraint: *wlr.PointerConstraintV1) void {
    const constraint: *Constraint = @fieldParentPtr("destroy", listener);
    const self = constraint.owner;
    if (self.active == wlr_constraint) {
        self.active = null;
        self.warpToHint(wlr_constraint);
    }
    constraint.release();
}

fn keyboardFocusChanged(listener: *wl.Listener(*wlr.Seat.event.KeyboardFocusChange), _: *wlr.Seat.event.KeyboardFocusChange) void {
    const self: *Self = @fieldParentPtr("keyboard_focus", listener);
    self.sync();
}

fn pointerFocusChanged(listener: *wl.Listener(*wlr.Seat.event.PointerFocusChange), _: *wlr.Seat.event.PointerFocusChange) void {
    const self: *Self = @fieldParentPtr("pointer_focus", listener);
    self.sync();
}
