//! Input targets: modifier state, pointer acceleration and which client surface an event reaches.

const std = @import("std");
const Input = @import("../Input.zig");
const wlr = @import("wlroots");
const Keyboard = @import("../Keyboard.zig");
const geometry = @import("../geometry.zig");
const scene_data = @import("../scene_data.zig");
const AccelProfile = Input.AccelProfile;
const AccelCurve = Input.AccelCurve;
const ClientTarget = Input.ClientTarget;

/// The Alt+wheel zoom modifier. While a client inhibits shortcuts, Alt is
/// the client's.
pub fn isAltHeld(input: *Input) bool {
    if (input.shortcuts_inhibit.inhibiting()) return false;
    var it = input.keyboards.iterator(.forward);
    while (it.next()) |kbd| {
        const wlr_kbd = kbd.device.toKeyboard();
        if (wlr_kbd.getModifiers().alt) return true;
    }
    return false;
}

/// Super (Logo) on any keyboard, distinct from `isAltHeld`. While a client
/// inhibits shortcuts, Super is the client's.
pub fn isSuperHeld(input: *Input) bool {
    if (input.shortcuts_inhibit.inhibiting()) return false;
    var it = input.keyboards.iterator(.forward);
    while (it.next()) |kbd| {
        const wlr_kbd = kbd.device.toKeyboard();
        if (wlr_kbd.getModifiers().logo) return true;
    }
    return false;
}

/// The `.super_key` pan trigger: `[input] pan_modifier` held on any keyboards.
pub fn isPanModifierHeld(input: *Input) bool {
    if (input.server.world.workspaces.active or input.server.world.overview.active()) return false;
    return switch (input.server.config.input.pan_modifier) {
        .super => input.isSuperHeld(),
        .super_alt => input.isDesktopZoomHeld(),
    };
}

/// Super+Alt: the wheel zooms the whole desktop, never the window under the
/// pointer, whatever `pan_modifier` is.
pub fn isDesktopZoomHeld(input: *Input) bool {
    return input.isSuperHeld() and input.isAltHeld();
}

/// True when the cursor is currently over the taskbar, so Super+drag pan can
/// be suppressed there in favor of the taskbar's own click/scroll handling
/// (e.g. dragging a taskbar item, or Super held while reaching for the start
/// button). A fresh hit test rather than `hovered_taskbar`, which is only
/// refreshed by passthrough motion and would otherwise lag one event behind.
pub fn cursorOverTaskbar(input: *Input) bool {
    const hit = scene_data.hitTest(input.server, input.cursor.x, input.cursor.y);
    return hit == .taskbar or hit == .dock;
}

pub fn updateAccel(input: *Input, profile: AccelProfile, p1: [2]f32, p2: [2]f32, max_speed: f32) void {
    input.accel_profile = profile;
    input.accel_curve = AccelCurve.init(p1, p2, max_speed);
}

pub fn accelMultiplier(input: *const Input, dx: f64, dy: f64) f64 {
    switch (input.accel_profile) {
        .flat => return 1.0,
        .bezier => {
            const speed: f32 = @floatCast(std.math.hypot(dx, dy));
            return @floatCast(input.accel_curve.lookup(speed / input.accel_curve.max_speed));
        },
    }
}

/// Record where a real hit-test just placed the pointer, in both
/// surface-local and world coordinates, so a later implicit-grab motion can
/// extrapolate from this baseline (see passthroughMotion). Preserve the
/// world-to-client scale too: window scale composes with the desktop camera.
pub fn rememberPointerGrab(input: *Input, local_x: f64, local_y: f64, world_scale: f64) void {
    const world = input.server.world.camera.toWorld(input.server.world.bounds, input.cursor.x, input.cursor.y);
    input.pointer_grab_local_x = local_x;
    input.pointer_grab_local_y = local_y;
    input.pointer_grab_world_x = world.x;
    input.pointer_grab_world_y = world.y;
    input.pointer_grab_world_scale = world_scale;
}

/// Layout position of a surface-local point on the surface of the last real
/// hit: the inverse of the implicit-grab extrapolation in passthroughMotion.
pub fn focusedSurfaceToLayout(input: *const Input, sx: f64, sy: f64) geometry.Vec2 {
    const world = input.server.world;
    const point = world.camera.toLayout(
        world.bounds,
        input.pointer_grab_world_x + (sx - input.pointer_grab_local_x) * input.pointer_grab_world_scale,
        input.pointer_grab_world_y + (sy - input.pointer_grab_local_y) * input.pointer_grab_world_scale,
    );
    return .{ .x = point.x, .y = point.y };
}

/// Whether pointer motion currently belongs to the pointer-focused client
/// rather than to a compositor grab, pan, selector, menu or lock.
pub fn motionReachesClient(input: *const Input) bool {
    const server = input.server;
    if (server.locker != null or server.polkit_dialog != null or server.switcher.active() or server.world.overview.active()) return false;
    if (server.screenshot_selector.output != null) return false;
    if (input.cursor_mode != .passthrough or input.grabbed_toplevel != null or input.resize_session != null) return false;
    if (input.server.world.mini_map.dragging) return false;
    if (input.desktop_grab or input.seat.drag != null) return false;
    if (input.window_menu.node != null) return false;
    if (server.tray) |tray| if (tray.menu_item != 0) return false;
    return input.seat.pointer_state.focused_surface != null;
}

/// Whether touch and tablet input may go to clients through their own
/// protocols. Otherwise it emulates the pointer, so the lock, dialogs,
/// menus, grabs and click-outside dismissal behave as for a mouse.
pub fn directInputReachesClients(input: *Input) bool {
    const server = input.server;
    if (server.locker != null or server.polkit_dialog != null or server.switcher.active() or server.world.overview.active()) return false;
    if (server.screenshot_selector.output != null) return false;
    if (input.cursor_mode != .passthrough or input.grabbed_toplevel != null or input.resize_session != null) return false;
    if (input.server.world.mini_map.dragging) return false;
    if (input.desktop_grab or input.seat.drag != null or input.active_buttons > 0) return false;
    if (input.window_menu.node != null) return false;
    if (server.tray) |tray| if (tray.menu_item != 0) return false;
    if (input.open_start_menu != null or input.open_power_menu != null or input.open_wifi != null or input.open_battery != null or input.open_calendar != null) return false;
    // Alt+drag moves and Super pans are pointer gestures.
    if (input.isSuperHeld() or input.isAltHeld()) return false;
    return true;
}

/// The client surface a hit landed on, if any.
pub fn clientTarget(input: *Input, hit: scene_data.Hit, lx: f64, ly: f64) ?ClientTarget {
    const world = input.server.world.camera.toWorld(input.server.world.bounds, lx, ly);
    const Found = struct { surface: *wlr.Surface, sx: f64, sy: f64, world: bool, scale: f64 };
    const found: Found = switch (hit) {
        .surface => |res| .{ .surface = res.surface, .sx = res.sx, .sy = res.sy, .world = true, .scale = res.toplevel.worldScale() / res.toplevel.surfaceScale() },
        .xwayland_unmanaged => |res| .{ .surface = res.surface, .sx = res.sx, .sy = res.sy, .world = true, .scale = 1.0 / input.server.xwaylandScale() },
        .layer => |res| .{ .surface = res.surface, .sx = res.sx, .sy = res.sy, .world = false, .scale = 1 },
        .input_popup => |res| .{ .surface = res.surface, .sx = res.sx, .sy = res.sy, .world = false, .scale = 1 },
        else => return null,
    };
    return .{
        .surface = found.surface,
        .sx = found.sx,
        .sy = found.sy,
        .anchor = .{
            .world = found.world,
            .local_x = found.sx,
            .local_y = found.sy,
            .origin_x = if (found.world) world.x else lx,
            .origin_y = if (found.world) world.y else ly,
            .scale = found.scale,
        },
    };
}

/// Keyboard focus for a touch or pen press on a client, as a click gives.
pub fn focusForPress(input: *Input, hit: scene_data.Hit) void {
    input.presses +%= 1;
    input.server.undo.nextPress();
    switch (hit) {
        .surface => |res| input.server.world.focusSurface(res.toplevel, res.surface),
        .layer => |res| res.owner.focus(),
        .xwayland_unmanaged => |res| if (res.owner.wantsKeyboard()) {
            @import("../Keyboard.zig").enter(input.server, res.surface);
        },
        else => {},
    }
}
