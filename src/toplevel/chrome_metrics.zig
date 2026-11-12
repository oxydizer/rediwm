//! Toplevel chrome metrics: decoration, titlebar, border and frame boxes.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const col = @import("../color.zig");
const chrome = @import("../chrome.zig");
const geometry = @import("../geometry.zig");
const xdg = @import("../xdg.zig");

/// Only committed negotiation may change the frame, so the client and
/// compositor switch decorations with the same surface update. A fullscreen
/// window never draws our titlebar/border/footer regardless of the
/// negotiated mode — same as every other compositor, the whole point of
/// fullscreen is an edge-to-edge client surface with no window-manager
/// chrome eating into it.
pub fn hasServerDecorations(toplevel: *const Toplevel) bool {
    if (toplevel.backend_gone) return false;
    if (toplevel.isFullscreen()) return false;
    return switch (toplevel.backend) {
        .xdg => blk: {
            // KDE defines using both protocols as undefined; prefer XDG
            // and its configure/ack synchronization when available.
            if (toplevel.decoration) |decoration| {
                break :blk decoration.decoration.current.mode == .server_side;
            }
            break :blk if (toplevel.kde_decoration) |decoration| decoration.current == .server else false;
        },
        .xwayland => |*adapter| adapter.serverDecorations(),
        .placeholder, .shell => true,
    };
}

pub fn chromeDensity(toplevel: *const Toplevel) f32 {
    return switch (toplevel.backend) {
        .xwayland => 0.75,
        else => 1,
    };
}

pub fn titlebarHeight(toplevel: *const Toplevel) i32 {
    return if (toplevel.hasServerDecorations()) (chrome.Metrics{ .density = toplevel.chromeDensity() }).titlebarHeight() else 0;
}

pub fn borderWidth(toplevel: *const Toplevel) i32 {
    return if (toplevel.hasServerDecorations()) chrome.frameBorder() else 0;
}

pub fn hasWorkspaceFocusBorder(toplevel: *const Toplevel) bool {
    return toplevel.server.world.workspaces.active and toplevel.activated and !toplevel.isFullscreen();
}

pub fn borderColor(toplevel: *const Toplevel) col.Premul {
    return chrome.windowBorderColor(toplevel.last_painted_hover, toplevel.hasWorkspaceFocusBorder());
}

pub fn footerHeight(toplevel: *const Toplevel) i32 {
    if (!toplevel.hasServerDecorations()) return 0;
    return chrome.frameBorder();
}

pub fn frameLocal(toplevel: *const Toplevel, lx: f64, ly: f64) geometry.Vec2 {
    const point = toplevel.server.world.toWorld(lx, ly);
    const lift = toplevel.dragLiftOffset();
    const local = geometry.toLocal(point.x, point.y, toplevel.x - lift.x, toplevel.y - lift.y);
    const scale = toplevel.worldScale() * toplevel.drag_lift_value;
    return .{ .x = local.x / scale, .y = local.y / scale };
}

pub fn frameWorld(toplevel: *const Toplevel, x: f64, y: f64) geometry.Vec2 {
    const lift = toplevel.dragLiftOffset();
    const scale = toplevel.worldScale() * toplevel.drag_lift_value;
    return .{
        .x = @as(f64, @floatFromInt(toplevel.x - lift.x)) + x * scale,
        .y = @as(f64, @floatFromInt(toplevel.y - lift.y)) + y * scale,
    };
}
