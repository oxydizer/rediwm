const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
pub const Protocols = opaque {};
extern fn rediwm_protocols_create(*wl.Server, *wlr.Backend, *wlr.Renderer, *wlr.Scene, *wlr.OutputLayout, *Server, *const fn (*Server) callconv(.c) bool, *const fn (*Server, *wlr.Surface) callconv(.c) void) ?*Protocols;
pub extern fn rediwm_protocols_destroy(?*Protocols) void;
pub extern fn rediwm_protocols_offer(?*Protocols, *wlr.Output) void;
pub extern fn rediwm_protocols_revoke(?*Protocols) void;
pub extern fn rediwm_protocols_tearing(?*Protocols, ?*wlr.Surface) bool;
extern fn rediwm_protocols_content(?*Protocols, ?*wlr.Surface) ?[*:0]const u8;
extern fn rediwm_surface_tag(?*wlr.Surface, bool) ?[*:0]const u8;
pub extern fn rediwm_surface_edge_is_srgb(*wlr.Surface) bool;
pub fn create(server: *Server) ?*Protocols {
    return rediwm_protocols_create(server.wl_server, server.backend, server.renderer, server.scene, server.output_layout, server, blocked, changed);
}
fn blocked(server: *Server) callconv(.c) bool {
    return server.greeter_mode or server.locker != null or server.polkit_dialog != null or server.shutting_down;
}
fn changed(server: *Server, surface: *wlr.Surface) callconv(.c) void {
    if (Toplevel.fromSurface(server, surface)) |top| top.handleIdentityChanged();
}
pub fn tag(surface: ?*wlr.Surface, description: bool) ?[]const u8 {
    const value = rediwm_surface_tag(surface, description) orelse return null;
    const bytes = std.mem.span(value);
    return if (std.unicode.utf8ValidateSlice(bytes)) bytes else null;
}
pub fn content(server: *Server, surface: ?*wlr.Surface) ?[]const u8 {
    return if (rediwm_protocols_content(server.extra_protocols, surface)) |s| std.mem.span(s) else null;
}
