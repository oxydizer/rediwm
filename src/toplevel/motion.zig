//! Toplevel animations: move, size, drag lift, dodge, workspace switch and map.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const sn = @import("../node.zig");
const chrome = @import("../chrome.zig");
const projection = @import("../projection.zig");
const loader = @import("config").loader;
const anim = @import("ui").anim;
const log = std.log.scoped(.toplevel);
const ConfigureWait = Toplevel.ConfigureWait;
const LaunchOrigin = Toplevel.LaunchOrigin;
const visualX = Toplevel.visualX;
const visualY = Toplevel.visualY;
const applySizeClip = Toplevel.applySizeClip;
const nowMs = Toplevel.nowMs;

pub fn finishMoveAnimation(toplevel: *Toplevel) void {
    if (!toplevel.move_x.active() and !toplevel.move_y.active()) return;
    const now_ms = nowMs();
    toplevel.setPosition(visualX(toplevel, now_ms), visualY(toplevel, now_ms));
}

pub fn finishSizeAnimation(toplevel: *Toplevel) void {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) return;
    const geom = toplevel.clientGeometry();
    const size = chromeSizeForClient(toplevel, geom.width, geom.height);
    toplevel.size_w.cancel(@floatFromInt(size.w));
    toplevel.size_h.cancel(@floatFromInt(size.h));
    applySizeClip(toplevel);
}

pub fn requestSizeAnimated(toplevel: *Toplevel, width: i32, height: i32) ConfigureWait {
    const wait = toplevel.requestSize(width, height);
    toplevel.animateChromeSize(width, height, wait);
    return wait;
}

/// Eases the frame toward a client size already requested (`wait`), clipping
/// the client to it while the client catches up.
pub fn animateChromeSize(toplevel: *Toplevel, width: i32, height: i32, wait: ConfigureWait) void {
    if (!toplevel.in_world or toplevel.isResizing()) return;
    toplevel.size_wait = wait;
    const now_ms = nowMs();
    const target = chromeSizeForClient(toplevel, width, height);
    if (target.w <= 0 or target.h <= 0) return;
    if (!toplevel.size_w.active() and toplevel.size_w.settle_ms == 0) {
        const cur_w: f32 = @floatFromInt(if (toplevel.chrome_width > 0) toplevel.chrome_width else target.w);
        toplevel.size_w = .{ .from = cur_w, .to = cur_w };
    }
    if (!toplevel.size_h.active() and toplevel.size_h.settle_ms == 0) {
        const cur_h: f32 = @floatFromInt(if (toplevel.chrome_height > 0) toplevel.chrome_height else target.h);
        toplevel.size_h = .{ .from = cur_h, .to = cur_h };
    }
    const curve = anim.curveFor(.window_resize);
    toplevel.size_w.retargetTo(now_ms, @floatFromInt(target.w), curve);
    toplevel.size_h.retargetTo(now_ms, @floatFromInt(target.h), curve);
    if (toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms)) {
        toplevel.size_w.cancel(@floatFromInt(target.w));
        toplevel.size_h.cancel(@floatFromInt(target.h));
    } else {
        toplevel.server.scheduleFrames();
    }
}

pub fn chromeSizeForClient(toplevel: *const Toplevel, client_w: i32, client_h: i32) struct { w: i32, h: i32 } {
    if (!toplevel.hasServerDecorations()) return .{ .w = client_w, .h = client_h };
    const footer = chrome.frameBorder();
    return .{
        .w = client_w + 2 * chrome.frameBorder(),
        .h = client_h + toplevel.titlebarHeight() + footer,
    };
}

pub fn ignoreCloseInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

pub fn applyVisualTransform(toplevel: *Toplevel, now_ms: i64) void {
    const zoom_scale = toplevel.worldScale();
    if (toplevel.in_world and !toplevel.closing) {
        toplevel.frame_tree.node.setEnabled(toplevel.switch_leaving or (@import("../window_tabs.zig").visible(toplevel) and toplevel.cameraFocusOpacity() > 0));
    }
    // Open keeps tree zoom at the logical window zoom so scene picking and
    // client-local coordinates stay 1:1 with the mapped frame (existing
    // tests and the "input keys off the logical map" rule). Close may scale
    // because the frame no longer accepts input.
    const factor: f64 = if (toplevel.closing)
        anim.windowMapScale(toplevel.map_motion.value(now_ms))
    else
        1.0;
    const lift = toplevel.dragLiftOffset();
    const x = visualX(toplevel, now_ms) + animOffset(toplevel.dodge_x, now_ms) + animOffset(toplevel.switch_x, now_ms) - lift.x;
    const y = visualY(toplevel, now_ms) + animOffset(toplevel.dodge_y, now_ms) + animOffset(toplevel.switch_y, now_ms) - lift.y;
    if (!toplevel.closing) if (toplevel.launch_origin) |origin| {
        const grow = launchGrowth(toplevel, origin, x, y, zoom_scale * toplevel.drag_lift_value, toplevel.map_motion.value(now_ms));
        _ = @import("../projection.zig").setTreeZoom(&toplevel.frame_tree.node, grow.zoom);
        toplevel.frame_tree.node.setPosition(grow.x, grow.y);
        return;
    };
    _ = @import("../projection.zig").setTreeZoom(&toplevel.frame_tree.node, zoom_scale * factor * toplevel.drag_lift_value);
    toplevel.frame_tree.node.setPosition(x, y);
}

/// The frame on its way from the dock icon it was launched from (`amount` 0)
/// to its place at `x`, `y` and tree zoom `rest_zoom` (`amount` 1): the icon's
/// square grows into the frame, centre to centre, keeping the frame's aspect.
pub fn launchGrowth(toplevel: *const Toplevel, origin: LaunchOrigin, x: i32, y: i32, rest_zoom: f64, amount: f32) struct { x: i32, y: i32, zoom: f64 } {
    const world = &toplevel.server.world;
    const t: f64 = amount;
    const w = @as(f64, @floatFromInt(@max(toplevel.chrome_width, 1))) * rest_zoom;
    const h = @as(f64, @floatFromInt(@max(toplevel.chrome_height, 1))) * rest_zoom;
    const icon = world.toWorld(origin.x + origin.width / 2, origin.y + origin.height / 2);
    const icon_side = @max(origin.width, origin.height) / world.camera.zoom();
    const start = std.math.clamp(icon_side / @max(w, h), 0.01, 1);
    const f = start + (1 - start) * t;
    const cx = icon.x + (@as(f64, @floatFromInt(x)) + w / 2 - icon.x) * t;
    const cy = icon.y + (@as(f64, @floatFromInt(y)) + h / 2 - icon.y) * t;
    return .{
        .x = @intFromFloat(@round(cx - w * f / 2)),
        .y = @intFromFloat(@round(cy - h * f / 2)),
        .zoom = rest_zoom * f,
    };
}

pub fn dragLiftOffset(toplevel: *const Toplevel) struct { x: i32, y: i32 } {
    const extra = toplevel.worldScale() * (toplevel.drag_lift_value - 1);
    return .{
        .x = @intFromFloat(@round(toplevel.drag_lift_anchor.x * extra)),
        .y = @intFromFloat(@round(toplevel.drag_lift_anchor.y * extra)),
    };
}

pub fn tickDragLift(toplevel: *Toplevel, now_ms: i64) bool {
    const input = &toplevel.server.input;
    const moving = input.cursor_mode == .move and input.grabbed_toplevel == toplevel;
    const config = toplevel.server.config.compositor;
    const lift = moving and config.drag_feedback and !toplevel.isFullscreen() and
        input.move_snap.unsnap_from == null and anim.enabled() and !anim.reducedMotion();
    if (moving) {
        const scale = toplevel.worldScale();
        toplevel.drag_lift_anchor = if (input.tiling_grab != null)
            .{ .x = @as(f64, @floatFromInt(toplevel.chrome_width)) / 2, .y = @as(f64, @floatFromInt(toplevel.chrome_height)) / 2 }
        else
            .{ .x = input.grab_x / scale, .y = input.grab_y / scale };
    }
    const target: f32 = if (lift) config.drag_scale else 1;
    if (!toplevel.drag_lift.active() and toplevel.drag_lift.to == target) return false;
    if (toplevel.drag_lift.to != target) toplevel.drag_lift.retargetTo(now_ms, target, anim.curveFor(.window_drag));
    const live = toplevel.drag_lift.active();
    _ = toplevel.drag_lift.sampleChanged(now_ms, 0.0001);
    const settled = toplevel.drag_lift.settled(now_ms);
    toplevel.drag_lift_value = std.math.clamp(if (settled) toplevel.drag_lift.to else toplevel.drag_lift.value(now_ms), 1, @import("config").loader.drag_scale_max);
    if (settled) {
        toplevel.drag_lift.cancel(@floatCast(toplevel.drag_lift_value));
        if (live) {
            toplevel.applyVisualTransform(now_ms);
            input.processCursorMotion(0);
        }
    }
    return !settled;
}

pub fn clearDragLift(toplevel: *Toplevel) void {
    toplevel.drag_lift.cancel(1);
    toplevel.drag_lift_value = 1;
    if (toplevel.in_world) toplevel.applyVisualTransform(nowMs());
}

pub fn animOffset(a: anim.Anim, now_ms: i64) i32 {
    if (!a.active()) return 0;
    return @intFromFloat(@round(a.value(now_ms)));
}

/// Slides the frame `dx`/`dy` world units from where it is, or back with 0/0.
/// The offset is presentation only, so the window's real position, size and
/// input state are untouched; every path that ends the reason for it must call
/// this with zeros (or `clearDodge`).
pub fn setDodge(toplevel: *Toplevel, dx: f32, dy: f32) void {
    if (!toplevel.in_world) return;
    const now_ms = nowMs();
    const curve = anim.curveFor(.window_move);
    if (!toplevel.dodge_x.active()) toplevel.dodge_x = .{};
    if (!toplevel.dodge_y.active()) toplevel.dodge_y = .{};
    toplevel.dodge_x.retargetTo(now_ms, dx, curve);
    toplevel.dodge_y.retargetTo(now_ms, dy, curve);
    toplevel.applyVisualTransform(now_ms);
    toplevel.server.scheduleFrames();
}

/// Drops any displacement at once, for a window that stops being shown.
pub fn clearDodge(toplevel: *Toplevel) void {
    if (!toplevel.dodge_x.active() and !toplevel.dodge_y.active()) return;
    toplevel.dodge_x.cancel(0);
    toplevel.dodge_y.cancel(0);
    if (toplevel.in_world) toplevel.applyVisualTransform(nowMs());
}

pub fn tickDodge(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.dodge_x.active() and !toplevel.dodge_y.active()) return false;
    _ = toplevel.dodge_x.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.dodge_y.sampleChanged(now_ms, anim.quantum_px);
    if (toplevel.dodge_x.settled(now_ms) and toplevel.dodge_y.settled(now_ms)) {
        // Back at rest: forget the animation so the window is not ticked forever.
        if (toplevel.dodge_x.to == 0 and toplevel.dodge_y.to == 0) {
            toplevel.dodge_x.cancel(0);
            toplevel.dodge_y.cancel(0);
        }
        return false;
    }
    return true;
}

/// Brings the window in with its workspace: from (`from_x`, `from_y`) world
/// units away, faded out with `fade`, or from where it is when it was leaving.
pub fn switchIn(toplevel: *Toplevel, from_x: f32, from_y: f32, fade: bool) void {
    if (!toplevel.switch_leaving) {
        toplevel.switch_x = .{ .from = from_x, .to = from_x };
        toplevel.switch_y = .{ .from = from_y, .to = from_y };
        const start: f32 = if (fade) 0 else 1;
        toplevel.switch_fade = .{ .from = start, .to = start, .property = .opacity };
    }
    toplevel.setSwitchLeaving(false);
    toplevel.retargetSwitch(0, 0, 1);
}

/// Takes the window out with the workspace it is on, which is already hidden:
/// it stays shown, inert, until it reaches (`to_x`, `to_y`) or has faded.
pub fn switchOut(toplevel: *Toplevel, to_x: f32, to_y: f32, fade: bool) void {
    toplevel.setSwitchLeaving(true);
    toplevel.retargetSwitch(to_x, to_y, if (fade) 0 else 1);
}

pub fn retargetSwitch(toplevel: *Toplevel, x: f32, y: f32, opacity: f32) void {
    const now_ms = nowMs();
    const curve = anim.curveFor(.camera_desktop);
    toplevel.switch_x.retargetTo(now_ms, x, curve);
    toplevel.switch_y.retargetTo(now_ms, y, curve);
    toplevel.switch_fade.retargetTo(now_ms, opacity, curve);
    if (!toplevel.tickSwitch(now_ms)) return;
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
    toplevel.server.scheduleFrames();
}

pub fn setSwitchLeaving(toplevel: *Toplevel, leaving: bool) void {
    if (toplevel.switch_leaving == leaving) return;
    toplevel.switch_leaving = leaving;
    _ = projection.setTreeInert(&toplevel.frame_tree.node, leaving);
}

/// Ends a workspace switch at once; a window that was leaving is hidden.
pub fn finishSwitch(toplevel: *Toplevel) void {
    if (!toplevel.switch_x.active() and !toplevel.switch_y.active() and !toplevel.switch_fade.active() and !toplevel.switch_leaving) return;
    toplevel.switch_x.cancel(0);
    toplevel.switch_y.cancel(0);
    toplevel.switch_fade.cancel(1);
    toplevel.setSwitchLeaving(false);
    if (!toplevel.in_world) return;
    const now_ms = nowMs();
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
}

pub fn tickSwitch(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.switch_x.active() and !toplevel.switch_y.active() and !toplevel.switch_fade.active() and !toplevel.switch_leaving) return false;
    _ = toplevel.switch_x.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.switch_y.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.switch_fade.sampleChanged(now_ms, anim.quantum_alpha);
    if (toplevel.switch_x.settled(now_ms) and toplevel.switch_y.settled(now_ms) and toplevel.switch_fade.settled(now_ms)) {
        toplevel.finishSwitch();
        return false;
    }
    return true;
}

pub fn tickMove(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.move_x.active() and !toplevel.move_y.active()) return false;
    _ = toplevel.move_x.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.move_y.sampleChanged(now_ms, anim.quantum_px);
    if (toplevel.move_x.settled(now_ms) and toplevel.move_y.settled(now_ms)) {
        toplevel.move_x.cancel(@floatFromInt(toplevel.x));
        toplevel.move_y.cancel(@floatFromInt(toplevel.y));
        return false;
    }
    return true;
}

pub fn tickSize(toplevel: *Toplevel, now_ms: i64) bool {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) return false;
    const moving = !toplevel.size_w.settled(now_ms) or !toplevel.size_h.settled(now_ms);
    const quantum = anim.rasterPixelQuantum(toplevel.render_scale);
    const w_changed = toplevel.size_w.sampleChanged(now_ms, quantum);
    const h_changed = toplevel.size_h.sampleChanged(now_ms, quantum);
    // At rest the frame may give way to the size the client took.
    if (w_changed or h_changed or !moving) {
        toplevel.syncChrome(true, now_ms) catch |err| {
            log.err("tickSize: could not update window decoration: {}", .{err});
        };
    }
    return moving;
}

pub fn tickMap(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.map_motion.active() and !toplevel.map_opacity.active()) return false;
    _ = toplevel.map_motion.sampleChanged(now_ms, 0.001);
    _ = toplevel.map_opacity.sampleChanged(now_ms, anim.quantum_alpha);
    if (toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms)) {
        if (toplevel.closing) return false;
        toplevel.map_motion.cancel(1);
        toplevel.map_opacity.cancel(1);
        toplevel.launch_origin = null;
        return false;
    }
    return true;
}

pub fn closingFinished(toplevel: *const Toplevel, now_ms: i64) bool {
    return toplevel.closing and toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms);
}

/// Ends a finished close animation. Only a destroyed backend frees the
/// window: one that merely unmapped (a withdrawn X11 window, an app hiding to
/// its tray) still has listeners on its surface and may map again.
pub fn finishClose(toplevel: *Toplevel) void {
    if (toplevel.backend_gone) return toplevel.destroyNow();
    if (toplevel.close_snapshot) |snap| {
        snap.node.destroy();
        toplevel.close_snapshot = null;
    }
    if (toplevel.in_closing_list) {
        toplevel.closing_link.remove();
        toplevel.in_closing_list = false;
    }
    toplevel.closing = false;
    toplevel.clearChromeCache();
    toplevel.frame_tree.node.setEnabled(false);
    toplevel.scene_tree.setEnabled(true);
}
