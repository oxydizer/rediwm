//! Zoom: zoom levels and steps, the zoom target and limits, finishing a zoom animation and the zoom OSD.

const Server = @import("../Server.zig");
const camera_mod = @import("../camera.zig");
const anim = @import("ui").anim;
const World = @import("../World.zig");

pub fn setZoom(world: *World, index: usize, x: f64, y: f64) void {
    const next = @min(index, camera_mod.zoom_levels.len -| 1);
    world.setZoomTarget(camera_mod.zoomAtIndex(next), next, x, y);
}

/// In camera-focus mode, zooming in continues through the distinct window
/// depths. Otherwise the ordinary desktop steps remain capped at 100%.
pub fn stepZoom(world: *World, steps: i32, x: f64, y: f64) void {
    var target = world.camera.targetZoom();
    for (0..@abs(steps)) |_| {
        var next: ?f64 = null;
        for (0..camera_mod.zoom_levels.len) |index| {
            considerZoomStep(target, camera_mod.zoomAtIndex(index), steps < 0, &next);
        }
        if (world.server.config.compositor.focus_zoom == .camera) {
            var it = world.toplevels.iterator(.forward);
            while (it.next()) |toplevel| {
                if (toplevel.tab_hidden or toplevel.layout() != .floating or toplevel.isFullscreen()) continue;
                const scale = @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index])) / 100;
                considerZoomStep(target, 1 / scale, steps < 0, &next);
            }
        }
        target = next orelse break;
    }
    world.setZoomTarget(target, camera_mod.nearestIndex(target), x, y);
}

pub fn considerZoomStep(current: f64, candidate: f64, inward: bool, next: *?f64) void {
    if (if (inward) candidate <= current + 1e-6 else candidate >= current - 1e-6) return;
    if (next.*) |previous| {
        if (if (inward) candidate >= previous else candidate <= previous) return;
    }
    next.* = candidate;
}

pub fn nearestZoom(world: *World, value: f64) f64 {
    var nearest = camera_mod.zoomAtIndex(camera_mod.nearestIndex(value));
    if (world.server.config.compositor.focus_zoom == .camera) {
        var it = world.toplevels.iterator(.forward);
        while (it.next()) |toplevel| {
            if (toplevel.tab_hidden or toplevel.layout() != .floating or toplevel.isFullscreen()) continue;
            const candidate = 100 / @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index]));
            if (@abs(candidate - value) < @abs(nearest - value)) nearest = candidate;
        }
    }
    return nearest;
}

pub fn setZoomTarget(world: *World, target_z: f64, next: usize, x: f64, y: f64) void {
    if (world.workspaces.mode != .canvas) return;
    world.mini_map.show(world.server, x, y);
    if (world.pinching) world.endPinch(false);
    if (next == world.camera.zoom_index and !world.zoom_anim.active() and
        @abs(world.camera.zoom_value - target_z) < 1e-9)
    {
        world.showZoom(x, y);
        return;
    }

    const now_ms = anim.nowMs();

    // Record camera zoom for undo. Coalescing keeps the first snapshot within
    // 600 ms, so wheel-zooming five notches produces one undoable entry.
    {
        const cam = world.camera;
        const undo_ms = Server.undoNowMs();
        world.server.undo.record(.{
            .kind = .camera_zoom,
            .press_seq = world.server.undo.press_seq,
            .at_ms = undo_ms,
            .camera = .{ .offset_x = cam.offset_x, .offset_y = cam.offset_y, .zoom_index = cam.zoom_index, .focus_zoom = cam.focus_zoom },
        }, undo_ms);
    }

    world.camera.focus_zoom = if (target_z != camera_mod.zoomAtIndex(next)) target_z else null;
    world.camera.zoom_limit = @max(world.camera.zoom_limit, target_z);
    world.camera.zoom_index = next;

    // A live pan keeps 1:1 with the pointer; snap zoom so offset math cannot
    // fight the drag. Reduced motion / disabled animations also snap.
    if (world.panning or !anim.enabled() or anim.speed() <= 0 or anim.reducedMotion()) {
        const point = world.camera.toWorld(world.bounds, x, y);
        world.camera.placeZoom(world.bounds, target_z, point, .{ .x = x, .y = y });
        world.camera.zoom_limit = @max(1, target_z);
        world.zoom_anim.cancel(@floatCast(world.camera.zoom_value));
        world.zoom_keeps_anchor = false;
        if (world.panning) {
            world.pan_raw_x = world.camera.offset_x;
            world.pan_raw_y = world.camera.offset_y;
        }
        world.applyCamera();
        world.server.input.processCursorMotion(0);
        world.showZoom(x, y);
        return;
    }

    if (!world.zoom_anim.active() or !world.zoom_keeps_anchor) {
        world.zoom_anim = .{ .from = @floatCast(world.camera.zoom_value), .to = @floatCast(world.camera.zoom_value) };
        world.zoom_anchor = .{ .x = x, .y = y };
        world.zoom_world = world.camera.toWorld(world.bounds, x, y);
        world.zoom_keeps_anchor = true;
        world.pan_x.cancel(@floatCast(world.camera.offset_x));
        world.pan_y.cancel(@floatCast(world.camera.offset_y));
    }

    world.camera.zoom_index = next;
    world.zoom_anim.retargetTo(now_ms, @floatCast(target_z), anim.curveFor(.camera_zoom));
    if (world.zoom_anim.settled(now_ms) or !world.zoom_anim.active()) {
        world.camera.placeZoom(world.bounds, target_z, world.zoom_world, world.zoom_anchor);
        world.camera.zoom_limit = @max(1, target_z);
        world.zoom_anim.cancel(@floatCast(world.camera.zoom_value));
        world.zoom_keeps_anchor = false;
        world.applyCamera();
    } else {
        _ = world.tickCamera(now_ms);
    }
    world.server.input.processCursorMotion(0);
    world.showZoom(x, y);
}

pub fn zoomLimits(world: *World) struct { lo: f64, hi: f64 } {
    const a: f64 = world.server.config.compositor.camera_zoom_min;
    const b: f64 = world.server.config.compositor.camera_zoom_max;
    var hi = @min(1, @max(a, b));
    if (world.server.config.compositor.focus_zoom == .camera) {
        var it = world.toplevels.iterator(.forward);
        while (it.next()) |toplevel| {
            if (toplevel.tab_hidden or toplevel.layout() != .floating or toplevel.isFullscreen()) continue;
            hi = @max(hi, 100 / @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index])));
        }
    }
    return .{ .lo = @min(1, @min(a, b)), .hi = hi };
}

pub fn finishZoomAnimation(world: *World) void {
    if (!world.zoom_anim.active()) {
        world.zoom_keeps_anchor = false;
        return;
    }
    const z = world.camera.targetZoom();
    world.camera.zoom_value = z;
    world.camera.zoom_limit = @max(1, z);
    if (world.zoom_keeps_anchor) {
        world.camera.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
    }
    world.zoom_anim.cancel(@floatCast(z));
    world.zoom_keeps_anchor = false;
}

pub fn showZoom(world: *World, x: f64, y: f64) void {
    const Output = @import("../Output.zig");
    const output = Output.atLayout(world.server, x, y) orelse world.server.getDefaultOutput() orelse return;
    const level = if (world.pinching) world.camera.zoom() else world.camera.targetZoom();
    @import("../osd.zig").showOn(world.server, output, .{ .kind = .zoom, .level = @floatCast(level) });
}
