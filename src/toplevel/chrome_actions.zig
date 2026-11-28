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
        if (chrome.controlRectFor(width, kind, toplevel.chromeMetrics()).contains(sx, sy)) return kind;
    }
    return null;
}

pub fn handleChromeClick(toplevel: *Toplevel, sx: f64, sy: f64, button: u32) void {
    if (!toplevel.hasServerDecorations() or sy >= @as(f64, @floatFromInt(toplevel.titlebarHeight()))) return;

    const hit = toplevel.tabAt(sx, sy);
    if (hit != .none) {
        // Tabs the client published: it owns them, so a click is a request.
        // (A left press on a tab itself is tracked from the button handler, so
        // it can become a reorder; this is the fallback and the other buttons.)
        if (toplevel.titlebar_tabs) |published| if (published.active()) {
            if (button == Input.btn_middle) {
                if (hit == .tab) published.sendClose(hit.tab);
                return;
            }
            if (button != Input.btn_left) return;
            switch (hit) {
                .tab => |id| published.sendSelect(id),
                .close => |id| published.sendClose(id),
                .plus => published.sendNewTab(),
                .previous => published.step(false),
                .next => published.step(true),
                .leading => toplevel.activateLeading(),
                .none => {},
            }
            return;
        };
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
            .leading, .none => {},
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
// so native clients can stop background work until restore. Dialogs are not
// minimized with their owner but hidden with it (`window_tabs.visible`), and
// show again when it is restored.
pub fn minimize(toplevel: *Toplevel) void {
    if (toplevel.tab_hidden) {
        if (@import("../window_tabs.zig").active(toplevel.server, toplevel.tab_group)) |active_tab| active_tab.minimize();
        return;
    }
    // A modal dialog goes with the owner it holds: minimized alone, it would
    // leave behind an owner that ignores input.
    var owner = toplevel;
    for (0..8) |_| {
        if (!owner.isModal()) break;
        owner = owner.owner() orelse break;
    }
    if (owner != toplevel and !owner.isModal()) return owner.minimize();
    // X11 clients can ask for this while withdrawn; the stack reorder below
    // needs the window to be in it.
    if (toplevel.minimized or !toplevel.in_world) return;
    // The flame snapshots the shown window, and a minimized window's frame is
    // hidden by the visual sync in detachInput (window_tabs.visible), so with
    // the flame on the flag is set after the snapshot. Off, it is set first, as
    // it always was.
    const flame = @import("../effects/window_minimize.zig").wanted(toplevel.server);
    if (!flame) toplevel.minimized = true;
    toplevel.detachInput();
    toplevel.finishSwitch();
    if (flame) {
        @import("../effects/window_minimize.zig").start(toplevel);
        toplevel.minimized = true;
    }
    toplevel.frame_tree.node.setEnabled(false);

    const server = toplevel.server;
    // One of its dialogs may hold the focus; it is hidden with the owner.
    const front = server.world.toplevels.first();
    const held_focus = if (front) |f| f.activated and (f == toplevel or isDialogOf(f, toplevel)) else false;
    if (server.input.seat.keyboard_state.focused_surface) |focused| {
        if (fromSurface(server, focused)) |holder| {
            if (holder == toplevel or isDialogOf(holder, toplevel)) server.input.seat.keyboardNotifyClearFocus();
        }
    }
    toplevel.setActivated(false);
    if (held_focus and front.? != toplevel) front.?.setActivated(false);
    switch (toplevel.backend) {
        .xwayland => |*adapter| {
            adapter.xsurface.setMinimized(true);
            adapter.xsurface.restack(null, .below);
        },
        .xdg => |*adapter| setXdgSuspended(adapter, true),
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

    if (toplevel.tab_group != 0 or hasDialogs(toplevel)) @import("../window_tabs.zig").refreshVisibility(server);
    if (server.world.workspaces.active) {
        @import("../workspaces.zig").focusFallback(server, toplevel.workspace_id);
    } else if (held_focus) {
        @import("../workspaces.zig").focusFallback(server, null);
    }
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

/// xdg_toplevel's suspended state exists from v6 on. wlroots checks the
/// global's version, not the client's, so for an older client it still sends
/// a configure that changes nothing visible. Wine (v2) takes any configure to
/// a window it minimized itself as the compositor restoring it: a fullscreen
/// game that minimizes on focus loss would come straight back, windowed and
/// shown as foreground to nobody, while it still looks minimized here.
fn setXdgSuspended(adapter: *xdg, suspended: bool) void {
    if (adapter.xdg_toplevel.resource.getVersion() < 6) return;
    _ = adapter.xdg_toplevel.setSuspended(suspended);
}

/// Whether `candidate` is a dialog of `owner`, directly or through other dialogs.
fn isDialogOf(candidate: *Toplevel, owner: *Toplevel) bool {
    var current = candidate;
    for (0..32) |_| {
        current = current.owner() orelse return false;
        if (current == owner) return true;
    }
    return false;
}

fn hasDialogs(owner: *Toplevel) bool {
    var it = owner.server.world.toplevels.iterator(.forward);
    while (it.next()) |candidate| {
        if (candidate != owner and candidate.in_world and candidate.owner() == owner) return true;
    }
    return false;
}

/// Restoring an owner shows its dialogs again, and focusing it passes the
/// keyboard to a modal one (`World.focusSurface`).
pub fn restore(toplevel: *Toplevel) void {
    toplevel.server.window_tabs.select(toplevel);
    defer if (toplevel.tab_group != 0 or hasDialogs(toplevel)) @import("../window_tabs.zig").refreshVisibility(toplevel.server);
    if (!toplevel.minimized or !toplevel.in_world) return;
    @import("../effects/window_minimize.zig").cancelFor(toplevel.server, toplevel.id);
    toplevel.minimized = false;
    toplevel.frame_tree.node.setEnabled(@import("../window_tabs.zig").visible(toplevel));
    switch (toplevel.backend) {
        .xwayland => |*adapter| adapter.xsurface.setMinimized(false),
        .xdg => |*adapter| setXdgSuspended(adapter, false),
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
