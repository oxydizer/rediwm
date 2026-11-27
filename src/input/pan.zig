//! Input canvas panning.

const std = @import("std");
const Input = @import("../Input.zig");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const PanTrigger = Input.PanTrigger;
const PanSession = Input.PanSession;

pub fn startPan(input: *Input, trigger: PanTrigger, device: ?*wlr.InputDevice) void {
    if (input.server.world.workspaces.mode != .canvas) return;
    if (input.server.world.mini_map.dragging) return;
    if (input.server.switcher.active()) return;
    // Don't start a new pan if this trigger is currently inhibited
    if (input.pan_session) |sess| {
        if (sess.inhibited and sess.trigger == trigger) return;
    }
    const already_panning = input.cursor_mode == .pan;
    if (input.finger_pan) input.finger_pan = false;
    if (input.gesture == .compositor_pinch) {
        input.server.world.endPinch(false);
        input.gesture = .none;
    }
    input.cursor_mode = .pan;
    input.setHover(null, null);
    input.seat.pointerClearFocus();
    input.setNamedCursor("grabbing");
    input.pan_session = .{
        .trigger = trigger,
        .initiating_device = device,
        .last_x = input.cursor.x,
        .last_y = input.cursor.y,
        // Super is always a compositor gesture. A middle press is held until
        // motion disambiguates a camera pan from an ordinary client click.
        .button_consumed = trigger == .super_key,
        .inhibited = false,
    };
    // Super is a pan from the first event. Middle waits for the motion
    // threshold so a click does not cancel an in-flight camera spring.
    if (!already_panning) {
        if (trigger == .super_key) input.server.world.beginPan();
        // Snapshot camera before the pan begins for undo.
        const cam = input.server.world.camera;
        input.server.undo.begin(.{
            .kind = .pan,
            .press_seq = input.server.undo.press_seq,
            .at_ms = 0,
            .camera = .{ .offset_x = cam.offset_x, .offset_y = cam.offset_y, .zoom_index = cam.zoom_index, .focus_zoom = cam.focus_zoom },
        });
    }
}

pub fn endPan(input: *Input) void {
    if (input.cursor_mode == .pan) {
        // Commit the pan undo entry only when the pan actually moved (i.e.
        // button_consumed flipped to true). A middle-click with no motion
        // must not eat the undo slot.
        if (input.pan_session) |sess| {
            if (sess.button_consumed) {
                const cam = input.server.world.camera;
                input.server.undo.commit(Server.undoNowMs(), .{
                    .camera = .{ .offset_x = cam.offset_x, .offset_y = cam.offset_y, .zoom_index = cam.zoom_index, .focus_zoom = cam.focus_zoom },
                });
            } else {
                input.server.undo.drop();
            }
        }
        input.server.world.endPanGesture();
        // The release frame refreshes held glass (see World.holdingGlass).
        input.server.scheduleFrames();
    }
    input.cursor_mode = .passthrough;
    input.setDefaultCursor();
    // Re-hit-test under cursor so hover state is restored
    input.processCursorMotion(0);
    // NOTE: pan_session is intentionally NOT cleared here — it is kept so
    // callers can check the inhibit flag until the trigger is released.
}

pub fn applyPanCursorDelta(input: *Input, dx: f64, dy: f64) void {
    if (dx == 0 and dy == 0) return;
    const pan_speed = input.server.config.input.pan_speed;
    const z = input.server.world.camera.zoom();
    input.server.world.panBy(-dx * pan_speed / z, -dy * pan_speed / z);
}

/// Keep an in-progress pan across output layout changes without dropping the
/// trigger. Refresh the motion baseline so the next event is not a jump from
/// pre-resize cursor coordinates.
pub fn rebasePan(input: *Input) void {
    if (input.pan_session) |*sess| {
        sess.last_x = input.cursor.x;
        sess.last_y = input.cursor.y;
    }
}

pub fn beginMiddlePanAfterThreshold(session: *PanSession, x: f64, y: f64) bool {
    if (session.trigger != .middle_button or session.button_consumed) return true;
    const dx = x - session.last_x;
    const dy = y - session.last_y;
    if (dx * dx + dy * dy < 16) return false;
    session.button_consumed = true;
    return true;
}
