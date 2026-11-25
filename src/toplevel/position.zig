//! Toplevel position: moves, output changes and remembered output disconnects.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const xscale = @import("../xwayland_scale.zig");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const events = @import("../ipc/events.zig");
const xdg = @import("../xdg.zig");
const anim = @import("ui").anim;
const nowMs = Toplevel.nowMs;

pub fn setPosition(toplevel: *Toplevel, x: i32, y: i32) void {
    toplevel.move_x.cancel(@floatFromInt(x));
    toplevel.move_y.cancel(@floatFromInt(y));
    commitPosition(toplevel, x, y, true);
}

/// Move a normal window to the selected output while preserving its offset
/// from the old usable area where possible. Maximized and fullscreen windows
/// are refit directly because their geometry is owned by the target output.
pub fn moveToOutput(toplevel: *Toplevel, output: *Output) bool {
    if (!toplevel.in_world or !output.isAvailable()) return false;
    if (toplevel.server.world.workspaces.active) {
        toplevel.server.world.workspaces.moveTo(toplevel, output.workspace_id);
        return true;
    }
    if (toplevel.isMaximized()) {
        toplevel.setMaximizedOn(output);
        return true;
    }
    if (toplevel.isFullscreen()) {
        toplevel.setFullscreenOn(output);
        return true;
    }
    if (toplevel.tile) |tile| {
        toplevel.setTiledOn(output, tile);
        return true;
    }

    const source = toplevel.currentOutput() orelse output;
    return toplevel.moveFromUsableToOutput(source.usableBox(), output);
}

pub fn moveFromUsableToOutput(toplevel: *Toplevel, source_box: wlr.Box, output: *Output) bool {
    if (!toplevel.in_world or !output.isAvailable()) return false;
    toplevel.finishMoveAnimation();
    const target = output.usableBox();
    if (target.width <= 0 or target.height <= 0) return false;
    const layout_position = toplevel.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
    const offset_x = @as(i32, @intFromFloat(@round(layout_position.x))) - source_box.x;
    const offset_y = @as(i32, @intFromFloat(@round(layout_position.y))) - source_box.y;
    const frame_w: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom()));
    const frame_h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom()));
    const max_x = @max(target.x, target.x + target.width - @max(frame_w, 1));
    const max_y = @max(target.y, target.y + target.height - @max(frame_h, 1));
    const target_layout_x = std.math.clamp(target.x + offset_x, target.x, max_x);
    const target_layout_y = std.math.clamp(target.y + offset_y, target.y, max_y);
    const world_position = toplevel.server.world.toWorld(@floatFromInt(target_layout_x), @floatFromInt(target_layout_y));
    toplevel.setPosition(
        @intFromFloat(@round(world_position.x)),
        @intFromFloat(@round(world_position.y)),
    );
    return true;
}

pub fn rememberOutputDisconnect(toplevel: *Toplevel, output_name: []const u8, source_box: wlr.Box) void {
    // A window moved off an output that went away keeps that home while it
    // stays where it was put: when the output it was moved to goes too (two
    // monitors dropping on a wake from sleep, or a closed lid's panel standing
    // in and hidden again), it is displaced again, not rehomed.
    if (hasOutputDisconnect(toplevel)) return;
    if (output_name.len == 0 or output_name.len > toplevel.reconnect_output.len) {
        toplevel.reconnect_output_len = 0;
        return;
    }
    const layout_position = toplevel.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
    std.mem.copyForwards(u8, toplevel.reconnect_output[0..output_name.len], output_name);
    toplevel.reconnect_output_len = output_name.len;
    toplevel.reconnect_expected_x = toplevel.x;
    toplevel.reconnect_expected_y = toplevel.y;
    toplevel.reconnect_offset_x = @as(i32, @intFromFloat(@round(layout_position.x))) - source_box.x;
    toplevel.reconnect_offset_y = @as(i32, @intFromFloat(@round(layout_position.y))) - source_box.y;
    toplevel.reconnect_maximized = toplevel.isMaximized();
    toplevel.reconnect_fullscreen = toplevel.isFullscreen();
    toplevel.reconnect_tile = toplevel.tile;
}

/// The window waits for an output that went away and hasn't been moved since.
pub fn hasOutputDisconnect(toplevel: *const Toplevel) bool {
    return toplevel.reconnect_output_len != 0 and
        toplevel.x == toplevel.reconnect_expected_x and toplevel.y == toplevel.reconnect_expected_y;
}

pub fn markOutputDisconnectPosition(toplevel: *Toplevel) void {
    toplevel.reconnect_expected_x = toplevel.x;
    toplevel.reconnect_expected_y = toplevel.y;
}

pub fn clearOutputDisconnect(toplevel: *Toplevel) void {
    toplevel.reconnect_output_len = 0;
    toplevel.reconnect_maximized = false;
    toplevel.reconnect_fullscreen = false;
    toplevel.reconnect_tile = null;
}

pub fn restoreOutputDisconnect(toplevel: *Toplevel, output: *Output) bool {
    if (toplevel.reconnect_output_len == 0 or
        !std.mem.eql(u8, toplevel.reconnect_output[0..toplevel.reconnect_output_len], std.mem.span(output.wlr_output.name))) return false;
    if (toplevel.x != toplevel.reconnect_expected_x or toplevel.y != toplevel.reconnect_expected_y) {
        clearOutputDisconnect(toplevel);
        return false;
    }
    if (!toplevel.in_world or !output.isAvailable()) return false;
    if (toplevel.reconnect_maximized) {
        toplevel.setMaximizedOn(output);
    } else if (toplevel.reconnect_fullscreen) {
        toplevel.setFullscreenOn(output);
    } else if (toplevel.reconnect_tile) |tile| {
        toplevel.setTiledOn(output, tile);
    } else {
        const target = output.usableBox();
        if (target.width <= 0 or target.height <= 0) return false;
        const frame_w: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom()));
        const frame_h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom()));
        const max_x = @max(target.x, target.x + target.width - @max(frame_w, 1));
        const max_y = @max(target.y, target.y + target.height - @max(frame_h, 1));
        const target_layout_x = std.math.clamp(target.x + toplevel.reconnect_offset_x, target.x, max_x);
        const target_layout_y = std.math.clamp(target.y + toplevel.reconnect_offset_y, target.y, max_y);
        const world_position = toplevel.server.world.toWorld(@floatFromInt(target_layout_x), @floatFromInt(target_layout_y));
        toplevel.setPosition(@intFromFloat(@round(world_position.x)), @intFromFloat(@round(world_position.y)));
    }
    clearOutputDisconnect(toplevel);
    return true;
}

/// Programmatic moves (maximize/restore, IPC, forced geometry). Direct
/// pointer drags keep using `setPosition` so the frame stays 1:1 with the
/// cursor.
pub fn setPositionAnimated(toplevel: *Toplevel, x: i32, y: i32) void {
    if (!toplevel.in_world or (toplevel.server.input.cursor_mode == .move and toplevel.server.input.grabbed_toplevel == toplevel) or toplevel.isResizing()) {
        toplevel.setPosition(x, y);
        return;
    }
    const now_ms = nowMs();
    const from_x = visualX(toplevel, now_ms);
    const from_y = visualY(toplevel, now_ms);
    if (!toplevel.move_x.active()) {
        toplevel.move_x = .{ .from = @floatFromInt(from_x), .to = @floatFromInt(from_x) };
    }
    if (!toplevel.move_y.active()) {
        toplevel.move_y = .{ .from = @floatFromInt(from_y), .to = @floatFromInt(from_y) };
    }
    const curve = anim.curveFor(.window_move);
    toplevel.move_x.retargetTo(now_ms, @floatFromInt(x), curve);
    toplevel.move_y.retargetTo(now_ms, @floatFromInt(y), curve);
    commitPosition(toplevel, x, y, false);
    toplevel.applyVisualTransform(now_ms);
    if (toplevel.move_x.settled(now_ms) and toplevel.move_y.settled(now_ms)) {
        toplevel.move_x.cancel(@floatFromInt(x));
        toplevel.move_y.cancel(@floatFromInt(y));
        toplevel.applyVisualTransform(now_ms);
    } else {
        toplevel.server.scheduleFrames();
    }
}

pub fn commitPosition(toplevel: *Toplevel, x: i32, y: i32, update_scene: bool) void {
    const moved = toplevel.x != x or toplevel.y != y;
    toplevel.x = x;
    toplevel.y = y;
    if (update_scene) toplevel.applyVisualTransform(nowMs());
    if (moved) toplevel.server.scheduleFrames();
    toplevel.server.world.ensureToplevelInBounds(toplevel);
    if (moved) {
        if (!toplevel.isResizing() and !toplevel.backend_gone) {
            switch (toplevel.backend) {
                .xwayland => |*adapter| {
                    const geom = toplevel.clientSurfaceGeometry();
                    if (geom.width > 0 and geom.height > 0) {
                        const n = toplevel.surfaceScale();
                        adapter.configure(
                            xscale.surfacePosition((x + toplevel.borderWidth()), n),
                            xscale.surfacePosition((y + toplevel.titlebarHeight()), n),
                            if (toplevel.auto_target != null and !toplevel.maximized and !toplevel.fullscreen) xscale.surfaceLength(toplevel.auto_target.?.width, n) else geom.width,
                            if (toplevel.auto_target != null and !toplevel.maximized and !toplevel.fullscreen) xscale.surfaceLength(toplevel.auto_target.?.height, n) else geom.height,
                        );
                    }
                },
                .xdg, .placeholder, .shell => {},
            }
        }
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowMoved(ipc, toplevel.id, x, y);
        }
        if (toplevel.server.idle) |im| {
            im.recheckInhibitors();
        }
    }
}

pub fn logicalWidth(toplevel: *const Toplevel) i32 {
    if (toplevel.size_w.settle_ms > 0) return @intFromFloat(@round(toplevel.size_w.to));
    return toplevel.chrome_width;
}

pub fn logicalHeight(toplevel: *const Toplevel) i32 {
    if (toplevel.size_h.settle_ms > 0) return @intFromFloat(@round(toplevel.size_h.to));
    return toplevel.chrome_height;
}

pub fn visualX(toplevel: *const Toplevel, now_ms: i64) i32 {
    if (toplevel.move_x.active()) return @intFromFloat(@round(toplevel.move_x.value(now_ms)));
    return toplevel.x;
}

pub fn visualY(toplevel: *const Toplevel, now_ms: i64) i32 {
    if (toplevel.move_y.active()) return @intFromFloat(@round(toplevel.move_y.value(now_ms)));
    return toplevel.y;
}
