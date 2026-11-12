//! Toplevel zoom: per-window zoom state, boost and animation.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const Server = @import("../Server.zig");
const resize = @import("../resize.zig");
const projection = @import("../projection.zig");
const anim = @import("ui").anim;
const log = std.log.scoped(.toplevel);
const nowMs = Toplevel.nowMs;

/// On-screen logical scale, combining window and camera zoom (before output DPI).
pub fn zoom(toplevel: *const Toplevel) f64 {
    return toplevel.worldScale() * toplevel.server.world.camera.zoom();
}

/// Client units to presented world units, including the temporary focus boost.
/// The saved frame position, client size and zoom_index remain unchanged.
pub fn worldScale(toplevel: *const Toplevel) f64 {
    if (toplevel.server.world.workspaces.active) return 1;
    return @import("../camera.zig").boostedScale(toplevel.zoom_scale, toplevel.server.world.camera.zoom(), toplevel.zoom_boost_value);
}

pub fn setZoomBoost(toplevel: *Toplevel, enabled: bool) void {
    const target: f32 = if (enabled and toplevel.layout() == .floating and !toplevel.isFullscreen()) 1 else 0;
    if (toplevel.zoom_boost.to == target) return;
    const now = nowMs();
    toplevel.zoom_boost.retargetTo(now, target, anim.curveFor(.window_zoom));
    _ = toplevel.tickZoomBoost(now);
    toplevel.server.scheduleFrames();
}

pub fn tickZoomBoost(toplevel: *Toplevel, now: i64) bool {
    const live = toplevel.zoom_boost.active();
    const settled = toplevel.zoom_boost.settled(now);
    toplevel.zoom_boost_value = if (settled) toplevel.zoom_boost.to else toplevel.zoom_boost.value(now);
    if (settled) {
        toplevel.zoom_boost.cancel(@floatCast(toplevel.zoom_boost_value));
        if (live) {
            toplevel.syncForeign();
            toplevel.server.input.processCursorMotion(0);
        }
    }
    return !settled;
}

pub fn clearZoomBoost(toplevel: *Toplevel) void {
    toplevel.zoom_boost.cancel(0);
    toplevel.zoom_boost_value = 0;
}

/// Explicit window zoom takes over from the temporary boost without a jump.
pub fn takeZoomBoost(toplevel: *Toplevel) void {
    if (toplevel.zoom_boost_value == 0 and toplevel.zoom_boost.to == 0) return;
    toplevel.zoom_scale = toplevel.worldScale();
    toplevel.zoom_anim.cancel(@floatCast(toplevel.zoom_scale));
    toplevel.clearZoomBoost();
}

pub fn cameraFocusOpacity(toplevel: *const Toplevel) f32 {
    if (toplevel.server.world.workspaces.active) return 1;
    if (toplevel.server.config.compositor.focus_zoom != .camera or toplevel.layout() != .floating or toplevel.isFullscreen()) return 1;
    // Windows passed by the camera fade away, and stop accepting input once
    // invisible. Reversing the zoom reveals the same retained scene again.
    return @floatCast(std.math.clamp((1.05 - toplevel.zoom()) / 0.05, 0, 1));
}

pub fn finishZoomAnimation(toplevel: *Toplevel) void {
    if (!toplevel.zoom_anim.active()) return;
    const target_scale = @as(f64, @floatFromInt(@import("../camera.zig").zoom_levels[toplevel.zoom_index])) / 100;
    toplevel.zoom_scale = target_scale;
    toplevel.zoom_anim = .{ .from = @floatCast(target_scale), .to = @floatCast(target_scale) };
    const target_ws = target_scale;
    const target_x = toplevel.zoom_anchor.x - toplevel.zoom_local.x * target_ws;
    const target_y = toplevel.zoom_anchor.y - toplevel.zoom_local.y * target_ws;
    toplevel.setPosition(@intFromFloat(@round(target_x)), @intFromFloat(@round(target_y)));
    toplevel.syncChrome(false, nowMs()) catch {};
}

pub fn tickZoom(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.zoom_anim.active()) return false;
    _ = toplevel.zoom_anim.sampleChanged(now_ms, 0.001);
    const settled = toplevel.zoom_anim.settled(now_ms);
    const target_scale = @as(f64, @floatFromInt(@import("../camera.zig").zoom_levels[toplevel.zoom_index])) / 100;
    const current_scale: f64 = if (settled)
        target_scale
    else
        @as(f64, toplevel.zoom_anim.value(now_ms));

    toplevel.zoom_scale = current_scale;

    const current_ws = current_scale;
    const nx = toplevel.zoom_anchor.x - toplevel.zoom_local.x * current_ws;
    const ny = toplevel.zoom_anchor.y - toplevel.zoom_local.y * current_ws;

    if (settled) {
        toplevel.zoom_anim = .{ .from = @floatCast(target_scale), .to = @floatCast(target_scale) };
        toplevel.setPosition(@intFromFloat(@round(nx)), @intFromFloat(@round(ny)));
        toplevel.syncChrome(false, now_ms) catch {};
        toplevel.server.input.processCursorMotion(0);
        return false;
    } else {
        const round_x: i32 = @intFromFloat(@round(nx));
        const round_y: i32 = @intFromFloat(@round(ny));
        const moved = toplevel.x != round_x or toplevel.y != round_y;
        toplevel.x = round_x;
        toplevel.y = round_y;
        if (moved) toplevel.server.world.ensureToplevelInBounds(toplevel);
        return true;
    }
}

pub fn setZoom(toplevel: *Toplevel, index: usize, lx: f64, ly: f64) void {
    if (toplevel.server.world.workspaces.active) return;
    toplevel.takeZoomBoost();
    const next = @min(index, @import("../camera.zig").zoom_levels.len - 1);
    if (next == toplevel.zoom_index and toplevel.zoom_scale == @as(f64, @floatFromInt(@import("../camera.zig").zoom_levels[next])) / 100) return;

    // Record for undo before modifying state.
    {
        const geom = toplevel.clientGeometry();
        const now_ms = @import("../Server.zig").undoNowMs();
        toplevel.server.undo.record(.{
            .kind = .window_zoom,
            .press_seq = toplevel.server.undo.press_seq,
            .at_ms = now_ms,
            .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = geom.width, .height = geom.height, .zoom_index = toplevel.zoom_index },
        }, now_ms);
    }
    const local = toplevel.frameLocal(lx, ly);
    const anchor = toplevel.server.world.toWorld(lx, ly);
    const scale = @as(f64, @floatFromInt(@import("../camera.zig").zoom_levels[next])) / 100;
    if (!@import("../projection.zig").setTreeZoom(&toplevel.frame_tree.node, scale)) {
        log.err("cannot allocate window zoom", .{});
        return;
    }
    toplevel.zoom_index = next;
    toplevel.zoom_scale = scale;
    toplevel.zoom_anim = .{ .from = @floatCast(scale), .to = @floatCast(scale) };
    // Keep the point under the pointer fixed, without resizing the client.
    toplevel.setPosition(@intFromFloat(@round(anchor.x - local.x * toplevel.worldScale())), @intFromFloat(@round(anchor.y - local.y * toplevel.worldScale())));
    toplevel.server.world.syncPresentation();
    toplevel.server.scheduleFrames();
    toplevel.server.input.processCursorMotion(0);
}

pub fn setZoomAnimated(toplevel: *Toplevel, index: usize, lx: f64, ly: f64) void {
    if (toplevel.server.world.workspaces.active) return;
    toplevel.takeZoomBoost();
    const next = @min(index, @import("../camera.zig").zoom_levels.len - 1);
    const target_scale = @as(f64, @floatFromInt(@import("../camera.zig").zoom_levels[next])) / 100;

    if (next == toplevel.zoom_index and toplevel.zoom_scale == target_scale and !toplevel.zoom_anim.active()) return;

    // Record for undo before modifying state.
    {
        const geom = toplevel.clientGeometry();
        const undo_ms = @import("../Server.zig").undoNowMs();
        toplevel.server.undo.record(.{
            .kind = .window_zoom,
            .press_seq = toplevel.server.undo.press_seq,
            .at_ms = undo_ms,
            .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = geom.width, .height = geom.height, .zoom_index = toplevel.zoom_index },
        }, undo_ms);
    }

    toplevel.finishMoveAnimation();

    const local = toplevel.frameLocal(lx, ly);
    const anchor = toplevel.server.world.toWorld(lx, ly);

    _ = @import("../projection.zig").setTreeZoom(&toplevel.frame_tree.node, toplevel.zoom_scale);

    toplevel.zoom_index = next;
    toplevel.zoom_anchor = .{ .x = anchor.x, .y = anchor.y };
    toplevel.zoom_local = .{ .x = local.x, .y = local.y };

    if (!toplevel.zoom_anim.active()) {
        toplevel.zoom_anim.from = @floatCast(toplevel.zoom_scale);
        toplevel.zoom_anim.to = @floatCast(toplevel.zoom_scale);
    }

    const now_ms = nowMs();
    toplevel.zoom_anim.retargetTo(now_ms, @floatCast(target_scale), anim.curveFor(.window_zoom));

    toplevel.server.scheduleFrames();
    toplevel.server.input.processCursorMotion(0);
}

// Shell windows have no surface commit, so apply the fixed-edge position as
// soon as their size changes too.
pub fn positionDuringResize(toplevel: *Toplevel) void {
    const session = toplevel.server.input.resize_session orelse return;
    const snapshot = if (session.toplevel == toplevel)
        session.snapshot
    else blk: {
        const peer = session.peer orelse return;
        if (peer.toplevel != toplevel) return;
        break :blk peer.snapshot;
    };
    const geom = toplevel.clientGeometry();
    if (geom.width > 0 and geom.height > 0) {
        const pos = resize.computeFramePosition(snapshot, geom.width, geom.height);
        const initial_x = snapshot.initial_frame_x;
        const initial_y = snapshot.initial_frame_y;
        // The fixed opposite edge is in displayed world coordinates.
        const dx: f64 = @floatFromInt(pos.x - initial_x);
        const dy: f64 = @floatFromInt(pos.y - initial_y);
        toplevel.setPosition(
            initial_x + @as(i32, @intFromFloat(@round(dx * toplevel.worldScale()))),
            initial_y + @as(i32, @intFromFloat(@round(dy * toplevel.worldScale()))),
        );
        if (session.peer != null and toplevel.tile != null) {
            if (toplevel.tile_target) |*target| {
                target.x = toplevel.x;
                target.y = toplevel.y;
                target.width = geom.width;
                target.height = geom.height;
            }
        }
    }
}

pub fn setZoomOrigin(toplevel: *Toplevel, index: usize) void {
    const next = @min(index, @import("../camera.zig").zoom_levels.len - 1);
    const scale = @as(f64, @floatFromInt(@import("../camera.zig").zoom_levels[next])) / 100;
    if (!@import("../projection.zig").setTreeZoom(&toplevel.frame_tree.node, scale)) {
        log.err("cannot allocate window zoom", .{});
        return;
    }
    toplevel.zoom_index = next;
    toplevel.zoom_scale = scale;
    toplevel.zoom_anim = .{ .from = @floatCast(scale), .to = @floatCast(scale) };
}
