//! The camera: world bounds, applying and sampling it, revealing and navigating to windows, reset, snapping and the per-frame tick.

const std = @import("std");
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const events = @import("../ipc/events.zig");
const camera_mod = @import("../camera.zig");
const anim = @import("ui").anim;
const World = @import("../World.zig");

/// Compute and store camera bounds from the combined output layout rectangle.
pub fn initBounds(world: *World, layout_x: i32, layout_y: i32, layout_w: i32, layout_h: i32) void {
    world.bounds = world.derivedBounds(layout_x, layout_y, layout_w, layout_h);
}

/// The configured grid, grown just enough to keep every resting window
/// reachable. A pure function of the layout, the config and the windows, so
/// the reachable area (and the mini-map drawn from it) never depends on where
/// a window happened to pass through.
pub fn derivedBounds(world: *World, layout_x: i32, layout_y: i32, layout_w: i32, layout_h: i32) camera_mod.Bounds {
    const cfg = world.server.config.compositor;
    const grid = camera_mod.computeGridBounds(layout_x, layout_y, layout_w, layout_h, cfg.canvas_columns, cfg.canvas_rows);
    if (world.workspaces.active) return grid;
    // Each window is measured against the grid alone, so stacking order
    // cannot change whether a frame's grab strip counts as reachable.
    var bounds = grid;
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.tab_hidden or top.closing or top.backend_gone or !top.in_world) continue;
        var reach = grid;
        expandForToplevel(&reach, top);
        bounds.max_x = @max(bounds.max_x, reach.max_x);
        bounds.max_y = @max(bounds.max_y, reach.max_y);
    }
    return bounds;
}

/// Frames are measured at the window's own zoom, not the temporary focus boost.
pub fn expandForToplevel(bounds: *camera_mod.Bounds, top: *const Toplevel) void {
    const w: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(top.chrome_width)) * top.zoom_scale));
    const h: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(top.chrome_height)) * top.zoom_scale));
    camera_mod.expandToFrame(
        bounds,
        top.x,
        top.y,
        w,
        h,
        @intFromFloat(@round(bounds.origin_x)),
        @intFromFloat(@round(bounds.origin_y)),
        @intFromFloat(@round(bounds.width)),
        @intFromFloat(@round(bounds.height)),
    );
}

/// Re-derive the bounds from the current windows, once per frame. Bounds
/// shrink again when a window comes back or goes away; a camera left beyond
/// the new limits glides back. During a move or resize grab they only grow, so
/// the canvas doesn't pull in under the pointer.
pub fn refreshBounds(world: *World) void {
    if (world.workspaces.active or world.bounds.width <= 0 or world.bounds.height <= 0) return;
    const old = world.bounds;
    var next = world.derivedBounds(@intFromFloat(@round(old.origin_x)), @intFromFloat(@round(old.origin_y)), @intFromFloat(@round(old.width)), @intFromFloat(@round(old.height)));
    const input = &world.server.input;
    if (input.cursor_mode == .move or input.cursor_mode == .resize) {
        next.max_x = @max(next.max_x, old.max_x);
        next.max_y = @max(next.max_y, old.max_y);
    }
    if (std.meta.eql(next, old)) return;
    world.bounds = next;
    var clamped = world.camera;
    clamped.clamp(next);
    if (!world.allowsOverscroll() and (clamped.offset_x != world.camera.offset_x or clamped.offset_y != world.camera.offset_y)) {
        world.springPan(clamped.offset_x, clamped.offset_y, .camera_reveal);
    }
}

/// Keep `toplevel` reachable right away, between per-frame refreshes.
pub fn ensureToplevelInBounds(world: *World, toplevel: *const Toplevel) void {
    if (world.workspaces.active) return;
    expandForToplevel(&world.bounds, toplevel);
}

/// Project the world without changing source nodes or client geometry.
pub fn applyCamera(world: *World) void {
    if (world.workspaces.active) world.camera = .{ .focus_zoom = 1 };
    if (!world.allowsOverscroll()) {
        world.camera.clamp(world.bounds);
    }
    // Input updates the authoritative camera immediately. Presentation is
    // synchronized at the output frame (or before a hit test that needs it),
    // so high-rate pan events do not repeatedly walk and damage the scene.
    world.camera_event_pending = true;
    world.server.scheduleFrames();
    if (world.server.idle) |im| {
        im.recheckInhibitors();
    }
}

pub fn allowsOverscroll(world: *const World) bool {
    return world.overview.active() or world.panning or world.pan_x.active() or world.pan_y.active();
}

/// True while the camera is being dragged or its springs/fling are in flight.
/// Glass holds every backdrop for that interval and refreshes on the settle frame.
pub fn holdingGlass(world: *const World) bool {
    return (world.overview.active() and world.overview.spread.active()) or world.panning or world.pinching or world.pan_x.active() or world.pan_y.active() or world.zoom_anim.active();
}

/// Analytic camera at `now_ms`, for IPC. Presentation still uses `world.camera`
/// as written by the last tick / gesture.
pub fn sampledCamera(world: *const World, now_ms: i64) camera_mod.Camera {
    var cam = world.camera;
    if (world.panning or world.pinching) return cam;
    if (world.zoom_anim.active()) {
        const z: f64 = @min(cam.zoom_limit, world.zoom_anim.value(now_ms));
        cam.zoom_value = z;
        if (world.zoom_keeps_anchor) {
            cam.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
        }
    }
    if (!world.zoom_keeps_anchor) {
        if (world.pan_x.active()) cam.offset_x = world.pan_x.value(now_ms);
        if (world.pan_y.active()) cam.offset_y = world.pan_y.value(now_ms);
    }
    return cam;
}

/// At most one camera event per output frame, even with high-rate input.
pub fn flushCameraEvent(world: *World) void {
    if (!world.camera_event_pending) return;
    world.camera_event_pending = false;
    // Panning moves windows between outputs without moving them in the world.
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| toplevel.syncForeign();
    const offset = camera_mod.appliedOffset(world.camera);
    if (world.server.ipc) |ipc| {
        const max_xi: i32 = @intFromFloat(world.bounds.max_x);
        const max_yi: i32 = @intFromFloat(world.bounds.max_y);
        events.onCameraChanged(ipc, offset.x, offset.y, max_xi, max_yi, world.camera.targetPercent());
    }
}

/// Use the same visibility threshold as window navigation. A focused window
/// showing only a sliver should be revealed by its taskbar button, not minimized.
pub fn isWindowVisible(world: *World, toplevel: *Toplevel, output: *@import("../Output.zig")) bool {
    return toplevel.frame_tree.node.enabled and toplevel.chrome_width > 0 and toplevel.chrome_height > 0 and
        world.windowFocusOffset(toplevel, output, world.camera, toplevel.worldScale(), false) == null;
}

/// Reveal `toplevel` on `output` if it is currently offscreen.
pub fn revealIfOffscreen(world: *World, toplevel: *Toplevel, output: *@import("../Output.zig")) void {
    world.workspaces.reveal(toplevel);
    if (world.workspaces.active) return;
    if (world.windowFocusOffset(toplevel, output, world.camera, toplevel.worldScale(), false)) |offset| {
        world.springPan(offset.x, offset.y, .camera_reveal);
    }
}

pub fn windowFocusOffset(world: *World, toplevel: *Toplevel, output: *@import("../Output.zig"), cam: camera_mod.Camera, scale: f64, force: bool) ?camera_mod.Vec {
    // A restored or just-placed window may not be in the last frame's bounds.
    world.ensureToplevelInBounds(toplevel);
    const usable = output.usableBox();
    return camera_mod.focusOffset(cam, world.bounds, .{ .x = @floatFromInt(toplevel.x), .y = @floatFromInt(toplevel.y) }, .{ .x = @as(f64, @floatFromInt(toplevel.chrome_width)) * scale, .y = @as(f64, @floatFromInt(toplevel.chrome_height)) * scale }, .{ .x = @floatFromInt(usable.x), .y = @floatFromInt(usable.y) }, .{ .x = @floatFromInt(usable.width), .y = @floatFromInt(usable.height) }, force);
}

/// Explicit navigation (Alt+Tab, directional focus and taskbar activation).
/// Plain pointer focus does not change the zoom beneath the pointer.
pub fn navigateTo(world: *World, toplevel: *Toplevel, output: *@import("../Output.zig")) void {
    world.workspaces.reveal(toplevel);
    if (world.workspaces.active) return;
    if (!toplevel.in_world or toplevel.minimized) return;
    const mode = world.server.config.compositor.focus_zoom;
    const floating = toplevel.layout() == .floating and !toplevel.isFullscreen();
    toplevel.setZoomBoost(mode == .boost and floating);
    const raw = @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index])) / 100;
    const changing_camera = mode == .camera and floating and @abs(world.camera.zoom() - 1 / raw) > 1e-6;
    if (mode == .camera and floating) {
        const usable = output.usableBox();
        world.setZoomTarget(1 / raw, 0, @as(f64, @floatFromInt(usable.x)) + @as(f64, @floatFromInt(usable.width)) / 2, @as(f64, @floatFromInt(usable.y)) + @as(f64, @floatFromInt(usable.height)) / 2);
    }
    var destination = world.camera;
    destination.zoom_value = destination.targetZoom();
    const scale = if (mode == .boost and floating) 1 / destination.zoom() else raw;
    if (world.windowFocusOffset(toplevel, output, destination, scale, changing_camera)) |offset| {
        world.springPan(offset.x, offset.y, .camera_reveal);
    }
}

pub fn refreshFocusZoom(world: *World) void {
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| toplevel.setZoomBoost(false);
    if (world.server.config.compositor.focus_zoom != .camera and world.camera.focus_zoom != null) {
        world.setZoom(0, world.server.input.cursor.x, world.server.input.cursor.y);
    }
    world.server.scheduleFrames();
}

/// Scroll the camera to bring `toplevel`'s frame into the output's usable area.
/// `output` is used for the usable-area box.
pub fn reveal(
    world: *World,
    toplevel: *Toplevel,
    output: *@import("../Output.zig"),
) void {
    if (world.windowFocusOffset(toplevel, output, world.camera, toplevel.worldScale(), true)) |offset| {
        world.springPan(offset.x, offset.y, .camera_reveal);
    }
}

/// Reset the camera to the origin and 100%, springing independently on each axis.
pub fn resetCamera(world: *World) void {
    world.mini_map.show(world.server, world.server.input.cursor.x, world.server.input.cursor.y);
    // Record for undo before modifying camera state.
    {
        const cam = world.camera;
        if (cam.offset_x != 0 or cam.offset_y != 0 or cam.zoom_index != 0 or cam.focus_zoom != null) {
            const undo_ms = Server.undoNowMs();
            world.server.undo.record(.{
                .kind = .camera_zoom,
                .press_seq = world.server.undo.press_seq,
                .at_ms = undo_ms,
                .camera = .{ .offset_x = cam.offset_x, .offset_y = cam.offset_y, .zoom_index = cam.zoom_index, .focus_zoom = cam.focus_zoom },
            }, undo_ms);
        }
    }
    const now_ms = anim.nowMs();
    world.panning = false;
    world.pinching = false;
    world.zoom_keeps_anchor = false;
    world.camera.zoom_index = 0;
    world.camera.focus_zoom = null;
    world.syncPanAnims();
    if (!world.zoom_anim.active()) {
        world.zoom_anim = .{ .from = @floatCast(world.camera.zoom_value), .to = @floatCast(world.camera.zoom_value) };
    }
    world.zoom_anim.retargetTo(now_ms, 1, anim.curveFor(.camera_zoom));
    world.pan_target = .camera_reveal;
    world.pan_x.retargetTo(now_ms, 0, anim.curveFor(.camera_reveal));
    world.pan_y.retargetTo(now_ms, 0, anim.curveFor(.camera_reveal));
    if ((world.zoom_anim.settled(now_ms) or !world.zoom_anim.active()) and
        (world.pan_x.settled(now_ms) or !world.pan_x.active()) and
        (world.pan_y.settled(now_ms) or !world.pan_y.active()))
    {
        world.camera = .{};
        world.zoom_anim.cancel(1);
        world.pan_x.cancel(0);
        world.pan_y.cancel(0);
        world.applyCamera();
    } else {
        _ = world.tickCamera(now_ms);
    }
    world.server.input.processCursorMotion(0);
    world.showZoom(world.server.input.cursor.x, world.server.input.cursor.y);
}

pub fn snapCamera(world: *World) void {
    const x: f32 = @floatCast(world.camera.offset_x);
    const y: f32 = @floatCast(world.camera.offset_y);
    const z: f32 = @floatCast(world.camera.targetZoom());
    world.panning = false;
    world.pinching = false;
    world.zoom_keeps_anchor = false;
    world.camera.zoom_value = z;
    world.camera.zoom_limit = @max(1, z);
    world.pan_x.cancel(x);
    world.pan_y.cancel(y);
    world.zoom_anim.cancel(z);
}

pub fn tickCamera(world: *World, now_ms: i64) bool {
    var animating = false;
    var moved = false;

    if (!world.pinching and world.zoom_anim.active()) {
        _ = world.zoom_anim.sampleChanged(now_ms, 0.001);
        const target_z = world.camera.targetZoom();
        const settled = world.zoom_anim.settled(now_ms);
        const z: f64 = if (settled) target_z else @min(world.camera.zoom_limit, world.zoom_anim.value(now_ms));
        if (world.camera.zoom_value != z) {
            world.camera.zoom_value = z;
            moved = true;
        }
        if (world.zoom_keeps_anchor) {
            world.camera.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
            if (world.panning) {
                world.pan_raw_x = world.camera.offset_x;
                world.pan_raw_y = world.camera.offset_y;
            }
            moved = true;
        }
        if (settled) {
            world.zoom_anim.cancel(@floatCast(target_z));
            world.camera.zoom_value = target_z;
            world.camera.zoom_limit = @max(1, target_z);
            world.zoom_keeps_anchor = false;
        } else {
            animating = true;
        }
    }

    if (!world.panning and !world.zoom_keeps_anchor) {
        const pan_x_live = world.pan_x.active();
        const pan_y_live = world.pan_y.active();
        if (tickPanAxis(&world.pan_x, &world.camera.offset_x, now_ms, true, world.bounds, world.camera.zoom(), !world.overview.active())) {
            animating = true;
        }
        if (tickPanAxis(&world.pan_y, &world.camera.offset_y, now_ms, false, world.bounds, world.camera.zoom(), !world.overview.active())) {
            animating = true;
        }
        if (pan_x_live or pan_y_live) moved = true;
    }

    if (moved or animating) {
        world.applyCamera();
        if (!animating) world.server.input.processCursorMotion(0);
    }
    return animating;
}

pub fn tickPanAxis(
    a: *anim.Anim,
    dest: *f64,
    now_ms: i64,
    is_x: bool,
    bounds: camera_mod.Bounds,
    zoom: f64,
    constrain: bool,
) bool {
    if (!a.active()) return false;
    _ = a.sampleChanged(now_ms, anim.quantum_px);
    const limits = camera_mod.offsetLimits(bounds, zoom);
    const lo = if (is_x) limits.lo_x else limits.lo_y;
    const hi = if (is_x) limits.hi_x else limits.hi_y;
    var value: f64 = a.value(now_ms);
    if (a.curve == .decay) {
        if (value < lo) {
            a.retargetWith(now_ms, @floatCast(lo), anim.curveFor(.camera_pan), a.velocity(now_ms));
            value = a.value(now_ms);
        } else if (value > hi) {
            a.retargetWith(now_ms, @floatCast(hi), anim.curveFor(.camera_pan), a.velocity(now_ms));
            value = a.value(now_ms);
        }
    }
    dest.* = value;
    if (a.settled(now_ms)) {
        const rest: f64 = a.to;
        dest.* = if (!constrain) rest else if (rest < lo) lo else if (rest > hi) hi else rest;
        a.cancel(@floatCast(dest.*));
        return false;
    }
    return true;
}

/// Re-apply rubber-band against current bounds after a layout change mid-drag.
pub fn rebindPan(world: *World) void {
    if (!world.panning) return;
    _ = camera_mod.applyMotionRubber(&world.camera, 0, 0, world.bounds, &world.pan_raw_x, &world.pan_raw_y);
}
