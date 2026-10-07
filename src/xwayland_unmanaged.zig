// Override-redirect X11 windows (menus, tooltips, combos). No chrome, no
// taskbar entry. Positioned in world coordinates from the X root box so
// camera pan/zoom stays presentation-only.
const std = @import("std");
const xscale = @import("xwayland_scale.zig");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("Server.zig");
const scene_data = @import("scene_data.zig");
const gpa = @import("main.zig").gpa;

const Unmanaged = @This();
const log = std.log.scoped(.xwayland);

server: *Server,
xsurface: *wlr.XwaylandSurface,
tree: *wlr.SceneTree,
scene_tree: ?*wlr.SceneTree = null,
node_data: scene_data.SceneData = undefined,

destroy: wl.Listener(void) = .init(handleDestroy),
associate: wl.Listener(void) = .init(handleAssociate),
dissociate: wl.Listener(void) = .init(handleDissociate),
set_geometry: wl.Listener(void) = .init(handleSetGeometry),
set_parent: wl.Listener(void) = .init(handleSetParent),
set_override_redirect: wl.Listener(void) = .init(handleSetOverrideRedirect),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),
grab_focus: wl.Listener(void) = .init(handleGrabFocus),
scene_destroy: wl.Listener(void) = .init(handleSceneDestroy),
surface_listeners: bool = false,

pub fn create(server: *Server, xsurface: *wlr.XwaylandSurface) !void {
    const unmanaged = try gpa.create(Unmanaged);
    errdefer gpa.destroy(unmanaged);
    const tree = try server.world.tree.createSceneTree();
    errdefer tree.node.destroy();
    const scale_n = server.xwaylandScale();
    if (scale_n > 1) {
        _ = @import("projection.zig").setTreeScale(&tree.node, 1.0 / scale_n);
    }
    unmanaged.* = .{
        .server = server,
        .xsurface = xsurface,
        .tree = tree,
    };
    unmanaged.node_data = .{ .role = .{ .xwayland_unmanaged = unmanaged } };
    scene_data.SceneData.attach(&unmanaged.node_data, &tree.node);
    tree.node.setEnabled(false);
    xsurface.data = unmanaged;
    xsurface.events.destroy.add(&unmanaged.destroy);
    xsurface.events.associate.add(&unmanaged.associate);
    xsurface.events.dissociate.add(&unmanaged.dissociate);
    xsurface.events.set_geometry.add(&unmanaged.set_geometry);
    xsurface.events.set_parent.add(&unmanaged.set_parent);
    xsurface.events.set_override_redirect.add(&unmanaged.set_override_redirect);
    xsurface.events.grab_focus.add(&unmanaged.grab_focus);
    unmanaged.syncPosition();
    if (xsurface.surface) |surface| {
        unmanaged.attachSurface();
        if (surface.mapped) unmanaged.mapRole();
    }
}

fn attachSurface(self: *Unmanaged) void {
    const surface = self.xsurface.surface orelse return;
    if (!self.surface_listeners) {
        surface.events.commit.add(&self.commit);
        surface.events.map.add(&self.map);
        surface.events.unmap.add(&self.unmap);
        self.surface_listeners = true;
    }
    if (self.scene_tree == null) {
        self.scene_tree = self.tree.createSceneSubsurfaceTree(surface) catch |err| {
            log.err("unmanaged X11 scene: {}", .{err});
            return;
        };
        self.scene_tree.?.node.events.destroy.add(&self.scene_destroy);
    }
}

fn detachSurface(self: *Unmanaged) void {
    if (self.surface_listeners) {
        self.commit.link.remove();
        self.map.link.remove();
        self.unmap.link.remove();
        self.surface_listeners = false;
    }
    if (self.scene_tree) |tree| {
        self.scene_destroy.link.remove();
        self.scene_tree = null;
        tree.node.destroy();
    }
}

fn handleSceneDestroy(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("scene_destroy", listener);
    self.scene_destroy.link.remove();
    self.scene_tree = null;
}

fn parentToplevel(self: *Unmanaged) ?*@import("Toplevel.zig") {
    const parent = self.xsurface.parent orelse return null;
    var it = self.server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        switch (toplevel.backend) {
            .xwayland => |*adapter| if (adapter.xsurface == parent) return toplevel,
            .xdg, .placeholder, .shell => {},
        }
    }
    return null;
}

fn syncPosition(self: *Unmanaged) void {
    const n = self.server.xwaylandScale();
    if (parentToplevel(self)) |parent| {
        const px = parent.x + parent.borderWidth();
        const py = parent.y + parent.titlebarHeight();
        const parent_x: i32 = parent.backend.xwayland.xsurface.x;
        const parent_y: i32 = parent.backend.xwayland.xsurface.y;
        const dx = @as(i32, self.xsurface.x) - parent_x;
        const dy = @as(i32, self.xsurface.y) - parent_y;
        self.tree.node.setPosition(px + xscale.worldFloor(dx, n), py + xscale.worldFloor(dy, n));
        return;
    }
    self.tree.node.setPosition(xscale.worldFloor(@as(i32, self.xsurface.x), n), xscale.worldFloor(@as(i32, self.xsurface.y), n));
}

fn destroyRole(self: *Unmanaged) void {
    self.detachSurface();
    self.destroy.link.remove();
    self.associate.link.remove();
    self.dissociate.link.remove();
    self.set_geometry.link.remove();
    self.set_parent.link.remove();
    self.set_override_redirect.link.remove();
    self.grab_focus.link.remove();
    self.xsurface.data = null;
    self.tree.node.destroy();
    gpa.destroy(self);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("destroy", listener);
    self.destroyRole();
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("associate", listener);
    self.attachSurface();
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("dissociate", listener);
    self.detachSurface();
}

fn handleSetGeometry(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("set_geometry", listener);
    self.syncPosition();
}

fn handleSetParent(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("set_parent", listener);
    self.syncPosition();
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("set_override_redirect", listener);
    if (self.xsurface.override_redirect) return;

    const server = self.server;
    const xsurface = self.xsurface;
    self.destroyRole();
    @import("Toplevel.zig").createXwayland(server, xsurface) catch |err| {
        log.err("could not transition override-redirect X11 window to managed: {}", .{err});
    };
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self: *Unmanaged = @fieldParentPtr("commit", listener);
    self.syncPosition();
}

fn handleMap(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("map", listener);
    self.mapRole();
}

fn mapRole(self: *Unmanaged) void {
    self.syncPosition();
    self.tree.node.setEnabled(true);
    self.tree.node.raiseToTop();
    self.server.scheduleFrames();
    // A toolkit menu/combo/tooltip opens from a click on its parent, never on
    // itself, so the reactive pointer-press focus grant in Input.zig never
    // fires for it. Grant focus on map so keyboard navigation and dismissal
    // (Escape, arrow keys, type-ahead) work without first clicking the popup.
    // wlroots' type-based override_redirect_wants_focus() heuristic misses
    // real toolkit popups that never set a recognized _NET_WM_WINDOW_TYPE
    // (e.g. a plain GtkMenu); grant focus eagerly here as a fallback, and
    // let handleGrabFocus below handle the client's own explicit request.
    if (self.wantsKeyboard()) self.grabKeyboard();
}

fn handleGrabFocus(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("grab_focus", listener);
    self.grabKeyboard();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const self: *Unmanaged = @fieldParentPtr("unmap", listener);
    self.tree.node.setEnabled(false);
    self.server.scheduleFrames();
    self.restoreFocus();
}

fn grabKeyboard(self: *Unmanaged) void {
    if (self.server.locker != null or self.server.polkit_dialog != null) return;
    const surface = self.xsurface.surface orelse return;
    @import("Keyboard.zig").enter(self.server, surface);
}

/// If this popup still holds keyboard focus when it unmaps (closed via
/// dismissal rather than a focus change elsewhere), return focus to its
/// parent window instead of leaving the seat focused on a hidden surface.
fn restoreFocus(self: *Unmanaged) void {
    if (self.server.locker != null or self.server.polkit_dialog != null) return;
    const own_surface = self.xsurface.surface orelse return;
    const seat = self.server.input.seat;
    const focused = seat.keyboard_state.focused_surface orelse return;
    if (focused != own_surface) return;
    const parent_toplevel = parentToplevel(self) orelse self.server.world.toplevels.first();
    const target = if (parent_toplevel) |t| t.surface() else null;
    if (target) |surface| {
        @import("Keyboard.zig").enter(self.server, surface);
    } else {
        seat.keyboardClearFocus();
    }
}

pub fn wantsKeyboard(self: *const Unmanaged) bool {
    return self.xsurface.overrideRedirectWantsFocus();
}
