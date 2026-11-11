//! Input scroll axes.

const std = @import("std");
const Input = @import("../Input.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const control_center = @import("../control_center/panel.zig");
const ui_scroll = @import("ui").widgets.scroll_container;
const Pointer = @import("../Pointer.zig");
const Toplevel = @import("../Toplevel.zig");
const chrome = @import("../chrome.zig");
const resize = @import("../resize.zig");
const scene_data = @import("../scene_data.zig");

pub fn cursorAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const input: *Input = @fieldParentPtr("cursor_axis", listener);
    if (input.blockedVirtual(&event.pointer.base)) return;
    if (input.zoom_device != &event.pointer.base) {
        input.zoom_scroll.reset();
        input.wheel_debounce = .{ .{}, .{} };
    }
    input.zoom_device = &event.pointer.base;
    var delta = event.delta;
    var delta_discrete = event.delta_discrete;
    if (event.source == .wheel and delta_discrete != 0) {
        const debounce = &input.wheel_debounce[@intCast(@intFromEnum(event.orientation))];
        const notch = debounce.feed(event.time_msec, delta, delta_discrete, input.server.config.input.wheel_debounce_ms) orelse return;
        delta = notch.delta;
        delta_discrete = notch.discrete;
    }
    input.processAxis(event.time_msec, event.orientation, delta, delta_discrete, event.source);
}

pub fn processAxis(
    input: *Input,
    time_msec: u32,
    orientation: wl.Pointer.Axis,
    raw_delta: f64,
    raw_delta_discrete: i32,
    source: wl.Pointer.AxisSource,
) void {
    if (input.server.idle) |im| im.notifyActivity(.pointer);
    if (input.server.locker) |lock| {
        if (lock.client) |client| if (input.server.polkit_dialog == null) client.axis(time_msec, orientation, raw_delta, raw_delta_discrete, source);
        return;
    }
    if (input.server.polkit_dialog != null or input.server.screenshot_selector.output != null) return;
    if (input.server.world.mini_map.dragging) return;
    if (input.server.switcher.active()) return;
    // Flip here, before zoom/UI/client branches, so `invert_scroll` behaves
    // like `natural_scroll` would if libinput's device toggle applied to
    // this device: a single, uniform reversal rather than one per consumer.
    const invert = input.server.config.input.invert_scroll;
    const delta: f64 = if (invert) -raw_delta else raw_delta;
    const delta_discrete: i32 = if (invert) -raw_delta_discrete else raw_delta_discrete;
    if (input.window_menu.node != null) {
        if (orientation == .vertical_scroll) input.window_menu.scroll(ui_scroll.axisDeltaPx(delta, delta_discrete));
        return;
    }
    if (input.server.tray) |tray| {
        if (tray.menu_item != 0) {
            tray.menuScroll(delta);
            return;
        }
    }
    if (input.server.world.workspaces.active and input.isSuperHeld()) {
        if (orientation == .vertical_scroll) {
            const steps = input.zoom_scroll.feed(delta_discrete, delta, @intCast(@intFromEnum(source)));
            if (steps != 0) input.server.world.workspaces.cycle(input.server, steps > 0);
        }
        return;
    }
    const scroll_hit = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
    if (scroll_hit == .taskbar) {
        const hit = scroll_hit.taskbar;
        if (hit.bar.appTrayAt(hit.sx, hit.sy)) |index| {
            if (input.server.tray) |tray| tray.scroll(index, if (delta_discrete != 0) delta_discrete else @intFromFloat(delta), orientation == .horizontal_scroll);
            return;
        }
    }
    if (scroll_hit == .chrome and !input.isAltHeld() and !input.isDesktopZoomHeld()) {
        const res = scroll_hit.chrome;
        if (res.toplevel.tabAt(res.sx, res.sy) != .none) {
            if (delta != 0) res.toplevel.stepTab(delta > 0);
            return;
        }
    }
    const desktop_zoom = input.isDesktopZoomHeld();
    const target: ?*Toplevel = if (input.server.world.workspaces.active or desktop_zoom) null else switch (scroll_hit) {
        .surface => |res| if (input.isAltHeld()) res.toplevel else null,
        .chrome => |res| if (input.isAltHeld() or (res.sy >= 0 and res.sy < res.toplevel.titlebarHeight())) res.toplevel else null,
        else => null,
    };
    const target_id = if (target) |window| window.id else 0;
    if (input.zoom_target_id != target_id) input.zoom_scroll.reset();
    input.zoom_target_id = target_id;
    if (!input.server.world.workspaces.active and (target != null or input.isAltHeld())) {
        if (orientation != .vertical_scroll) return;
        if (!input.canZoom()) {
            input.zoom_scroll.reset();
            return;
        }
        // Discrete steps still, but World.setZoom / Toplevel.setZoomAnimated
        // retarget a spring so repeated wheel ticks stay continuous.
        const steps = input.zoom_scroll.feed(delta_discrete, delta, @intCast(@intFromEnum(source)));
        if (steps != 0) {
            const index = if (target) |window| window.zoom_index else input.server.world.camera.zoom_index;
            const current: i32 = @intCast(index);
            const max_index: i32 = @intCast(@import("../camera.zig").zoom_levels.len - 1);
            const next: usize = @intCast(std.math.clamp(current + steps, 0, max_index));
            if (next == 0 or next == @as(usize, @intCast(max_index))) input.zoom_scroll.reset();
            if (next != index or target == null) {
                if (target) |window| {
                    window.setZoomAnimated(next, input.cursor.x, input.cursor.y);
                } else {
                    input.server.world.stepZoom(steps, input.cursor.x, input.cursor.y);
                }
            }
        }
        return;
    }
    input.zoom_scroll.reset();
    if (input.cursor_mode == .resize or input.cursor_mode == .pan) return;
    // Two-finger touchpad motion over empty desktop is a camera pan, matching
    // the middle-drag rubber-band/fling model. Mouse wheels stay no-ops here.
    const desktop_finger = !input.server.world.workspaces.active and source == .finger and (scroll_hit == .none or input.finger_pan);
    if (desktop_finger and input.cursor_mode == .passthrough and input.resize_session == null) {
        if (raw_delta == 0 and raw_delta_discrete == 0) {
            if (input.finger_pan) {
                input.finger_pan = false;
                input.server.world.endPanGesture();
                input.server.scheduleFrames();
            }
            return;
        }
        const z = input.server.world.camera.zoom();
        const pan_speed = input.server.config.input.pan_speed;
        if (orientation == .vertical_scroll) {
            input.server.world.panBy(0, -raw_delta * pan_speed / z);
        } else {
            input.server.world.panBy(-raw_delta * pan_speed / z, 0);
        }
        input.finger_pan = true;
        return;
    }
    // Detented wheel clicks glide in shell panels; touchpads are already smooth.
    const notch = source == .wheel and delta_discrete != 0;
    switch (scroll_hit) {
        .desktop => |hit| {
            if (orientation == .vertical_scroll) hit.desktop.scroll(delta);
            return;
        },
        .wifi_popup => |hit| {
            if (orientation == .vertical_scroll) hit.popup.scrollWheel(ui_scroll.axisDeltaPx(delta, delta_discrete));
            return;
        },
        .mini_map => return,
        .control_center => |hit| {
            if (orientation == .vertical_scroll) {
                control_center.scrollWheel(hit.cc, hit.sx, hit.sy, ui_scroll.axisDeltaPx(delta, delta_discrete), notch);
            }
            return;
        },
        .start_menu => |hit| {
            if (orientation == .vertical_scroll) {
                hit.menu.scrollWheel(hit.sx, hit.sy, ui_scroll.axisDeltaPx(delta, delta_discrete), notch);
            }
            return;
        },
        .dock => |hit| {
            hit.dock.scroll(ui_scroll.axisDeltaPx(delta, delta_discrete));
            return;
        },
        .taskbar => |hit| {
            if (orientation == .vertical_scroll) {
                hit.bar.scrollVolume(hit.sx, hit.sy, ui_scroll.axisDeltaPx(delta, delta_discrete), notch);
            }
            return;
        },
        else => {},
    }
    if (notch) return input.client_wheel.forward(time_msec, orientation, delta, delta_discrete);
    input.seat.pointerNotifyAxis(
        time_msec,
        orientation,
        delta,
        delta_discrete,
        source,
        .identical,
    );
}
