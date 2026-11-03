//! Bounded, input-transparent snapshots; the real window minimizes immediately.
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const Server = @import("../Server.zig");
const Top = @import("../Toplevel.zig");
const Output = @import("../Output.zig");
const anim = @import("ui").anim;
const ribbon = @import("ribbon.zig");
const geometry = @import("minimize_mesh.zig");
const mesh_scene = @import("ribbon_scene.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

next: ?*Self,
id: u64,
tree: *sn.Tree,
node: *sn.Buffer,
source: geometry.Box,
target: ribbon.Point,
preset: ribbon.Preset,
started: i64,
duration: f32,
last_tick: i64 = -1,
bounds: wlr.Box,

extern fn rediwm_output_snapshot(renderer: *@import("../scene_output.zig").Renderer, projection: *@import("../projection.zig").Projection, output: *@import("../scene_outputs.zig").SceneOutput, root: *sn.Node, box: wlr.Box, scale: f32, buffer: *wlr.Buffer, fence: ?*@import("../explicit_sync.zig").ReadFence, dest: *sn.Buffer) bool;

pub fn cancelAll(server: *Server) void {
    while (server.minimize_ribbons) |self| remove(&server.minimize_ribbons, self);
}

pub fn cancelFor(server: *Server, id: u64) void {
    var link = &server.minimize_ribbons;
    while (link.*) |self| {
        if (self.id == id) remove(link, self) else link = &self.next;
    }
}

fn remove(link: *?*Self, self: *Self) void {
    link.* = self.next;
    self.tree.node.destroy();
    gpa.destroy(self);
}

pub fn start(top: *Top) void {
    const server = top.server;
    const binding = server.config.effects.minimize();
    if (!binding.enabled or !server.ribbons_ready or !anim.enabled() or anim.reducedMotion() or
        anim.speed() <= 0 or server.locker != null or top.closing or !top.frame_tree.node.enabled or
        !@import("../workspaces.zig").visible(top)) return;
    const preset = server.config.effects.find(binding.preset) orelse return;
    if (preset.opacity <= 0) return;
    var count: usize = 0;
    var it = server.minimize_ribbons;
    while (it) |entry| : (it = entry.next) count += 1;
    if (count >= 8) return;
    create(top, preset) catch |err| std.log.debug("minimize ribbon unavailable: {}", .{err});
}

fn create(top: *Top, preset: ribbon.Preset) !void {
    const server = top.server;
    const output = top.currentOutput() orelse return error.NoOutput;
    const out = server.scene_outputs.get(output.wlr_output) orelse return error.NoOutput;
    const a = top.frameWorld(0, 0);
    const b = top.frameWorld(@floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height));
    const tl = server.world.toLayout(a.x, a.y);
    const br = server.world.toLayout(b.x, b.y);
    const box: wlr.Box = .{ .x = @intFromFloat(@round(tl.x)), .y = @intFromFloat(@round(tl.y)), .width = @intFromFloat(@round(br.x) - @round(tl.x)), .height = @intFromFloat(@round(br.y) - @round(tl.y)) };
    if (box.width <= 0 or box.height <= 0) return error.NoGeometry;
    // At most 8 Mi pixels per snapshot; oversized windows use a smaller raster.
    const area = @as(f32, @floatFromInt(box.width)) * @as(f32, @floatFromInt(box.height));
    const scale = @min(output.wlr_output.scale, @sqrt(8 * 1024 * 1024 / area));
    const width: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.width)) * scale))));
    const height: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.height)) * scale))));
    const formats = server.renderer.getTextureFormats(server.renderer.render_buffer_caps) orelse return error.NoFormat;
    const format = formats.get(0x34325241) orelse return error.NoFormat;
    const swapchain = try wlr.Swapchain.create(server.allocator, width, height, @constCast(format));
    defer swapchain.destroy();
    const buffer = try swapchain.acquire();
    defer buffer.unlock();
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    const tree = try server.nodes.tree.createSceneTree();
    errdefer tree.node.destroy();
    tree.node.placeBelow(&server.taskbar_tree.node);
    const node = mesh_scene.create(tree) orelse return error.OutOfMemory;
    node.node.setEnabled(false);
    server.world.syncPresentation();
    if (!rediwm_output_snapshot(server.output_renderer, server.world.projection, out, &top.frame_tree.node, box, scale, buffer, server.read_fence, node)) return error.SnapshotFailed;
    self.* = .{ .next = server.minimize_ribbons, .id = top.id, .tree = tree, .node = node, .source = .{ .x = @floatFromInt(box.x), .y = @floatFromInt(box.y), .width = @floatFromInt(box.width), .height = @floatFromInt(box.height) }, .target = destination(top, output), .preset = preset, .started = anim.nowMs(), .duration = 720 / anim.speed(), .bounds = box };
    server.minimize_ribbons = self;
    self.update(self.started);
    server.scheduleFrames();
}

fn destination(top: *Top, output: *Output) ribbon.Point {
    if (output.taskbar) |bar| {
        for (bar.chips.items) |chip| if (chip.toplevel == top) return .{
            .x = @as(f32, @floatFromInt(bar.box.x)) + chip.renderX(anim.nowMs()) + chip.width / 2,
            .y = @floatFromInt(bar.box.y + @divTrunc(bar.box.height, 2)),
        };
    }
    const dock = &output.dock;
    if (dock.visible) for (dock.ids[0..dock.count], 0..) |id, i| {
        if (id == top.id) {
            const icon = dock.iconBox(i, 1, 36);
            return .{ .x = @as(f32, @floatFromInt(dock.box.x)) + icon.x + icon.w / 2, .y = @as(f32, @floatFromInt(dock.box.y)) + icon.y + icon.h / 2 };
        }
    };
    var box: wlr.Box = undefined;
    top.server.output_layout.getBox(output.wlr_output, &box);
    return .{ .x = @floatFromInt(box.x + @divTrunc(box.width, 2)), .y = @floatFromInt(box.y + box.height - 2) };
}

fn update(self: *Self, now: i64) void {
    const p = @as(f32, @floatFromInt(@max(0, now - self.started))) / self.duration;
    const geo = geometry.mesh(self.source, self.target, p, self.preset);
    mesh_scene.present(self.node, &geo);
    self.bounds = .{ .x = geo.x, .y = geo.y, .width = geo.width, .height = geo.height };
    self.last_tick = now;
    anim.observeNoteChanged();
}

pub fn tick(output: *Output, now: i64) bool {
    const server = output.server;
    if (server.locker != null or !anim.enabled() or anim.reducedMotion()) {
        cancelAll(server);
        return false;
    }
    var box: wlr.Box = undefined;
    server.output_layout.getBox(output.wlr_output, &box);
    var live = false;
    var link = &server.minimize_ribbons;
    while (link.*) |self| {
        const top = server.findToplevelById(self.id);
        if (top == null or !top.?.minimized or !@import("../workspaces.zig").visible(top.?) or
            @as(f32, @floatFromInt(now - self.started)) >= self.duration)
        {
            remove(link, self);
            continue;
        }
        if (self.last_tick != now) self.update(now);
        const b = self.bounds;
        live = live or (b.x < box.x + box.width and b.y < box.y + box.height and
            b.x + b.width > box.x and b.y + b.height > box.y);
        link = &self.next;
    }
    return live;
}
