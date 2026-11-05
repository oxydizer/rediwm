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
    toplevel.frame_tree.node.raiseToTop();
    toplevel.syncXwaylandStack();
}

pub fn syncXwaylandStack(toplevel: *Toplevel) void {
    if (toplevel.backend != .xwayland or toplevel.backend_gone) return;
    if (!@import("../workspaces.zig").visible(toplevel)) {
        toplevel.backend.xwayland.xsurface.restack(null, .below);
        return;
    }
    // Use the nearest managed X11 sibling above us. This also covers an
    // initially unfocused window placed below a focused Wayland window.
    if (toplevel.frame_tree.node.parent) |parent| {
        var found_self = false;
        var it = parent.children.iterator(.forward);
        while (it.next()) |node| {
            if (node == &toplevel.frame_tree.node) {
                found_self = true;
                continue;
            }
            if (!found_self) continue;
            const data = scene_data.SceneData.fromNode(node) orelse continue;
            if (data.role != .toplevel) continue;
            const other = data.role.toplevel;
            if (!other.in_world or other.minimized or !@import("../workspaces.zig").visible(other) or other.backend_gone or other.backend != .xwayland) continue;
            toplevel.backend.xwayland.xsurface.restack(other.backend.xwayland.xsurface, .below);
            return;
        }
    }
    toplevel.backend.xwayland.xsurface.restack(null, .above);
}

pub fn setActivated(toplevel: *Toplevel, activated: bool) void {
    const changed = toplevel.activated != activated;
    toplevel.activated = activated;
    if (!activated) toplevel.setGlow(null);
    if (toplevel.wlr_foreign) |handle| handle.setActivated(activated);
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setActivated(activated),
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
