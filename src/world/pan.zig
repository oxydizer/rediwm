//! Panning and pinching: spring pans, pan gestures and pinch zoom.

const std = @import("std");
const camera_mod = @import("../camera.zig");
const anim = @import("ui").anim;
const World = @import("../World.zig");

pub fn springPan(world: *World, x: f64, y: f64, target: anim.Target) void {
    if (world.workspaces.mode != .canvas) return;
    world.pan_target = target;
    world.mini_map.show(world.server, world.server.input.cursor.x, world.server.input.cursor.y);
    if (world.pinching) world.endPinch(false);
    const now_ms = anim.nowMs();
    const limits = camera_mod.offsetLimits(world.bounds, world.camera.targetZoom());
    const tx = if (limits.hi_x < limits.lo_x) (limits.lo_x + limits.hi_x) / 2 else std.math.clamp(x, limits.lo_x, limits.hi_x);
    const ty = if (limits.hi_y < limits.lo_y) (limits.lo_y + limits.hi_y) / 2 else std.math.clamp(y, limits.lo_y, limits.hi_y);
    world.zoom_keeps_anchor = false;
    world.syncPanAnims();
    const curve = anim.curveFor(target);
    world.pan_x.retargetTo(now_ms, @floatCast(tx), curve);
    world.pan_y.retargetTo(now_ms, @floatCast(ty), curve);
    if ((world.pan_x.settled(now_ms) or !world.pan_x.active()) and
        (world.pan_y.settled(now_ms) or !world.pan_y.active()))
    {
        world.camera.offset_x = tx;
        world.camera.offset_y = ty;
        world.pan_x.cancel(@floatCast(tx));
        world.pan_y.cancel(@floatCast(ty));
        world.applyCamera();
    } else {
        _ = world.tickCamera(now_ms);
    }
}

pub fn beginPan(world: *World) void {
    if (world.workspaces.mode != .canvas) return;
    world.mini_map.show(world.server, world.server.input.cursor.x, world.server.input.cursor.y);
    if (world.pinching) world.endPinch(false);
    world.zoom_keeps_anchor = false;
    world.finishZoomAnimation();
    const x = world.camera.offset_x;
    const y = world.camera.offset_y;
    world.pan_x.cancel(@floatCast(x));
    world.pan_y.cancel(@floatCast(y));
    world.panning = true;
    world.pan_raw_x = x;
    world.pan_raw_y = y;
}

pub fn panBy(world: *World, dx: f64, dy: f64) void {
    if (world.workspaces.mode != .canvas) return;
    if (!world.panning) world.beginPan();
    _ = camera_mod.applyMotionRubber(&world.camera, dx, dy, world.bounds, &world.pan_raw_x, &world.pan_raw_y);
    world.applyCamera();
}

pub fn endPanGesture(world: *World) void {
    if (!world.panning) return;
    world.panning = false;
    // Stop where the hand releases; only animate a short return from overscroll.
    world.pan_x.cancel(@floatCast(world.camera.offset_x));
    world.pan_y.cancel(@floatCast(world.camera.offset_y));
    world.springPan(world.camera.offset_x, world.camera.offset_y, .camera_pan);
}

pub fn cancelPan(world: *World) void {
    if (!world.panning) return;
    world.panning = false;
    const x: f32 = @floatCast(world.camera.offset_x);
    const y: f32 = @floatCast(world.camera.offset_y);
    world.pan_x.cancel(x);
    world.pan_y.cancel(y);
    world.camera.clamp(world.bounds);
    world.applyCamera();
}

pub fn beginPinch(world: *World, lx: f64, ly: f64) void {
    world.mini_map.show(world.server, lx, ly);
    if (world.panning) world.endPanGesture();
    const now_ms = anim.nowMs();
    const z = world.camera.zoom();
    world.pinching = true;
    world.pinch_start_zoom = z;
    world.pinch_start_index = world.camera.zoom_index;
    world.pinch_start_target = world.camera.targetZoom();
    world.camera.zoom_limit = @max(world.camera.zoom_limit, world.zoomLimits().hi);
    world.zoom_raw = z;
    world.zoom_anchor = .{ .x = lx, .y = ly };
    world.zoom_world = world.camera.toWorld(world.bounds, lx, ly);
    world.zoom_keeps_anchor = true;
    world.zoom_anim.cancel(@floatCast(z));
    world.vel_z.reset();
    world.vel_z.push(now_ms, @floatCast(z));
}

pub fn pinchTo(world: *World, scale: f64) void {
    if (!world.pinching) return;
    const now_ms = anim.nowMs();
    const raw = world.pinch_start_zoom * @max(scale, 1e-3);
    world.zoom_raw = raw;
    const range = world.zoomLimits();
    const dim = @max(range.hi - range.lo, 0.25);
    const z = @min(world.camera.zoom_limit, camera_mod.rubberBand(raw, range.lo, range.hi, dim));
    world.camera.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
    world.vel_z.push(now_ms, @floatCast(world.camera.zoom_value));
    world.applyCamera();
    world.showZoom(world.zoom_anchor.x, world.zoom_anchor.y);
}

pub fn endPinch(world: *World, cancelled: bool) void {
    if (!world.pinching) return;
    world.pinching = false;
    const now_ms = anim.nowMs();
    const visual = world.camera.zoom_value;
    const target = if (cancelled) world.pinch_start_target else world.nearestZoom(visual);
    const idx: usize = if (cancelled) world.pinch_start_index else camera_mod.nearestIndex(target);
    world.camera.zoom_index = idx;
    world.camera.focus_zoom = if (target != camera_mod.zoomAtIndex(idx)) target else null;
    const vz = if (cancelled) 0 else world.vel_z.velocity(now_ms);
    world.zoom_keeps_anchor = true;
    world.zoom_anim = .{ .from = @floatCast(visual), .to = @floatCast(visual) };
    if (!anim.enabled() or anim.speed() <= 0 or anim.reducedMotion()) {
        world.camera.placeZoom(world.bounds, target, world.zoom_world, world.zoom_anchor);
        world.zoom_anim.cancel(@floatCast(target));
        world.zoom_keeps_anchor = false;
        world.applyCamera();
    } else {
        world.zoom_anim.retargetWith(now_ms, @floatCast(target), anim.curveFor(.camera_zoom), vz);
        if (world.zoom_anim.settled(now_ms) or !world.zoom_anim.active()) {
            world.camera.placeZoom(world.bounds, target, world.zoom_world, world.zoom_anchor);
            world.zoom_anim.cancel(@floatCast(target));
            world.zoom_keeps_anchor = false;
            world.applyCamera();
        } else {
            _ = world.tickCamera(now_ms);
        }
    }
    world.server.input.processCursorMotion(0);
    world.showZoom(world.zoom_anchor.x, world.zoom_anchor.y);
}

pub fn syncPanAnims(world: *World) void {
    if (!world.pan_x.active()) {
        const x: f32 = @floatCast(world.camera.offset_x);
        world.pan_x = .{ .from = x, .to = x };
    }
    if (!world.pan_y.active()) {
        const y: f32 = @floatCast(world.camera.offset_y);
        world.pan_y = .{ .from = y, .to = y };
    }
}
