const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
pub const Protocols = opaque {};
extern fn rediwm_protocols_create(
    *wl.Server,
    *wlr.Backend,
    *wlr.Renderer,
    *@import("scene_outputs.zig").SceneOutputs,
    *wlr.OutputLayout,
    *Server,
    *const fn (*Server) callconv(.c) bool,
    *const fn (*Server, *wlr.Surface) callconv(.c) void,
    *const fn (*Server) callconv(.c) void,
    *const fn (*Server, *wlr.Surface) callconv(.c) void,
) ?*Protocols;
pub extern fn rediwm_protocols_destroy(?*Protocols) void;
pub extern fn rediwm_protocols_offer(?*Protocols, *wlr.Output) void;
pub extern fn rediwm_protocols_revoke(?*Protocols) void;
pub extern fn rediwm_protocols_tearing(?*Protocols, ?*wlr.Surface) bool;
extern fn rediwm_protocols_content(?*Protocols, ?*wlr.Surface) ?[*:0]const u8;
extern fn rediwm_surface_tag(?*wlr.Surface, bool) ?[*:0]const u8;
pub extern fn rediwm_surface_edge_is_srgb(*wlr.Surface) bool;
extern fn rediwm_xdg_toplevel_modal(*wlr.XdgToplevel) bool;
pub fn create(server: *Server) ?*Protocols {
    return rediwm_protocols_create(server.wl_server, server.backend, server.renderer, server.scene_outputs, server.output_layout, server, blocked, changed, ring, modalChanged);
}
/// The client's xdg-dialog-v1 modal hint; `Toplevel.isModal` adds the owner.
pub fn modal(top: *wlr.XdgToplevel) bool {
    return rediwm_xdg_toplevel_modal(top);
}
fn modalChanged(server: *Server, surface: *wlr.Surface) callconv(.c) void {
    // An unmapped dialog is not in the stack yet; its hint is read when it maps.
    const top = Toplevel.fromSurface(server, surface) orelse return;
    if (top.surface() == surface) top.handleModalChanged();
}
fn blocked(server: *Server) callconv(.c) bool {
    return server.greeter_mode or server.locker != null or server.polkit_dialog != null or server.shutting_down;
}
fn changed(server: *Server, surface: *wlr.Surface) callconv(.c) void {
    if (Toplevel.fromSurface(server, surface)) |top| top.handleIdentityChanged();
}
fn ring(server: *Server) callconv(.c) void {
    // Limit all clients together, including requests for an unavailable bell.
    const now = std.Io.Clock.awake.now(server.io).toMilliseconds();
    if (server.last_system_bell_ms) |last| {
        if (now - last < 250) return;
    }
    server.last_system_bell_ms = now;
    var arena = std.heap.ArenaAllocator.init(@import("main.zig").gpa);
    defer arena.deinit();
    _ = @import("audio/sounds.zig").play(server, arena.allocator(), "bell") catch return;
}
pub fn tag(surface: ?*wlr.Surface, description: bool) ?[]const u8 {
    const value = rediwm_surface_tag(surface, description) orelse return null;
    const bytes = std.mem.span(value);
    return if (std.unicode.utf8ValidateSlice(bytes)) bytes else null;
}
pub fn content(server: *Server, surface: ?*wlr.Surface) ?[]const u8 {
    return if (rediwm_protocols_content(server.extra_protocols, surface)) |s| std.mem.span(s) else null;
}

extern fn rediwm_workspace_mode(?*Protocols, bool, *const fn (*Server, c_uint) callconv(.c) void) void;
extern fn rediwm_workspace_update(?*Protocols, c_uint, [*:0]const u8, ?*wlr.Output, bool) void;
fn activateWorkspace(server: *Server, id: c_uint) callconv(.c) void {
    if (id <= @import("workspaces.zig").count) server.world.workspaces.switchTo(server, @intCast(id));
}
pub fn syncWorkspaces(server: *Server) void {
    const manager = &server.world.workspaces;
    rediwm_workspace_mode(server.extra_protocols, manager.active, activateWorkspace);
    if (!manager.active) return;
    for (manager.slots, 0..) |slot, index| {
        if (!slot.exists) continue;
        const output = slot.output;
        rediwm_workspace_update(server.extra_protocols, @intCast(index + 1), @import("workspaces.zig").names[index], if (output) |o| o.wlr_output else null, if (output) |o| o.workspace_id == index + 1 else false);
    }
}
