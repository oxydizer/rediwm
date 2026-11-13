// Authoritative window geometry and the shared desktop camera. Source nodes
// remain in world coordinates under a disabled tree. projection.c maintains
// the displayed tree between wallpaper and output-local shell UI.
const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const events = @import("ipc/events.zig");
pub const camera_mod = @import("camera.zig");

const World = @This();
const Projection = @import("projection.zig").Projection;
const sn = @import("node.zig");
const glass = @import("glass.zig");
const anim = @import("ui").anim;

server: *Server,
tree: *sn.Tree,
projection: *Projection,
/// Mapped windows, front of the list is the focused/top of the stack.
toplevels: wl.list.Head(Toplevel, .link) = undefined,
/// Unmapped windows whose close animation still owns a scene tree.
closing: wl.list.Head(Toplevel, .closing_link) = undefined,
workspaces: @import("workspaces.zig") = .{},
camera: camera_mod.Camera = .{},
overview: @import("world/overview.zig") = .{},
bounds: camera_mod.Bounds = .{},
mini_map: @import("mini_map.zig") = .{},
camera_event_pending: bool = false,
pan_x: anim.Anim = .{},
pan_y: anim.Anim = .{},
pan_target: anim.Target = .camera_pan,
zoom_anim: anim.Anim = .{ .from = 1, .to = 1 },
/// Layout-space zoom anchor, captured once at gesture start.
zoom_anchor: camera_mod.Vec = .{ .x = 0, .y = 0 },
/// World-space point that stays under `zoom_anchor` while zoom animates.
zoom_world: camera_mod.Vec = .{ .x = 0, .y = 0 },
zoom_keeps_anchor: bool = false,
/// True while a Super/middle-button pan is driving the offset 1:1.
panning: bool = false,
/// Unconstrained pan offset; rubber-banded into `camera.offset_*` while held.
pan_raw_x: f64 = 0,
pan_raw_y: f64 = 0,
/// True while a touchpad pinch is driving zoom 1:1.
pinching: bool = false,
pinch_start_zoom: f64 = 1,
pinch_start_index: usize = 0,
pinch_start_target: f64 = 1,
zoom_raw: f64 = 1,
vel_z: anim.VelocityTracker = .{},
/// Last chip selected during the current Super hold; IDs survive window teardown safely.
peek_window_id: ?u64 = null,

pub fn init(world: *World, server: *Server, tree: *sn.Tree) !void {
    world.* = .{
        .server = server,
        .tree = tree,
        .projection = Projection.create(server.nodes, tree, server.scene_outputs) orelse return error.SceneCreateFailed,
    };
    world.toplevels.init();
    world.closing.init();
}

const world_focus = @import("world/focus.zig");
pub const focus = world_focus.focus;
pub const focusSurface = world_focus.focusSurface;
pub const raiseTransientChildren = world_focus.raiseTransientChildren;
pub const cycleFocus = world_focus.cycleFocus;
pub const cycleFocusPrev = world_focus.cycleFocusPrev;
pub const peekTarget = world_focus.peekTarget;
pub const tickHover = world_focus.tickHover;

/// Windows whose backend is still alive are freed later by its destroy signal.
pub fn destroyClosing(world: *World) void {
    while (world.closing.first()) |toplevel| {
        toplevel.finishClose();
    }
}

const world_camera = @import("world/camera.zig");
pub const initBounds = world_camera.initBounds;
pub const derivedBounds = world_camera.derivedBounds;
pub const refreshBounds = world_camera.refreshBounds;
pub const ensureToplevelInBounds = world_camera.ensureToplevelInBounds;
pub const applyCamera = world_camera.applyCamera;
pub const allowsOverscroll = world_camera.allowsOverscroll;
pub const holdingGlass = world_camera.holdingGlass;
pub const sampledCamera = world_camera.sampledCamera;
pub const flushCameraEvent = world_camera.flushCameraEvent;
pub const isWindowVisible = world_camera.isWindowVisible;
pub const revealIfOffscreen = world_camera.revealIfOffscreen;
pub const windowFocusOffset = world_camera.windowFocusOffset;
pub const navigateTo = world_camera.navigateTo;
pub const refreshFocusZoom = world_camera.refreshFocusZoom;
pub const reveal = world_camera.reveal;
pub const resetCamera = world_camera.resetCamera;
pub const snapCamera = world_camera.snapCamera;
pub const tickCamera = world_camera.tickCamera;
pub const rebindPan = world_camera.rebindPan;

pub fn deinit(world: *World) void {
    world.workspaces.tiler.deinit();
    world.mini_map.deinit();
    Projection.destroy(world.projection);
}
pub fn syncPresentation(world: *World) void {
    if (world.server.xwayland) |xwayland| xwayland.syncGeometry();
    const now = anim.nowMs();
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (world.overview.active() or toplevel.zoom_boost_value != 0 or world.server.config.compositor.focus_zoom == .camera) {
            toplevel.applyVisualTransform(now);
            toplevel.applyOpacity(now);
        }
        toplevel.syncOutputScale();
    }
    Projection.syncFixed(world.projection, world.camera.zoom(), world.camera.offset_x, world.camera.offset_y, world.bounds.origin_x, world.bounds.origin_y, if (world.server.config.compositor.desktop_icons_fixed) world.server.world_desktop_tree else null);
    if (world.server.text_input) |relay| relay.updatePopups();
    if (world.server.desktop) |desktop| desktop.syncOverlayPosition();
}
pub fn toWorld(world: *const World, x: f64, y: f64) camera_mod.Vec {
    return world.camera.toWorld(world.bounds, x, y);
}
pub fn toLayout(world: *const World, x: f64, y: f64) camera_mod.Vec {
    return world.camera.toLayout(world.bounds, x, y);
}

const world_zoom = @import("world/zoom.zig");
pub const setZoom = world_zoom.setZoom;
pub const stepZoom = world_zoom.stepZoom;
pub const nearestZoom = world_zoom.nearestZoom;
pub const setZoomTarget = world_zoom.setZoomTarget;
pub const zoomLimits = world_zoom.zoomLimits;
pub const finishZoomAnimation = world_zoom.finishZoomAnimation;
pub const showZoom = world_zoom.showZoom;

const world_pan = @import("world/pan.zig");
pub const springPan = world_pan.springPan;
pub const beginPan = world_pan.beginPan;
pub const panBy = world_pan.panBy;
pub const endPanGesture = world_pan.endPanGesture;
pub const cancelPan = world_pan.cancelPan;
pub const beginPinch = world_pan.beginPinch;
pub const pinchTo = world_pan.pinchTo;
pub const endPinch = world_pan.endPinch;
pub const syncPanAnims = world_pan.syncPanAnims;
