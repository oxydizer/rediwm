//! Layer-shell scene integration. The scene tree follows the surface and its subsurfaces.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("node.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const SceneData = @import("scene_data.zig").SceneData;
const gpa = @import("main.zig").gpa;
const Self = @This();
server: *Server,
layer: *wlr.LayerSurfaceV1,
/// The layer's root: placed by `place`, holding the surface and its subsurfaces.
tree: *sn.Tree,
identity: SceneData,
link: wl.list.Link = undefined,
commit: wl.Listener(*wlr.Surface) = .init(committed),
destroy: wl.Listener(*wlr.LayerSurfaceV1) = .init(destroyed),
output_destroy: wl.Listener(*wlr.Output) = .init(outputDestroyed),
was_mapped: bool = false,
configured_size: ?[2]u32 = null,

pub fn create(server: *Server, layer: *wlr.LayerSurfaceV1) !void {
    const output: *wlr.Output = layer.output orelse defaultOutput(server) orelse {
        layer.destroy();
        return;
    };
    layer.output = output;
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    const tree = try server.desktop_tree.createSceneTree();
    errdefer tree.node.destroy();
    _ = try tree.createSceneSubsurfaceTree(layer.surface);
    self.* = .{ .server = server, .layer = layer, .tree = tree, .identity = .{ .role = .{ .layer = self } } };
    self.identity.attach(&self.tree.node);
    server.layer_surfaces.prepend(self);
    layer.data = self;
    layer.surface.events.commit.add(&self.commit);
    layer.events.destroy.add(&self.destroy);
    output.events.destroy.add(&self.output_destroy);
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
    var ox: i32 = 0;
    var oy: i32 = 0;
    _ = self.tree.node.coords(&ox, &oy);
    return @import("geometry.zig").toLocal(x, y, ox, oy);
}

/// Place exclusive panels first, from overlay to background and oldest first
/// within a layer. Other surfaces see the space left by all mapped panels.
pub fn arrangeOutput(output: *Output) bool {
    const server = output.server;
    if (server.shutting_down or (server.layer_surfaces.empty() and output.layer_work_area == null)) return false;
    var full = output.cached_box;
    if (!output.idle_blanked) server.output_layout.getBox(output.wlr_output, &full);
    const base = output.shellUsableBox();
    var usable = base;
    const Layer = @import("wayland").server.zwlr.LayerShellV1.Layer;
    for ([_]Layer{ .overlay, .top, .bottom, .background }) |layer| {
        var it = server.layer_surfaces.iterator(.reverse);
        while (it.next()) |self| {
            if (self.layer.output != output.wlr_output or !self.layer.initialized or self.layer.current.layer != layer) continue;
            if (self.reserves()) self.place(&full, &usable);
        }
    }
    var it = server.layer_surfaces.iterator(.reverse);
    while (it.next()) |self| {
        if (self.layer.output == output.wlr_output and self.layer.initialized and !self.reserves()) self.place(&full, &usable);
    }
    const area: ?wlr.Box = if (std.meta.eql(usable, base)) null else usable;
    if (std.meta.eql(area, output.layer_work_area)) return false;
    output.layer_work_area = area;
    // In workspace mode syncOutputs refits each workspace on its own output.
    if (!server.world.workspaces.active) {
        var tops = server.world.toplevels.iterator(.forward);
        while (tops.next()) |top| {
            if (top.fullscreen or (!top.maximized and top.tile == null) or top.currentOutput() != output) continue;
            if (top.maximized) top.setMaximizedOn(output) else if (top.tile) |tile| top.setTiledOn(output, tile);
        }
    }
    return true;
}

fn reserves(self: *Self) bool {
    return self.layer.current.exclusive_zone > 0 and @as(u32, @bitCast(self.layer.getExclusiveEdge())) != 0;
}

fn layoutChanged(layer: *wlr.LayerSurfaceV1) void {
    const output = Output.fromWlr(layer.output orelse return) orelse return;
    if (!arrangeOutput(output)) return;
    output.server.world.workspaces.syncOutputs(output.server);
    if (output.server.desktop) |desktop| desktop.syncLayout();
}

// A preceding panel can leave less space than a stretched surface's margins.
fn stretchedSize(extent: i32, leading: i32, trailing: i32) i32 {
    return @intCast(std.math.clamp(@as(i64, extent) - leading - trailing, 1, std.math.maxInt(i32)));
}

fn place(self: *Self, full: *const wlr.Box, usable: *wlr.Box) void {
    const parent = switch (self.layer.current.layer) {
        .background, .bottom => self.server.desktop_tree,
        .top => self.server.taskbar_tree,
        .overlay => self.server.overlay_tree,
        _ => self.server.desktop_tree,
    };
    self.tree.node.reparent(parent);
    const state = &self.layer.current;
    // An exclusive zone of -1 takes the whole output, otherwise what is left.
    const bounds: wlr.Box = if (state.exclusive_zone == -1) full.* else usable.*;
    const margin = state.margin;
    const anchor = state.anchor;
    var box: wlr.Box = .{ .x = 0, .y = 0, .width = @bitCast(state.desired_width), .height = @bitCast(state.desired_height) };

    if (box.width == 0) {
        box.x = bounds.x +% margin.left;
        box.width = stretchedSize(bounds.width, margin.left, margin.right);
    } else if (anchor.left and anchor.right) {
        box.x = bounds.x +% @divTrunc(bounds.width, 2) -% @divTrunc(box.width, 2);
    } else if (anchor.left) {
        box.x = bounds.x +% margin.left;
    } else if (anchor.right) {
        box.x = bounds.x +% bounds.width -% box.width -% margin.right;
    } else {
        box.x = bounds.x +% @divTrunc(bounds.width, 2) -% @divTrunc(box.width, 2);
    }

    if (box.height == 0) {
        box.y = bounds.y +% margin.top;
        box.height = stretchedSize(bounds.height, margin.top, margin.bottom);
    } else if (anchor.top and anchor.bottom) {
        box.y = bounds.y +% @divTrunc(bounds.height, 2) -% @divTrunc(box.height, 2);
    } else if (anchor.top) {
        box.y = bounds.y +% margin.top;
    } else if (anchor.bottom) {
        box.y = bounds.y +% bounds.height -% box.height -% margin.bottom;
    } else {
        box.y = bounds.y +% @divTrunc(bounds.height, 2) -% @divTrunc(box.height, 2);
    }

    self.tree.node.setPosition(box.x, box.y);
    const size = [2]u32{ @bitCast(box.width), @bitCast(box.height) };
    if (self.configured_size == null or !std.meta.eql(self.configured_size.?, size)) {
        _ = self.layer.configure(size[0], size[1]);
        self.configured_size = size;
    }

    if (self.layer.surface.mapped and state.exclusive_zone > 0) {
        const zone = state.exclusive_zone;
        const edge = self.layer.getExclusiveEdge();
        if (edge.top or edge.bottom) {
            const reserve = std.math.clamp(zone +| (if (edge.top) margin.top else margin.bottom), 0, @max(0, usable.height - 1));
            if (edge.top) usable.y +|= reserve;
            usable.height -= reserve;
        } else if (edge.left or edge.right) {
            const reserve = std.math.clamp(zone +| (if (edge.left) margin.left else margin.right), 0, @max(0, usable.width - 1));
            if (edge.left) usable.x +|= reserve;
            usable.width -= reserve;
        }
    }
}

fn committed(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self: *Self = @fieldParentPtr("commit", listener);
    const mapped = self.layer.surface.mapped;
    if (!self.layer.initialized) self.configured_size = null;
    if (self.layer.initial_commit or mapped != self.was_mapped or @as(u32, @bitCast(self.layer.current.committed)) != 0) {
        self.was_mapped = mapped;
        layoutChanged(self.layer);
    }
    if (self.layer.current.committed.keyboard_interactivity and self.layer.current.keyboard_interactive == .on_demand and self.server.input.seat.pointer_state.focused_surface == self.layer.surface) self.focus();
    if (self.layer.current.keyboard_interactive == .none and self.server.input.seat.keyboard_state.focused_surface == self.layer.surface) self.server.input.seat.keyboardClearFocus();
    if (self.server.idle) |im| im.recheckInhibitors();
}
fn outputDestroyed(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("output_destroy", listener);
    self.layer.destroy();
}
fn destroyed(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const self: *Self = @fieldParentPtr("destroy", listener);
    const server = self.server;
    self.tree.node.destroy();
    self.commit.link.remove();
    self.destroy.link.remove();
    self.output_destroy.link.remove();
    self.link.remove();
    layoutChanged(self.layer);
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
