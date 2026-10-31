//! Input pointer motion: layout mapping, warping, passthrough and grab motion.

const std = @import("std");
const Input = @import("../Input.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const control_center = @import("../control_center/panel.zig");
const ui_input = @import("ui").input;
const Pointer = @import("../Pointer.zig");
const chrome = @import("../chrome.zig");
const Output = @import("../Output.zig");
const geometry = @import("../geometry.zig");
const resize = @import("../resize.zig");
const snap = @import("../snap.zig");
const scene_data = @import("../scene_data.zig");
const applyPanCursorDelta = Input.applyPanCursorDelta;
const beginMiddlePanAfterThreshold = Input.beginMiddlePanAfterThreshold;

pub fn cursorMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const input: *Input = @fieldParentPtr("cursor_motion", listener);
    if (input.blockedVirtual(&event.pointer.base)) return;
    @import("../startup.zig").markFirstInput();
    if (input.server.idle) |im| im.notifyActivity(.pointer);

    var dx = event.delta_x;
    var dy = event.delta_y;
    const mult = input.accelMultiplier(dx, dy);
    dx *= mult;
    dy *= mult;

    if (input.server.locker != null or input.server.polkit_dialog != null) {
        input.cursor.move(&event.pointer.base, dx, dy);
        input.lockClientMotion(event.time_msec);
        return;
    }

    if (input.cursor_mode == .passthrough and input.resize_session == null and input.grabbed_toplevel == null) {
        if (input.server.screenshot_selector.output == null and input.isPanModifierHeld() and input.active_buttons == 0 and !input.server.world.mini_map.dragging and !input.cursorOverTaskbar()) {
            const inhibited = if (input.pan_session) |sess| sess.inhibited and sess.trigger == .super_key else false;
            if (!inhibited) {
                input.startPan(.super_key, &event.pointer.base);
            }
        }
    }

    if (input.cursor_mode == .pan) {
        if (input.pan_session) |*sess| if (!sess.inhibited) {
            const prev_x = input.cursor.x;
            const prev_y = input.cursor.y;
            input.cursor.move(&event.pointer.base, dx, dy);
            const actual_dx = input.cursor.x - prev_x;
            const actual_dy = input.cursor.y - prev_y;

            if (actual_dx != 0 or actual_dy != 0) {
                if (!beginMiddlePanAfterThreshold(sess, input.cursor.x, input.cursor.y)) return;
                // Rubber-band past Bounds instead of warping the cursor back:
                // interior pans stay 1:1; overscroll follows with falling gain.
                applyPanCursorDelta(input, actual_dx, actual_dy);
            }
            return;
        };
    }

    const allowed = input.pointer_constraints.clientMotion(event.time_msec, dx, dy, event.unaccel_dx, event.unaccel_dy) orelse return;
    input.cursor.move(&event.pointer.base, allowed.dx, allowed.dy);
    input.processCursorMotion(event.time_msec);
    input.pointer_constraints.sync();
}

pub fn cursorMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const input: *Input = @fieldParentPtr("cursor_motion_absolute", listener);
    if (input.blockedVirtual(&event.pointer.base)) return;
    if (input.server.idle) |im| im.notifyActivity(.pointer);
    var x: f64 = undefined;
    var y: f64 = undefined;
    input.cursor.absoluteToLayoutCoords(&event.pointer.base, event.x, event.y, &x, &y);
    input.layoutMotion(&event.pointer.base, x, y, event.time_msec);
}

/// Absolute pointer motion to a layout point: pointer devices, and touch and
/// tablet input emulating a pointer. The caller sends the pointer frame.
pub fn layoutMotion(input: *Input, device: ?*wlr.InputDevice, x: f64, y: f64, time_msec: u32) void {
    @import("../startup.zig").markFirstInput();
    if (input.server.locker != null or input.server.polkit_dialog != null) {
        _ = input.cursor.warpClosest(device, x, y);
        input.lockClientMotion(time_msec);
        return;
    }

    if (input.cursor_mode == .passthrough and input.resize_session == null and input.grabbed_toplevel == null) {
        if (input.server.screenshot_selector.output == null and input.isPanModifierHeld() and input.active_buttons == 0 and !input.server.world.mini_map.dragging and !input.cursorOverTaskbar()) {
            const inhibited = if (input.pan_session) |sess| sess.inhibited and sess.trigger == .super_key else false;
            if (!inhibited) {
                input.startPan(.super_key, device);
            }
        }
    }

    const prev_x = input.cursor.x;
    const prev_y = input.cursor.y;
    if (input.cursor_mode == .pan) {
        _ = input.cursor.warpClosest(device, x, y);
        if (input.pan_session) |*sess| if (!sess.inhibited) {
            const dx = input.cursor.x - prev_x;
            const dy = input.cursor.y - prev_y;
            if (dx != 0 or dy != 0) {
                if (!beginMiddlePanAfterThreshold(sess, input.cursor.x, input.cursor.y)) return;
                applyPanCursorDelta(input, dx, dy);
            }
            return;
        };
        input.processCursorMotion(time_msec);
        return;
    }
    // Absolute devices (tablets, nested backends) still drive relative
    // listeners and constraints, with the layout delta as both deltas.
    const constrained = input.pointer_constraints.active != null;
    const allowed = input.pointer_constraints.clientMotion(time_msec, x - prev_x, y - prev_y, x - prev_x, y - prev_y) orelse return;
    if (constrained) {
        input.cursor.move(device, allowed.dx, allowed.dy);
    } else {
        _ = input.cursor.warpClosest(device, x, y);
    }
    input.processCursorMotion(time_msec);
    input.pointer_constraints.sync();
}

/// Synthetic absolute motion follows the same pan policy as physical motion.
/// Coordinates are in the output layout, before the world camera transform.
pub fn warpCursor(input: *Input, x: f64, y: f64, time_msec: u32) void {
    if (input.server.locker != null or input.server.polkit_dialog != null) return;
    if (input.server.idle) |im| im.notifyActivity(.pointer);
    if (input.cursor_mode == .passthrough and input.resize_session == null and
        input.grabbed_toplevel == null and input.active_buttons == 0 and !input.server.world.mini_map.dragging and input.server.screenshot_selector.output == null and
        input.isPanModifierHeld() and !input.cursorOverTaskbar())
    {
        input.startPan(.super_key, null);
    }
    const previous_x = input.cursor.x;
    const previous_y = input.cursor.y;
    if (input.cursor_mode != .pan) {
        const constrained = input.pointer_constraints.active != null;
        const allowed = input.pointer_constraints.clientMotion(time_msec, x - previous_x, y - previous_y, x - previous_x, y - previous_y) orelse {
            input.seat.pointerNotifyFrame();
            return;
        };
        if (constrained) {
            input.cursor.move(null, allowed.dx, allowed.dy);
        } else {
            _ = input.cursor.warp(null, x, y);
        }
        input.processCursorMotion(time_msec);
        input.seat.pointerNotifyFrame();
        input.pointer_constraints.sync();
        return;
    }
    _ = input.cursor.warp(null, x, y);
    if (input.pan_session) |*session| {
        if (!session.inhibited) {
            const dx = input.cursor.x - previous_x;
            const dy = input.cursor.y - previous_y;
            if (!beginMiddlePanAfterThreshold(session, input.cursor.x, input.cursor.y)) return;
            applyPanCursorDelta(input, dx, dy);
        }
    }
}

/// An auto-hiding dock shows when the pointer reaches its edge. Moving or
/// resizing a window, or holding a button for a client (a selection dragged to
/// the edge), must not raise it; dragging an app from the start menu does.
pub fn updateDockReveal(input: *Input) void {
    const engaged = input.cursor_mode == .passthrough and (input.active_buttons == 0 or input.dock_drag.active());
    var it = input.server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.pointerAt(input.cursor.x, input.cursor.y, engaged);
}

pub fn processCursorMotion(input: *Input, time_msec: u32) void {
    if (input.server.locker != null or input.server.polkit_dialog != null or input.server.switcher.active()) return;
    defer input.updateGrabBorderGlow();
    input.positionDragIcon();
    input.drag_dodge.motion();
    input.updateDockReveal();
    if (input.server.screenshot_selector.output != null) {
        input.server.screenshot_selector.motion(input.cursor.x, input.cursor.y);
        return;
    }
    if (input.window_menu.node != null) {
        input.window_menu.motion(input.cursor.x, input.cursor.y);
        input.seat.pointerClearFocus();
        return;
    }
    if (input.server.tray) |tray| {
        if (tray.menu_item != 0) {
            tray.menuMotion(input.cursor.x, input.cursor.y);
            input.seat.pointerClearFocus();
            return;
        }
    }
    if (input.tiling_grab != null) {
        @import("../tiling_grab.zig").motion(input);
        return;
    }
    switch (input.cursor_mode) {
        .passthrough => input.passthroughMotion(time_msec),
        .move => input.processMove(),
        .resize => input.processResize(),
        .pan => {}, // handled in cursorMotion / cursorMotionAbsolute
    }
}

pub fn passthroughMotion(input: *Input, time_msec: u32) void {
    if (input.dock_drag.motion(input)) return;
    // Shell controls keep receiving motion until release, just like a client's
    // implicit grab. A scrollbar drag may leave the whole window or panel.
    if (input.open_control_center) |cc| {
        if (cc.pointer_down) {
            const local = cc.localPoint(input.cursor.x, input.cursor.y);
            control_center.pointerMotion(cc, local.x, local.y);
            if (cc.appearance.item_drag != null) input.setNamedCursor("grabbing") else input.setShellCursor(ui_input.current.overText());
            input.seat.pointerClearFocus();
            return;
        }
    }
    if (input.open_start_menu) |menu| {
        if (menu.dispatcher.scroll_drag != null) {
            const local = scene_data.toNodeLocal(&menu.buffer_node.node, input.cursor.x, input.cursor.y);
            menu.pointerMotion(local.x, local.y);
            input.setDefaultCursor();
            input.seat.pointerClearFocus();
            return;
        }
    }
    if (input.server.world.mini_map.dragging) {
        input.server.world.mini_map.motion(input.cursor.x, input.cursor.y);
        input.setNamedCursor("grabbing");
        input.seat.pointerClearFocus();
        return;
    }
    if (input.desktop_grab) {
        if (input.server.desktop) |desktop| {
            const local = desktop.localPoint(input.cursor.x, input.cursor.y);
            desktop.pointerMotion(local.x, local.y);
            return;
        }
        input.desktop_grab = false;
    }
    // An implicit layer grab keeps surface-local coordinates even when the
    // pointer crosses a normal window or the taskbar during icon selection.
    if (input.active_buttons > 0 and input.seat.drag == null) {
        if (input.seat.pointer_state.focused_surface) |focused| {
            if (wlr.InputPopupSurfaceV2.tryFromWlrSurface(focused.getRootSurface()) != null) {
                if (input.server.text_input) |relay| {
                    if (relay.popupPoint(focused, input.cursor.x, input.cursor.y)) |point| {
                        input.seat.pointerNotifyMotion(time_msec, point.x, point.y);
                        return;
                    }
                }
            }
            if (wlr.LayerSurfaceV1.tryFromWlrSurface(focused.getRootSurface())) |layer| {
                if (layer.data) |data| {
                    const owner: *@import("../LayerSurface.zig") = @ptrCast(@alignCast(data));
                    const local = owner.localPoint(input.cursor.x, input.cursor.y);
                    input.seat.pointerNotifyMotion(time_msec, local.x, local.y);
                    return;
                }
            }
            // Same idea for ordinary client content (toplevels and
            // override-redirect popups): once a button is held, the pointer
            // stays implicitly grabbed by whatever surface it went down on,
            // even past the surface's own bounds or into another window.
            // Re-hit-testing here would silently re-enter a different
            // surface mid-gesture, invalidating the seat's pointer grab
            // serial before the client can recognize a drag-and-drop
            // gesture or extend a text selection past its own edge - this
            // was confirmed to break wl_data_device.start_drag entirely,
            // independent of Xwayland (reproduces with two native Wayland
            // clients). Extrapolate from the last real hit's surface-local/
            // world correspondence rather than the surface's geometry
            // directly, since it may be a subsurface we don't otherwise
            // track the position of.
            const world = input.server.world.camera.toWorld(input.server.world.bounds, input.cursor.x, input.cursor.y);
            const local_x = input.pointer_grab_local_x + (world.x - input.pointer_grab_world_x) / input.pointer_grab_world_scale;
            const local_y = input.pointer_grab_local_y + (world.y - input.pointer_grab_world_y) / input.pointer_grab_world_scale;
            input.seat.pointerNotifyMotion(time_msec, local_x, local_y);
            return;
        }
    }
    const hit = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
    input.updateBorderGlow(hit);
    if (hit != .toast) {
        input.clearToastHover();
    }
    var dock_it = input.server.outputs.iterator(.forward);
    while (dock_it.next()) |out| {
        if (hit != .dock or hit.dock.dock != &out.dock) out.dock.leave();
    }
    input.server.world.mini_map.hover(hit == .mini_map);
    if (hit != .power_menu) {
        if (input.open_power_menu) |menu| menu.pointerMotion(-1, -1);
    }
    if (hit != .control_center) {
        if (input.open_control_center) |cc| control_center.pointerLeave(cc);
    }
    if (hit != .start_menu) {
        if (input.open_start_menu) |menu| menu.pointerLeave();
    }
    if (hit != .desktop) {
        if (input.server.desktop) |desktop| desktop.pointerLeave();
    }
    switch (hit) {
        .mini_map => {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            input.setNamedCursor("grab");
            input.seat.pointerClearFocus();
        },
        .input_popup => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            // Clear any compositor resize/menu cursor before a new client enter.
            if (input.seat.pointer_state.focused_surface != res.surface) input.setDefaultCursor();
            input.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
            input.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
        },
        .toast => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            input.setToastHover(res.toast);
            res.toast.pointerMotion(res.sx, res.sy);
            input.setDefaultCursor();
            input.seat.pointerClearFocus();
        },
        .dock => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            res.dock.motion(res.sx, res.sy);
            input.setDefaultCursor();
            input.seat.pointerClearFocus();
        },
        .taskbar => |res| {
            input.hovered_resize_edges = null;
            if (input.hovered_taskbar) |previous| {
                if (previous != res.bar) previous.pointerLeave();
            }
            input.hovered_taskbar = res.bar;
            res.bar.pointerMotion(res.sx, res.sy);
            input.setHover(null, null);
            input.setDefaultCursor();
            input.seat.pointerClearFocus();
        },
        .chrome => |hit_chrome| {
            input.clearTaskbarHover();
            const toplevel = hit_chrome.toplevel;
            if (input.server.config.compositor.focus_follows_mouse) {
                input.server.world.focus(toplevel);
            }
            const local = toplevel.frameLocal(input.cursor.x, input.cursor.y);
            const has_control = toplevel.controlAt(hit_chrome.sx, hit_chrome.sy) != null or toplevel.tabAt(hit_chrome.sx, hit_chrome.sy) != .none;
            toplevel.hoverTab(hit_chrome.sx, hit_chrome.sy);
            if (resize.detectResizeEdges(local.x, local.y, toplevel.chrome_width, toplevel.chrome_height, toplevel.titlebarHeight(), chrome.frame_border, chrome.frame_border, has_control)) |edges| {
                input.hovered_resize_edges = edges;
                input.setHover(toplevel, null);
                input.setNamedCursor(edges.cursorName());
                input.seat.pointerClearFocus();
            } else {
                input.hovered_resize_edges = null;
                input.setHover(toplevel, toplevel.controlAt(hit_chrome.sx, hit_chrome.sy));
                input.setDefaultCursor();
                input.seat.pointerClearFocus();
            }
        },
        .wifi_popup => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            input.setDefaultCursor();
            res.popup.motion(res.sx, res.sy);
            input.seat.pointerClearFocus();
        },
        .calendar, .battery_popup => {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            input.setDefaultCursor();
            input.seat.pointerClearFocus();
        },
        .control_center => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            control_center.pointerMotion(res.cc, res.sx, res.sy);
            if (control_center.overDraggable(res.cc, res.sx, res.sy)) input.setNamedCursor("grab") else input.setShellCursor(ui_input.current.overText());
            input.seat.pointerClearFocus();
        },
        .start_menu => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            res.menu.pointerMotion(res.sx, res.sy);
            input.setShellCursor(res.menu.dispatcher.overText());
            input.seat.pointerClearFocus();
        },
        .power_menu => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            res.menu.pointerMotion(res.sx, res.sy);
            input.setDefaultCursor();
            input.seat.pointerClearFocus();
        },
        .surface => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(res.toplevel, null);
            if (input.server.config.compositor.focus_follows_mouse) {
                input.server.world.focusSurface(res.toplevel, res.surface);
            }
            // Clear any compositor resize/menu cursor before a new client enter.
            if (input.seat.pointer_state.focused_surface != res.surface) input.setDefaultCursor();
            input.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
            input.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            const ws = res.toplevel.worldScale() / res.toplevel.surfaceScale();
            input.rememberPointerGrab(res.sx, res.sy, ws);
        },
        .layer => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            // Clear any compositor resize/menu cursor before a new client enter.
            if (input.seat.pointer_state.focused_surface != res.surface) input.setDefaultCursor();
            input.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
            input.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
        },
        .xwayland_unmanaged => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            // Clear any compositor resize/menu cursor before a new client enter.
            if (input.seat.pointer_state.focused_surface != res.surface) input.setDefaultCursor();
            input.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
            input.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            input.rememberPointerGrab(res.sx, res.sy, 1.0 / input.server.xwaylandScale());
        },
        .desktop => |res| {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            // Defer focus clearing to the active pointer grab so wlroots
            // updates its DnD drag focus as well as ordinary pointer focus.
            input.seat.pointerNotifyClearFocus();
            res.desktop.pointerMotion(res.x, res.y);
            if (input.seat.drag != null) res.desktop.dragHover();
        },
        .none => {
            input.hovered_resize_edges = null;
            input.clearTaskbarHover();
            input.setHover(null, null);
            input.setDefaultCursor();
            input.seat.pointerClearFocus();
        },
    }
}

pub fn processMove(input: *Input) void {
    const toplevel = input.grabbed_toplevel orelse {
        input.clearGrab();
        return;
    };
    // A press that turns into a drag doesn't start a double-click.
    if (input.title_press) |press| {
        if (@abs(input.cursor.x - press.x) > snap.double_click_px or @abs(input.cursor.y - press.y) > snap.double_click_px) input.title_press = null;
    }
    if (input.move_snap.unsnap_from) |from| {
        if (@abs(input.cursor.x - from.x) < snap.unsnap_px and @abs(input.cursor.y - from.y) < snap.unsnap_px) return;
        input.move_snap.unsnap_from = null;
        input.floatGrabbed(toplevel);
    }
    defer input.updateSnapTarget(toplevel);
    // grab_x/y are world-space offsets (set in startMove); cursor is in layout
    // space. Convert to world before computing the new frame position.
    const wx = input.server.world.toWorld(input.cursor.x, input.cursor.y).x;
    const wy = input.server.world.toWorld(input.cursor.x, input.cursor.y).y;
    var pos = geometry.Vec2.toI32(.{
        .x = wx - input.grab_x,
        .y = wy - input.grab_y,
    });
    // A bar reserved along the top edge stops the frame at its lower edge, so
    // the titlebar can't be dragged out of reach behind it.
    if (topBarLimit(input)) |limit| {
        const layout = input.server.world.toLayout(@floatFromInt(pos.x), @floatFromInt(pos.y));
        if (layout.y < limit) pos.y = @intFromFloat(@round(input.server.world.toWorld(layout.x, limit).y));
    }
    toplevel.setPosition(pos.x, pos.y);
}

/// Layout y a dragged frame's top may not pass: the usable area's top on the
/// output under the cursor, unless another output lies above it.
fn topBarLimit(input: *Input) ?f64 {
    const output = Output.atLayout(input.server, input.cursor.x, input.cursor.y) orelse return null;
    var full: wlr.Box = undefined;
    input.server.output_layout.getBox(output.wlr_output, &full);
    const usable = output.usableBox();
    if (usable.y <= full.y) return null;
    if (Output.atLayout(input.server, input.cursor.x, @as(f64, @floatFromInt(full.y)) - 1) != null) return null;
    return @floatFromInt(usable.y);
}

pub fn processResize(input: *Input) void {
    const session = &(input.resize_session orelse {
        input.cursor_mode = .passthrough;
        return;
    });
    if (session.settling) return;

    const toplevel = session.toplevel;
    const constraints = toplevel.sizeConstraints();

    // Use the same unscaled cursor space as the resize snapshot.
    const cursor_wx = input.server.world.toWorld(input.cursor.x, input.cursor.y).x / toplevel.worldScale();
    const cursor_wy = input.server.world.toWorld(input.cursor.x, input.cursor.y).y / toplevel.worldScale();

    const desired = resize.computeDesiredClientSize(
        session.snapshot,
        cursor_wx,
        cursor_wy,
        constraints,
    );

    if (desired.width != session.latest_desired_size.width or desired.height != session.latest_desired_size.height) {
        session.latest_desired_size = desired;
        session.dirty = true;
        if (session.pacing_output) |out| {
            out.wlr_output.scheduleFrame();
        } else {
            input.server.scheduleFrames();
        }
    }
}
