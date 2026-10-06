// Seat, cursor, and pointer/keyboard policy.
const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const control_center = @import("control_center/panel.zig");
const ControlCenter = control_center.ControlCenter;
const StartMenu = @import("start_menu/panel.zig").StartMenu;
const PowerMenu = @import("power_menu.zig").PowerMenu;
const ui_scroll = @import("ui").widgets.scroll_container;
const ui_input = @import("ui").input;
const Keyboard = @import("Keyboard.zig");
const Output = @import("Output.zig");
const Pointer = @import("Pointer.zig");
const Server = @import("Server.zig");
const Taskbar = @import("Taskbar.zig");
const Toplevel = @import("Toplevel.zig");
const chrome = @import("chrome.zig");
const geometry = @import("geometry.zig");
const glass = @import("glass.zig");
const resize = @import("resize.zig");
const snap = @import("snap.zig");
const scene_data = @import("scene_data.zig");
const CursorSerial = @import("input/cursor_serial.zig");
const ClientWheel = @import("input/client_wheel.zig");
const PointerConstraints = @import("input/pointer_constraints.zig");
const ShortcutsInhibit = @import("input/shortcuts_inhibit.zig");
const Touch = @import("input/touch.zig");
const Tablet = @import("input/tablet.zig");
const Lid = @import("input/lid.zig");
const DragDodge = @import("input/drag_dodge.zig");
const cursor_theme = @import("cursor_theme.zig");
const gpa = @import("main.zig").gpa;

const Input = @This();

const log = std.log.scoped(.input);

// linux/input-event-codes.h
pub const btn_left: u32 = 0x110;
pub const btn_right: u32 = 0x111;
pub const btn_middle: u32 = 0x112;

pub const PanTrigger = enum { super_key, middle_button };
/// `[input] pan_modifier`: what `.super_key` pans need held.
pub const PanModifier = @import("config").types.PanModifier;
pub const AccelProfile = @import("config").types.AccelProfile;
pub const AccelCurve = @import("config").types.AccelCurve;

pub const PanSession = struct {
    trigger: PanTrigger,
    initiating_device: ?*wlr.InputDevice,
    /// Last known absolute cursor position (layout coords), for absolute devices.
    last_x: f64,
    last_y: f64,
    /// Whether the initiating button was consumed (not sent to clients).
    button_consumed: bool,
    /// Set true after Escape; pan cannot restart until the trigger is released.
    inhibited: bool = false,
};

pub const ResizeSession = struct {
    toplevel: *Toplevel,
    generation: u64,
    initiating_device: ?*wlr.InputDevice,
    initiating_button: u32,
    edges: resize.Edges,
    snapshot: resize.ResizeSnapshot,
    latest_desired_size: resize.ClientSize,
    dirty: bool = false,
    pacing_output: ?*Output = null,
    outstanding_configure: Toplevel.ConfigureWait = .none,
    last_sent_width: i32 = 0,
    last_sent_height: i32 = 0,
    settling: bool = false,
};

server: *Server,
seat: *wlr.Seat,
cursor: *wlr.Cursor,
cursor_mgr: *wlr.XcursorManager,
// Forwarded verbatim to whichever client surface has pointer focus (via
// zwp_pointer_gestures_v1) so e.g. Chromium's touchpad pinch-to-zoom and
// swipe navigation work; the compositor's own Ctrl+scroll zoom is a
// separate, unrelated mechanism (see zoom_scroll) and does not consume these.
pointer_gestures: *wlr.PointerGesturesV1,
/// Relative motion and pointer lock/confinement for games.
pointer_constraints: PointerConstraints = undefined,
/// Compositor bindings handed to VMs and remote desktops.
shortcuts_inhibit: ShortcutsInhibit = undefined,
/// A file manager slides aside while a file is dragged out of it.
drag_dodge: DragDodge = undefined,
/// Touchscreens: wl_touch, or pointer emulation.
touch: Touch = undefined,
/// Drawing tablets: tablet-v2, or pointer emulation.
tablet: Tablet = undefined,
/// Lid switches.
lid: Lid = undefined,
default_cursor_applied: bool = false,
// Whether the applied default cursor is the launch-feedback "progress" one.
default_cursor_busy: bool = false,
// Theme name and size cursor_mgr was created with, to spot config changes.
cursor_theme_name: [128]u8 = undefined,
cursor_theme_len: usize = 0,
cursor_theme_size: u32 = 0,
cursor_source: enum { default, theme, surface, hidden } = .default,
cursor_name: ?[*:0]const u8 = "default",
cursor_serial: CursorSerial = .{},
keyboards: wl.list.Head(Keyboard, .link) = undefined,
pointers: wl.list.Head(Pointer, .link) = undefined,
// The one open control center, if any (opening/open/closing all count) —
// routes pointer gestures and captures keys only while focused.
// Output creates it; ControlCenter.destroy clears this reference.
open_control_center: ?*ControlCenter = null,
// The one open start menu, if any — gates keyboard grab and click-outside
// dismissal. Set/cleared by Output.openStartMenu/closeStartMenu.
open_start_menu: ?*StartMenu = null,
window_menu: @import("taskbar/window_menu.zig").Menu = .{},
open_calendar: ?*@import("calendar.zig").Calendar = null,
open_battery: ?*@import("battery_popup.zig").Popup = null,
open_wifi: ?*@import("network/popup.zig").Popup = null,
screenshot_buttons: u32 = 0,
polkit_buttons: u32 = 0,
// The one open power menu, if any — gates keyboard grab and click-outside
// dismissal. Set/cleared by Output.openPowerMenu/closePowerMenu.
open_power_menu: ?*PowerMenu = null,

new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursor),
request_set_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(requestSetShape),
drag_icon_tree: ?*wlr.SceneTree = null,
start_drag: wl.Listener(*wlr.Drag) = .init(startDrag),
drag_icon_destroy: wl.Listener(void) = .init(dragIconDestroyed),
request_start_drag: wl.Listener(*wlr.Seat.event.RequestStartDrag) = .init(requestStartDrag),
new_virtual_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) = .init(newVirtualPointer),
request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelection),
request_set_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) = .init(requestSetPrimarySelection),

cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotion),
cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsolute),
cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButton),
cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxis),
/// Acceleration and optional smoothing for wheel notches sent to clients.
client_wheel: ClientWheel = .{},
cursor_frame: wl.Listener(*wlr.Cursor) = .init(cursorFrame),

cursor_swipe_begin: wl.Listener(*wlr.Pointer.event.SwipeBegin) = .init(cursorSwipeBegin),
cursor_swipe_update: wl.Listener(*wlr.Pointer.event.SwipeUpdate) = .init(cursorSwipeUpdate),
cursor_swipe_end: wl.Listener(*wlr.Pointer.event.SwipeEnd) = .init(cursorSwipeEnd),
cursor_pinch_begin: wl.Listener(*wlr.Pointer.event.PinchBegin) = .init(cursorPinchBegin),
cursor_pinch_update: wl.Listener(*wlr.Pointer.event.PinchUpdate) = .init(cursorPinchUpdate),
cursor_pinch_end: wl.Listener(*wlr.Pointer.event.PinchEnd) = .init(cursorPinchEnd),
cursor_hold_begin: wl.Listener(*wlr.Pointer.event.HoldBegin) = .init(cursorHoldBegin),
cursor_hold_end: wl.Listener(*wlr.Pointer.event.HoldEnd) = .init(cursorHoldEnd),

cursor_mode: enum { passthrough, move, resize, pan } = .passthrough,
hovered_toplevel: ?*Toplevel = null,
hovered_taskbar: ?*Taskbar = null,
tray_buttons: u32 = 0,
hovered_toast: ?*@import("notifications/toast.zig").Toast = null,
grabbed_toplevel: ?*Toplevel = null,
grab_x: f64 = 0,
grab_y: f64 = 0,
grab_box: wlr.Box = undefined,
move_snap: MoveSnap = .{},
/// The last titlebar press, for double-click-to-maximize.
title_press: ?TitlePress = null,
/// Pointer presses so far: a double-click is two presses in a row.
presses: u64 = 0,
resize_session: ?ResizeSession = null,
next_session_generation: u64 = 1,
hovered_resize_edges: ?resize.Edges = null,
pan_session: ?PanSession = null,
/// Who owns the in-flight pinch/swipe: a focused client, or the compositor camera.
gesture: enum { none, client_pinch, client_swipe, compositor_pinch, compositor_swipe } = .none,
/// Two-finger touchpad scroll over empty desktop, distinct from middle-drag.
finger_pan: bool = false,
zoom_scroll: @import("camera.zig").ZoomScroll = .{},
zoom_device: ?*wlr.InputDevice = null,
zoom_target_id: u64 = 0,
active_buttons: u32 = 0,
/// A press landed on the compositor-drawn desktop; like a client's implicit
/// grab, motion stays desktop-local until every button is released.
desktop_grab: bool = false,
/// Releases belong to the map even if a modal transition cancels its grab.
mini_map_buttons: u32 = 0,
/// Last known (surface-local, world) correspondence for whichever ordinary
/// client surface currently holds pointer focus, refreshed on every real
/// hit. Lets passthroughMotion's implicit grab (see below) keep reporting
/// plausible local coordinates to that surface while a button is held and
/// the cursor is no longer actually over it, without needing to know the
/// surface's on-screen geometry directly (it may be a subsurface).
pointer_grab_local_x: f64 = 0,
pointer_grab_local_y: f64 = 0,
pointer_grab_world_x: f64 = 0,
pointer_grab_world_y: f64 = 0,
pointer_grab_world_scale: f64 = 1,
accel_profile: AccelProfile = .bezier,
accel_curve: AccelCurve = undefined,

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
    return scene_data.hitTest(input.server, input.cursor.x, input.cursor.y) == .taskbar;
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
fn rememberPointerGrab(input: *Input, local_x: f64, local_y: f64, world_scale: f64) void {
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
    if (server.locker != null or server.polkit_dialog != null or server.switcher.active()) return false;
    if (server.screenshot_selector.output != null) return false;
    if (input.cursor_mode != .passthrough or input.grabbed_toplevel != null or input.resize_session != null) return false;
    if (input.server.world.mini_map.dragging) return false;
    if (input.desktop_grab or input.seat.drag != null) return false;
    if (input.window_menu.target != null) return false;
    if (server.tray) |tray| if (tray.menu_item != 0) return false;
    return input.seat.pointer_state.focused_surface != null;
}

/// Whether touch and tablet input may go to clients through their own
/// protocols. Otherwise it emulates the pointer, so the lock, dialogs,
/// menus, grabs and click-outside dismissal behave as for a mouse.
pub fn directInputReachesClients(input: *Input) bool {
    const server = input.server;
    if (server.locker != null or server.polkit_dialog != null or server.switcher.active()) return false;
    if (server.screenshot_selector.output != null) return false;
    if (input.cursor_mode != .passthrough or input.grabbed_toplevel != null or input.resize_session != null) return false;
    if (input.server.world.mini_map.dragging) return false;
    if (input.desktop_grab or input.seat.drag != null or input.active_buttons > 0) return false;
    if (input.window_menu.target != null) return false;
    if (server.tray) |tray| if (tray.menu_item != 0) return false;
    if (input.open_start_menu != null or input.open_power_menu != null or input.open_wifi != null or input.open_battery != null or input.open_calendar != null) return false;
    // Alt+drag moves and Super pans are pointer gestures.
    if (input.isSuperHeld() or input.isAltHeld()) return false;
    return true;
}

/// Maps layout points to the surface-local coordinates of a surface pressed
/// at one point, so a held touch or pen stays with it wherever it moves
/// (the same extrapolation as the pointer's implicit grab).
pub const SurfaceAnchor = struct {
    /// Window content lives in the world; layer and IME popups in the layout.
    world: bool,
    local_x: f64,
    local_y: f64,
    origin_x: f64,
    origin_y: f64,
    /// World (or layout) units per surface unit.
    scale: f64,

    pub fn local(anchor: SurfaceAnchor, input: *const Input, lx: f64, ly: f64) geometry.Vec2 {
        const point: geometry.Vec2 = if (anchor.world) blk: {
            const w = input.server.world.camera.toWorld(input.server.world.bounds, lx, ly);
            break :blk .{ .x = w.x, .y = w.y };
        } else .{ .x = lx, .y = ly };
        return .{
            .x = anchor.local_x + (point.x - anchor.origin_x) / anchor.scale,
            .y = anchor.local_y + (point.y - anchor.origin_y) / anchor.scale,
        };
    }
};

pub const ClientTarget = struct {
    surface: *wlr.Surface,
    sx: f64,
    sy: f64,
    anchor: SurfaceAnchor,
};

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
            if (input.seat.getKeyboard()) |keyboard| {
                input.seat.keyboardNotifyEnter(res.surface, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
            }
        },
        else => {},
    }
}

pub fn updateCapabilities(input: *Input) void {
    input.seat.setCapabilities(.{
        .pointer = true,
        .keyboard = input.keyboards.length() > 0,
        .touch = input.touch.devices.length() > 0,
    });
}

pub fn init(input: *Input, server: *Server) Server.CompositorError!void {
    const seat = wlr.Seat.create(server.wl_server, "default") catch return error.SeatCreateFailed;
    errdefer seat.destroy(); // load() or a later listener add must not leak the seat
    const cursor = wlr.Cursor.create() catch return error.CursorCreateFailed;
    errdefer cursor.destroy();
    cursor_theme.init(gpa, server.io);
    const cursor_mgr = createCursorManager(server.config.input.cursor_theme, server.config.input.cursor_size) orelse return error.XcursorCreateFailed;
    errdefer cursor_mgr.destroy();
    const pointer_gestures = wlr.PointerGesturesV1.create(server.wl_server) catch return error.PointerGesturesCreateFailed;

    input.* = .{
        .server = server,
        .seat = seat,
        .cursor = cursor,
        .cursor_mgr = cursor_mgr,
        .pointer_gestures = pointer_gestures,
        .accel_profile = server.config.input.accel_profile,
        .accel_curve = AccelCurve.init(
            server.config.input.accel_p1,
            server.config.input.accel_p2,
            server.config.input.accel_max_speed,
        ),
    };
    input.rememberCursorTheme(server.config.input.cursor_theme, server.config.input.cursor_size);
    input.keyboards.init();
    input.pointers.init();

    // The display owns the manager; Input owns its listener and serial tracker.
    const shape_mgr = wlr.CursorShapeManagerV1.create(server.wl_server, 2) catch return error.CursorShapeManagerCreateFailed;
    input.cursor_serial.init(server.wl_server, seat) catch return error.CursorSerialTrackerCreateFailed;
    errdefer input.cursor_serial.deinit();
    shape_mgr.events.request_set_shape.add(&input.request_set_shape);
    errdefer input.request_set_shape.link.remove();

    server.backend.events.new_input.add(&input.new_input);
    errdefer input.new_input.link.remove();
    input.seat.events.request_set_cursor.add(&input.request_set_cursor);
    errdefer input.request_set_cursor.link.remove();
    input.seat.events.start_drag.add(&input.start_drag);
    errdefer input.start_drag.link.remove();
    input.seat.events.request_start_drag.add(&input.request_start_drag);
    errdefer input.request_start_drag.link.remove();
    input.seat.events.request_set_selection.add(&input.request_set_selection);
    errdefer input.request_set_selection.link.remove();
    input.seat.events.request_set_primary_selection.add(&input.request_set_primary_selection);
    errdefer input.request_set_primary_selection.link.remove();

    input.cursor.attachOutputLayout(server.output_layout);
    input.cursor_mgr.load(1) catch return error.XcursorCreateFailed;
    input.cursor.events.motion.add(&input.cursor_motion);
    input.cursor.events.motion_absolute.add(&input.cursor_motion_absolute);
    input.cursor.events.button.add(&input.cursor_button);
    input.cursor.events.axis.add(&input.cursor_axis);
    input.cursor.events.frame.add(&input.cursor_frame);
    input.cursor.events.swipe_begin.add(&input.cursor_swipe_begin);
    input.cursor.events.swipe_update.add(&input.cursor_swipe_update);
    input.cursor.events.swipe_end.add(&input.cursor_swipe_end);
    input.cursor.events.pinch_begin.add(&input.cursor_pinch_begin);
    input.cursor.events.pinch_update.add(&input.cursor_pinch_update);
    input.cursor.events.pinch_end.add(&input.cursor_pinch_end);
    input.cursor.events.hold_begin.add(&input.cursor_hold_begin);
    input.cursor.events.hold_end.add(&input.cursor_hold_end);
    input.pointer_constraints.init(input) catch return error.PointerConstraintsCreateFailed;
    errdefer input.pointer_constraints.deinit();
    input.shortcuts_inhibit.init(input) catch return error.ShortcutsInhibitCreateFailed;
    errdefer input.shortcuts_inhibit.deinit();
    input.drag_dodge.init(input);
    errdefer input.drag_dodge.deinit();
    input.touch.init(input);
    errdefer input.touch.deinit();
    input.tablet.init(input);
    errdefer input.tablet.deinit();
    input.lid.init(input);
    // Soft-fail like other optional globals; the display owns the manager.
    if (wlr.VirtualPointerManagerV1.create(server.wl_server)) |manager| {
        manager.events.new_virtual_pointer.add(&input.new_virtual_pointer);
    } else |err| {
        input.new_virtual_pointer.link.init();
        log.warn("init: could not create virtual-pointer manager: {}", .{err});
    }
}

fn createCursorManager(theme: []const u8, size: u32) ?*wlr.XcursorManager {
    var buf: [128]u8 = undefined;
    const name: ?[*:0]const u8 = if (cursor_theme.managerTheme(theme)) |t|
        (std.fmt.bufPrintZ(&buf, "{s}", .{t}) catch return null).ptr
    else
        null;
    return wlr.XcursorManager.create(name, size) catch null;
}

fn rememberCursorTheme(input: *Input, theme: []const u8, size: u32) void {
    input.cursor_theme_len = @min(theme.len, input.cursor_theme_name.len);
    @memcpy(input.cursor_theme_name[0..input.cursor_theme_len], theme[0..input.cursor_theme_len]);
    input.cursor_theme_size = size;
}

pub fn cursorThemeName(input: *const Input) []const u8 {
    return input.cursor_theme_name[0..input.cursor_theme_len];
}

/// Config reload: switch to a changed `cursor_theme`/`cursor_size`.
pub fn applyCursorTheme(input: *Input, theme: []const u8, size: u32) void {
    if (size == input.cursor_theme_size and std.mem.eql(u8, theme, input.cursor_theme_name[0..input.cursor_theme_len])) return;
    const mgr = createCursorManager(theme, size) orelse {
        log.warn("cursor theme '{s}' at size {d}: could not create manager", .{ theme, size });
        return;
    };
    // wlr_cursor keeps the manager of its current xcursor image; drop that
    // image before destroying the old manager. Client surface cursors hold
    // no manager and stay.
    if (input.cursor_source == .default or input.cursor_source == .theme) input.cursor.unsetImage();
    input.cursor_mgr.destroy();
    input.cursor_mgr = mgr;
    input.rememberCursorTheme(theme, size);
    mgr.load(1) catch {};
    var it = input.server.outputs.iterator(.forward);
    while (it.next()) |out| mgr.load(out.wlr_output.scale) catch {};
    if (input.server.xwayland) |xwayland| xwayland.applyCursor();
    switch (input.cursor_source) {
        .theme => if (input.cursor_name) |name| input.cursor.setXcursor(mgr, name),
        .default => {
            input.default_cursor_applied = false;
            input.setDefaultCursor();
        },
        // A client surface cursor is not ours to replace; the next enter
        // or shape request picks up the new theme.
        .surface, .hidden => {},
    }
}

/// Load the configured theme at every output scale.
pub fn refreshOutputScales(input: *Input) void {
    var it = input.server.outputs.iterator(.forward);
    while (it.next()) |out| {
        input.cursor_mgr.load(out.wlr_output.scale) catch |err| {
            log.warn("cursor theme at scale {d}: {}", .{ out.wlr_output.scale, err });
        };
    }
}

pub fn setDefaultCursor(input: *Input) void {
    const busy = input.server.launch_feedback.busy() and input.cursor_mgr.getXcursor("progress", 1) != null;
    if (input.default_cursor_applied and input.default_cursor_busy == busy) return;
    input.default_cursor_busy = busy;
    input.default_cursor_applied = true;
    input.cursor_source = .default;
    if (busy) {
        // Launch feedback: an app is starting. wlroots animates the spinner.
        input.cursor.setXcursor(input.cursor_mgr, "progress");
        input.cursor_name = "progress";
        return;
    }
    input.cursor.setXcursor(input.cursor_mgr, "default");
    input.cursor_name = "default";
}

/// Launch feedback started or ended: swap the arrow for the progress cursor
/// (or back) wherever the default cursor is showing.
pub fn refreshBusyCursor(input: *Input) void {
    if (input.cursor_source == .default) input.setDefaultCursor();
}

/// Cursor over compositor-drawn UI: the text cursor over editable fields,
/// otherwise the arrow (buttons and menus keep the arrow, as on other desktops).
fn setShellCursor(input: *Input, over_text: bool) void {
    if (over_text) input.setNamedCursor("text") else input.setDefaultCursor();
}

pub fn setNamedCursor(input: *Input, name: [*:0]const u8) void {
    input.default_cursor_applied = false;
    input.cursor.setXcursor(input.cursor_mgr, name);
    input.cursor_source = .theme;
    input.cursor_name = name;
}

pub fn deinit(input: *Input) void {
    input.window_menu.close();
    input.start_drag.link.remove();
    if (input.drag_icon_tree) |tree| tree.node.destroy();
    input.pointer_constraints.deinit();
    input.shortcuts_inhibit.deinit();
    input.drag_dodge.deinit();
    input.lid.deinit();
    input.tablet.deinit();
    input.touch.deinit();
    input.request_set_shape.link.remove();
    input.cursor_serial.deinit();
    input.new_input.link.remove();
    input.request_set_cursor.link.remove();
    input.request_set_selection.link.remove();
    input.request_set_primary_selection.link.remove();
    input.request_start_drag.link.remove();
    input.new_virtual_pointer.link.remove();
    input.cursor_motion.link.remove();
    input.cursor_motion_absolute.link.remove();
    input.cursor_button.link.remove();
    input.cursor_axis.link.remove();
    input.client_wheel.deinit();
    input.cursor_frame.link.remove();
    input.cursor_swipe_begin.link.remove();
    input.cursor_swipe_update.link.remove();
    input.cursor_swipe_end.link.remove();
    input.cursor_pinch_begin.link.remove();
    input.cursor_pinch_update.link.remove();
    input.cursor_pinch_end.link.remove();
    input.cursor_hold_begin.link.remove();
    input.cursor_hold_end.link.remove();

    // Reverse of init: cursor theme, cursor, then seat (the display still owns
    // the rest of the protocol objects until Server.deinit destroys it).
    input.cursor_mgr.destroy();
    cursor_theme.deinit(gpa);
    input.cursor.destroy();
    input.seat.destroy();
}

/// Drag-to-edge snapping for the current move grab (snap.zig).
const MoveSnap = struct {
    target: ?snap.Target = null,
    output: ?*Output = null,
    preview: snap.Preview = .{},
    /// A maximized or tiled window stays put until the pointer travels
    /// `snap.unsnap_px` from here, then floats under it (floatGrabbed).
    unsnap_from: ?geometry.Vec2 = null,
    /// Floating geometry before the drag, restored when leaving the snap.
    origin: ?Toplevel.RestoreGeometry = null,
};

const TitlePress = struct {
    press: u64,
    toplevel_id: u64,
    time_msec: u32,
    x: f64,
    y: f64,
};

pub fn startMove(input: *Input, toplevel: *Toplevel) void {
    toplevel.finishZoomAnimation();
    toplevel.finishMoveAnimation();
    toplevel.finishSizeAnimation();
    const snapped = toplevel.layout() != .floating and !toplevel.isFullscreen();
    input.move_snap.preview.hide();
    input.move_snap = .{
        .preview = input.move_snap.preview,
        .unsnap_from = if (snapped) .{ .x = input.cursor.x, .y = input.cursor.y } else null,
        .origin = if (toplevel.layout() == .floating) toplevel.rememberGeometry() else null,
    };
    // Cursor is in layout space; convert to world space to compute the grab
    // offset relative to the window origin (which lives in world space).
    const wx = input.server.world.toWorld(input.cursor.x, input.cursor.y).x;
    const wy = input.server.world.toWorld(input.cursor.x, input.cursor.y).y;
    const origin = geometry.toLocal(wx, wy, toplevel.x, toplevel.y);
    input.grabbed_toplevel = toplevel;
    input.cursor_mode = .move;
    // The window is held until release; its client gets the pointer back
    // (and sets its own cursor) on the re-enter after the move.
    input.setHover(null, null);
    input.seat.pointerClearFocus();
    input.setNamedCursor("grabbing");
    input.grab_x = origin.x;
    input.grab_y = origin.y;
    // Snapshot current geometry for undo. Press folding: if a focus change
    // already fired on this press, begin() will inherit its focus id.
    const geom = toplevel.clientGeometry();
    input.server.undo.begin(.{
        .kind = .move,
        .press_seq = input.server.undo.press_seq,
        .at_ms = 0,
        .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = geom.width, .height = geom.height, .zoom_index = toplevel.zoom_index, .layout = toplevel.layout() },
    });
}

/// Ends a move grab, dropping the window into the snap zone under the
/// pointer when `apply_snap` (a button release rather than a cancel).
fn endMove(input: *Input, apply_snap: bool) void {
    // The release frame refreshes a held titlebar blur (see heldGlass).
    input.server.scheduleFrames();
    const target = input.move_snap.target;
    const output = input.move_snap.output;
    const origin = input.move_snap.origin;
    input.move_snap.preview.hide();
    input.move_snap = .{ .preview = input.move_snap.preview };
    // Before snapping: setPositionAnimated jumps while a move grab is live.
    input.cursor_mode = .passthrough;
    const toplevel = input.grabbed_toplevel orelse {
        input.server.undo.drop();
        return;
    };
    input.grabbed_toplevel = null;
    if (apply_snap) if (target) |t| if (output) |out| toplevel.snapTo(out, t, origin);
    const geom = toplevel.clientGeometry();
    input.server.undo.commit(Server.undoNowMs(), .{
        .window = .{
            .id = toplevel.id,
            .x = toplevel.x,
            .y = toplevel.y,
            .width = geom.width,
            .height = geom.height,
            .zoom_index = toplevel.zoom_index,
            .layout = toplevel.layout(),
        },
    });
}

/// Drag-to-restore: float a maximized or tiled window at its restore size,
/// keeping the grab at the same fraction of the frame width so the titlebar
/// stays under the pointer.
fn floatGrabbed(input: *Input, toplevel: *Toplevel) void {
    const restore = toplevel.tile_restore orelse toplevel.maximize_restore;
    const ws = toplevel.worldScale();
    const old_w = @as(f64, @floatFromInt(@max(1, toplevel.chrome_width))) * ws;
    const fraction = std.math.clamp(input.grab_x / old_w, 0, 1);
    toplevel.leaveLayout();
    const geom = restore orelse return;
    _ = toplevel.requestSize(geom.width, geom.height);
    const new_w = @as(f64, @floatFromInt(geom.width + 2 * toplevel.borderWidth())) * ws;
    const title_h = @as(f64, @floatFromInt(@max(1, toplevel.titlebarHeight()))) * ws;
    input.grab_x = fraction * new_w;
    input.grab_y = @min(input.grab_y, title_h - 1);
}

fn updateSnapTarget(input: *Input, toplevel: *Toplevel) void {
    const found = input.snapTargetAt(toplevel);
    const target = if (found) |f| f.target else null;
    const output = if (found) |f| f.output else null;
    if (std.meta.eql(target, input.move_snap.target) and output == input.move_snap.output) return;
    input.move_snap.target = target;
    input.move_snap.output = output;
    if (found) |f| {
        const rect = snap.targetRect(f.output.usableBox(), f.target, input.server.config.compositor.window_gap);
        input.move_snap.preview.show(input.server.overlay_tree, rect);
    } else {
        input.move_snap.preview.hide();
    }
}

fn snapTargetAt(input: *Input, toplevel: *Toplevel) ?struct { target: snap.Target, output: *Output } {
    if (!input.server.config.compositor.snap_to_edges or toplevel.isFullscreen() or toplevel.parentWindow() != null) return null;
    const x = input.cursor.x;
    const y = input.cursor.y;
    const output = Output.atLayout(input.server, x, y) orelse return null;
    var box: wlr.Box = undefined;
    input.server.output_layout.getBox(output.wlr_output, &box);
    const left: f64 = @floatFromInt(box.x);
    const top: f64 = @floatFromInt(box.y);
    const right: f64 = @floatFromInt(box.x + box.width);
    const bottom: f64 = @floatFromInt(box.y + box.height);
    const open: snap.OpenEdges = .{
        .left = Output.atLayout(input.server, left - 1, y) == null,
        .right = Output.atLayout(input.server, right, y) == null,
        .top = Output.atLayout(input.server, x, top - 1) == null,
        .bottom = Output.atLayout(input.server, x, bottom) == null,
    };
    const target = snap.targetAt(x, y, box, output.usableBox(), open) orelse return null;
    return .{ .target = target, .output = output };
}

/// Records a titlebar press; true when it completes a double-click.
fn titleDoubleClick(input: *Input, toplevel: *Toplevel, time_msec: u32) bool {
    const press: TitlePress = .{ .press = input.presses, .toplevel_id = toplevel.id, .time_msec = time_msec, .x = input.cursor.x, .y = input.cursor.y };
    if (input.title_press) |prev| {
        if (prev.press + 1 == press.press and
            prev.toplevel_id == press.toplevel_id and
            press.time_msec -% prev.time_msec <= snap.double_click_ms and
            @abs(press.x - prev.x) <= snap.double_click_px and
            @abs(press.y - prev.y) <= snap.double_click_px)
        {
            input.title_press = null;
            return true;
        }
    }
    input.title_press = press;
    return false;
}

/// A dragged window's nearly opaque titlebar keeps its blur until release.
pub fn heldGlass(input: *const Input) ?*glass.Effect {
    if (input.cursor_mode != .move) return null;
    const toplevel = input.grabbed_toplevel orelse return null;
    if (!chrome.titlebarGlassMayHold(toplevel.titlebar_buffer.opacity)) return null;
    return toplevel.glass_effect;
}

pub fn startResize(
    input: *Input,
    toplevel: *Toplevel,
    wlr_edges: wlr.Edges,
    initiating_device: ?*wlr.InputDevice,
    initiating_button: u32,
) void {
    const edges = resize.Edges.fromWlr(wlr_edges);
    if (edges.isNone()) return;

    if (toplevel.minimized or
        toplevel.isMaximized() or
        toplevel.isFullscreen() or
        !toplevel.isMapped())
    {
        return;
    }

    if (input.resize_session != null) {
        input.cancelResize();
    }

    // Resizing a tile makes it an ordinary window of the tile's geometry.
    const layout_before = toplevel.layout();
    toplevel.leaveLayout();
    input.server.world.focus(toplevel);
    toplevel.finishZoomAnimation();
    toplevel.finishMoveAnimation();
    toplevel.finishSizeAnimation();
    input.setHover(null, null);

    input.cursor_mode = .resize;
    input.grabbed_toplevel = toplevel;
    input.seat.pointerClearFocus();

    input.setNamedCursor(edges.cursorName());

    const geom = toplevel.clientGeometry();
    const client_w = if (geom.width > 0) geom.width else 100;
    const client_h = if (geom.height > 0) geom.height else 100;
    const footer = toplevel.footerHeight();

    // Resize deltas are measured in unscaled client units.
    const cursor_wx = input.server.world.toWorld(input.cursor.x, input.cursor.y).x / toplevel.worldScale();
    const cursor_wy = input.server.world.toWorld(input.cursor.x, input.cursor.y).y / toplevel.worldScale();

    const snapshot = resize.createSnapshot(
        cursor_wx,
        cursor_wy,
        toplevel.x,
        toplevel.y,
        client_w,
        client_h,
        toplevel.titlebarHeight(),
        toplevel.borderWidth(),
        footer,
        edges,
    );

    const gen = input.next_session_generation;
    input.next_session_generation += 1;

    const pacing_output = Output.atLayout(input.server, input.cursor.x, input.cursor.y);

    input.resize_session = .{
        .toplevel = toplevel,
        .generation = gen,
        .initiating_device = initiating_device,
        .initiating_button = initiating_button,
        .edges = edges,
        .snapshot = snapshot,
        .latest_desired_size = .{ .width = client_w, .height = client_h },
        .dirty = false,
        .pacing_output = pacing_output,
    };

    toplevel.setResizing(true);
    const wait = toplevel.requestSize(client_w, client_h);
    if (input.resize_session) |*sess| {
        sess.outstanding_configure = wait;
        sess.last_sent_width = client_w;
        sess.last_sent_height = client_h;
    }
    // Snapshot current geometry for undo at the start of the resize.
    input.server.undo.begin(.{
        .kind = .resize,
        .press_seq = input.server.undo.press_seq,
        .at_ms = 0,
        .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = client_w, .height = client_h, .zoom_index = toplevel.zoom_index, .layout = layout_before },
    });
}

pub fn finishResize(input: *Input) void {
    const session = &(input.resize_session orelse return);
    const toplevel = session.toplevel;

    toplevel.setResizing(false);
    const final_size = session.latest_desired_size;
    session.outstanding_configure = toplevel.requestSize(final_size.width, final_size.height);
    session.last_sent_width = final_size.width;
    session.last_sent_height = final_size.height;

    input.cursor_mode = .passthrough;
    input.grabbed_toplevel = null;
    session.settling = true;

    // Commit the resize undo entry now that the final geometry is known.
    input.server.undo.commit(Server.undoNowMs(), .{
        .window = .{
            .id = toplevel.id,
            .x = toplevel.x,
            .y = toplevel.y,
            .width = final_size.width,
            .height = final_size.height,
            .zoom_index = toplevel.zoom_index,
            .layout = toplevel.layout(),
        },
    });

    // Compositor-owned windows have already applied the final size and
    // position; no client commit will arrive to finish their resize session.
    if (session.outstanding_configure == .none) input.finishSettlement(session.generation);
    input.processCursorMotion(0);
}

pub fn cancelResize(input: *Input) void {
    const session = input.resize_session orelse return;
    const toplevel = session.toplevel;

    input.resize_session = null;
    input.cursor_mode = .passthrough;
    input.grabbed_toplevel = null;
    // Cancelled resize: discard the in-flight undo entry.
    input.server.undo.drop();

    if (toplevel.isMapped()) {
        toplevel.setResizing(false);
        const geom = toplevel.clientGeometry();
        if (geom.width > 0 and geom.height > 0) {
            _ = toplevel.requestSize(geom.width, geom.height);
        }
    }
    input.processCursorMotion(0);
}

pub fn flushResizeConfigure(input: *Input, output: *Output) void {
    const session = &(input.resize_session orelse return);
    if (session.pacing_output != null and session.pacing_output != output) return;
    if (session.settling) return;
    if (!session.dirty) return;
    if (session.outstanding_configure != .none) return;

    const toplevel = session.toplevel;
    const desired = session.latest_desired_size;

    if (desired.width == session.last_sent_width and desired.height == session.last_sent_height) {
        session.dirty = false;
        return;
    }

    session.outstanding_configure = toplevel.requestSize(desired.width, desired.height);
    session.last_sent_width = desired.width;
    session.last_sent_height = desired.height;
    session.dirty = false;
}

pub fn finishSettlement(input: *Input, generation: u64) void {
    if (input.resize_session) |session| {
        if (session.generation == generation) {
            const toplevel = session.toplevel;
            input.resize_session = null;
            // Invalidations during the grab were deferred; sample even if this
            // settling commit reports no further edge damage.
            toplevel.pending_edge_sample = true;
            toplevel.syncChrome(true, false, Toplevel.nowMs()) catch {};
        }
    }
}

pub fn clearGrab(input: *Input) void {
    input.server.world.mini_map.hide();
    if (input.resize_session != null) {
        input.cancelResize();
    } else if (input.cursor_mode == .pan) {
        input.endPan();
    } else {
        if (input.cursor_mode == .move) {
            input.endMove(false);
            input.setDefaultCursor();
        }
        input.cursor_mode = .passthrough;
        input.grabbed_toplevel = null;
    }
}

pub fn startPan(input: *Input, trigger: PanTrigger, device: ?*wlr.InputDevice) void {
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

fn applyPanCursorDelta(input: *Input, dx: f64, dy: f64) void {
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

fn beginMiddlePanAfterThreshold(session: *PanSession, x: f64, y: f64) bool {
    if (session.trigger != .middle_button or session.button_consumed) return true;
    const dx = x - session.last_x;
    const dy = y - session.last_y;
    if (dx * dx + dy * dy < 16) return false;
    session.button_consumed = true;
    return true;
}

pub fn detachOutput(input: *Input, output: *Output) void {
    if (input.move_snap.output == output) {
        input.move_snap.target = null;
        input.move_snap.output = null;
        input.move_snap.preview.hide();
    }
    if (input.resize_session) |*session| {
        if (session.pacing_output == output) session.pacing_output = null;
    }
}

pub fn detachToplevel(input: *Input, toplevel: *Toplevel) void {
    if (input.window_menu.target == toplevel) input.window_menu.close();
    if (input.hovered_toplevel == toplevel) input.hovered_toplevel = null;
    input.drag_dodge.detach(toplevel);
    if (input.grabbed_toplevel == toplevel) input.clearGrab();
    if (input.resize_session) |session| {
        if (session.toplevel == toplevel) input.cancelResize();
    }
}

pub fn detachTaskbar(input: *Input, bar: *Taskbar) void {
    if (input.window_menu.bar == bar) input.window_menu.close();
    if (input.hovered_taskbar == bar) {
        input.hovered_taskbar = null;
        input.server.scheduleFrames();
    }
}

/// Returns true if the key was handled as a compositor keybind.
pub fn handleKeybind(input: *Input, mods: wlr.Keyboard.ModifierMask, key: xkb.Keysym) bool {
    const action = input.server.config.lookupKeybind(mods, key) orelse return false;
    // Disabled inherited bindings must allow the key through to clients, as
    // must restore_shortcuts when no client inhibits them (Keyboard.processKey).
    if (action == .noop or action == .restore_shortcuts) return false;
    input.server.executeAction(action);
    return true;
}

/// Returns true if (mods, key) is bound to `toggle_start_menu`.
pub fn isToggleStartMenu(input: *Input, mods: wlr.Keyboard.ModifierMask, key: xkb.Keysym) bool {
    const action = input.server.config.lookupKeybind(mods, key) orelse return false;
    return action == .toggle_start_menu;
}

fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const input: *Input = @fieldParentPtr("new_input", listener);
    input.addDevice(device);
}

/// Marks virtual-pointer-v1 devices in `wlr.InputDevice.data`.
var virtual_pointer_tag: u8 = 0;

/// wayvnc, KDE Connect and similar remote-input clients. Their pointer shares
/// the cursor with hardware, and like virtual keyboards never reaches the lock
/// screen or an authentication dialog (`blockedVirtual`).
fn newVirtualPointer(listener: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer), event: *wlr.VirtualPointerManagerV1.event.NewPointer) void {
    const input: *Input = @fieldParentPtr("new_virtual_pointer", listener);
    const device = &event.new_pointer.pointer.base;
    device.data = &virtual_pointer_tag;
    input.addDevice(device);
    if (event.suggested_output) |output| input.cursor.mapInputToOutput(device, output);
}

/// Lock surfaces of an ext-session-lock client follow the pointer; the
/// polkit dialog is not shown over a lock, but it keeps priority if it is.
fn lockClientMotion(input: *Input, time_msec: u32) void {
    if (input.server.polkit_dialog != null) return;
    const lock = input.server.locker orelse return;
    lock.pointerMoved(input.cursor.x, input.cursor.y);
    const client = lock.client orelse return;
    _ = client.pointerMotion(time_msec);
}

fn blockedVirtual(input: *const Input, device: *wlr.InputDevice) bool {
    return device.data == @as(?*anyopaque, &virtual_pointer_tag) and
        (input.server.locker != null or input.server.polkit_dialog != null);
}

fn addDevice(input: *Input, device: *wlr.InputDevice) void {
    switch (device.type) {
        .keyboard => Keyboard.create(input.server, device) catch |err| {
            log.err("newInput: could not create keyboard: {}", .{err});
            return;
        },
        .pointer => {
            input.cursor.attachInputDevice(device);
            Pointer.create(input, device) catch |err| {
                log.err("newInput: could not track pointer device: {}", .{err});
            };
        },
        .touch => input.touch.addDevice(device),
        .tablet => input.tablet.addTablet(device),
        .tablet_pad => input.tablet.addPad(device),
        .@"switch" => input.lid.addDevice(device),
    }
    input.updateCapabilities();
}

fn requestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const input: *Input = @fieldParentPtr("request_set_cursor", listener);
    if (input.clientMaySetCursor(event.seat_client)) {
        input.default_cursor_applied = false;
        input.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
        input.cursor_source = if (event.surface != null) .surface else .hidden;
        input.cursor_name = null;
    }
}

fn clientMaySetCursor(input: *Input, client: *wlr.Seat.Client) bool {
    return (input.server.locker == null and input.server.polkit_dialog == null) and input.server.screenshot_selector.output == null and input.cursor_mode == .passthrough and
        input.hovered_resize_edges == null and
        client == input.seat.pointer_state.focused_client;
}

fn requestSetShape(
    listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape),
    event: *wlr.CursorShapeManagerV1.event.RequestSetShape,
) void {
    const input: *Input = @fieldParentPtr("request_set_shape", listener);
    if (event.device_type != .pointer or !input.clientMaySetCursor(event.seat_client)) return;
    if (input.cursor_serial.enter_serial == null or event.serial != input.cursor_serial.enter_serial.?) return;

    const name = wlr.CursorShapeManagerV1.shapeName(event.shape);
    if (event.shape == .default or input.cursor_mgr.getXcursor(name, 1) == null) {
        input.setDefaultCursor();
    } else {
        input.setNamedCursor(name);
    }
}

fn requestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const input: *Input = @fieldParentPtr("request_set_selection", listener);
    if (input.server.locker != null or input.server.polkit_dialog != null) return;
    input.seat.setSelection(event.source, event.serial);
}

fn requestSetPrimarySelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection),
    event: *wlr.Seat.event.RequestSetPrimarySelection,
) void {
    const input: *Input = @fieldParentPtr("request_set_primary_selection", listener);
    if (input.server.locker != null or input.server.polkit_dialog != null) return;
    input.seat.setPrimarySelection(event.source, event.serial);
}

fn cursorMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const input: *Input = @fieldParentPtr("cursor_motion", listener);
    if (input.blockedVirtual(event.device)) return;
    @import("startup.zig").markFirstInput();
    if (input.server.idle) |im| im.notifyActivity(.pointer);

    var dx = event.delta_x;
    var dy = event.delta_y;
    const mult = input.accelMultiplier(dx, dy);
    dx *= mult;
    dy *= mult;

    if (input.server.locker != null or input.server.polkit_dialog != null) {
        input.cursor.move(event.device, dx, dy);
        input.lockClientMotion(event.time_msec);
        return;
    }

    if (input.cursor_mode == .passthrough and input.resize_session == null and input.grabbed_toplevel == null) {
        if (input.server.screenshot_selector.output == null and input.isPanModifierHeld() and input.active_buttons == 0 and !input.server.world.mini_map.dragging and !input.cursorOverTaskbar()) {
            const inhibited = if (input.pan_session) |sess| sess.inhibited and sess.trigger == .super_key else false;
            if (!inhibited) {
                input.startPan(.super_key, event.device);
            }
        }
    }

    if (input.cursor_mode == .pan) {
        if (input.pan_session) |*sess| if (!sess.inhibited) {
            const prev_x = input.cursor.x;
            const prev_y = input.cursor.y;
            input.cursor.move(event.device, dx, dy);
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
    input.cursor.move(event.device, allowed.dx, allowed.dy);
    input.processCursorMotion(event.time_msec);
    input.pointer_constraints.sync();
}

fn cursorMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const input: *Input = @fieldParentPtr("cursor_motion_absolute", listener);
    if (input.blockedVirtual(event.device)) return;
    if (input.server.idle) |im| im.notifyActivity(.pointer);
    var x: f64 = undefined;
    var y: f64 = undefined;
    input.cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &x, &y);
    input.layoutMotion(event.device, x, y, event.time_msec);
}

/// Absolute pointer motion to a layout point: pointer devices, and touch and
/// tablet input emulating a pointer. The caller sends the pointer frame.
pub fn layoutMotion(input: *Input, device: ?*wlr.InputDevice, x: f64, y: f64, time_msec: u32) void {
    @import("startup.zig").markFirstInput();
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

pub fn processCursorMotion(input: *Input, time_msec: u32) void {
    if (input.server.locker != null or input.server.polkit_dialog != null or input.server.switcher.active()) return;
    input.positionDragIcon();
    input.drag_dodge.motion();
    if (input.server.screenshot_selector.output != null) {
        input.server.screenshot_selector.motion(input.cursor.x, input.cursor.y);
        return;
    }
    if (input.window_menu.target != null) {
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
    switch (input.cursor_mode) {
        .passthrough => input.passthroughMotion(time_msec),
        .move => input.processMove(),
        .resize => input.processResize(),
        .pan => {}, // handled in cursorMotion / cursorMotionAbsolute
    }
}

fn passthroughMotion(input: *Input, time_msec: u32) void {
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
                    const owner: *@import("LayerSurface.zig") = @ptrCast(@alignCast(data));
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
    if (hit != .toast) {
        input.clearToastHover();
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
            const radius: f32 = toplevel.cornerRadius();
            const footer = chrome.footerHeight(radius);

            if (resize.detectResizeEdges(local.x, local.y, toplevel.chrome_width, toplevel.chrome_height, toplevel.titlebarHeight(), chrome.frame_border, footer, has_control)) |edges| {
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
            input.setShellCursor(ui_input.current.overText());
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
            // Clearing client focus also leaves a DnD drag unfocused, which
            // is what lets the desktop receive its drop.
            input.seat.pointerClearFocus();
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

fn processMove(input: *Input) void {
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
    const pos = geometry.Vec2.toI32(.{
        .x = wx - input.grab_x,
        .y = wy - input.grab_y,
    });
    toplevel.setPosition(pos.x, pos.y);
}

fn processResize(input: *Input) void {
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

fn cursorButton(
    listener: *wl.Listener(*wlr.Pointer.event.Button),
    event: *wlr.Pointer.event.Button,
) void {
    const input: *Input = @fieldParentPtr("cursor_button", listener);
    if (input.blockedVirtual(event.device)) return;
    input.processButton(event.device, event.button, event.state, event.time_msec);
}

pub fn processButton(
    input: *Input,
    device: ?*wlr.InputDevice,
    button: u32,
    state: wl.Pointer.ButtonState,
    time_msec: u32,
) void {
    @import("startup.zig").markFirstInput();
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
    if (input.window_menu.target != null) {
        if (state == .pressed) {
            input.tray_buttons |= screenshot_bit;
            input.window_menu.press(input.cursor.x, input.cursor.y, button);
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
        if (state == .released) input.server.switcher.cancel();
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
    if (button == btn_middle and input.server.config.input.middle_button_pan) {
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

fn processClientButton(
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
        if (input.open_start_menu) |sm| {
            const local = scene_data.toNodeLocal(&sm.buffer_node.node, input.cursor.x, input.cursor.y);
            sm.pointerButtonUp(local.x, local.y);
        }
        if (input.open_power_menu) |pm| {
            const local = scene_data.toNodeLocal(&pm.buffer_node.node, input.cursor.x, input.cursor.y);
            pm.pointerButtonUp(local.x, local.y);
        }
        if (input.desktop_grab) {
            if (input.server.desktop) |desktop| desktop.pointerButton(button, false);
            if (input.active_buttons == 0) input.desktop_grab = false;
        }
        if (input.seat.drag != null) if (input.server.desktop) |desktop| {
            if (scene_data.hitTest(input.server, input.cursor.x, input.cursor.y) == .desktop) _ = desktop.drop(button);
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
        .taskbar => |res| {
            res.bar.pointerPress(res.sx, res.sy);
            return;
        },
        .chrome => |res| {
            input.server.world.focus(res.toplevel);
            if (button == btn_left) {
                const local = res.toplevel.frameLocal(input.cursor.x, input.cursor.y);
                const has_control = res.toplevel.controlAt(res.sx, res.sy) != null or res.toplevel.tabAt(res.sx, res.sy) != .none;
                const radius: f32 = res.toplevel.cornerRadius();
                const footer = chrome.footerHeight(radius);
                if (resize.detectResizeEdges(local.x, local.y, res.toplevel.chrome_width, res.toplevel.chrome_height, res.toplevel.titlebarHeight(), chrome.frame_border, footer, has_control)) |edges| {
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
            const alt = if (input.seat.getKeyboard()) |keyboard| keyboard.getModifiers().alt else false;
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
        const seat = input.seat;
        const surface = hit.xwayland_unmanaged.surface;
        if (seat.getKeyboard()) |keyboard| {
            seat.keyboardNotifyEnter(surface, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
        }
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
    if (hit == .surface) input.server.world.focusSurface(hit.surface.toplevel, hit.surface.surface);
    _ = input.seat.pointerNotifyButton(time_msec, button, state);
    switch (hit) {
        .surface => |res| {
            const ws = res.toplevel.worldScale() / res.toplevel.surfaceScale();
            input.rememberPointerGrab(res.sx, res.sy, ws);
            if (input.seat.getKeyboard()) |keyboard| {
                if (keyboard.getModifiers().alt) {
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

fn setHover(input: *Input, toplevel: ?*Toplevel, control: ?chrome.ControlKind) void {
    if (input.hovered_toplevel) |previous| {
        if (previous != toplevel) previous.applyHover(false, null);
    }
    input.hovered_toplevel = toplevel;
    if (toplevel) |hovered| hovered.applyHover(true, control);
}

fn clearTaskbarHover(input: *Input) void {
    if (input.hovered_taskbar) |previous| {
        previous.pointerLeave();
        input.hovered_taskbar = null;
    }
}

pub fn clearToastHover(input: *Input) void {
    if (input.hovered_toast) |previous| {
        previous.setHovered(false, @import("Taskbar.zig").nowMs());
        input.hovered_toast = null;
    }
}

fn setToastHover(input: *Input, toast: *@import("notifications/toast.zig").Toast) void {
    if (input.hovered_toast == toast) return;
    input.clearToastHover();
    input.hovered_toast = toast;
    toast.setHovered(true, @import("Taskbar.zig").nowMs());
}

fn cursorAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const input: *Input = @fieldParentPtr("cursor_axis", listener);
    if (input.blockedVirtual(event.device)) return;
    if (input.zoom_device != event.device) input.zoom_scroll.reset();
    input.zoom_device = event.device;
    input.processAxis(event.time_msec, event.orientation, event.delta, event.delta_discrete, event.source);
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
    if (input.window_menu.target != null) return;
    const invert = input.server.config.input.invert_scroll;
    const delta: f64 = if (invert) -raw_delta else raw_delta;
    const delta_discrete: i32 = if (invert) -raw_delta_discrete else raw_delta_discrete;
    if (input.server.tray) |tray| {
        if (tray.menu_item != 0) {
            tray.menuScroll(delta);
            return;
        }
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
    const target: ?*Toplevel = if (desktop_zoom) null else switch (scroll_hit) {
        .surface => |res| if (input.isAltHeld()) res.toplevel else null,
        .chrome => |res| if (input.isAltHeld() or (res.sy >= 0 and res.sy < res.toplevel.titlebarHeight())) res.toplevel else null,
        else => null,
    };
    const target_id = if (target) |window| window.id else 0;
    if (input.zoom_target_id != target_id) input.zoom_scroll.reset();
    input.zoom_target_id = target_id;
    if (target != null or input.isAltHeld()) {
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
            const max_index: i32 = @intCast(@import("camera.zig").zoom_levels.len - 1);
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
    const desktop_finger = source == .finger and (scroll_hit == .none or input.finger_pan);
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
        .taskbar => |hit| {
            if (orientation == .vertical_scroll) {
                hit.bar.scrollVolume(hit.sx, hit.sy, ui_scroll.axisDeltaPx(delta, delta_discrete));
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

fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const input: *Input = @fieldParentPtr("cursor_frame", listener);
    input.seat.pointerNotifyFrame();
}

fn cursorSwipeBegin(listener: *wl.Listener(*wlr.Pointer.event.SwipeBegin), event: *wlr.Pointer.event.SwipeBegin) void {
    const input: *Input = @fieldParentPtr("cursor_swipe_begin", listener);
    input.handleSwipeBegin(event.time_msec, event.fingers);
}

fn cursorSwipeUpdate(listener: *wl.Listener(*wlr.Pointer.event.SwipeUpdate), event: *wlr.Pointer.event.SwipeUpdate) void {
    const input: *Input = @fieldParentPtr("cursor_swipe_update", listener);
    input.handleSwipeUpdate(event.time_msec, event.dx, event.dy);
}

fn cursorSwipeEnd(listener: *wl.Listener(*wlr.Pointer.event.SwipeEnd), event: *wlr.Pointer.event.SwipeEnd) void {
    const input: *Input = @fieldParentPtr("cursor_swipe_end", listener);
    input.handleSwipeEnd(event.time_msec, event.cancelled);
}

fn cursorPinchBegin(listener: *wl.Listener(*wlr.Pointer.event.PinchBegin), event: *wlr.Pointer.event.PinchBegin) void {
    const input: *Input = @fieldParentPtr("cursor_pinch_begin", listener);
    input.handlePinchBegin(event.time_msec, event.fingers);
}

fn cursorPinchUpdate(listener: *wl.Listener(*wlr.Pointer.event.PinchUpdate), event: *wlr.Pointer.event.PinchUpdate) void {
    const input: *Input = @fieldParentPtr("cursor_pinch_update", listener);
    input.handlePinchUpdate(event.time_msec, event.dx, event.dy, event.scale, event.rotation);
}

fn cursorPinchEnd(listener: *wl.Listener(*wlr.Pointer.event.PinchEnd), event: *wlr.Pointer.event.PinchEnd) void {
    const input: *Input = @fieldParentPtr("cursor_pinch_end", listener);
    input.handlePinchEnd(event.time_msec, event.cancelled);
}

fn cursorHoldBegin(listener: *wl.Listener(*wlr.Pointer.event.HoldBegin), event: *wlr.Pointer.event.HoldBegin) void {
    const input: *Input = @fieldParentPtr("cursor_hold_begin", listener);
    input.pointer_gestures.sendHoldBegin(input.seat, event.time_msec, event.fingers);
}

fn cursorHoldEnd(listener: *wl.Listener(*wlr.Pointer.event.HoldEnd), event: *wlr.Pointer.event.HoldEnd) void {
    const input: *Input = @fieldParentPtr("cursor_hold_end", listener);
    input.pointer_gestures.sendHoldEnd(input.seat, event.time_msec, event.cancelled);
}

/// Camera changes cannot invalidate an in-flight client or compositor grab.
pub fn canZoom(input: *Input) bool {
    if (input.server.world.mini_map.dragging) return false;
    if (input.active_buttons != 0 or input.resize_session != null or input.seat.pointerHasGrab()) return false;
    if (input.server.world.pinching) return false;
    return input.cursor_mode == .passthrough or
        (input.cursor_mode == .pan and input.pan_session != null and input.pan_session.?.trigger == .super_key);
}

fn clientSurfaceHit(hit: scene_data.Hit) bool {
    return switch (hit) {
        .surface, .layer, .xwayland_unmanaged, .input_popup => true,
        else => false,
    };
}

fn compositorOwnsPinch(input: *Input) bool {
    if (input.server.locker != null or input.server.polkit_dialog != null or input.server.switcher.active()) return false;
    if (input.cursor_mode == .move or input.cursor_mode == .resize or input.resize_session != null) return false;
    return !clientSurfaceHit(scene_data.hitTest(input.server, input.cursor.x, input.cursor.y));
}

fn compositorOwnsSwipe(input: *Input, fingers: u32) bool {
    if (fingers != 2) return false;
    if (input.server.locker != null or input.server.polkit_dialog != null or input.server.switcher.active()) return false;
    if (input.cursor_mode != .passthrough or input.resize_session != null) return false;
    return scene_data.hitTest(input.server, input.cursor.x, input.cursor.y) == .none;
}

pub fn handlePinchBegin(input: *Input, time_msec: u32, fingers: u32) void {
    if (input.server.polkit_dialog != null) return;
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
    if (input.server.polkit_dialog != null) return;
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
    if (input.server.polkit_dialog != null) return;
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
    if (input.server.polkit_dialog != null) return;
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

fn positionDragIcon(input: *Input) void {
    if (input.drag_icon_tree) |tree| {
        tree.node.setPosition(@intFromFloat(@floor(input.cursor.x)), @intFromFloat(@floor(input.cursor.y)));
    }
}

fn startDrag(listener: *wl.Listener(*wlr.Drag), drag: *wlr.Drag) void {
    const input: *Input = @fieldParentPtr("start_drag", listener);
    input.drag_dodge.begin(drag);
    if (drag.grab_type != .keyboard_pointer) return;
    const icon = drag.icon orelse return;
    if (input.drag_icon_tree) |tree| tree.node.destroy();
    // wlroots gives drag icons an empty input region, so they cannot steal
    // the drop target. This tree stays in output coordinates, outside the camera.
    const tree = input.server.overlay_tree.createSceneDragIcon(icon) catch return;
    input.drag_icon_tree = tree;
    tree.node.events.destroy.add(&input.drag_icon_destroy);
    input.positionDragIcon();
}

/// Escape during a drag abandons it. Destroying the source tells its client the
/// drag was cancelled, and ending the grab then leaves the target, hides the
/// icon and forgets the drag. The button is still held; its release reaches
/// the client under the pointer like any other, so nothing is dropped.
pub fn cancelDrag(input: *Input) bool {
    const drag = input.seat.drag orelse return false;
    if (drag.grab_type != .keyboard_pointer) return false;
    if (drag.source) |source| source.destroy();
    input.seat.pointerEndGrab();
    return true;
}

fn dragIconDestroyed(listener: *wl.Listener(void)) void {
    const input: *Input = @fieldParentPtr("drag_icon_destroy", listener);
    input.drag_icon_destroy.link.remove();
    input.drag_icon_tree = null;
}

fn requestStartDrag(listener: *wl.Listener(*wlr.Seat.event.RequestStartDrag), event: *wlr.Seat.event.RequestStartDrag) void {
    const input: *Input = @fieldParentPtr("request_start_drag", listener);
    if (input.server.locker != null or input.server.polkit_dialog != null) {
        if (event.drag.source) |source| source.destroy();
        return;
    }
    if (input.seat.validatePointerGrabSerial(event.origin, event.serial)) {
        input.seat.startPointerDrag(event.drag, event.serial);
    } else if (event.drag.source) |source| source.destroy();
}

test "accel curve computes valid monotonic LUT and clamps speeds" {
    const curve = AccelCurve.init(.{ 0.0, 0.0 }, .{ 0.15, 1.0 }, 10.0);
    try std.testing.expectEqual(@as(f32, 0.0), curve.lut[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), curve.lut[255], 0.001);

    // Monotonically non-decreasing
    for (0..AccelCurve.lut_size - 1) |i| {
        try std.testing.expect(curve.lut[i] <= curve.lut[i + 1]);
    }

    // Boundary lookups
    try std.testing.expectEqual(@as(f32, 0.0), curve.lookup(0.0));
    try std.testing.expectEqual(@as(f32, 0.0), curve.lookup(-1.0));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), curve.lookup(1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), curve.lookup(2.5), 0.001);
}

test "accel curve linear control points yield identity mapping" {
    // A cubic bezier with control points (1/3, 1/3) and (2/3, 2/3) is the line y = x.
    const curve = AccelCurve.init(.{ 1.0 / 3.0, 1.0 / 3.0 }, .{ 2.0 / 3.0, 2.0 / 3.0 }, 10.0);
    for (0..AccelCurve.lut_size) |i| {
        const expected = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(AccelCurve.lut_size - 1));
        try std.testing.expectApproxEqAbs(expected, curve.lut[i], 0.01);
    }
}

test "accelMultiplier handles flat and bezier profiles" {
    var dummy_input: Input = undefined;
    dummy_input.accel_profile = .flat;
    dummy_input.accel_curve = AccelCurve.init(.{ 0.0, 0.0 }, .{ 0.15, 1.0 }, 10.0);

    // Flat profile always returns 1.0
    try std.testing.expectEqual(@as(f64, 1.0), dummy_input.accelMultiplier(0.0, 0.0));
    try std.testing.expectEqual(@as(f64, 1.0), dummy_input.accelMultiplier(1.0, 2.0));
    try std.testing.expectEqual(@as(f64, 1.0), dummy_input.accelMultiplier(10.0, 0.0));

    // Bezier profile scales according to speed
    dummy_input.accel_profile = .bezier;
    try std.testing.expectEqual(@as(f64, 0.0), dummy_input.accelMultiplier(0.0, 0.0));

    const low_mult = dummy_input.accelMultiplier(1.0, 0.0);
    const mid_mult = dummy_input.accelMultiplier(3.0, 4.0); // magnitude = 5.0 -> norm_speed = 0.5
    const max_mult = dummy_input.accelMultiplier(10.0, 0.0); // magnitude = 10.0 -> norm_speed = 1.0
    const over_mult = dummy_input.accelMultiplier(20.0, 0.0);

    try std.testing.expect(low_mult > 0.0 and low_mult < mid_mult);
    try std.testing.expect(mid_mult < max_mult);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), max_mult, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), over_mult, 0.001);
}
