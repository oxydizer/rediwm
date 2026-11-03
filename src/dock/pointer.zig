//! Pointer input: tooltip, motion, presses, clicks, context menu, hiding shortcuts and launching.

const std = @import("std");
const wlr = @import("wlroots");
const ui = @import("ui");
const Server = @import("../Server.zig");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const default_apps = @import("../config_runtime/default_apps.zig");
const anim = ui.anim;
const gpa = @import("../main.zig").gpa;
const Self = @import("../Dock.zig");
const Shortcut = Self.Shortcut;
const tooltip_delay_ms = Self.tooltip_delay_ms;
const hidden = Self.hidden;
const hashValue = Self.hashValue;

/// The pointer is on a new icon (or off every one): its tooltip waits out the
/// delay again.
pub fn restartTip(self: *Self) void {
    self.cancelTip();
    const hovered = self.dispatcher.hovered orelse return;
    if (hovered.kind != .button) return;
    if (self.tip_timer == null) self.tip_timer = self.output.?.server.wl_server.getEventLoop().addTimer(*Self, onTipTimer, self) catch null;
    if (self.tip_timer) |timer| {
        if (timer.timerUpdate(tooltip_delay_ms)) {
            self.tip_armed = true;
            return;
        } else |_| {}
    }
    // No timer: show at once.
    self.tip_ready = true;
}

pub fn cancelTip(self: *Self) void {
    self.tip_ready = false;
    if (!self.tip_armed) return;
    self.tip_armed = false;
    if (self.tip_timer) |timer| timer.timerUpdate(0) catch {};
}

pub fn onTipTimer(self: *Self) c_int {
    self.tip_armed = false;
    if (self.dispatcher.hovered == null or self.tooltip == null) return 0;
    self.tip_ready = true;
    self.paintTooltip() catch {};
    self.output.?.wlr_output.scheduleFrame();
    return 0;
}

pub fn paintTooltip(self: *Self) !void {
    const hovered = self.dispatcher.hovered orelse {
        // A rebuild can leave nothing hovered without a motion.
        self.cancelTip();
        self.tooltip.?.node.setEnabled(false);
        return;
    };
    if (hovered.kind != .button or !self.tip_ready) {
        self.tooltip.?.node.setEnabled(false);
        return;
    }
    const index = hovered.kind.button.id;
    const pal = ui.theme.shellPalette();
    const value = self.label(index);
    var hasher = std.hash.Wyhash.init(0);
    const area = self.output.?.dockAreaBox();
    hashValue(&hasher, .{ pal, self.scale, self.position, self.box.width, area.width, value });
    const key = hasher.final();
    if (key == self.tip_drawn) {
        // Same text: only the button under it may differ.
        self.placeTooltip(hovered, self.tooltip.?.dst_width, area);
        self.tooltip.?.node.setEnabled(true);
        return;
    }
    const max_width = if (self.position.vertical()) area.width - self.box.width - 18 else self.box.width;
    const width: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(max_width)), @max(80, (ui.text.measureWidthF(value, .manrope, pal.font_size, 1) catch 100) + 24)));
    const image = try PanelBuffer.create(width, 30, self.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
    r.palette = pal;
    var bg = pal.window_bg;
    bg[3] = 0.98;
    r.fillRect(0, 0, @floatFromInt(width), 30, .{ .color = bg, .radius = 8, .border_width = 1, .border_color = pal.accent });
    r.drawText(10, 0, @floatFromInt(width - 20), 30, .{ .content = value, .font_size = pal.font_size, .color = pal.window_fg });
    self.tooltip.?.setBuffer(&image.base);
    self.tooltip.?.setDestSize(width, 30);
    self.placeTooltip(hovered, width, area);
    self.tooltip.?.node.setEnabled(true);
    self.tip_drawn = key;
}

pub fn placeTooltip(self: *Self, hovered: *ui.layout.Widget, width: i32, area: wlr.Box) void {
    var x = self.box.x + @as(i32, @intFromFloat(hovered.computed_x + hovered.computed_width / 2)) - @divTrunc(width, 2);
    var y = self.box.y + @as(i32, @intFromFloat(hovered.computed_y + hovered.computed_height / 2)) - 15;
    switch (self.position) {
        .top => y = self.box.y + self.box.height + 8,
        .bottom => y = self.box.y - 38,
        .left => x = self.box.x + self.box.width + 8,
        .right => x = self.box.x - width - 8,
    }
    x = std.math.clamp(x, area.x, @max(area.x, area.x + area.width - width));
    y = std.math.clamp(y, area.y, @max(area.y, area.y + area.height - 30));
    self.tooltip.?.node.setPosition(x - self.box.x, y - self.box.y);
}

pub fn motion(self: *Self, x: f64, y: f64) void {
    const old = self.dispatcher.hovered;
    self.dispatcher.pointerMotion(&self.input_root, @floatCast(x), @floatCast(y));
    if (old != self.dispatcher.hovered) {
        self.restartTip();
        self.repaint();
    }
}

pub fn leave(self: *Self) void {
    // `Dispatcher.pointerLeave` keeps a hovered button lit, and this runs on
    // every motion elsewhere: a motion outside the dock unhovers it once.
    if (self.dispatcher.hovered != null) self.motion(-1, -1);
}

pub fn repaint(self: *Self) void {
    if (self.node == null) return;
    self.paint(anim.nowMs()) catch {};
    self.output.?.wlr_output.scheduleFrame();
}

pub fn press(self: *Self, x: f64, y: f64) void {
    // A pinned icon can be dragged to another place among the pins, so it acts
    // when released in place (`clickPin`); the other launchers act on press, like
    // the taskbar.
    if (self.buttonAt(@floatCast(x), @floatCast(y))) |index| if (self.pin_of[index]) |p| {
        const input = &self.output.?.server.input;
        input.dock_drag.armReorder(input, self.pins[p].id, self.pins[p].icon, self.scale);
        return;
    };
    self.dispatcher.pointerButtonDown(&self.input_root, @floatCast(x), @floatCast(y));
    self.dispatcher.pointerButtonUp(&self.input_root, @floatCast(x), @floatCast(y));
    self.repaint();
}

pub fn buttonAt(self: *const Self, x: f32, y: f32) ?usize {
    for (self.buttons[0..self.count], 0..) |*button, index| {
        if (button.contains(x, y)) return index;
    }
    return null;
}

/// The point (`x`, `y`), in the coordinates `motion` takes, is on the Trash item.
pub fn trashAt(self: *const Self, x: f64, y: f64) bool {
    const index = self.buttonAt(@floatCast(x), @floatCast(y)) orelse return false;
    return self.shortcuts[index] == .trash;
}

/// A pinned icon was pressed and released without being dragged: its click,
/// if the pointer (at layout position `x`, `y`) is still on that icon.
pub fn clickPin(self: *Self, x: f64, y: f64, app_id: []const u8) void {
    const local_x: f32 = @floatCast(x - @as(f64, @floatFromInt(self.box.x)));
    const local_y: f32 = @floatCast(y - @as(f64, @floatFromInt(self.box.y)));
    const index = self.buttonAt(local_x, local_y) orelse return;
    const p = self.pin_of[index] orelse return;
    if (!std.mem.eql(u8, self.pins[p].id, app_id)) return;
    clicked(self, index);
    self.repaint();
}

pub fn contextMenu(self: *Self, x: f64, y: f64, screen_x: i32) bool {
    self.dispatcher.pointerMotion(&self.input_root, @floatCast(x), @floatCast(y));
    const button = self.dispatcher.hovered orelse return false;
    if (button.kind != .button) return false;
    const index = button.kind.button.id;
    const target = self.topAt(index);
    const shortcut = self.shortcuts[index];
    const pin: ?[]const u8 = if (self.pin_of[index]) |p| self.pins[p].id else null;
    if (target == null and shortcut == null and pin == null) return false;
    const input = &self.output.?.server.input;
    input.window_menu.openDock(self, target, shortcut, pin, screen_x, self.box.y + @as(i32, @intFromFloat(y)));
    return input.window_menu.node != null;
}

/// Removes a shortcut's launcher. Its app still shows while it runs.
pub fn removeShortcut(self: *Self, shortcut: Shortcut) void {
    const server = self.output.?.server;
    if (shortcut == .trash) {
        @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, "dock_show_trash", false) catch |err| {
            std.log.warn("could not remove the dock's trash: {}", .{err});
            return;
        };
        server.config.compositor.dock_show_trash = false;
    } else self.saveHidden("dock_hidden_shortcuts", @tagName(shortcut)) catch |err| {
        std.log.warn("could not remove dock shortcut: {}", .{err});
        return;
    };
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
}

pub fn saveHidden(self: *Self, comptime key: []const u8, name: []const u8) !void {
    const server = self.output.?.server;
    const old = @field(server.config.compositor, key);
    if (hidden(old, name)) return;
    const a = server.config.arena.allocator();
    const items = try a.alloc([]const u8, old.len + 1);
    @memcpy(items[0..old.len], old);
    items[old.len] = try a.dupe(u8, name);
    try @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, key, @as([]const []const u8, items));
    @field(server.config.compositor, key) = items;
}

pub fn clicked(owner: ?*anyopaque, index: usize) void {
    const self: *Self = @ptrCast(@alignCast(owner.?));
    const output = self.output.?;
    const server = output.server;
    if (server.locker != null) return;
    if (self.openWindowPicker(index)) return;
    if (self.topAt(index)) |top| {
        const focused = @import("../ipc/handlers.zig").findFocusedToplevel(server) == top;
        if (!top.minimized and focused and server.world.isWindowVisible(top, output)) {
            top.minimize();
        } else {
            if (top.minimized) top.restore() else server.world.focus(top);
            server.world.navigateTo(top, output);
        }
    } else if (self.pin_of[index]) |pin_index| {
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        const id = self.pins[pin_index].id;
        const entry = default_apps.find(snapshot.entries, id) orelse return;
        server.launch_feedback.setOrigin(self.launchOrigin(index));
        defer server.launch_feedback.clearOrigin();
        @import("../start_menu/launch.zig").launch(gpa, server, entry) catch |err| std.log.warn("could not launch pinned app {s}: {}", .{ id, err });
    } else if (self.shortcuts[index]) |shortcut| switch (shortcut) {
        .applications => output.toggleAppLauncher(),
        .files, .terminal => {
            server.launch_feedback.setOrigin(self.launchOrigin(index));
            defer server.launch_feedback.clearOrigin();
            @import("../config_runtime/actions.zig").executeAction(server, .{ .spawn = if (shortcut == .files) "default-file-manager" else "default-terminal" });
        },
        .settings => output.toggleControlCenter(),
        .trash => {
            server.launch_feedback.setOrigin(self.launchOrigin(index));
            defer server.launch_feedback.clearOrigin();
            openTrash(server);
        },
    };
}

/// Opens the trash (`$XDG_DATA_HOME/Trash/files`) in the default file manager,
/// as the desktop's Trash icon does.
pub fn openTrash(server: *Server) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const home = server.environ.getPosix("HOME") orelse return;
    const data_home = server.environ.getPosix("XDG_DATA_HOME") orelse (std.fmt.allocPrint(a, "{s}/.local/share", .{home}) catch return);
    const trash = std.fmt.allocPrint(a, "{s}/Trash/files", .{data_home}) catch return;
    // Files browses the trash by path; it must exist before the first deletion.
    std.Io.Dir.cwd().createDirPath(server.io, trash) catch {};
    const id = server.config.compositor.default_file_manager;
    if (id.len > 0) {
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        if (default_apps.find(snapshot.entries, id)) |entry| {
            const uris = @import("../desktop/dnd.zig").uriList(a, &.{trash}) catch return;
            const uri = std.mem.trimEnd(u8, uris, "\r\n");
            @import("../start_menu/launch.zig").launchUris(gpa, server, entry, &.{uri}) catch |err| std.log.warn("could not open the trash in {s}: {}", .{ id, err });
            return;
        }
    }
    @import("../config_runtime/actions.zig").spawnArgv(server, &.{ "rediwm-files", trash });
}

/// The layout-space square of item `index`'s icon, which a window it launches
/// grows out of.
pub fn launchOrigin(self: *const Self, index: usize) @import("../launch_feedback.zig").Origin {
    const button = &self.buttons[index];
    const side: f64 = @min(button.computed_width, button.computed_height);
    return .{
        .x = @as(f64, @floatFromInt(self.box.x)) + button.computed_x + (button.computed_width - side) / 2,
        .y = @as(f64, @floatFromInt(self.box.y)) + button.computed_y + (button.computed_height - side) / 2,
        .width = side,
        .height = side,
    };
}
