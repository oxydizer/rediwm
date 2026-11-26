//! Toplevel stacking, activation and closing.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const scene_data = @import("../scene_data.zig");
const xdg = @import("../xdg.zig");
const xwayland_surface = @import("../xwayland_surface.zig");
const log = std.log.scoped(.toplevel);
const nowMs = Toplevel.nowMs;

/// Keep X11's input stacking in step with the displayed scene. Xwayland
/// resolves pointer events against its own root window stack even when our
/// scene hit test already selected the right surface.
pub fn raise(toplevel: *Toplevel) void {
    // A scrolling workspace keeps its floating windows above the strip.
    if (@import("../scroll_tiling.zig").raiseFloor(toplevel)) |floating|
        toplevel.frame_tree.node.placeBelow(&floating.frame_tree.node)
    else
        toplevel.frame_tree.node.raiseToTop();
    toplevel.syncXwaylandStack();
}

pub fn syncXwaylandStack(toplevel: *Toplevel) void {
    if (toplevel.backend != .xwayland or toplevel.backend_gone) return;
    if (!@import("../workspaces.zig").visible(toplevel)) {
        toplevel.backend.xwayland.xsurface.restack(null, .below);
        return;
    }
    // Within each workspace, use the nearest managed sibling above us in
    // scene order. A window on another workspace stays below the entire
    // pointer workspace, even if it has just opened or taken keyboard focus.
    const preferred = if (toplevel.server.xwayland) |xw| xw.pointer_workspace else 0;
    const local = preferred != 0 and toplevel.workspace_id == preferred;
    var first_preferred: ?*@import("wlroots").XwaylandSurface = null;
    if (toplevel.frame_tree.node.parent) |parent| {
        var found_self = false;
        var it = parent.children.iterator(.forward);
        while (it.next()) |node| {
            if (node == &toplevel.frame_tree.node) {
                found_self = true;
                continue;
            }
            const data = scene_data.SceneData.fromNode(node) orelse continue;
            if (data.role != .toplevel) continue;
            const other = data.role.toplevel;
            if (!other.in_world or other.minimized or other.backend_gone or other.backend != .xwayland or !@import("../workspaces.zig").visible(other)) continue;
            if (preferred != 0 and !@import("../window_tabs.zig").visible(other)) continue;
            if (preferred != 0 and (other.workspace_id == preferred) != local) {
                if (!local and first_preferred == null) first_preferred = other.backend.xwayland.xsurface;
                continue;
            }
            if (!found_self) continue;
            toplevel.backend.xwayland.xsurface.restack(other.backend.xwayland.xsurface, .below);
            return;
        }
    }
    if (first_preferred) |above| {
        toplevel.backend.xwayland.xsurface.restack(above, .below);
    } else toplevel.backend.xwayland.xsurface.restack(null, .above);
}

pub fn setActivated(toplevel: *Toplevel, activated: bool) void {
    const changed = toplevel.activated != activated;
    toplevel.activated = activated;
    if (!activated) toplevel.setGlow(null);
    if (toplevel.wlr_foreign) |handle| handle.setActivated(activated);
    switch (toplevel.backend) {
        // wlroots sends a configure on every call; an unchanged one reads to
        // Wine as a restore when it reaches a window it minimized itself.
        .xdg => |*adapter| if (adapter.xdg_toplevel.scheduled.activated != activated) {
            _ = adapter.xdg_toplevel.setActivated(activated);
        },
        .xwayland => |*adapter| {
            if (activated) {
                switch (adapter.xsurface.icccmInputModel()) {
                    .none => {},
                    .passive => adapter.xsurface.activate(true),
                    .local, .global => xwayland_surface.offerFocus(adapter.xsurface),
                }
            } else {
                adapter.xsurface.activate(false);
            }
        },
        .placeholder => {},
        .shell => |*sw| if (sw.control_center) |cc| cc.setActivated(activated),
    }
    if (changed and toplevel.in_world) toplevel.syncChrome(false, nowMs()) catch |err| {
        log.warn("activation: could not repaint title: {}", .{err});
    };
}

/// Publishes state, title, output and parent changes to wlr foreign-toplevel
/// clients; unchanged values send nothing.
pub fn syncForeign(toplevel: *Toplevel) void {
    @import("../auto_tiling.zig").observe(toplevel);
    if (toplevel.wlr_foreign) |handle| handle.sync();
}

pub fn sendClose(toplevel: *Toplevel) void {
    switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.sendClose(),
        .xwayland => |*adapter| adapter.xsurface.close(),
        .placeholder => |*ph| ph.cancel(toplevel),
        .shell => |*sw| if (sw.control_center) |cc| cc.close(),
    }
}

/// Bypass the client's close handler, including an unresponsive application.
pub fn forceClose(toplevel: *Toplevel) void {
    switch (toplevel.backend) {
        .xdg => {
            const client = toplevel.waylandClient() orelse return;
            const pid = client.getCredentials().pid;
            if (pid > 1 and pid != std.c.getpid()) std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            client.destroy();
        },
        .xwayland => |*adapter| if (toplevel.server.xwayland) |xwayland| xwayland.forceClose(adapter.xsurface.window_id),
        .placeholder => |*ph| {
            if (ph.pid) |pid| {
                if (pid > 1 and pid != std.c.getpid()) std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            }
            ph.cancel(toplevel);
        },
        .shell => toplevel.sendClose(),
    }
}
