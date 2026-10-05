//! Legacy KDE decoration negotiation, used by GTK/Ghostty. Unlike XDG
//! decoration this belongs to a wl_surface and can precede its shell role.
const wl = @import("wayland").server.wl;
const kde = @import("wayland").server.org;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const scene_data = @import("scene_data.zig");
const gpa = @import("main.zig").gpa;

const Decoration = @This();
const Resource = kde.KdeKwinServerDecoration;
const ManagerResource = kde.KdeKwinServerDecorationManager;
pub const Mode = enum(u32) { none, client, server };

resource: *Resource,
surface: ?*wlr.Surface,
toplevel: ?*Toplevel = null,
link: wl.list.Link = undefined,
requested: Mode = .server,
pending: Mode = .server,
current: Mode = .client,
surface_destroy: wl.Listener(*wlr.Surface) = .init(handleSurfaceDestroy),

pub const Manager = struct {
    global: *wl.Global,
    decorations: wl.list.Head(Decoration, .link) = undefined,

    pub fn init(self: *Manager, server: *Server) !void {
        self.* = .{ .global = try wl.Global.create(server.wl_server, ManagerResource, 1, *Manager, self, bind) };
        self.decorations.init();
    }

    pub fn deinit(self: *Manager) void {
        self.global.destroy();
        while (self.decorations.first()) |decoration| decoration.resource.destroy();
    }

    pub fn attach(self: *Manager, toplevel: *Toplevel) void {
        var it = self.decorations.iterator(.forward);
        while (it.next()) |decoration| {
            if (decoration.surface == toplevel.surface()) {
                decoration.toplevel = toplevel;
                toplevel.kde_decoration = decoration;
                return;
            }
        }
    }

    fn bind(client: *wl.Client, self: *Manager, version: u32, id: u32) void {
        const resource = ManagerResource.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        resource.setHandler(*Manager, handleRequest, null, self);
        resource.sendDefaultMode(@intFromEnum(Mode.server));
    }

    fn handleRequest(manager: *ManagerResource, request: ManagerResource.Request, self: *Manager) void {
        switch (request) {
            .create => |args| {
                const surface = wlr.Surface.fromWlSurface(args.surface);
                var it = self.decorations.iterator(.forward);
                while (it.next()) |existing| {
                    if (existing.surface == surface) {
                        manager.getClient().postImplementationError("surface already has a KDE decoration");
                        return;
                    }
                }
                const decoration = gpa.create(Decoration) catch {
                    manager.getClient().postNoMemory();
                    return;
                };
                const resource = Resource.create(manager.getClient(), 1, args.id) catch {
                    gpa.destroy(decoration);
                    manager.getClient().postNoMemory();
                    return;
                };
                decoration.* = .{ .resource = resource, .surface = surface };
                self.decorations.append(decoration);
                surface.events.destroy.add(&decoration.surface_destroy);
                resource.setHandler(*Decoration, handleDecorationRequest, handleDestroy, decoration);
                // Only the exact toplevel surface may receive chrome. Never
                // walk popup parents or subsurface roots here.
                if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg| {
                    if (scene_data.xdgSceneTree(xdg)) |tree| {
                        if (scene_data.SceneData.fromNodeOrParents(&tree.node)) |data| {
                            if (data.role == .toplevel and data.role.toplevel.surface() == surface) {
                                decoration.toplevel = data.role.toplevel;
                                data.role.toplevel.kde_decoration = decoration;
                            }
                        }
                    }
                }
                decoration.applyMode(true);
            },
        }
    }
};

pub fn applyMode(self: *Decoration, reply: bool) void {
    var mode = self.requested;
    if (self.toplevel) |toplevel| {
        if (toplevel.live_rules.decorations) |rule| mode = switch (rule) {
            .auto => self.requested,
            .server => .server,
            .client => .client,
        };
    }
    if (reply or self.pending != mode) self.resource.sendMode(@intFromEnum(mode));
    self.pending = mode;
}

pub fn commit(self: *Decoration) void {
    // KDE has no configure/ack serial. Apply the announced mode with the
    // client's next surface commit. Initial rules are resolved before here.
    self.current = self.pending;
    self.applyMode(false);
}

fn handleDecorationRequest(resource: *Resource, request: Resource.Request, self: *Decoration) void {
    switch (request) {
        .release => resource.destroy(),
        .request_mode => |args| {
            if (self.surface == null) return;
            self.requested = switch (args.mode) {
                0 => .none,
                1 => .client,
                2 => .server,
                else => {
                    resource.getClient().postImplementationError("invalid KDE decoration mode");
                    return;
                },
            };
            self.applyMode(true);
        },
    }
}

fn detach(self: *Decoration) void {
    if (self.toplevel) |toplevel| toplevel.kde_decoration = null;
    self.toplevel = null;
}

fn handleSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self: *Decoration = @fieldParentPtr("surface_destroy", listener);
    self.surface_destroy.link.remove();
    self.surface = null;
    self.detach();
    // The protocol resource may outlive the wl_surface; leave it inert.
}

fn handleDestroy(_: *Resource, self: *Decoration) void {
    const toplevel = self.toplevel;
    self.detach();
    if (self.surface != null) self.surface_destroy.link.remove();
    self.link.remove();
    gpa.destroy(self);
    if (toplevel) |top| top.syncChrome(true, true, Toplevel.nowMs()) catch {};
}
