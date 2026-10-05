//! Native, modal region picker. All geometry is output-local logical pixels.
const std = @import("std");
const wlr = @import("wlroots");
const col = @import("../color.zig");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const Self = @This();
const stats = @import("../ipc/stats.zig");

output: ?*Output = null,
tree: ?*wlr.SceneTree = null,
shades: [4]?*wlr.SceneRect = @splat(null),
borders: [4]?*wlr.SceneBuffer = @splat(null),
// GLES can release SceneBuffer.buffer after uploading its pixels. Keep the
// immutable strip dimensions here; geometry must not borrow that buffer later.
strip_sizes: [2]struct { width: f64 = 0, height: f64 = 0 } = @splat(.{}),
corners: [8]?*wlr.SceneRect = @splat(null),
label: ?*wlr.SceneBuffer = null,
label_width: i32 = -1,
label_height: i32 = -1,
dirty: bool = false,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
start_x: i32 = 0,
start_y: i32 = 0,
end_x: i32 = 0,
end_y: i32 = 0,
dragging: bool = false,
fn selectionRed() col.Straight {
    return col.Straight.fromRgba(ui.theme.global.screenshot_border);
}
fn selectionWhite() col.Straight {
    return col.Straight.fromRgba(ui.theme.global.screenshot_fg);
}

pub fn cancel(self: *Self) void {
    if (self.tree) |tree| tree.node.destroy();
    if (self.output) |output| output.server.input.setDefaultCursor();
    self.* = .{};
}

pub fn open(self: *Self, server: *Server) !void {
    if (server.locker != null or server.input.active_buttons != 0 or server.input.cursor_mode != .passthrough) return;
    self.cancel();
    server.switcher.cancel();
    // Keep open panels in the scene being captured. Modal input routing keeps
    // selection gestures from activating or dismissing them.
    const output = server.getDefaultOutput() orelse return;
    server.world.mini_map.hide();
    self.output = output;
    errdefer self.cancel();
    server.output_layout.getBox(output.wlr_output, &self.box);
    self.tree = try server.overlay_tree.createSceneTree();
    stats.global_stats.screenshot_selection.scene_nodes_created += 1;
    self.tree.?.node.setPosition(self.box.x, self.box.y);
    self.tree.?.node.raiseToTop();
    server.input.seat.pointerNotifyClearFocus();
    server.input.setNamedCursor("crosshair");
    try self.createSelection();
    try self.paintToolbar();
    self.dirty = true;
    self.flush(output);
}

fn setRect(node: *wlr.SceneRect, x: i32, y: i32, width: i32, height: i32) void {
    node.node.setEnabled(width > 0 and height > 0);
    if (width <= 0 or height <= 0) return;
    node.node.setPosition(x, y);
    node.setSize(width, height);
}

// Four immutable dash strips replace hundreds of individual scene rectangles.
// Crop the strips as the region grows: never stretch the dash pattern.
fn createSelection(self: *Self) !void {
    const tree = self.tree.?;
    const scale = self.output.?.wlr_output.scale;
    for (&self.shades) |*node| node.* = try col.createRect(tree, 0, 0, col.Straight.fromRgba(ui.theme.global.screenshot_shade).premultiply());
    for (0..2) |axis| {
        const horizontal = axis == 0;
        const image = try PanelBuffer.create(if (horizontal) self.box.width else 1, if (horizontal) 1 else self.box.height, scale);
        defer image.base.drop();
        self.strip_sizes[axis] = .{ .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) };
        for (image.pixels, 0..) |*pixel, i| {
            const device_pos = if (horizontal) i % @as(usize, @intCast(image.width)) else i / @as(usize, @intCast(image.width));
            const logical_pos: usize = @intFromFloat(@as(f64, @floatFromInt(device_pos)) / scale);
            pixel.* = if (logical_pos % 12 < 7) selectionRed().argb() else selectionWhite().argb();
        }
        for (0..2) |edge| {
            self.borders[axis * 2 + edge] = try tree.createSceneBuffer(&image.base);
            self.borders[axis * 2 + edge].?.node.setEnabled(false);
        }
    }
    for (&self.corners, 0..) |*node, i| {
        node.* = try col.createRect(tree, if (i % 2 == 0) 13 else 9, if (i % 2 == 0) 13 else 9, (if (i % 2 == 0) selectionRed() else selectionWhite()).premultiply());
        node.*.?.node.setEnabled(false);
    }
    self.label = try tree.createSceneBuffer(null);
    self.label.?.setDestSize(116, 30);
    self.label.?.node.setEnabled(false);
    stats.global_stats.screenshot_selection.scene_nodes_created += 17;
}

fn setBorder(self: *Self, index: usize, x: i32, y: i32, length: i32) void {
    const node = self.borders[index].?;
    node.node.setEnabled(length > 0 and self.dragging);
    if (length <= 0 or !self.dragging) return;
    const horizontal = index < 2;
    const size = self.strip_sizes[index / 2];
    const span = @as(f64, @floatFromInt(length)) * self.output.?.wlr_output.scale;
    node.setSourceBox(&.{
        .x = 0,
        .y = 0,
        .width = if (horizontal) @min(span, size.width) else size.width,
        .height = if (horizontal) size.height else @min(span, size.height),
    });
    node.setDestSize(if (horizontal) length else 1, if (horizontal) 1 else length);
    node.node.setPosition(x, y);
}

/// Called once at the beginning of the target output's frame, before glass and
/// capture. Motion only replaces pending geometry, so unseen positions cost O(1).
pub fn flush(self: *Self, output: *Output) void {
    if (self.output != output or !self.dirty) return;
    self.dirty = false;
    const started = stats.nowNs();
    defer {
        stats.global_stats.screenshot_selection.updates += 1;
        stats.global_stats.screenshot_selection.update_ns += stats.nowNs() -% started;
    }
    self.updateSelection() catch |err| {
        self.cancel();
        report(output.server, "Screenshot failed", @errorName(err));
    };
}

fn toolbarX(self: *Self) i32 {
    return @max(0, @divTrunc(self.box.width - 360, 2));
}

fn updateSelection(self: *Self) !void {
    const x = @min(self.start_x, self.end_x);
    const y = @min(self.start_y, self.end_y);
    const w: i32 = @intCast(@abs(self.end_x - self.start_x));
    const h: i32 = @intCast(@abs(self.end_y - self.start_y));
    const right = x + w;
    const bottom = y + h;
    if (self.dragging) {
        setRect(self.shades[0].?, 0, 0, self.box.width, y);
        setRect(self.shades[1].?, 0, bottom, self.box.width, self.box.height - bottom);
        setRect(self.shades[2].?, 0, y, x, h);
        setRect(self.shades[3].?, right, y, self.box.width - right, h);
    } else {
        setRect(self.shades[0].?, 0, 0, self.box.width, self.box.height);
        for (self.shades[1..]) |node| node.?.node.setEnabled(false);
    }
    self.setBorder(0, x, y, w);
    self.setBorder(1, x, bottom, w);
    self.setBorder(2, x, y, h);
    self.setBorder(3, right, y, h);
    for ([_]i32{ x, right }, 0..) |cx, ix| for ([_]i32{ y, bottom }, 0..) |cy, iy| {
        const outer = self.corners[(ix * 2 + iy) * 2].?;
        const inner = self.corners[(ix * 2 + iy) * 2 + 1].?;
        outer.node.setEnabled(self.dragging);
        inner.node.setEnabled(self.dragging);
        outer.node.setPosition(cx - 6, cy - 6);
        inner.node.setPosition(cx - 4, cy - 4);
    };
    const label_node = self.label.?;
    label_node.node.setEnabled(self.dragging);
    if (!self.dragging) return;
    if (self.label_width != w or self.label_height != h) {
        var buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "{d} × {d}", .{ w, h });
        const image = try PanelBuffer.create(116, 30, self.output.?.wlr_output.scale);
        defer image.base.drop();
        var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.output.?.wlr_output.scale);
        r.fillRect(0, 0, 116, 30, .{ .color = ui.theme.global.screenshot_label_bg, .radius = 5, .border_width = 1, .border_color = ui.theme.global.screenshot_label_border });
        r.drawText(10, 4, 100, 22, .{ .content = label, .font_size = 13, .color = selectionWhite().toRgba() });
        label_node.setBuffer(&image.base);
        self.label_width = w;
        self.label_height = h;
        stats.global_stats.screenshot_selection.label_paints += 1;
    }
    label_node.node.setPosition(std.math.clamp(right - 116, 0, @max(0, self.box.width - 116)), @min(bottom + 10, self.box.height - 30));
}

fn paintToolbar(self: *Self) !void {
    const tree = self.tree.?;
    stats.global_stats.screenshot_selection.toolbar_paints += 1;
    stats.global_stats.screenshot_selection.scene_nodes_created += 1;
    const image = try PanelBuffer.create(360, 88, self.output.?.wlr_output.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.output.?.wlr_output.scale);
    const t = ui.theme.shellPalette();
    r.palette = t;
    r.fillRect(0, 0, 360, 58, .{ .color = t.window_bg, .radius = 9, .border_width = 1, .border_color = t.border_hover });
    const buttons = ui.widgets.button;
    // Region is the mode in effect; Full Screen captures at once. `button()`
    // hit tests the same boxes.
    buttons.paint(&r, .{ .x = 9, .y = 8, .w = 132, .h = 42 }, .{ .variant = .primary, .leading_icon = .region, .label = "Region" }, .{});
    buttons.paint(&r, .{ .x = 146, .y = 8, .w = 164, .h = 42 }, .{ .variant = .ghost, .leading_icon = .display, .label = "Full Screen" }, .{});
    buttons.paint(&r, .{ .x = 316, .y = 8, .w = 36, .h = 42 }, .{ .variant = .chrome, .icon = .close, .label = "Cancel" }, .{});
    r.drawText(12, 64, 340, 22, .{ .content = "Drag to save and copy · Esc to cancel", .font_size = 13, .color = selectionWhite().toRgba() });
    const node = try tree.createSceneBuffer(&image.base);
    node.setDestSize(360, 88);
    node.node.setPosition(self.toolbarX(), 20);
}

pub fn motion(self: *Self, x: f64, y: f64) void {
    if (!self.dragging) return;
    stats.global_stats.screenshot_selection.motion_events += 1;
    const end_x = std.math.clamp(@as(i32, @intFromFloat(x)) - self.box.x, 0, self.box.width);
    const end_y = std.math.clamp(@as(i32, @intFromFloat(y)) - self.box.y, 0, self.box.height);
    if (end_x == self.end_x and end_y == self.end_y and !self.dirty) return;
    self.end_x = end_x;
    self.end_y = end_y;
    self.invalidate();
}

fn invalidate(self: *Self) void {
    if (!self.dirty) self.output.?.wlr_output.scheduleFrame();
    self.dirty = true;
}

pub fn button(self: *Self, button_code: u32, pressed: bool, x: f64, y: f64) void {
    if (button_code == 273 and pressed) {
        self.cancel();
        return;
    }
    if (button_code != 272) return;
    const lx = @as(i32, @intFromFloat(x)) - self.box.x;
    const ly = @as(i32, @intFromFloat(y)) - self.box.y;
    if (pressed) {
        const tx = lx - self.toolbarX();
        if (ly >= 20 and ly < 78 and tx >= 0 and tx < 360) {
            if (tx >= 316) self.cancel() else if (tx >= 146) self.capture(null);
            return;
        }
        if (lx < 0 or ly < 0 or lx >= self.box.width or ly >= self.box.height) return;
        self.start_x = lx;
        self.start_y = ly;
        self.dragging = true;
        self.invalidate();
        self.motion(x, y);
    } else if (self.dragging) {
        self.motion(x, y);
        if (self.output == null) return;
        const crop: wlr.Box = .{ .x = @min(self.start_x, self.end_x), .y = @min(self.start_y, self.end_y), .width = @intCast(@abs(self.end_x - self.start_x)), .height = @intCast(@abs(self.end_y - self.start_y)) };
        if (crop.width > 1 and crop.height > 1) self.capture(crop) else {
            self.dragging = false;
            self.invalidate();
        }
    }
}

fn capture(self: *Self, crop: ?wlr.Box) void {
    const output = self.output orelse return;
    self.cancel(); // Remove all picker pixels before the capture frame.
    save(output.server, output, crop);
}

pub fn save(server: *Server, output: *Output, crop: ?wlr.Box) void {
    saveInner(server, output, crop) catch |err| report(server, "Screenshot failed", @errorName(err));
}

fn saveInner(server: *Server, output: *Output, crop: ?wlr.Box) !void {
    const gpa = @import("../main.zig").gpa;
    const mgr = server.screenshot_mgr orelse return error.CaptureUnavailable;
    const home = server.environ.getPosix("HOME") orelse return error.NoHomeDirectory;
    const directory = try std.fmt.allocPrint(gpa, "{s}/Screenshots", .{home});
    defer gpa.free(directory);
    try std.Io.Dir.cwd().createDirPath(server.io, directory);
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts)) != .SUCCESS) return error.ClockFailed;
    const path = try std.fmt.allocPrint(gpa, "{s}/Screenshot-{d}-{d}-{d}.png", .{ directory, ts.sec, ts.nsec, mgr.next_job_id });
    defer gpa.free(path);
    const result = try mgr.queueRequest(.{ .output = std.mem.span(output.wlr_output.name), .path = path, .crop = if (crop) |b| .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height } else null }, null, null);
    if (result == .err) report(server, "Screenshot failed", result.err);
}

pub fn report(server: *Server, title: []const u8, body: []const u8) void {
    if (server.notifications) |manager| {
        _ = manager.postNotification("Screenshot", 0, "", title, body, &.{}, 1, false, true, 3500, "", null) catch {};
    }
}
