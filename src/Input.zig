// Seat, cursor, and pointer/keyboard policy.
const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const sn = @import("node.zig");
const xkb = @import("xkbcommon");

const control_center = @import("control_center/panel.zig");
const ControlCenter = control_center.ControlCenter;
const StartMenu = @import("start_menu/panel.zig").StartMenu;
const PowerMenu = @import("power_menu.zig").PowerMenu;
const Keyboard = @import("Keyboard.zig");
const Output = @import("Output.zig");
const Pointer = @import("Pointer.zig");
const Server = @import("Server.zig");
const Taskbar = @import("Taskbar.zig");
const Toplevel = @import("Toplevel.zig");
const geometry = @import("geometry.zig");
const resize = @import("resize.zig");
const snap = @import("snap.zig");
const CursorSerial = @import("input/cursor_serial.zig");
const ClientWheel = @import("input/client_wheel.zig");
const WheelDebounce = @import("input/wheel_debounce.zig");
const PointerConstraints = @import("input/pointer_constraints.zig");
const ShortcutsInhibit = @import("input/shortcuts_inhibit.zig");
const Touch = @import("input/touch.zig");
const Tablet = @import("input/tablet.zig");
const Lid = @import("input/lid.zig");
const DragDodge = @import("input/drag_dodge.zig");
const cursor_theme = @import("cursor_theme.zig");
const gpa = @import("main.zig").gpa;
const input_targets = @import("input/targets.zig");
const input_cursor = @import("input/cursor.zig");
const input_grabs = @import("input/grabs.zig");
const input_pan = @import("input/pan.zig");
const input_devices = @import("input/devices.zig");
const input_motion = @import("input/motion.zig");
const input_buttons = @import("input/buttons.zig");
const input_hover = @import("input/hover.zig");
const input_axis = @import("input/axis.zig");
const input_gestures = @import("input/gestures.zig");
const input_drag = @import("input/drag.zig");

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

/// The other half of a manually tiled pair being resized together.
pub const ResizePeerSession = struct {
    toplevel: *Toplevel,
    snapshot: resize.ResizeSnapshot,
    latest_desired_size: resize.ClientSize,
    dirty: bool = false,
    outstanding_configure: Toplevel.ConfigureWait = .none,
    last_sent_width: i32 = 0,
    last_sent_height: i32 = 0,
};

pub const ResizeSession = struct {
    toplevel: *Toplevel,
    generation: u64,
    initiating_device: ?*wlr.InputDevice,
    initiating_button: u32,
    edges: resize.Edges,
    snapshot: resize.ResizeSnapshot,
    latest_desired_size: resize.ClientSize,
    peer: ?ResizePeerSession = null,
    dirty: bool = false,
    pacing_output: ?*Output = null,
    outstanding_configure: Toplevel.ConfigureWait = .none,
    last_sent_width: i32 = 0,
    last_sent_height: i32 = 0,
    settling: bool = false,

    /// Whether a toplevel participates in this resize gesture.
    pub fn includes(self: *const ResizeSession, toplevel: *const Toplevel) bool {
        if (self.toplevel == toplevel) return true;
        const peer = self.peer orelse return false;
        return peer.toplevel == toplevel;
    }

    /// Whether either participant is still waiting for its client configure.
    pub fn hasOutstandingConfigure(self: *const ResizeSession) bool {
        if (self.outstanding_configure != .none) return true;
        const peer = self.peer orelse return false;
        return peer.outstanding_configure != .none;
    }
};

/// A left-button press on a taskbar chip, retained while deciding whether
/// the gesture is a click or a drag.
pub const TaskbarDragSession = struct {
    bar: *Taskbar,
    window_id: u64,
    origin_index: usize,
    press_x: f64,
    press_y: f64,
    dragging: bool = false,
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
/// No image until native input is enumerated (`holdCursor`): an arrow that
/// cannot move yet is not shown. The image state above is still tracked.
cursor_held: bool = false,
cursor_serial: CursorSerial = .{},
keyboards: wl.list.Head(Keyboard, .link) = undefined,
pointers: wl.list.Head(Pointer, .link) = undefined,
/// Monotonic live tokens keep Settings selection safe across allocator reuse.
next_pointer_id: u64 = 1,
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
drag_icon_tree: ?*sn.Tree = null,
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
/// Drops stray clicks from bouncing wheel encoders, per axis, before anything
/// sees them.
wheel_debounce: [2]WheelDebounce = .{ .{}, .{} },
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
/// The window whose edge highlight follows the pointer (`updateBorderGlow`).
glow_toplevel: ?*Toplevel = null,
hovered_taskbar: ?*Taskbar = null,
taskbar_drag: ?TaskbarDragSession = null,
tray_buttons: u32 = 0,
hovered_toast: ?*@import("notifications/toast.zig").Toast = null,
grabbed_toplevel: ?*Toplevel = null,
grab_x: f64 = 0,
grab_y: f64 = 0,
grab_box: wlr.Box = undefined,
move_snap: MoveSnap = .{},
tiling_grab: ?@import("tiling_grab.zig") = null,
/// An application being dragged from the start menu to the dock.
dock_drag: @import("dock_drag.zig") = .{},
/// Files from a client's drag, dropped on the dock's Trash.
trash_drop: @import("trash_drop.zig") = .{},
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
taskbar_focus_scroll: @import("camera.zig").ZoomScroll = .{},
zoom_device: ?*wlr.InputDevice = null,
zoom_target_id: u64 = 0,
active_buttons: u32 = 0,
/// A press landed on the compositor-drawn desktop; like a client's implicit
/// grab, motion stays desktop-local until every button is released.
desktop_grab: bool = false,
/// Releases belong to the map even if a modal transition cancels its grab.
mini_map_buttons: u32 = 0,
/// A click can accept/cancel the switcher mid-press; its matching release
/// must still be swallowed rather than reaching whatever is now focused.
switcher_buttons: u32 = 0,
overview_buttons: u32 = 0,
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

// input/targets.zig
pub const isAltHeld = input_targets.isAltHeld;
pub const isSuperHeld = input_targets.isSuperHeld;
pub const isPanModifierHeld = input_targets.isPanModifierHeld;
pub const isDesktopZoomHeld = input_targets.isDesktopZoomHeld;
pub const cursorOverTaskbar = input_targets.cursorOverTaskbar;
pub const updateAccel = input_targets.updateAccel;
pub const accelMultiplier = input_targets.accelMultiplier;
pub const rememberPointerGrab = input_targets.rememberPointerGrab;
pub const focusedSurfaceToLayout = input_targets.focusedSurfaceToLayout;
pub const motionReachesClient = input_targets.motionReachesClient;
pub const directInputReachesClients = input_targets.directInputReachesClients;
pub const clientTarget = input_targets.clientTarget;
pub const focusForPress = input_targets.focusForPress;

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
    // Parses the whole theme. The greeter loads it per output scale instead
    // (refreshOutputScales), and its only cursor is the default one.
    if (!server.greeter_mode) input.cursor_mgr.load(1) catch return error.XcursorCreateFailed;
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

// input/cursor.zig
pub const createCursorManager = input_cursor.createCursorManager;
pub const rememberCursorTheme = input_cursor.rememberCursorTheme;
pub const cursorThemeName = input_cursor.cursorThemeName;
pub const applyCursorTheme = input_cursor.applyCursorTheme;
pub const reloadCursorTheme = input_cursor.reloadCursorTheme;
pub const applyCursorThemeImpl = input_cursor.applyCursorThemeImpl;
pub const refreshOutputScales = input_cursor.refreshOutputScales;
pub const setDefaultCursor = input_cursor.setDefaultCursor;
pub const showXcursor = input_cursor.showXcursor;
pub const holdCursor = input_cursor.holdCursor;
pub const releaseCursor = input_cursor.releaseCursor;
pub const refreshBusyCursor = input_cursor.refreshBusyCursor;
pub const setShellCursor = input_cursor.setShellCursor;
pub const setNamedCursor = input_cursor.setNamedCursor;

pub fn deinit(input: *Input) void {
    if (input.tiling_grab) |*grab| {
        if (grab.snapshot) |*tree| tree.deinit(gpa);
        if (grab.undo_snapshot) |snapshot| snapshot.destroy();
    }
    input.tiling_grab = null;
    input.window_menu.close();
    input.start_drag.link.remove();
    if (input.drag_icon_tree) |tree| tree.node.destroy();
    input.pointer_constraints.deinit();
    input.shortcuts_inhibit.deinit();
    input.drag_dodge.deinit();
    input.trash_drop.deinit();
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
pub const MoveSnap = struct {
    target: ?snap.Target = null,
    output: ?*Output = null,
    preview: snap.Preview = .{},
    /// A maximized or tiled window stays put until the pointer travels
    /// `snap.unsnap_px` from here, then floats under it (floatGrabbed).
    unsnap_from: ?geometry.Vec2 = null,
    /// Floating geometry before the drag, restored when leaving the snap.
    origin: ?Toplevel.RestoreGeometry = null,
};

pub const TitlePress = struct {
    press: u64,
    toplevel_id: u64,
    time_msec: u32,
    x: f64,
    y: f64,
};

// input/grabs.zig
pub const startMove = input_grabs.startMove;
pub const endMove = input_grabs.endMove;
pub const floatGrabbed = input_grabs.floatGrabbed;
pub const updateSnapTarget = input_grabs.updateSnapTarget;
pub const snapTargetAt = input_grabs.snapTargetAt;
pub const titleDoubleClick = input_grabs.titleDoubleClick;
pub const heldGlass = input_grabs.heldGlass;
pub const startResize = input_grabs.startResize;
pub const finishResize = input_grabs.finishResize;
pub const cancelResize = input_grabs.cancelResize;
pub const flushResizeConfigure = input_grabs.flushResizeConfigure;
pub const finishSettlement = input_grabs.finishSettlement;
pub const clearGrab = input_grabs.clearGrab;

// input/pan.zig
pub const startPan = input_pan.startPan;
pub const endPan = input_pan.endPan;
pub const applyPanCursorDelta = input_pan.applyPanCursorDelta;
pub const rebasePan = input_pan.rebasePan;
pub const beginMiddlePanAfterThreshold = input_pan.beginMiddlePanAfterThreshold;

pub fn detachOutput(input: *Input, output: *Output) void {
    if (input.window_menu.output == output) input.window_menu.close();
    if (input.tiling_grab != null) input.finishTilingGrab(false);
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
    if (input.window_menu.references(toplevel)) input.window_menu.close();
    if (input.taskbar_drag) |session| {
        if (session.window_id == toplevel.id) {
            input.taskbar_drag = null;
            input.setDefaultCursor();
        }
    }
    if (input.hovered_toplevel == toplevel) input.hovered_toplevel = null;
    if (input.glow_toplevel == toplevel) input.glow_toplevel = null;
    input.drag_dodge.detach(toplevel);
    if (input.grabbed_toplevel == toplevel) input.clearGrab();
    if (input.resize_session) |session| {
        if (session.includes(toplevel)) input.cancelResize();
    }
}

pub fn detachTaskbar(input: *Input, bar: *Taskbar) void {
    if (input.window_menu.bar == bar) input.window_menu.close();
    if (input.taskbar_drag) |session| {
        if (session.bar == bar) {
            input.taskbar_drag = null;
            input.setDefaultCursor();
        }
    }
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

// input/devices.zig
pub const newInput = input_devices.newInput;
pub const newVirtualPointer = input_devices.newVirtualPointer;
pub const lockClientMotion = input_devices.lockClientMotion;
pub const blockedVirtual = input_devices.blockedVirtual;
pub const addDevice = input_devices.addDevice;
pub const requestSetCursor = input_devices.requestSetCursor;
pub const clientMaySetCursor = input_devices.clientMaySetCursor;
pub const requestSetShape = input_devices.requestSetShape;
pub const requestSetSelection = input_devices.requestSetSelection;
pub const requestSetPrimarySelection = input_devices.requestSetPrimarySelection;

// input/motion.zig
pub const cursorMotion = input_motion.cursorMotion;
pub const cursorMotionAbsolute = input_motion.cursorMotionAbsolute;
pub const layoutMotion = input_motion.layoutMotion;
pub const warpCursor = input_motion.warpCursor;
pub const updateDockReveal = input_motion.updateDockReveal;
pub const processCursorMotion = input_motion.processCursorMotion;
pub const passthroughMotion = input_motion.passthroughMotion;
pub const processMove = input_motion.processMove;
pub const processResize = input_motion.processResize;

// input/buttons.zig
pub const cursorButton = input_buttons.cursorButton;
pub const processButton = input_buttons.processButton;
pub const processClientButton = input_buttons.processClientButton;

// input/hover.zig
pub const updateBorderGlow = input_hover.updateBorderGlow;
pub const updateGrabBorderGlow = input_hover.updateGrabBorderGlow;
pub const setBorderGlowTarget = input_hover.setBorderGlowTarget;
pub const setHover = input_hover.setHover;
pub const clearTaskbarHover = input_hover.clearTaskbarHover;
pub const clearToastHover = input_hover.clearToastHover;
pub const setToastHover = input_hover.setToastHover;

// input/axis.zig
pub const cursorAxis = input_axis.cursorAxis;
pub const processAxis = input_axis.processAxis;

// input/gestures.zig
pub const cursorFrame = input_gestures.cursorFrame;
pub const cursorSwipeBegin = input_gestures.cursorSwipeBegin;
pub const cursorSwipeUpdate = input_gestures.cursorSwipeUpdate;
pub const cursorSwipeEnd = input_gestures.cursorSwipeEnd;
pub const cursorPinchBegin = input_gestures.cursorPinchBegin;
pub const cursorPinchUpdate = input_gestures.cursorPinchUpdate;
pub const cursorPinchEnd = input_gestures.cursorPinchEnd;
pub const cursorHoldBegin = input_gestures.cursorHoldBegin;
pub const cursorHoldEnd = input_gestures.cursorHoldEnd;
pub const canZoom = input_gestures.canZoom;
pub const clientSurfaceHit = input_gestures.clientSurfaceHit;
pub const compositorOwnsPinch = input_gestures.compositorOwnsPinch;
pub const compositorOwnsSwipe = input_gestures.compositorOwnsSwipe;
pub const handlePinchBegin = input_gestures.handlePinchBegin;
pub const handlePinchUpdate = input_gestures.handlePinchUpdate;
pub const handlePinchEnd = input_gestures.handlePinchEnd;
pub const handleSwipeBegin = input_gestures.handleSwipeBegin;
pub const handleSwipeUpdate = input_gestures.handleSwipeUpdate;
pub const handleSwipeEnd = input_gestures.handleSwipeEnd;

// input/drag.zig
pub const positionDragIcon = input_drag.positionDragIcon;
pub const startDrag = input_drag.startDrag;
pub const finishTilingGrab = input_drag.finishTilingGrab;
pub const cancelDrag = input_drag.cancelDrag;
pub const dragIconDestroyed = input_drag.dragIconDestroyed;
pub const requestStartDrag = input_drag.requestStartDrag;

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
