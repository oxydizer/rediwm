//! wp_pointer_warp_v1: a client moves the pointer to a point on its own
//! surface. Wine implements SetCursorPos with it (games recentring the cursor
//! every frame, launchers placing it on a button); without it Wine falls
//! back to a short pointer lock with a cursor hint, which the compositor
//! cannot tell from a real lock.
//!
//! A warp is honoured only while the target surface's tree has pointer focus
//! and motion reaches the client (the same states that keep pointer
//! constraints off), with a serial this seat sent that client, to a point
//! inside the surface. A locked pointer stays put (its cursor hint is the
//! warp), a confined one only moves within its region. The client then gets
//! ordinary absolute motion to the new point; relative-pointer clients get
//! no delta, since the hand on the mouse did not move.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wp = @import("wayland").server.wp;
const wlr = @import("wlroots");
const Input = @import("../Input.zig");
const VirtualInput = @import("virtual.zig").VirtualInput;
const Self = @This();

input: *Input,
global: *wl.Global,

pub fn init(self: *Self, input: *Input) !void {
    self.* = .{
        .input = input,
        .global = try wl.Global.create(input.server.wl_server, wp.PointerWarpV1, 1, *Self, self, bind),
    };
}

/// Bound managers outlive the global until their clients go; they carry no
/// state, and no request is dispatched after the display stops.
pub fn deinit(self: *Self) void {
    self.global.destroy();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.PointerWarpV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(resource: *wp.PointerWarpV1, request: wp.PointerWarpV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .warp_pointer => |args| {
            const surface = wlr.Surface.fromWlSurface(args.surface);
            self.warp(resource.getClient(), surface, args.pointer, args.x.toDouble(), args.y.toDouble(), args.serial);
        },
    }
}

fn warp(self: *Self, client: *wl.Client, surface: *wlr.Surface, pointer: *wl.Pointer, sx: f64, sy: f64, serial: u32) void {
    const input = self.input;
    const seat = input.seat;
    if (surface.resource.getClient() != client) return;
    const seat_client = wlr.Seat.Client.fromWlPointer(pointer) orelse return;
    if (seat_client.seat != seat or seat_client.client != client) return;
    if (!seat_client.validateEventSerial(serial)) return;
    if (!(sx >= 0 and sy >= 0 and sx < @as(f64, @floatFromInt(surface.current.width)) and
        sy < @as(f64, @floatFromInt(surface.current.height)))) return;
    if (!input.motionReachesClient()) return;
    const focused = seat.pointer_state.focused_surface orelse return;
    if (focused.getRootSurface() != surface.getRootSurface()) return;
    // The cursor/surface correspondence is kept for the focused surface;
    // carry the point there through the shared root's coordinates.
    const target = rootOffset(surface);
    const origin = rootOffset(focused);
    const fx = sx + target.x - origin.x;
    const fy = sy + target.y - origin.y;
    if (input.pointer_constraints.active) |constraint| switch (constraint.type) {
        .locked => return,
        .confined => {
            const x = std.math.lossyCast(c_int, @floor(fx));
            const y = std.math.lossyCast(c_int, @floor(fy));
            if (constraint.surface != focused or !constraint.region.containsPoint(x, y, null)) return;
        },
    };
    const point = input.focusedSurfaceToLayout(fx, fy);
    if (!input.cursor.warp(null, point.x, point.y)) return;
    input.processCursorMotion(VirtualInput.nowMs());
    seat.pointerNotifyFrame();
    input.pointer_constraints.sync();
}

/// Where `surface`'s origin sits in its root surface's coordinates.
fn rootOffset(surface: *wlr.Surface) struct { x: f64, y: f64 } {
    var x: i32 = 0;
    var y: i32 = 0;
    var current = surface;
    while (wlr.Subsurface.tryFromWlrSurface(current)) |sub| {
        x += sub.current.x;
        y += sub.current.y;
        current = sub.parent;
    }
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}
