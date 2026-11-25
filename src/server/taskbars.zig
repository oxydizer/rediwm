//! Server taskbars: refresh, hold, position and fullscreen visibility.

const std = @import("std");
const Server = @import("../Server.zig");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");

// Rebuilds every output's taskbar chip layout (FLIP-animating any that
// moved) and keeps the bar above windows but below menus and modal overlays.
pub fn refreshTaskbars(server: *Server) void {
    if (server.taskbar_hold > 0) {
        server.taskbar_hold_pending = true;
        return;
    }
    var strip_moved = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        output.dock.invalidate();
        if (output.taskbar) |bar| {
            var box: wlr.Box = undefined;
            server.output_layout.getBox(output.wlr_output, &box);
            if (box.width > 0 and box.height > 0 and !bar.isPlaced(box)) {
                const strip = bar.reserved;
                bar.relayout(box);
                strip_moved = strip_moved or bar.reserved != strip;
                if (server.input.open_start_menu) |sm| {
                    if (sm.wlr_output == output.wlr_output) sm.relayout();
                }
            }
            bar.notifyToplevelsChanged();
        }
    }
    server.taskbar_tree.node.placeBelow(&server.overlay_tree.node);
    server.updateTaskbarFullscreenVisibility();
    if (strip_moved) server.applyTaskbarPosition();
}

// Coalesces taskbar refreshes until the matching `releaseTaskbars`, which
// runs one. Mapping a window refreshes the bar before the window is known to
// be a new tab of an existing group; without the hold the bar would show (and
// FLIP-animate) a transient extra chip.
pub fn holdTaskbars(server: *Server) void {
    server.taskbar_hold += 1;
}

pub fn releaseTaskbars(server: *Server) void {
    server.taskbar_hold -= 1;
    if (server.taskbar_hold == 0 and server.taskbar_hold_pending) {
        server.taskbar_hold_pending = false;
        server.refreshTaskbars();
    }
}

// Like refreshTaskbars, but always relayouts instead of only when bar height
// changed. Item geometry (chip/tray/start-button size, the start button's
// gap and icon size) also derives from `chip_gap`/`start_button_gap`/
// `start_button_icon_size`, none of which move `bar.box.height`, so the
// cheaper height-guarded path used by window-lifecycle events can't detect
// them. Callers are theme-change sites only (the settings panel, config
// hot-reload), not the frequent per-window-event ones, so the extra full
// raster pass here is rare and not a hot-path concern.
pub fn refreshTaskbarsGeometry(server: *Server) void {
    var strip_moved = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        output.dock.invalidate();
        if (output.taskbar) |bar| {
            var box: wlr.Box = undefined;
            server.output_layout.getBox(output.wlr_output, &box);
            const strip = bar.reserved;
            bar.relayout(box);
            strip_moved = strip_moved or bar.reserved != strip;
            if (server.input.open_start_menu) |sm| {
                if (sm.wlr_output == output.wlr_output) sm.relayout();
            }
        }
    }
    server.taskbar_tree.node.placeBelow(&server.overlay_tree.node);
    server.updateTaskbarFullscreenVisibility();
    if (strip_moved) server.applyTaskbarPosition();
}

/// Apply a changed taskbar edge, or a changed strip (size or gap, or the
/// dock's: `Dock.reserves`), to panels, reserved space and fixed layouts.
pub fn applyTaskbarPosition(server: *Server) void {
    Output.syncLayout(server);
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.fullscreen) continue;
        const output = toplevel.resolveTargetOutput() orelse continue;
        if (toplevel.maximized) {
            toplevel.setMaximizedOn(output);
        } else if (toplevel.tile) |tile| {
            toplevel.setTiledOn(output, tile);
        } else if (server.config.compositor.taskbar_position == .top) {
            // Keep visible floating titlebars reachable when the strip moves
            // over them, including the Settings window that made the change.
            const usable = output.usableBox();
            const position = server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
            const top: f64 = @floatFromInt(usable.y);
            const bar_height: f64 = if (output.taskbar) |bar| @floatFromInt(bar.reserved) else 0;
            if (position.y >= top - bar_height and position.y < top) {
                const target = server.world.toWorld(position.x, top);
                toplevel.finishMoveAnimation();
                toplevel.setPosition(@intFromFloat(@round(target.x)), @intFromFloat(@round(target.y)));
            }
        }
    }
}

// Hides the taskbar strip on whichever output currently hosts the focused
// fullscreen window (e.g. a video fullscreened in a browser), the same way
// a layer-shell panel would yield to an exclusive-fullscreen surface. Other
// outputs keep their bar, since a fullscreen window elsewhere shouldn't
// blank an unrelated monitor's taskbar.
pub fn updateTaskbarFullscreenVisibility(server: *Server) void {
    const focused = @import("../ipc/handlers.zig").findFocusedToplevel(server);
    // The raw compositor-side intent flag, not `isFullscreen()`: for xdg
    // surfaces that reads the client-acked `current.fullscreen`, which lags
    // a round trip behind the resize we already applied synchronously in
    // setFullscreenOn/toggleFullscreen. Reading the same flag those setters
    // write keeps the bar in lockstep with the resize instead of flashing
    // on top for a frame.
    const fullscreen_output: ?*Output = if (focused) |t|
        (if (t.fullscreen and @import("../workspaces.zig").visible(t)) t.currentOutput() else null)
    else
        null;

    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const bar = output.taskbar orelse continue;
        bar.tree.node.setEnabled(!bar.parked and fullscreen_output != output);
    }
}
