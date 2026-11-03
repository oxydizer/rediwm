//! Toplevel chrome clicks, minimize and restore.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const Input = @import("../Input.zig");
const chrome = @import("../chrome.zig");
const events = @import("../ipc/events.zig");
const xdg = @import("../xdg.zig");
const fromSurface = Toplevel.fromSurface;

pub fn controlAt(toplevel: *Toplevel, sx: f64, sy: f64) ?chrome.ControlKind {
    if (!toplevel.hasServerDecorations() or sy >= @as(f64, @floatFromInt(toplevel.titlebarHeight()))) return null;
    const width = toplevel.chrome_width - toplevel.controlInsets().right;
    inline for (.{ chrome.ControlKind.close, .maximize, .minimize }) |kind| {
        if (chrome.controlRectScaled(width, kind, toplevel.chromeDensity()).contains(sx, sy)) return kind;
    }
    return null;
}

pub fn handleChromeClick(toplevel: *Toplevel, sx: f64, sy: f64, button: u32) void {
    if (!toplevel.hasServerDecorations() or sy >= @as(f64, @floatFromInt(toplevel.titlebarHeight()))) return;

    const hit = toplevel.tabAt(sx, sy);
    if (hit != .none) {
        if (button != Input.btn_left) return;
        switch (hit) {
            .tab => |id| if (toplevel.server.findToplevelById(id)) |target| toplevel.server.world.focus(target),
            .close => |id| if (toplevel.server.findToplevelById(id)) |target| {
                toplevel.server.world.focus(target);
                target.sendClose();
            },
            .plus => toplevel.server.window_tabs.launch(toplevel),
            .previous => toplevel.stepTab(false),
            .next => toplevel.stepTab(true),
            .none => {},
        }
        return;
    }
    if (toplevel.controlAt(sx, sy)) |kind| switch (kind) {
        .close => @import("../window_tabs.zig").closeGroup(toplevel),
        .maximize => toplevel.toggleMaximize(),
        .minimize => toplevel.minimize(),
    } else if (button == Input.btn_left) {
        toplevel.beginMove();
    }
}

// The client stays mapped while minimized. xdg-shell v6 reports suspended
// so native clients can stop background work until restore.
pub fn minimize(toplevel: *Toplevel) void {
    if (toplevel.tab_hidden) {
        if (@import("../window_tabs.zig").active(toplevel.server, toplevel.tab_group)) |active_tab| active_tab.minimize();
        return;
    }
    // X11 clients can ask for this while withdrawn; the stack reorder below
    // needs the window to be in it.
    if (toplevel.minimized or !toplevel.in_world) return;
    toplevel.detachInput();
    toplevel.finishSwitch();
    @import("../effects/window_minimize.zig").start(toplevel);
    toplevel.minimized = true;
    toplevel.frame_tree.node.setEnabled(false);

    const server = toplevel.server;
    if (server.input.seat.keyboard_state.focused_surface) |focused| {
        if (fromSurface(server, focused) == toplevel) server.input.seat.keyboardNotifyClearFocus();
    }
    toplevel.setActivated(false);
    switch (toplevel.backend) {
        .xwayland => |*adapter| {
            adapter.xsurface.setMinimized(true);
            adapter.xsurface.restack(null, .below);
        },
        .xdg => |*adapter| {
            _ = adapter.xdg_toplevel.setSuspended(true);
        },
        .placeholder, .shell => {},
    }

    // Move to the back of the stack so the taskbar's active-window mark and
    // the F1 cycle both skip past minimized windows.
    toplevel.link.remove();
    server.world.toplevels.append(toplevel);

    server.refreshTaskbars();
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }

    if (toplevel.tab_group != 0) @import("../window_tabs.zig").refreshVisibility(server);
    if (server.world.workspaces.active) @import("../workspaces.zig").focusFallback(server, toplevel.workspace_id);
    // Must run last: content_tree stays alive and rendering-ready while
    // minimized (only the frame is hidden), so a window-capture source
    // over it wouldn't otherwise notice — unlike a real close, nothing
    // here destroys the scene node to trigger WindowCaptureSource's
    // graceful stop. The failure contract's "minimize: End the selected
    // source's session" row needs this explicit hard-disconnect fallback
    // instead — and since the capturing client can be this same toplevel's
    // own client (self-capture), disconnecting it can free `toplevel`
    // itself; nothing above this point may run afterward.
    if (server.capture_mgr) |cm| {
        cm.stopForWindow(toplevel.id, @import("../capture/manager.zig").failure_window_closed);
    }
}

pub fn restore(toplevel: *Toplevel) void {
    toplevel.server.window_tabs.select(toplevel);
    defer if (toplevel.tab_group != 0) @import("../window_tabs.zig").refreshVisibility(toplevel.server);
    if (!toplevel.minimized or !toplevel.in_world) return;
    @import("../effects/window_minimize.zig").cancelFor(toplevel.server, toplevel.id);
    toplevel.minimized = false;
    toplevel.frame_tree.node.setEnabled(@import("../window_tabs.zig").visible(toplevel));
    switch (toplevel.backend) {
        .xwayland => |*adapter| adapter.xsurface.setMinimized(false),
        .xdg => |*adapter| {
            _ = adapter.xdg_toplevel.setSuspended(false);
        },
        .placeholder, .shell => {},
    }
    toplevel.server.world.focus(toplevel);
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }
}
