//! Temporary spread of live windows, including minimized windows. Presentation
//! transforms leave client geometry, saved positions and focus intact until a
//! selection is accepted. IDs survive client teardown while overview is open.
const std = @import("std");
const World = @import("../World.zig");
const Top = @import("../Toplevel.zig");
const Output = @import("../Output.zig");
const camera = @import("../camera.zig");
const anim = @import("ui").anim;
const sn = @import("../node.zig");
const Self = @This();
const cards_mod = @import("overview_cards.zig");
const gpa = @import("../main.zig").gpa;

saved: ?camera.Camera = null,
destination: camera.Camera = .{},
returning: bool = false,
selected: ?u64 = null,
activate: ?u64 = null,
boosted: ?u64 = null,
output: ?*Output = null,
tree: ?*sn.Tree = null,
edges: [4]*sn.Buffer = undefined,
pointer_x: f64 = 0,
pointer_y: f64 = 0,
cards: std.ArrayList(cards_mod.Card) = .empty,
spread: anim.Anim = .{},

pub const apply = cards_mod.apply;

pub fn amount(self: *const Self, now: i64) f64 {
    return if (self.active()) std.math.clamp(self.spread.value(now), 0, 1) else 0;
}

pub fn contains(self: *Self, id: u64) bool {
    return self.active() and cards_mod.find(self, id) != null;
}

pub fn active(self: *const Self) bool {
    return self.saved != null;
}

pub fn eligible(top: *Top) bool {
    return top.in_world and !top.backend_gone and !top.closing and
        !top.tab_hidden and top.chrome_width > 0 and top.chrome_height > 0;
}

pub fn find(world: *World, id: ?u64) ?*Top {
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |top| if (id == top.id and eligible(top)) return top;
    return null;
}

pub fn toggle(self: *Self, world: *World) void {
    if (self.active()) {
        self.dismiss(world);
        return;
    }
    const server = world.server;
    const input = &server.input;
    if (world.workspaces.active or server.locker != null or server.polkit_dialog != null or
        input.cursor_mode != .passthrough or input.active_buttons != 0 or input.seat.drag != null or
        input.seat.pointerHasGrab() or input.gesture != .none or input.desktop_grab or input.dock_drag.active()) return;
    const output = server.getDefaultOutput() orelse return;
    if (!output.isLogicallyEnabled() or output.idle_blanked) return;
    self.output = output;
    if (output.usableBox().width <= 80 or output.usableBox().height <= 80) return;
    self.createOutline(server.overlay_tree) catch {
        self.output = null;
        return;
    };
    cards_mod.prepare(self, world) catch {
        self.clear();
        return;
    };
    if (self.cards.items.len == 0) {
        self.clear();
        return;
    }
    self.saved = world.sampledCamera(anim.nowMs());
    // Preserve the view actually on screen, even when invoked mid-animation.
    if (@abs(self.saved.?.targetZoom() - self.saved.?.zoom()) > 1e-9) self.saved.?.focus_zoom = self.saved.?.zoom();
    self.returning = false;
    self.activate = null;
    self.boosted = null;
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        @import("../effects/window_minimize.zig").cancelFor(server, top.id);
        if (top.zoom_boost.to > 0) self.boosted = top.id;
        top.setZoomBoost(false);
        if (self.selected == null and eligible(top)) self.selected = top.id;
    }
    server.switcher.cancel();
    server.screenshot_selector.cancel();
    input.window_menu.close();
    if (server.tray) |tray| tray.closeMenu();
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |out| {
        out.closeStartMenu();
        out.closePowerMenu();
        out.closeWifi();
        out.closeBattery();
        out.closeCalendar();
    }
    var keyboards = input.keyboards.iterator(.forward);
    while (keyboards.next()) |keyboard| {
        keyboard.stopRepeat();
        keyboard.stopShellRepeat();
        keyboard.stopSwitcherRepeat();
    }
    world.peek_window_id = null;
    world.mini_map.hide();
    input.seat.pointerClearFocus();
    input.pointer_constraints.sync();
    input.setDefaultCursor();
    self.pointer_x = input.cursor.x;
    self.pointer_y = input.cursor.y;
    self.spread.retargetTo(anim.nowMs(), 1, anim.curveFor(.camera_zoom));
    self.transition(world, self.saved.?);
}

fn transition(self: *Self, world: *World, target: camera.Camera) void {
    self.destination = target;
    const now = anim.nowMs();
    world.panning = false;
    world.pinching = false;
    world.zoom_keeps_anchor = false;
    world.camera.zoom_index = target.zoom_index;
    world.camera.focus_zoom = target.targetZoom();
    world.camera.zoom_limit = @max(world.camera.zoom_limit, target.zoom());
    world.pan_target = .camera_reveal;
    world.pan_x = .{ .from = @floatCast(world.camera.offset_x), .to = @floatCast(world.camera.offset_x) };
    world.pan_y = .{ .from = @floatCast(world.camera.offset_y), .to = @floatCast(world.camera.offset_y) };
    world.zoom_anim = .{ .from = @floatCast(world.camera.zoom()), .to = @floatCast(world.camera.zoom()) };
    world.pan_x.retargetTo(now, @floatCast(target.offset_x), anim.curveFor(.camera_reveal));
    world.pan_y.retargetTo(now, @floatCast(target.offset_y), anim.curveFor(.camera_reveal));
    world.zoom_anim.retargetTo(now, @floatCast(target.zoom()), anim.curveFor(.camera_zoom));
    if (!world.pan_x.active() and !world.pan_y.active() and !world.zoom_anim.active()) {
        world.camera = target;
    } else {
        _ = world.tickCamera(now);
    }
    world.applyCamera();
}

pub fn dismiss(self: *Self, world: *World) void {
    const saved = self.saved orelse return;
    if (self.returning) return;
    self.returning = true;
    self.activate = null;
    self.spread.retargetTo(anim.nowMs(), 0, anim.curveFor(.camera_zoom));
    self.transition(world, saved);
}

pub fn accept(self: *Self, world: *World) void {
    var target = self.saved orelse return;
    if (self.returning) return;
    const top = find(world, self.selected) orelse return self.dismiss(world);
    const mode = world.server.config.compositor.focus_zoom;
    const floating = top.layout() == .floating and !top.isFullscreen();
    // Camera-focus windows live at different depths. Visiting one must use
    // its depth, or the restored camera can pass it and make it invisible.
    if (mode == .camera and floating) {
        target.zoom_value = 1 / top.zoom_scale;
        target.focus_zoom = target.zoom_value;
        target.zoom_limit = @max(1, target.zoom_value);
    }
    const scale = if (mode == .boost and floating) 1 / target.zoom() else top.zoom_scale;
    if (world.windowFocusOffset(top, self.output.?, target, scale, true)) |offset| {
        target.offset_x = offset.x;
        target.offset_y = offset.y;
    }
    self.activate = top.id;
    self.returning = true;
    self.spread.retargetTo(anim.nowMs(), 0, anim.curveFor(.camera_zoom));
    self.transition(world, target);
}

/// Immediate teardown for lock/auth, config reload, output removal and shutdown.
pub fn cancel(self: *Self, world: *World) void {
    const saved = self.saved orelse return;
    world.camera = saved;
    self.finish(world, false);
}

fn finish(self: *Self, world: *World, accepted: bool) void {
    const chosen = if (accepted) self.activate else null;
    const boosted = self.boosted;
    self.clear();
    world.snapCamera();
    if (find(world, chosen)) |top| {
        if (top.minimized) top.restore() else world.focus(top);
        top.setZoomBoost(world.server.config.compositor.focus_zoom == .boost);
    }
    if (chosen == null) if (find(world, boosted)) |top| top.setZoomBoost(true);
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        top.applyVisualTransform(anim.nowMs());
        top.applyOpacity(anim.nowMs());
    }
    world.applyCamera();
    world.server.input.processCursorMotion(0);
}

fn clear(self: *Self) void {
    if (self.tree) |tree| tree.node.destroy();
    self.cards.deinit(gpa);
    self.* = .{};
}

/// Update captions and selection after the live window geometry has settled.
pub fn update(self: *Self, world: *World, now: i64) bool {
    if (!self.active()) return false;
    if (!self.output.?.isLogicallyEnabled() or self.output.?.idle_blanked) {
        self.cancel(world);
        return false;
    }
    _ = self.spread.sampleChanged(now, 0.001);
    const moving = !self.spread.settled(now);
    if (!moving) self.spread.cancel(self.spread.to);
    if (self.returning) {
        if (!moving and !world.pan_x.active() and !world.pan_y.active() and !world.zoom_anim.active()) {
            world.camera = self.destination;
            self.finish(world, true);
            return false;
        }
    } else {
        cards_mod.prepare(self, world) catch self.dismiss(world);
        if (self.cards.items.len == 0) self.dismiss(world);
        if (find(world, self.selected) == null) self.selected = if (self.cards.items.len > 0) self.cards.items[0].id else null;
    }
    for (self.cards.items) |card| if (find(world, card.id)) |top| top.applyVisualTransform(now);
    cards_mod.paint(self, now);
    return moving or (self.active() and !self.spread.settled(now));
}

pub fn motion(self: *Self, world: *World, x: f64, y: f64) void {
    if (self.returning or (x == self.pointer_x and y == self.pointer_y)) return;
    self.pointer_x = x;
    self.pointer_y = y;
    if (cards_mod.picked(self, world, x, y)) |id| {
        if (self.selected == id) return;
        self.selected = id;
        world.server.scheduleFrames();
    }
}

pub fn press(self: *Self, world: *World, button: u32) void {
    if (self.returning) return;
    const cursor = world.server.input.cursor;
    if (button == 272) {
        if (cards_mod.picked(self, world, cursor.x, cursor.y)) |id| {
            self.selected = id;
            self.accept(world);
        } else self.dismiss(world);
    } else if (button == 273) self.dismiss(world);
}

pub fn navigate(self: *Self, world: *World, dx: f64, dy: f64) void {
    if (self.returning) return;
    const current = cards_mod.find(self, self.selected orelse return) orelse return;
    const from = current.target;
    var score: f64 = std.math.inf(f64);
    for (self.cards.items) |card| {
        if (card.id == current.id) continue;
        const x = card.target.x + card.target.width / 2 - from.x - from.width / 2;
        const y = card.target.y + card.target.height / 2 - from.y - from.height / 2;
        const along = x * dx + y * dy;
        if (along <= 1) continue;
        const across = @abs(x * dy - y * dx);
        const distance = along + across * 2;
        if (distance < score) {
            score = distance;
            self.selected = card.id;
        }
    }
    world.server.scheduleFrames();
}

fn createOutline(self: *Self, parent: *sn.Tree) !void {
    const tree = try parent.createSceneTree();
    errdefer tree.node.destroy();
    const pixel = try @import("../panel_buffer.zig").PanelBuffer.create(1, 1, 1);
    defer pixel.base.drop();
    const rgba = @import("ui").theme.global.switcher_selected_border;
    pixel.pixels[0] = (@import("../color.zig").Straight{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] }).premultiply().argb();
    for (&self.edges) |*edge| {
        edge.* = try tree.createSceneBuffer(&pixel.base);
        edge.*.point_accepts_input = ignoreInput;
    }
    self.tree = tree;
}

pub fn ignoreInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}
