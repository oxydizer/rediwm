//! Window adapter for the reusable ribbon geometry and scene mesh nodes.
const std = @import("std");
const Server = @import("../Server.zig");
const Top = @import("../Toplevel.zig");
const Output = @import("../Output.zig");
const sn = @import("../node.zig");
const projection = @import("../projection.zig");
const anim = @import("ui").anim;
const ribbon = @import("ribbon.zig");
const border = @import("border.zig");
const mesh_scene = @import("ribbon_scene.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();
const Resize = @import("window_resize.zig");
const Heading = @import("move_heading.zig");
const move_trail = @import("move_trail.zig");

id: u64,
resizing: ?Resize = null,
tree: *sn.Tree,
nodes: [4]*sn.Buffer,
paths: [2]ribbon.Path = @splat(.{}),
preset: ribbon.Preset,
previous: ribbon.Point,
previous_position: ribbon.Point,
heading: Heading = .{},
last_tick: i64 = -1,
last_move: ?i64 = null,
emitting: bool = true,
visible: bool = false,
// Last world-space bounds, for pacing only the outputs the ribbons intersect.
bounds: [4]struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0 } = @splat(.{}),

pub fn configure(server: *Server) void {
    cancel(server);
    @import("window_minimize.zig").cancelAll(server);
    const enabled = !server.greeter_mode and (server.config.effects.window_move.enabled or server.config.effects.minimize().enabled or server.config.effects.resize().enabled);
    server.ribbons_ready = enabled and server.output_renderer.setRibbons(true);
    if (!enabled) _ = server.output_renderer.setRibbons(false);
    if (enabled and !server.ribbons_ready) std.log.warn("flame ribbons: shader unavailable; effect disabled", .{});
}

pub fn cancel(server: *Server) void {
    const self = server.window_ribbons orelse return;
    server.window_ribbons = null;
    self.tree.node.destroy();
    gpa.destroy(self);
}

pub fn cancelFor(server: *Server, id: u64) void {
    if (server.window_ribbons) |self| if (self.id == id) cancel(server);
}

pub fn start(top: *Top) void {
    startWith(top, top.server.config.effects.window_move, false);
}

/// Whether resizes may play the flame (and so follow-through): the cheap,
/// usual "no". Stays true after the ribbon itself has faded away.
pub fn resizeEnabled(server: *Server) bool {
    return server.ribbons_ready and server.config.effects.resize().enabled;
}

pub fn startResize(top: *Top) void {
    startWith(top, top.server.config.effects.resize(), true);
}

fn startWith(top: *Top, binding: @import("config").effects.Binding, resize: bool) void {
    const server = top.server;
    cancel(server);
    if (!binding.enabled or !server.ribbons_ready or !anim.enabled() or anim.reducedMotion() or server.locker != null) return;
    const preset = server.config.effects.find(binding.preset) orelse return;
    if (preset.opacity == 0) return;
    // Past every early out, so a disabled effect costs a resize nothing.
    const resizing: ?Resize = if (resize) Resize.init(top) else null;
    const self = gpa.create(Self) catch return;
    const tree = top.frame_tree.createSceneTree() catch {
        gpa.destroy(self);
        return;
    };
    var nodes: [4]*sn.Buffer = undefined;
    for (&nodes) |*node| {
        node.* = mesh_scene.create(tree) orelse {
            tree.node.destroy();
            gpa.destroy(self);
            return;
        };
        node.*.node.setEnabled(false);
    }
    nodes[3].node.lowerToBottom();
    if (!projection.setTreeUnclipped(&tree.node, true)) {
        tree.node.destroy();
        gpa.destroy(self);
        return;
    }
    tree.node.placeAbove(&top.shadow_tree.node);
    if (resizing != null) tree.node.raiseToTop();
    self.* = .{
        .id = top.id,
        .resizing = resizing,
        .tree = tree,
        .nodes = nodes,
        .preset = preset,
        .previous = .{ .x = @floatFromInt(top.frame_tree.node.x), .y = @floatFromInt(top.frame_tree.node.y) },
        .previous_position = .{ .x = @floatFromInt(top.x), .y = @floatFromInt(top.y) },
    };
    server.window_ribbons = self;
}

pub fn stop(server: *Server) void {
    if (server.window_ribbons) |self| {
        self.emitting = false;
        if (self.resizing) |*state| state.released = anim.nowMs();
    }
}

pub fn resizeMotion(top: *Top) void {
    const self = top.server.window_ribbons orelse return;
    if (self.id != top.id or !self.emitting) return;
    if (self.resizing) |*state| state.motion(top);
}

pub fn resizeSize(top: *Top, now: i64, requested: @import("../resize.zig").ClientSize) @import("../resize.zig").ClientSize {
    if (!anim.enabled() or anim.reducedMotion()) return requested;
    const self = top.server.window_ribbons orelse return requested;
    if (self.id != top.id) return requested;
    if (self.resizing) |*state| return state.follow.value(now, anim.speed());
    return requested;
}

fn anchors(direction: u2, w: f32, h: f32, width: f32) struct { points: [2]ribbon.Point, spreads: [2]ribbon.Point } {
    const inset = @min(16, @min(w, h) * 0.1);
    const half = @min(width * ribbon.source_across, @max(0, (if (direction < 2) h else w) - 2 * inset) * 0.2);
    // Straddle each trailing corner: one source on the trailing side, the
    // other partway along the adjacent edge. The midpoint feeds the path;
    // each ribbon's diagonal half-vector places its two bright tips exactly.
    const center = (inset + 2 * half) / 2;
    const along = @min(@max(inset, width * 0.6), (if (direction < 2) w else h) * 0.25) / 2;
    const points: [2]ribbon.Point = switch (direction) {
        0 => .{ .{ .x = along, .y = center }, .{ .x = along, .y = h - center } },
        1 => .{ .{ .x = w - along, .y = center }, .{ .x = w - along, .y = h - center } },
        2 => .{ .{ .x = center, .y = along }, .{ .x = w - center, .y = along } },
        3 => .{ .{ .x = center, .y = h - along }, .{ .x = w - center, .y = h - along } },
    };
    const spreads: [2]ribbon.Point = switch (direction) {
        0 => .{ .{ .x = -along, .y = center }, .{ .x = along, .y = center } },
        1 => .{ .{ .x = -along, .y = -center }, .{ .x = along, .y = -center } },
        2 => .{ .{ .x = -center, .y = along }, .{ .x = -center, .y = -along } },
        3 => .{ .{ .x = center, .y = along }, .{ .x = center, .y = -along } },
    };
    return .{ .points = points, .spreads = spreads };
}

pub fn tick(self: *Self, output: *Output, now: i64) bool {
    const server = output.server;
    const top = server.findToplevelById(self.id) orelse {
        cancel(server);
        return false;
    };
    if (server.locker != null or !anim.enabled() or anim.reducedMotion() or !top.in_world or
        top.minimized or top.closing or top.switch_leaving or !top.frame_tree.node.enabled)
    {
        cancel(server);
        return false;
    }
    const following = if (self.resizing) |*state| state.pending(now) else false;
    if (now != self.last_tick or (if (self.resizing) |*state| state.needsUpdate(top) else false)) {
        self.last_tick = now;
        if (self.resizing) |*state| state.update(self, top, now) else self.update(top, now);
        if (!self.emitting and !self.visible and !following) {
            cancel(server);
            return false;
        }
    }
    if (following) if (server.input.resize_session) |session| {
        if (session.toplevel == top and (session.pacing_output == null or session.pacing_output == output)) return true;
    };
    if (!self.visible) return false;
    var box: @import("wlroots").Box = undefined;
    server.output_layout.getBox(output.wlr_output, &box);
    for (self.bounds) |b| {
        const p = server.world.toLayout(b.x, b.y);
        const z = server.world.camera.zoom();
        if (p.x < @as(f64, @floatFromInt(box.x + box.width)) and p.y < @as(f64, @floatFromInt(box.y + box.height)) and
            p.x + b.w * z > @as(f64, @floatFromInt(box.x)) and p.y + b.h * z > @as(f64, @floatFromInt(box.y))) return true;
    }
    return false;
}

fn update(self: *Self, top: *Top, now: i64) void {
    const origin: ribbon.Point = .{ .x = @floatFromInt(top.frame_tree.node.x), .y = @floatFromInt(top.frame_tree.node.y) };
    const scale: f32 = @floatCast(top.worldScale() * top.drag_lift_value);
    // Lift/settlement moves the presentation tree too; only a real drag feeds
    // the trails or chooses a trailing side.
    const position: ribbon.Point = .{ .x = @floatFromInt(top.x), .y = @floatFromInt(top.y) };
    const dx = position.x - self.previous_position.x;
    const dy = position.y - self.previous_position.y;
    const moved = @abs(dx) >= 0.5 or @abs(dy) >= 0.5;
    // Clear a finished fade before seeding a resumed drag's first segment.
    for (&self.paths) |*path| path.expire(now, self.preset.lifetime_ms);
    if (self.emitting and moved) {
        self.last_move = now;
        if (self.heading.update(dx, dy)) self.paths = @splat(.{});
        const sources = anchors(self.heading.value, @as(f32, @floatFromInt(top.chrome_width)) * scale, @as(f32, @floatFromInt(top.chrome_height)) * scale, self.preset.width_px);
        for (&self.paths, sources.points) |*path, p| {
            if (path.len == 0) path.push(.{ .x = self.previous.x + p.x, .y = self.previous.y + p.y }, now - 1, self.preset);
            path.push(.{ .x = origin.x + p.x, .y = origin.y + p.y }, now, self.preset);
        }
    }
    self.previous = origin;
    self.previous_position = position;
    self.visible = false;
    const sources = anchors(self.heading.value, @as(f32, @floatFromInt(top.chrome_width)) * scale, @as(f32, @floatFromInt(top.chrome_height)) * scale, self.preset.width_px);
    var trails: [2]ribbon.Geometry = undefined;
    for (&self.paths, 0..) |*path, i| {
        path.tickFlutter(now, self.emitting and moved);
        trails[i] = path.mesh(now, self.preset, origin, scale, @as(f32, @floatFromInt(i)) * std.math.pi, sources.spreads[i]);
        self.present(i, trails[i], origin, scale);
    }
    self.present(3, move_trail.between(&trails), origin, scale);
    const age = if (self.last_move) |last| std.math.clamp(@as(f32, @floatFromInt(now - last)) / @as(f32, @floatFromInt(@min(self.preset.lifetime_ms, ribbon.stop_fade_ms))), 0, 1) else 1;
    const decorated = top.hasServerDecorations() and @import("../chrome.zig").shapes;
    const halo = border.mesh(@floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height), if (decorated) top.cornerRadius() else 0, if (decorated) top.shapePolygon(top.chrome_width, top.chrome_height) else null, std.math.clamp(self.preset.width_px * 0.4, 6, 24) / scale, (1 - age) * (1 - age), self.preset);
    self.present(2, halo, origin, scale);
}

pub fn present(self: *Self, i: usize, geo: ribbon.Geometry, origin: ribbon.Point, scale: f32) void {
    const node = self.nodes[i];
    if (geo.mesh.count == 0 and !node.node.enabled) return;
    anim.observeNoteChanged();
    mesh_scene.present(node, &geo);
    self.bounds[i] = .{ .x = origin.x + @as(f32, @floatFromInt(geo.x)) * scale, .y = origin.y + @as(f32, @floatFromInt(geo.y)) * scale, .w = @as(f32, @floatFromInt(geo.width)) * scale, .h = @as(f32, @floatFromInt(geo.height)) * scale };
    self.visible = self.visible or geo.mesh.count >= 4;
}
