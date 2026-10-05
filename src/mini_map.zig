//! Transient, output-local navigation overlay. The grid raster is retained;
//! Window outlines and the rounded viewport are retained; no polling timer.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const ui = @import("ui");
const col = @import("color.zig");
const anim = @import("ui").anim;
const geo = @import("mini_map_geometry.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const SceneData = @import("scene_data.zig").SceneData;
const Self = @This();
const gpa = @import("main.zig").gpa;

server: ?*Server = null,
output: ?*Output = null,
tree: ?*wlr.SceneTree = null,
background: ?*wlr.SceneBuffer = null,
window_tree: ?*wlr.SceneTree = null,
outlines: std.ArrayList(Outline) = .empty,
marker: ?*wlr.SceneBuffer = null,
marker_cache: ?MarkerCache = null,
scene_data: SceneData = undefined,
timer: ?*wl.EventSource = null,
visible: bool = false,
hovered: bool = false,
dragging: bool = false,
armed: bool = false,
fade_start: ?i64 = null,
map: geo.Map = undefined,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
anchor: @import("camera.zig").Vec = .{ .x = 0, .y = 0 },
cache: ?Cache = null,
last_camera: ?@import("camera.zig").Camera = null,
const Outline = struct {
    tree: *wlr.SceneTree,
    edges: [4]*wlr.SceneRect,
    color: ?col.Premul = null,
};
const Cache = struct { map: geo.Map, bounds: @import("camera.zig").Bounds, columns: u32, rows: u32, scale: f32, bg: [4]f32, fg: [4]f32, bg_opacity: f32 = 0.91, grid_alpha: f32 = 0.065, border_alpha: f32 = 0.12, radius: f32 = 4 };
const MarkerCache = struct { width: i32, height: i32, scale: f32, accent: [4]f32, fill_alpha: f32 = 0.12, border_alpha: f32 = 0.85, radius: f32 = 4 };


fn blocked(server: *Server) bool {
    if (server.tray) |tray| if (tray.menu_item != 0) return true;
    return server.greeter_mode or server.locker != null or server.polkit_dialog != null or
        server.screenshot_selector.output != null or server.switcher.active() or
        server.input.open_start_menu != null or
        server.input.open_power_menu != null or server.input.open_wifi != null or server.input.open_battery != null or server.input.open_calendar != null;
}

pub fn show(self: *Self, server: *Server, x: f64, y: f64) void {
    if (!server.config.compositor.mini_map_enabled or blocked(server)) return;
    self.server = server;
    if (self.dragging) return;
    const output = Output.atLayout(server, x, y) orelse server.getDefaultOutput() orelse return;
    if (!output.isAvailable() or output.idle_blanked) return;
    // Keep one output for an entire animated navigation sequence.
    if (!self.visible or !server.world.holdingGlass()) self.output = output;
    self.visible = true;
    self.fade_start = null;
    self.disarm();
    self.last_camera = null;
    server.scheduleFrames();
}

fn ensureNodes(self: *Self) !void {
    if (self.tree != null) return;
    const server = self.server.?;
    const tree = try server.overlay_tree.createSceneTree();
    errdefer tree.node.destroy();
    tree.node.lowerToBottom();
    const bg = try tree.createSceneBuffer(null);
    bg.setFilterMode(.bilinear);
    const window_tree = try tree.createSceneTree();
    const marker = try tree.createSceneBuffer(null);
    marker.setFilterMode(.bilinear);
    self.scene_data = .{ .role = .{ .mini_map = self } };
    self.scene_data.attach(&bg.node);
    self.scene_data.attach(&marker.node);
    if (self.timer == null) self.timer = try server.wl_server.getEventLoop().addTimer(*Self, timeout, self);
    self.tree = tree;
    self.background = bg;
    self.window_tree = window_tree;
    self.marker = marker;
}

pub fn hide(self: *Self) void {
    const had_pointer = self.dragging or self.hovered;
    self.visible = false;
    self.dragging = false;
    self.hovered = false;
    self.fade_start = null;
    self.disarm();
    if (self.tree) |tree| tree.node.setEnabled(false);
    if (had_pointer) if (self.server) |server| server.input.setDefaultCursor();
}

pub fn deinit(self: *Self) void {
    if (self.timer) |timer| timer.remove();
    if (self.tree) |tree| tree.node.destroy();
    self.outlines.deinit(gpa);
    self.* = .{};
}

pub fn outputRemoved(self: *Self, output: *Output) void {
    if (self.output == output) {
        self.hide();
        self.output = null;
    }
}

pub fn reconfigure(self: *Self) void {
    self.hide();
    self.cache = null;
}

fn disarm(self: *Self) void {
    if (self.armed) if (self.timer) |timer| timer.timerUpdate(0) catch {};
    self.armed = false;
}

fn timeout(self: *Self) c_int {
    self.armed = false;
    if (!self.visible or self.hovered or self.dragging) return 0;
    if (!anim.enabled() or anim.reducedMotion()) {
        self.hide();
    } else {
        self.fade_start = anim.nowMs();
    }
    if (self.output) |output| output.wlr_output.scheduleFrame();
    return 0;
}

pub fn hover(self: *Self, on: bool) void {
    if (self.hovered == on) return;
    self.hovered = on;
    self.fade_start = null;
    self.disarm();
    if (self.output) |output| output.wlr_output.scheduleFrame();
}

fn outputBox(self: *Self) geo.Rect {
    var box: wlr.Box = undefined;
    self.server.?.output_layout.getBox(self.output.?.wlr_output, &box);
    return .{ .x = @floatFromInt(box.x), .y = @floatFromInt(box.y), .w = @floatFromInt(box.width), .h = @floatFromInt(box.height) };
}

pub fn press(self: *Self, lx: f64, ly: f64) void {
    if (!self.visible or self.tree == null) return;
    const world = &self.server.?.world;
    // Stop competing animations at their current visual values, without a jump.
    self.server.?.input.finger_pan = false;
    if (self.server.?.input.gesture == .compositor_pinch) self.server.?.input.gesture = .none;
    world.panning = false;
    world.pinching = false;
    world.zoom_keeps_anchor = false;
    world.pan_x.cancel(@floatCast(world.camera.offset_x));
    world.pan_y.cancel(@floatCast(world.camera.offset_y));
    world.zoom_anim.cancel(@floatCast(world.camera.zoom()));
    const x = lx - @as(f64, @floatFromInt(self.box.x));
    const y = ly - @as(f64, @floatFromInt(self.box.y));
    const v = self.map.viewport(world.camera, world.bounds, self.outputBox());
    self.anchor = if (v.contains(x, y)) .{ .x = x - v.x, .y = y - v.y } else .{ .x = v.w / 2, .y = v.h / 2 };
    self.dragging = true;
    self.hover(true);
    self.motion(lx, ly);
}

pub fn motion(self: *Self, lx: f64, ly: f64) void {
    if (!self.dragging) return;
    const world = &self.server.?.world;
    const x = lx - @as(f64, @floatFromInt(self.box.x));
    const y = ly - @as(f64, @floatFromInt(self.box.y));
    world.camera = self.map.drag(world.camera, world.bounds, self.outputBox(), x, y, self.anchor);
    world.applyCamera();
}

pub fn release(self: *Self) void {
    self.dragging = false;
    self.hovered = false;
    self.disarm();
    if (self.output) |output| output.wlr_output.scheduleFrame();
}

pub fn tick(self: *Self, output: *Output, now: i64) bool {
    if (!self.visible or self.output != output) return false;
    const server = self.server.?;
    if (blocked(server) or !server.config.compositor.mini_map_enabled or !output.isAvailable() or output.idle_blanked) {
        self.hide();
        return false;
    }
    self.ensureNodes() catch {
        self.hide();
        return false;
    };
    const usable = output.usableBox();
    if (usable.width < 80 or usable.height < 80) {
        self.hide();
        return false;
    }
    const cfg = server.config.compositor;
    const world = &server.world;
    const map = geo.Map.init(world.bounds, world.camera.zoom(), @min(220, @as(f64, @floatFromInt(usable.width - 32))), @min(140, @as(f64, @floatFromInt(usable.height - 32))));
    const theme = ui.theme.shellPalette();
    const key: Cache = .{ .map = map, .bounds = world.bounds, .columns = cfg.canvas_columns, .rows = cfg.canvas_rows, .scale = output.wlr_output.scale, .bg = theme.window_bg, .fg = theme.window_fg, .bg_opacity = theme.mini_map_bg_opacity, .grid_alpha = theme.mini_map_grid_alpha, .border_alpha = theme.mini_map_border_alpha, .radius = theme.mini_map_radius };
    if (self.cache == null or !std.meta.eql(self.cache.?, key)) {
        if (self.dragging) {
            self.hide();
            return false;
        }
        self.map = map;
        self.paint(key) catch {
            self.hide();
            return false;
        };
        self.cache = key;
    }
    const w: i32 = @intFromFloat(@ceil(self.map.width));
    const h: i32 = @intFromFloat(@ceil(self.map.height));
    self.box = .{ .x = switch (cfg.mini_map_position) {
        .bottom_left => usable.x + 16,
        .bottom_center => usable.x + @divTrunc(usable.width - w, 2),
        .bottom_right => usable.x + usable.width - w - 16,
    }, .y = usable.y + usable.height - h - 16, .width = w, .height = h };
    // The system OSD wins when it occupies the same screen rectangle.
    if (output.osd.node) |node| if (node.node.enabled and output.osd.state != null) {
        var x: i32 = 0;
        var y: i32 = 0;
        _ = node.node.coords(&x, &y);
        if (x < self.box.x + w and x + node.dst_width > self.box.x and y < self.box.y + h and y + node.dst_height > self.box.y) {
            self.hide();
            return false;
        }
    };
    self.tree.?.node.setPosition(self.box.x, self.box.y);
    self.tree.?.node.setEnabled(true);
    // A map can appear beneath a stationary pointer. Resolve actual scene
    // ownership so a covering toast does not hold the map open underneath it.
    if (!self.dragging) {
        var sx: f64 = 0;
        var sy: f64 = 0;
        const picked = server.scene.tree.node.at(server.input.cursor.x, server.input.cursor.y, &sx, &sy);
        self.hovered = server.input.cursor_mode == .passthrough and server.input.active_buttons == 0 and
            picked != null and SceneData.fromNode(picked.?) == &self.scene_data;
    }
    const changed = self.last_camera == null or !std.meta.eql(self.last_camera.?, world.camera);
    self.last_camera = world.camera;
    if (changed or world.holdingGlass() or self.hovered or self.dragging) {
        self.disarm();
        self.fade_start = null;
    }
    // Arm on the last changed frame too: no extra frame is needed while idle.
    if (!world.holdingGlass() and !self.hovered and !self.dragging and !self.armed and self.fade_start == null) {
        self.timer.?.timerUpdate(@intCast(cfg.mini_map_hide_ms)) catch {};
        self.armed = true;
    }
    const opacity: f32 = if (self.fade_start) |start| @floatCast(1 - std.math.clamp(@as(f64, @floatFromInt(now - start)) / 160, 0, 1)) else 1;
    if (opacity <= 0) {
        self.hide();
        return false;
    }
    self.syncWindows(theme.window_fg, opacity) catch {
        self.hide();
        return false;
    };
    self.background.?.setOpacity(opacity);
    const v = self.map.viewport(world.camera, world.bounds, self.outputBox());
    const x0: i32 = @intFromFloat(@round(std.math.clamp(v.x, 0, self.map.width)));
    const y0: i32 = @intFromFloat(@round(std.math.clamp(v.y, 0, self.map.height)));
    const x1: i32 = @intFromFloat(@round(std.math.clamp(v.x + v.w, 0, self.map.width)));
    const y1: i32 = @intFromFloat(@round(std.math.clamp(v.y + v.h, 0, self.map.height)));
    const mw = @max(1, x1 - x0);
    const mh = @max(1, y1 - y0);
    const marker_key: MarkerCache = .{ .width = mw, .height = mh, .scale = output.wlr_output.scale, .accent = theme.accent, .fill_alpha = theme.mini_map_marker_alpha, .border_alpha = theme.mini_map_marker_border_alpha, .radius = theme.mini_map_radius };
    if (self.marker_cache == null or !std.meta.eql(self.marker_cache.?, marker_key)) {
        self.paintMarker(marker_key) catch {
            self.hide();
            return false;
        };
        self.marker_cache = marker_key;
    }
    self.marker.?.node.setPosition(x0, y0);
    self.marker.?.setOpacity(opacity);
    return self.fade_start != null;
}

fn paintMarker(self: *Self, key: MarkerCache) !void {
    const image = try PanelBuffer.createUnpooled(key.width, key.height, key.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, key.scale);
    var fill = key.accent;
    fill[3] *= key.fill_alpha;
    var border = key.accent;
    border[3] *= key.border_alpha;
    const w: f32 = @floatFromInt(key.width);
    const h: f32 = @floatFromInt(key.height);
    r.fillRect(0, 0, w, h, .{ .color = fill, .radius = @min(key.radius, @min(w, h) / 2), .border_width = 1, .border_color = border });
    self.marker.?.setBuffer(&image.base);
    self.marker.?.setDestSize(key.width, key.height);
}

// Pool outlines by display order, without retaining pointers to client windows.
// Camera-only panning leaves their world geometry unchanged.
fn syncWindows(self: *Self, foreground: [4]f32, opacity: f32) !void {
    var count: usize = 0;
    var it = self.server.?.world.toplevels.iterator(.reverse);
    while (it.next()) |top| {
        if (!top.in_world or top.tab_hidden or top.minimized or top.closing or top.backend_gone) continue;
        const origin = top.frameWorld(0, 0);
        const extent = top.frameWorld(@floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height));
        const projected = self.map.project(.{ .x = origin.x, .y = origin.y, .w = extent.x - origin.x, .h = extent.y - origin.y });
        const x0: i32 = @intFromFloat(@round(std.math.clamp(projected.x, 0, self.map.width)));
        const y0: i32 = @intFromFloat(@round(std.math.clamp(projected.y, 0, self.map.height)));
        const x1: i32 = @intFromFloat(@round(std.math.clamp(projected.x + projected.w, 0, self.map.width)));
        const y1: i32 = @intFromFloat(@round(std.math.clamp(projected.y + projected.h, 0, self.map.height)));
        if (x1 <= x0 or y1 <= y0) continue;
        if (count == self.outlines.items.len) {
            const tree = try self.window_tree.?.createSceneTree();
            errdefer tree.node.destroy();
            var edges: [4]*wlr.SceneRect = undefined;
            for (&edges) |*edge| {
                edge.* = try col.createRect(tree, 1, 1, .transparent);
                self.scene_data.attach(&edge.*.node);
            }
            try self.outlines.append(gpa, .{ .tree = tree, .edges = edges });
        }
        const outline = &self.outlines.items[count];
        const color = (col.Straight{ .r = foreground[0], .g = foreground[1], .b = foreground[2], .a = foreground[3] * ui.theme.global.mini_map_window_alpha * opacity }).premultiply();
        const recolor = outline.color == null or !std.meta.eql(outline.color.?, color);
        const rects = [_][4]i32{ .{ x0, y0, x1 - x0, 1 }, .{ x0, y1 - 1, x1 - x0, 1 }, .{ x0, y0, 1, y1 - y0 }, .{ x1 - 1, y0, 1, y1 - y0 } };
        for (outline.edges, rects) |edge, rect| {
            edge.node.setPosition(rect[0], rect[1]);
            edge.setSize(rect[2], rect[3]);
            if (recolor) col.setRect(edge, color);
        }
        outline.color = color;
        count += 1;
    }
    for (self.outlines.items[count..]) |outline| outline.tree.node.destroy();
    self.outlines.shrinkRetainingCapacity(count);
}

fn paint(self: *Self, key: Cache) !void {
    const m = key.map;
    const w: i32 = @intFromFloat(@ceil(m.width));
    const h: i32 = @intFromFloat(@ceil(m.height));
    const image = try PanelBuffer.create(w, h, key.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, key.scale);
    var bg = key.bg;
    bg[3] = key.bg_opacity;
    var line = key.fg;
    line[3] *= key.grid_alpha;
    var border = key.fg;
    border[3] *= key.border_alpha;
    r.fillRect(0, 0, @floatFromInt(w), @floatFromInt(h), .{ .color = bg, .radius = key.radius, .border_width = 1, .border_color = border });
    // Keep grid strokes inside the rounded panel's border and corners.
    r.clip = .{ .x = key.radius, .y = key.radius, .w = @max(0, @as(f32, @floatFromInt(w)) - 2 * key.radius), .h = @max(0, @as(f32, @floatFromInt(h)) - 2 * key.radius) };
    // The configured grid remains centered even if reachable bounds have grown.
    const b = key.bounds;
    const left = b.origin_x - b.width * @as(f64, @floatFromInt(key.columns - 1)) / 2;
    const top = b.origin_y - b.height * @as(f64, @floatFromInt(key.rows - 1)) / 2;
    const grid = m.project(.{ .x = left, .y = top, .w = b.width * @as(f64, @floatFromInt(key.columns)), .h = b.height * @as(f64, @floatFromInt(key.rows)) });
    for (0..key.columns + 1) |i| {
        const x = grid.x + @as(f64, @floatFromInt(i)) * b.width * m.scale;
        r.fillRect(@floatCast(x), @floatCast(grid.y), 1 / key.scale, @floatCast(grid.h), .{ .color = line });
    }
    for (0..key.rows + 1) |i| {
        const y = grid.y + @as(f64, @floatFromInt(i)) * b.height * m.scale;
        r.fillRect(@floatCast(grid.x), @floatCast(y), @floatCast(grid.w), 1 / key.scale, .{ .color = line });
    }
    self.background.?.setBuffer(&image.base);
    self.background.?.setDestSize(w, h);
}
