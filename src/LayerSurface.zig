//! Layer-shell scene integration. SceneLayerSurfaceV1 owns mapping and subsurfaces.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const SceneData = @import("scene_data.zig").SceneData;
const gpa = @import("main.zig").gpa;
const Self = @This();
server: *Server,
layer: *wlr.LayerSurfaceV1,
scene: *wlr.SceneLayerSurfaceV1,
identity: SceneData,
link: wl.list.Link = undefined,
commit: wl.Listener(*wlr.Surface) = .init(committed),
destroy: wl.Listener(*wlr.LayerSurfaceV1) = .init(destroyed),
output_destroy: wl.Listener(*wlr.Output) = .init(outputDestroyed),
output_commit: wl.Listener(*wlr.Output.event.Commit) = .init(outputCommitted),

pub fn create(server: *Server, layer: *wlr.LayerSurfaceV1) !void {
    const output = layer.output orelse defaultOutput(server) orelse {
        layer.destroy();
        return;
    };
    layer.output = output;
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    self.* = .{ .server = server, .layer = layer, .scene = try server.desktop_tree.createSceneLayerSurfaceV1(layer), .identity = .{ .role = .{ .layer = self } } };
    self.identity.attach(&self.scene.tree.node);
    server.layer_surfaces.prepend(self);
    layer.data = self;
    layer.surface.events.commit.add(&self.commit);
    layer.events.destroy.add(&self.destroy);
    output.events.destroy.add(&self.output_destroy);
    output.events.commit.add(&self.output_commit);
}

fn defaultOutput(server: *Server) ?*wlr.Output {
    if (server.getDefaultOutput()) |output| return output.wlr_output;
    // Sleeping outputs still host layers. Closing a new layer just because
    // every screen is dark makes clients such as notification daemons retry.
    if (server.preferredPrimaryOutput()) |output| {
        if (output.idle_blanked) return output.wlr_output;
    }
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (output.isLogicallyEnabled() and output.idle_blanked) return output.wlr_output;
    }
    return null;
}

pub fn localPoint(self: *Self, x: f64, y: f64) @import("geometry.zig").Vec2 {
    return @import("scene_data.zig").toNodeLocal(&self.scene.tree.node, x, y);
}

pub fn arrange(self: *Self) void {
    const parent = switch (self.layer.current.layer) {
        .background, .bottom => self.server.desktop_tree,
        .top => self.server.taskbar_tree,
        .overlay => self.server.overlay_tree,
        _ => self.server.desktop_tree,
    };
    self.scene.tree.node.reparent(parent);
    var full: wlr.Box = undefined;
    self.server.output_layout.getBox(self.layer.output, &full);
    const output = Output.fromWlr(self.layer.output.?);
    if (output) |out| if (out.idle_blanked) {
        full = out.cached_box;
    };
    var usable = full;
    if (output) |out| usable = out.usableBox();
    self.scene.configure(&full, &usable);
}
fn committed(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self: *Self = @fieldParentPtr("commit", listener);
    if (self.layer.initial_commit or @as(u32, @bitCast(self.layer.current.committed)) != 0) self.arrange();
    if (self.layer.current.committed.keyboard_interactivity and self.layer.current.keyboard_interactive == .on_demand and self.server.input.seat.pointer_state.focused_surface == self.layer.surface) self.focus();
    if (self.layer.current.keyboard_interactive == .none and self.server.input.seat.keyboard_state.focused_surface == self.layer.surface) self.server.input.seat.keyboardClearFocus();
    if (self.server.idle) |im| im.recheckInhibitors();
}
fn outputCommitted(listener: *wl.Listener(*wlr.Output.event.Commit), event: *wlr.Output.event.Commit) void {
    const self: *Self = @fieldParentPtr("output_commit", listener);
    if (event.state.committed.mode or event.state.committed.scale or event.state.committed.transform) self.arrange();
}
fn outputDestroyed(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("output_destroy", listener);
    self.layer.destroy();
}
fn destroyed(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const self: *Self = @fieldParentPtr("destroy", listener);
    const server = self.server;
    self.commit.link.remove();
    self.destroy.link.remove();
    self.output_destroy.link.remove();
    self.output_commit.link.remove();
    self.link.remove();
    self.layer.data = null;
    gpa.destroy(self);
    if (server.idle) |im| im.recheckInhibitors();
}
pub fn focus(self: *Self) void {
    if (self.server.locker != null or self.server.polkit_dialog != null) return;
    if (self.layer.current.keyboard_interactive == .none) return;
    const seat = self.server.input.seat;
    if (seat.keyboard_state.focused_surface) |previous| {
        if (@import("Toplevel.zig").fromSurface(self.server, previous)) |prev| {
            prev.setActivated(false);
        }
    }
    if (seat.getKeyboard()) |keyboard| {
        seat.keyboardNotifyEnter(self.layer.surface, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
    } else {
        const modifiers = std.mem.zeroes(wlr.Keyboard.Modifiers);
        seat.keyboardNotifyEnter(self.layer.surface, &.{}, &modifiers);
    }
    self.server.refreshTaskbars();
}
