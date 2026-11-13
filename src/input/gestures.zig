//! Input touchpad gestures: pinch, swipe and hold.

const std = @import("std");
const Input = @import("../Input.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Pointer = @import("../Pointer.zig");
const resize = @import("../resize.zig");
const scene_data = @import("../scene_data.zig");

pub fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const input: *Input = @fieldParentPtr("cursor_frame", listener);
    input.seat.pointerNotifyFrame();
}

pub fn cursorSwipeBegin(listener: *wl.Listener(*wlr.Pointer.event.SwipeBegin), event: *wlr.Pointer.event.SwipeBegin) void {
    const input: *Input = @fieldParentPtr("cursor_swipe_begin", listener);
    input.handleSwipeBegin(event.time_msec, event.fingers);
}

pub fn cursorSwipeUpdate(listener: *wl.Listener(*wlr.Pointer.event.SwipeUpdate), event: *wlr.Pointer.event.SwipeUpdate) void {
    const input: *Input = @fieldParentPtr("cursor_swipe_update", listener);
    input.handleSwipeUpdate(event.time_msec, event.dx, event.dy);
}

pub fn cursorSwipeEnd(listener: *wl.Listener(*wlr.Pointer.event.SwipeEnd), event: *wlr.Pointer.event.SwipeEnd) void {
    const input: *Input = @fieldParentPtr("cursor_swipe_end", listener);
    input.handleSwipeEnd(event.time_msec, event.cancelled);
}

pub fn cursorPinchBegin(listener: *wl.Listener(*wlr.Pointer.event.PinchBegin), event: *wlr.Pointer.event.PinchBegin) void {
    const input: *Input = @fieldParentPtr("cursor_pinch_begin", listener);
    input.handlePinchBegin(event.time_msec, event.fingers);
}

pub fn cursorPinchUpdate(listener: *wl.Listener(*wlr.Pointer.event.PinchUpdate), event: *wlr.Pointer.event.PinchUpdate) void {
    const input: *Input = @fieldParentPtr("cursor_pinch_update", listener);
    input.handlePinchUpdate(event.time_msec, event.dx, event.dy, event.scale, event.rotation);
}

pub fn cursorPinchEnd(listener: *wl.Listener(*wlr.Pointer.event.PinchEnd), event: *wlr.Pointer.event.PinchEnd) void {
    const input: *Input = @fieldParentPtr("cursor_pinch_end", listener);
    input.handlePinchEnd(event.time_msec, event.cancelled);
}

pub fn cursorHoldBegin(listener: *wl.Listener(*wlr.Pointer.event.HoldBegin), event: *wlr.Pointer.event.HoldBegin) void {
    const input: *Input = @fieldParentPtr("cursor_hold_begin", listener);
    input.pointer_gestures.sendHoldBegin(input.seat, event.time_msec, event.fingers);
}

pub fn cursorHoldEnd(listener: *wl.Listener(*wlr.Pointer.event.HoldEnd), event: *wlr.Pointer.event.HoldEnd) void {
    const input: *Input = @fieldParentPtr("cursor_hold_end", listener);
    input.pointer_gestures.sendHoldEnd(input.seat, event.time_msec, event.cancelled);
}

/// Camera changes cannot invalidate an in-flight client or compositor grab.
pub fn canZoom(input: *Input) bool {
    if (input.server.world.workspaces.active or input.server.world.overview.active()) return false;
    if (input.server.world.mini_map.dragging) return false;
    if (input.active_buttons != 0 or input.resize_session != null or input.seat.pointerHasGrab()) return false;
    if (input.server.world.pinching) return false;
    return input.cursor_mode == .passthrough or
        (input.cursor_mode == .pan and input.pan_session != null and input.pan_session.?.trigger == .super_key);
}

pub fn clientSurfaceHit(hit: scene_data.Hit) bool {
    return switch (hit) {
        .surface, .layer, .xwayland_unmanaged, .input_popup => true,
        else => false,
    };
}

pub fn compositorOwnsPinch(input: *Input) bool {
    if (input.server.world.workspaces.active or input.server.world.overview.active()) return false;
    if (input.server.locker != null or input.server.polkit_dialog != null or input.server.switcher.active()) return false;
    if (input.cursor_mode == .move or input.cursor_mode == .resize or input.resize_session != null) return false;
    return !clientSurfaceHit(scene_data.hitTest(input.server, input.cursor.x, input.cursor.y));
}

pub fn compositorOwnsSwipe(input: *Input, fingers: u32) bool {
    if (input.server.world.workspaces.active or input.server.world.overview.active()) return false;
    if (fingers != 2) return false;
    if (input.server.locker != null or input.server.polkit_dialog != null or input.server.switcher.active()) return false;
    if (input.cursor_mode != .passthrough or input.resize_session != null) return false;
    return scene_data.hitTest(input.server, input.cursor.x, input.cursor.y) == .none;
}

pub fn handlePinchBegin(input: *Input, time_msec: u32, fingers: u32) void {
    if (input.server.polkit_dialog != null or input.server.world.overview.active()) return;
    if (input.server.idle) |im| im.notifyActivity(.pointer);
    if (input.gesture == .compositor_swipe) {
        input.server.world.endPanGesture();
        input.gesture = .none;
        input.server.scheduleFrames();
    }
    if (fingers >= 2 and compositorOwnsPinch(input)) {
        input.gesture = .compositor_pinch;
        input.server.world.beginPinch(input.cursor.x, input.cursor.y);
        return;
    }
    input.gesture = .client_pinch;
    input.pointer_gestures.sendPinchBegin(input.seat, time_msec, fingers);
}

pub fn handlePinchUpdate(input: *Input, time_msec: u32, dx: f64, dy: f64, scale: f64, rotation: f64) void {
    if (input.server.polkit_dialog != null or input.server.world.overview.active()) return;
    if (input.gesture == .compositor_pinch) {
        input.server.world.pinchTo(scale);
        return;
    }
    input.pointer_gestures.sendPinchUpdate(input.seat, time_msec, dx, dy, scale, rotation);
}

pub fn handlePinchEnd(input: *Input, time_msec: u32, cancelled: bool) void {
    if (input.gesture == .compositor_pinch) {
        input.server.world.endPinch(cancelled);
        input.gesture = .none;
        input.server.scheduleFrames();
        return;
    }
    if (input.gesture == .client_pinch) {
        input.pointer_gestures.sendPinchEnd(input.seat, time_msec, cancelled);
    }
    input.gesture = .none;
}

pub fn handleSwipeBegin(input: *Input, time_msec: u32, fingers: u32) void {
    if (input.server.polkit_dialog != null or input.server.world.overview.active()) return;
    if (input.server.idle) |im| im.notifyActivity(.pointer);
    if (input.gesture == .compositor_pinch) {
        input.server.world.endPinch(false);
        input.gesture = .none;
    }
    if (compositorOwnsSwipe(input, fingers)) {
        input.gesture = .compositor_swipe;
        input.server.world.beginPan();
        return;
    }
    input.gesture = .client_swipe;
    input.pointer_gestures.sendSwipeBegin(input.seat, time_msec, fingers);
}

pub fn handleSwipeUpdate(input: *Input, time_msec: u32, dx: f64, dy: f64) void {
    if (input.server.polkit_dialog != null or input.server.world.overview.active()) return;
    if (input.gesture == .compositor_swipe) {
        const z = input.server.world.camera.zoom();
        const pan_speed = input.server.config.input.pan_speed;
        input.server.world.panBy(-dx * pan_speed / z, -dy * pan_speed / z);
        return;
    }
    input.pointer_gestures.sendSwipeUpdate(input.seat, time_msec, dx, dy);
}

pub fn handleSwipeEnd(input: *Input, time_msec: u32, cancelled: bool) void {
    if (input.gesture == .compositor_swipe) {
        if (cancelled) input.server.world.cancelPan() else input.server.world.endPanGesture();
        input.gesture = .none;
        input.server.scheduleFrames();
        return;
    }
    if (input.gesture == .client_swipe) {
        input.pointer_gestures.sendSwipeEnd(input.seat, time_msec, cancelled);
    }
    input.gesture = .none;
}
