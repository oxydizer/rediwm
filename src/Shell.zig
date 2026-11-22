// xdg-shell, XDG and KDE decoration protocols. Creates compositor objects for new
// toplevels, popups, and decoration objects; policy lives on those objects
// and on World/Input, not here.
const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const KdeDecoration = @import("KdeDecoration.zig");
const TitlebarTabs = @import("TitlebarTabs.zig");
const Decoration = @import("Decoration.zig");
const Popup = @import("Popup.zig");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const scene_data = @import("scene_data.zig");

const Shell = @This();

const log = std.log.scoped(.shell);

server: *Server,
kde_decorations: KdeDecoration.Manager,
titlebar_tabs: TitlebarTabs.Manager,
xdg_shell: *wlr.XdgShell,
xdg_decoration_manager: *wlr.XdgDecorationManagerV1,
new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevel),
new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopup),
new_xdg_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(newXdgDecoration),

pub fn init(shell: *Shell, server: *Server) Server.CompositorError!void {
    const xdg_shell = wlr.XdgShell.create(server.wl_server, 6) catch return error.XdgShellCreateFailed;
    const xdg_decoration_manager = wlr.XdgDecorationManagerV1.create(server.wl_server) catch return error.XdgDecorationCreateFailed;
    // Both globals are destroyed with the display; Server.init's errdefer
    // `wl_server.destroy()` covers a failure after this returns.
    shell.* = .{
        .server = server,
        .kde_decorations = undefined,
        .titlebar_tabs = undefined,
        .xdg_shell = xdg_shell,
        .xdg_decoration_manager = xdg_decoration_manager,
    };
    shell.kde_decorations.init(server) catch return error.KdeDecorationCreateFailed;
    shell.titlebar_tabs.init(server) catch return error.TitlebarTabsCreateFailed;
    shell.xdg_shell.events.new_toplevel.add(&shell.new_xdg_toplevel);
    shell.xdg_shell.events.new_popup.add(&shell.new_xdg_popup);
    shell.xdg_decoration_manager.events.new_toplevel_decoration.add(&shell.new_xdg_decoration);
}

pub fn deinit(shell: *Shell) void {
    shell.titlebar_tabs.deinit();
    shell.kde_decorations.deinit();
    shell.new_xdg_toplevel.link.remove();
    shell.new_xdg_popup.link.remove();
    shell.new_xdg_decoration.link.remove();
}

fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    const shell: *Shell = @fieldParentPtr("new_xdg_toplevel", listener);
    // Listener cannot throw: one bad client must not kill the compositor.
    Toplevel.create(shell.server, xdg_toplevel) catch |err| {
        log.err("newXdgToplevel: could not create view: {}", .{err});
    };
}

fn newXdgPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
    const shell: *Shell = @fieldParentPtr("new_xdg_popup", listener);
    Popup.create(shell.server, xdg_popup) catch |err| {
        log.err("newXdgPopup: could not create popup: {}", .{err});
    };
}

fn newXdgDecoration(
    _: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    decoration: *wlr.XdgToplevelDecorationV1,
) void {
    const tree = scene_data.xdgSceneTree(decoration.toplevel.base) orelse return;
    const data = scene_data.SceneData.fromNodeOrParents(&tree.node) orelse return;
    const toplevel = switch (data.role) {
        .toplevel => |t| t,
        .chrome => |t| t,
        .wifi_popup, .battery_popup, .calendar, .taskbar, .dock, .control_center, .start_menu, .power_menu, .layer, .xwayland_unmanaged, .toast, .desktop, .mini_map => return,
    };
    Decoration.create(decoration, toplevel) catch |err| {
        log.err("newXdgDecoration: could not track decoration: {}", .{err});
    };
}
