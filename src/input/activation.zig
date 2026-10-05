//! User-authorized xdg activation. wlroots owns token expiry and single use.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const Self = @This();

server: *Server = undefined,
manager: *wlr.XdgActivationV1 = undefined,
new_token: wl.Listener(*wlr.XdgActivationTokenV1) = .init(newToken),
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = .init(requestActivate),

pub fn init(self: *Self, server: *Server) !void {
    const manager = try wlr.XdgActivationV1.create(server.wl_server);
    manager.token_timeout_msec = 10_000;
    self.* = .{
        .server = server,
        .manager = manager,
    };
    manager.events.new_token.add(&self.new_token);
    manager.events.request_activate.add(&self.request_activate);
}

pub fn createToken(self: *Self) ?*wlr.XdgActivationTokenV1 {
    return self.manager.createToken();
}

pub fn deinit(self: *Self) void {
    self.new_token.link.remove();
    self.request_activate.link.remove();
}

fn newToken(listener: *wl.Listener(*wlr.XdgActivationTokenV1), token: *wlr.XdgActivationTokenV1) void {
    const self: *Self = @fieldParentPtr("new_token", listener);
    const seat = self.server.input.seat;
    if (self.server.locker != null or token.seat != seat) return;
    const source = token.surface orelse return;
    const focused = seat.keyboard_state.focused_surface orelse return;
    if (source.getRootSurface() != focused.getRootSurface()) return;
    const client = seat.clientForWlClient(source.resource.getClient()) orelse return;
    if (!client.validateEventSerial(token.serial)) return;
    // Remember authorization at issuance, so launching an app still works if
    // the source disappears or focus changes while the new process starts.
    token.data = self;
}

fn requestActivate(listener: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate), event: *wlr.XdgActivationV1.event.RequestActivate) void {
    const self: *Self = @fieldParentPtr("request_activate", listener);
    self.server.launch_feedback.endToken(std.mem.span(event.token.name()));
    if (self.server.locker != null or self.server.polkit_dialog != null) return;
    if (Toplevel.fromSurface(self.server, event.surface)) |top| {
        if (top.surface() == event.surface and self.server.window_tabs.activated(top, std.mem.span(event.token.name()))) return;
    }
    if (event.token.data == @as(*anyopaque, @ptrCast(self))) {
        const top = Toplevel.fromSurface(self.server, event.surface) orelse return;
        // Activation targets a mapped toplevel, never a popup or subsurface.
        if (top.surface() != event.surface or !event.surface.mapped) return;
        if (top.minimized) top.restore() else self.server.world.focus(top);
        if (self.server.getDefaultOutput()) |out| self.server.world.revealIfOffscreen(top, out);
        self.server.scheduleFrames();
    } else if (event.token.data) |data| {
        var it = self.server.world.toplevels.iterator(.forward);
        while (it.next()) |candidate| {
            if (candidate.backend == .placeholder and @as(*anyopaque, @ptrCast(candidate)) == data) {
                const top = Toplevel.fromSurface(self.server, event.surface) orelse return;
                top.placeholder_source = candidate;
                if (top.surface() != null and event.surface.mapped) {
                    if (top.minimized) top.restore() else self.server.world.focus(top);
                    if (self.server.getDefaultOutput()) |out| self.server.world.revealIfOffscreen(top, out);
                    self.server.scheduleFrames();
                }
                break;
            }
        }
    } else {
        // A known token without focus authorization can request attention.
        // Unknown/expired tokens are discarded by wlroots before this callback.
        const top = Toplevel.fromSurface(self.server, event.surface) orelse return;
        if (top.surface() != event.surface or !event.surface.mapped) return;
        top.setUrgent(true);
    }
}
