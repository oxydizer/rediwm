//! Input pointer buttons: compositor, chrome and client presses.

const std = @import("std");
const Input = @import("../Input.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const control_center = @import("../control_center/panel.zig");
const Keyboard = @import("../Keyboard.zig");
const Output = @import("../Output.zig");
const Pointer = @import("../Pointer.zig");
const chrome = @import("../chrome.zig");
const resize = @import("../resize.zig");
const scene_data = @import("../scene_data.zig");
const btn_left = Input.btn_left;
const btn_right = Input.btn_right;
const btn_middle = Input.btn_middle;

pub fn cursorButton(
    listener: *wl.Listener(*wlr.Pointer.event.Button),
    event: *wlr.Pointer.event.Button,
) void {
    const input: *Input = @fieldParentPtr("cursor_button", listener);
    if (input.blockedVirtual(&event.pointer.base)) return;
    input.processButton(&event.pointer.base, event.button, event.state, event.time_msec);
}

pub fn processButton(
    input: *Input,
    device: ?*wlr.InputDevice,
    button: u32,
    state: wl.Pointer.ButtonState,
    time_msec: u32,
) void {
    @import("../startup.zig").markFirstInput();
    if (input.server.idle) |im| {
        if (im.interceptWakeButton(button, state)) return;
        im.notifyActivity(.pointer);
    }
    const map_bit: u32 = if (button >= 272 and button < 304) @as(u32, 1) << @as(u5, @intCast(button - 272)) else 0;
    if (state == .released and input.mini_map_buttons & map_bit != 0) {
        input.mini_map_buttons &= ~map_bit;
        if (button == btn_left) input.server.world.mini_map.release();
        input.processCursorMotion(time_msec);
        return;
    }
    if (state == .released and input.overview_buttons & map_bit != 0) {
        input.overview_buttons &= ~map_bit;
        return;
    }
    if (input.server.locker) |lock| {
        // Before the client: a drag begun on the built-in screen must end.
        if (state == .released and button == btn_left) lock.pointerReleased();
        if (lock.client) |client| if (client.button(time_msec, button, state)) return;
        if (state == .pressed and button == btn_left) lock.click(input.cursor.x, input.cursor.y);
        return;
    }
    const polkit_bit: u32 = if (button >= 272 and button < 304) @as(u32, 1) << @as(u5, @intCast(button - 272)) else 0;
    if (state == .released and input.polkit_buttons & polkit_bit != 0) {
        input.polkit_buttons &= ~polkit_bit;
        if (input.server.polkit_dialog) |dialog| if (button == btn_left) dialog.button(false, input.cursor.x, input.cursor.y);
        return;
    }
    if (input.server.polkit_dialog) |dialog| {
        if (state == .pressed) input.polkit_buttons |= polkit_bit;
        if (button == btn_left) dialog.button(state == .pressed, input.cursor.x, input.cursor.y);
        return;
    }
    if (input.server.world.overview.active()) {
        if (state == .pressed) {
            input.overview_buttons |= map_bit;
            input.server.world.overview.press(&input.server.world, button);
        }
        return;
    }
    const screenshot_bit: u32 = if (button >= 272 and button < 304) @as(u32, 1) << @as(u5, @intCast(button - 272)) else 0;
    if (state == .released and input.screenshot_buttons & screenshot_bit != 0) {
        input.screenshot_buttons &= ~screenshot_bit;
        if (input.server.screenshot_selector.output != null) input.server.screenshot_selector.button(button, false, input.cursor.x, input.cursor.y);
        return;
    }
    if (input.server.screenshot_selector.output != null) {
        if (state == .pressed) input.screenshot_buttons |= screenshot_bit;
        input.server.screenshot_selector.button(button, state == .pressed, input.cursor.x, input.cursor.y);
        return;
    }
    if (state == .released and input.tray_buttons & screenshot_bit != 0) {
        input.tray_buttons &= ~screenshot_bit;
        return;
    }
    if (state == .released and input.switcher_buttons & screenshot_bit != 0) {
        input.switcher_buttons &= ~screenshot_bit;
        return;
    }
    if (input.window_menu.node != null) {
        if (state == .pressed) {
            input.tray_buttons |= screenshot_bit;
            input.window_menu.press(input.cursor.x, input.cursor.y, button);
        } else if (input.active_buttons > 0) {
            // A dock picker opens during the icon's left press, after that
            // press was counted below. Its release still ends the button grab.
            input.active_buttons -= 1;
            input.pointer_constraints.sync();
        }
        return;
    }
    if (button == 0x111 and state == .pressed and input.cursor_mode == .passthrough and
        input.active_buttons == 0 and input.seat.drag == null and !input.server.switcher.active())
    {
        const picked = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
        if (picked == .taskbar) {
            const hit = picked.taskbar;
            switch (hit.bar.hitTest(hit.sx, hit.sy)) {
                .chip => |target| {
                    input.tray_buttons |= screenshot_bit;
                    input.window_menu.open(hit.bar, target, @intFromFloat(input.cursor.x));
                    return;
                },
                else => {},
            }
        } else if (picked == .dock) {
            const hit = picked.dock;
            if (hit.dock.contextMenu(hit.sx, hit.sy, @intFromFloat(input.cursor.x))) {
                input.tray_buttons |= screenshot_bit;
                return;
            }
        }
    }
    if (input.server.tray) |tray| {
        if (tray.menu_item != 0) {
            if (state == .pressed) {
                input.tray_buttons |= screenshot_bit;
                tray.menuClick(input.cursor.x, input.cursor.y, button);
            }
            return;
        }
        const picked = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
        if (picked == .taskbar) {
            const hit = picked.taskbar;
            if (hit.bar.appTrayAt(hit.sx, hit.sy)) |index| {
                if (state == .pressed) {
                    input.tray_buttons |= screenshot_bit;
                    tray.click(index, button, hit.bar, @intFromFloat(input.cursor.x), @intFromFloat(input.cursor.y));
                    input.seat.pointerClearFocus();
                }
                return;
            }
        }
    }
    if (input.server.switcher.active()) {
        if (state == .pressed) {
            input.switcher_buttons |= screenshot_bit;
            input.server.switcher.press(input.server, input.cursor.x, input.cursor.y, button);
        }
        return;
    }
    if (input.server.world.mini_map.dragging or
        (input.cursor_mode == .passthrough and input.active_buttons == 0 and input.seat.drag == null and
            scene_data.hitTest(input.server, input.cursor.x, input.cursor.y) == .mini_map))
    {
        if (state == .pressed) {
            input.mini_map_buttons |= map_bit;
            if (button == btn_left) input.server.world.mini_map.press(input.cursor.x, input.cursor.y);
        }
        input.seat.pointerClearFocus();
        input.pointer_constraints.sync();
        return;
    }
    if (state == .pressed) {
        input.active_buttons += 1;
        input.presses +%= 1;
        input.server.undo.nextPress();
    } else if (state == .released) {
        if (input.active_buttons > 0) input.active_buttons -= 1;
    }

    if (input.tiling_grab) |session| {
        if (state == .released and button == session.button) {
            input.finishTilingGrab(true);
            input.processCursorMotion(time_msec);
        }
        return;
    }
    if (input.cursor_mode == .resize) {
        if (state == .released) {
            if (input.resize_session) |session| {
                if (session.initiating_button == button) {
                    input.finishResize();
                }
            } else {
                input.cursor_mode = .passthrough;
            }
        }
        return;
    }

    // Middle button: start/end pan
    if (button == btn_middle and !input.server.world.workspaces.active and input.server.config.input.middle_button_pan) {
        if (state == .pressed) {
            if (input.cursor_mode == .passthrough and input.resize_session == null and input.grabbed_toplevel == null) {
                const inhibited = if (input.pan_session) |sess|
                    sess.inhibited and sess.trigger == .middle_button
                else
                    false;
                if (!inhibited) input.startPan(.middle_button, device);
            } else if (input.cursor_mode == .pan and input.pan_session != null and input.pan_session.?.trigger == .super_key) {
                // Switching from Super pan to middle pan rebases without a jump
                input.pan_session.?.trigger = .middle_button;
                input.pan_session.?.initiating_device = device;
                input.pan_session.?.last_x = input.cursor.x;
                input.pan_session.?.last_y = input.cursor.y;
                input.pan_session.?.button_consumed = true;
            }
        } else {
            // Released
            if (input.cursor_mode == .pan and input.pan_session != null and input.pan_session.?.trigger == .middle_button) {
                if (input.pan_session.?.initiating_device == null or device == null or input.pan_session.?.initiating_device == device) {
                    const client_click = !input.pan_session.?.button_consumed;
                    input.endPan();
                    input.pan_session = null;
                    if (client_click) {
                        input.processClientButton(device, button, .pressed, time_msec);
                        input.processClientButton(device, button, .released, time_msec);
                    }
                }
            } else if (input.pan_session != null and input.pan_session.?.trigger == .middle_button) {
                // Clear inhibit when trigger button is released
                input.pan_session = null;
            }
        }
        return;
    }

    input.processClientButton(device, button, state, time_msec);
}

pub fn processClientButton(
    input: *Input,
    device: ?*wlr.InputDevice,
    button: u32,
    state: wl.Pointer.ButtonState,
    time_msec: u32,
) void {
    // When panning:
    if (input.cursor_mode == .pan) {
        if (input.pan_session) |sess| {
            if (sess.trigger == .middle_button) {
                // Middle-button pan owns input until its middle release: suppress other button actions
                return;
            } else if (sess.trigger == .super_key) {
                if (state == .released) return; // swallow releases during Super pan
                // Non-middle button press ends Super pan so Super+left move or Super+right resize can start
                input.endPan();
                input.pan_session = null;
            }
        }
    }

    if (state == .released) {
        if (input.hovered_toast) |toast| {
            const local = scene_data.toNodeLocal(&toast.buffer_node.node, input.cursor.x, input.cursor.y);
            toast.pointerButtonUp(local.x, local.y);
        }
        if (input.open_control_center) |cc| {
            const local = cc.localPoint(input.cursor.x, input.cursor.y);
            control_center.pointerButtonUp(cc, local.x, local.y);
        }
        // A drag onto the dock ends here; the menu must not see it as a click.
        if (!input.dock_drag.release(input, button)) if (input.open_start_menu) |sm| {
            const local = scene_data.toNodeLocal(&sm.buffer_node.node, input.cursor.x, input.cursor.y);
            sm.pointerButtonUp(local.x, local.y);
        };
        if (input.open_power_menu) |pm| {
            const local = scene_data.toNodeLocal(&pm.buffer_node.node, input.cursor.x, input.cursor.y);
            pm.pointerButtonUp(local.x, local.y);
        }
        if (input.desktop_grab) {
            if (input.server.desktop) |desktop| desktop.pointerButton(button, false);
            if (input.active_buttons == 0) input.desktop_grab = false;
        }
        if (input.seat.drag != null) switch (scene_data.hitTest(input.server, input.cursor.x, input.cursor.y)) {
            .desktop => if (input.server.desktop) |desktop| {
                _ = desktop.drop(button);
            },
            .dock => |res| _ = input.trash_drop.drop(res.dock, res.sx, res.sy, button),
            else => {},
        };
        _ = input.seat.pointerNotifyButton(time_msec, button, state);
        // A move grab ends here, and `grabbed_toplevel` must be dropped with the
        // mode: startPan() refuses to start while a toplevel is grabbed, so a
        // stale pointer left behind by a titlebar/Super drag kills every later pan
        // (Super and middle alike) while zoom, which doesn't consult it, keeps
        // working — the state has to stay in sync with `cursor_mode`.
        // The release frame also refreshes a held titlebar blur (see heldGlass).
        if (input.cursor_mode == .move) input.endMove(true);
        input.cursor_mode = .passthrough;
        input.grabbed_toplevel = null;
        input.processCursorMotion(time_msec);
        return;
    }

    if (input.open_wifi) |popup| {
        const picked = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
        switch (picked) {
            .wifi_popup => {},
            .taskbar => |res| {
                const own_anchor = switch (res.bar.hitTest(res.sx, res.sy)) {
                    .tray => |i| i == 1,
                    else => false,
                };
                if (!own_anchor) popup.output.closeWifi();
            },
            else => {
                popup.output.closeWifi();
                return;
            },
        }
    }
    if (input.open_battery) |popup| {
        const picked = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
        const inside = switch (picked) {
            .battery_popup => true,
            .taskbar => |res| switch (res.bar.hitTest(res.sx, res.sy)) {
                .battery, .clock => true,
                .tray => |i| i == 1,
                else => false,
            },
            else => false,
        };
        if (!inside) {
            popup.output.closeBattery();
            return;
        }
    }

    if (input.open_calendar) |calendar| {
        const picked = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
        const inside = switch (picked) {
            .calendar => true,
            .taskbar => |res| switch (res.bar.hitTest(res.sx, res.sy)) {
                .battery, .clock => true,
                .tray => |i| i == 1,
                else => false,
            },
            else => false,
        };
        if (!inside) {
            calendar.output.closeCalendar();
            return;
        }
    }

    if (input.open_start_menu) |sm| {
        if (sm.state != .closing and !sm.containsPoint(input.cursor.x, input.cursor.y)) {
            const hit_test = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
            const clicked_start_btn = switch (hit_test) {
                .taskbar => |res| res.bar.hitTest(res.sx, res.sy) == .start_button,
                else => false,
            };
            if (!clicked_start_btn) {
                if (Output.fromWlr(sm.wlr_output)) |output| output.closeStartMenu();
                return;
            }
        }
    }

    if (input.open_power_menu) |pm| {
        if (pm.state != .closing and !pm.containsPoint(input.cursor.x, input.cursor.y)) {
            if (Output.fromWlr(pm.wlr_output)) |output| output.closePowerMenu();
            return;
        }
    }

    const hit = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
    switch (hit) {
        .mini_map => return,
        .toast => |res| {
            res.toast.pointerButtonDown(res.sx, res.sy);
            return;
        },
        .dock => |res| {
            if (button == btn_left) res.dock.press(res.sx, res.sy);
            return;
        },
        .taskbar => |res| {
            res.bar.pointerPress(res.sx, res.sy);
            return;
        },
        .chrome => |res| {
            input.server.world.focus(res.toplevel);
            if (button == btn_left) {
                const local = res.toplevel.frameLocal(input.cursor.x, input.cursor.y);
                const has_control = res.toplevel.controlAt(res.sx, res.sy) != null or res.toplevel.tabAt(res.sx, res.sy) != .none;
                if (resize.detectResizeEdges(local.x, local.y, res.toplevel.chrome_width, res.toplevel.chrome_height, res.toplevel.titlebarHeight(), chrome.frameBorder(), chrome.frameBorder(), has_control)) |edges| {
                    input.startResize(res.toplevel, edges.toWlr(), device, button);
                    return;
                }
                const on_title = !has_control and res.sy < @as(f64, @floatFromInt(res.toplevel.titlebarHeight()));
                if (on_title and input.titleDoubleClick(res.toplevel, time_msec)) {
                    res.toplevel.toggleMaximize();
                    return;
                }
            }
            res.toplevel.handleChromeClick(res.sx, res.sy, button);
            return;
        },
        .wifi_popup => |res| {
            if (button == btn_left) res.popup.press(res.sx, res.sy);
            return;
        },
        .battery_popup => |res| {
            if (button == btn_left) res.popup.press(res.sx, res.sy);
            return;
        },
        .calendar => |res| {
            if (button == btn_left) res.calendar.press(res.sx, res.sy);
        },
        .control_center => |res| {
            const toplevel = res.cc.toplevel;
            input.server.world.focus(toplevel);
            // Alt+drag moves and Alt+right-drag resizes, as over a client.
            const alt = if (input.server.world.workspaces.active) input.isSuperHeld() else input.isAltHeld();
            if (alt and button == btn_left) {
                toplevel.beginMove();
            } else if (alt and button == btn_right) {
                const local = toplevel.frameLocal(input.cursor.x, input.cursor.y);
                const edges = resize.selectEdgesFromQuadrant(local.x, local.y, 0, 0, toplevel.chrome_width, toplevel.chrome_height);
                input.startResize(toplevel, edges.toWlr(), device, button);
            } else if (button == btn_left) {
                control_center.pointerButtonDown(res.cc, res.sx, res.sy);
            }
            return;
        },
        .start_menu => |res| {
            res.menu.pointerButtonDown(res.sx, res.sy);
            if (button == btn_left) if (res.menu.pressedApp()) |app| input.dock_drag.arm(input, app.id, app.icon, res.menu.wlr_output.scale);
            return;
        },
        .power_menu => |res| {
            res.menu.pointerButtonDown(res.sx, res.sy);
            return;
        },
        .desktop => |res| {
            res.desktop.pointerButton(button, true);
            input.desktop_grab = true;
        },
        .surface, .layer, .xwayland_unmanaged, .input_popup => {},
        .none => {},
    }

    if (hit == .layer) hit.layer.owner.focus();
    if (hit == .xwayland_unmanaged and hit.xwayland_unmanaged.owner.wantsKeyboard()) {
        const surface = hit.xwayland_unmanaged.surface;
        @import("../Keyboard.zig").enter(input.server, surface);
    }
    // Any keyboard-focus change belonging to this click must be requested
    // before pointerNotifyButton, not after: a client's own request_start_drag
    // must reference the button press's serial, and if a keyboard enter (a
    // real, separate serial-bearing event) reaches the client afterward, GTK
    // ends up referencing that later serial instead - wlroots then rejects
    // the drag as stale (confirmed via wlr_seat_pointer.c's own "Pointer grab
    // serial validation failed" log; reproduces with two native Wayland
    // clients, nothing Xwayland-specific). Clicking an unfocused window to
    // start a drag from it is a completely ordinary gesture, so this isn't a
    // narrow edge case.
    if (input.server.world.workspaces.active and input.isSuperHeld() and hit == .surface and (button == btn_left or button == btn_right)) {
        const top = hit.surface.toplevel;
        input.server.world.focus(top);
        if (button == btn_left) top.beginMove() else {
            const local = top.frameLocal(input.cursor.x, input.cursor.y);
            const edges = resize.selectEdgesFromQuadrant(local.x, local.y, 0, 0, top.chrome_width, top.chrome_height);
            input.startResize(top, edges.toWlr(), device, button);
        }
        return;
    }
    if (hit == .surface) input.server.world.focusSurface(hit.surface.toplevel, hit.surface.surface);
    _ = input.seat.pointerNotifyButton(time_msec, button, state);
    switch (hit) {
        .surface => |res| {
            const ws = res.toplevel.worldScale() / res.toplevel.surfaceScale();
            input.rememberPointerGrab(res.sx, res.sy, ws);
            if (input.seat.getKeyboard()) |keyboard| {
                if (!input.server.world.workspaces.active and keyboard.getModifiers().alt) {
                    if (button == btn_left) {
                        res.toplevel.beginMove();
                    } else if (button == btn_right) {
                        // Select edges in the unscaled frame.
                        const local = res.toplevel.frameLocal(input.cursor.x, input.cursor.y);
                        const edges = resize.selectEdgesFromQuadrant(
                            local.x,
                            local.y,
                            0,
                            0,
                            res.toplevel.chrome_width,
                            res.toplevel.chrome_height,
                        );
                        input.startResize(res.toplevel, edges.toWlr(), device, button);
                    }
                }
            }
        },
        .xwayland_unmanaged => |res| input.rememberPointerGrab(res.sx, res.sy, 1.0 / input.server.xwaylandScale()),
        else => {},
    }
}
