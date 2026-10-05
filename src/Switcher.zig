//! Held-modifier window carousel. IDs freeze MRU order for the duration of a
//! gesture; scene buffers retain preview storage independently of clients.
const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const Renderer = @import("ui").paint.Renderer;
const anim = @import("ui").anim;
const Anim = anim.Anim;
const gpa = @import("main.zig").gpa;
const Self = @This();
const theme = @import("ui").theme;
const card_w = 224;
const card_h = 220;
const stride = 244;
const height = 284;

const Card = struct {
    id: u64,
    label: *wlr.SceneBuffer,
    label_source: wlr.FBox,
    icon: *wlr.SceneBuffer,
    icon_source: wlr.FBox,
    icon_ready: bool = false,
    preview: ?*wlr.SceneBuffer = null,
    source: wlr.FBox = undefined,
    pw: i32 = 0,
    ph: i32 = 0,
};

pub const Trigger = enum { alt, ctrl };
trigger: Trigger = .alt,
tree: ?*wlr.SceneTree = null,
output: ?*Output = null,
background: ?*wlr.SceneBuffer = null,
cards: std.ArrayList(Card) = .empty,
buffers: std.ArrayList(*wlr.Buffer) = .empty,
selected: usize = 0,
scroll: Anim = .{},
width: i32 = 0,
scale: f32 = 1,

pub fn active(self: *const Self) bool {
    return self.tree != null;
}

pub fn triggerHeld(self: *const Self, server: *Server) bool {
    var it = server.input.keyboards.iterator(.forward);
    while (it.next()) |keyboard| {
        const mods = keyboard.device.toKeyboard().getModifiers();
        if (switch (self.trigger) {
            .alt => mods.alt,
            .ctrl => mods.ctrl,
        }) return true;
    }
    return false;
}

pub fn step(self: *Self, server: *Server, reverse: bool, trigger: Trigger) void {
    const opening = !self.active();
    if (opening) {
        self.trigger = trigger;
        self.open(server) catch |err| {
            std.log.warn("window switcher: {}", .{err});
            self.cancel();
            return;
        };
    }
    if (self.cards.items.len == 0) return;
    const n = self.cards.items.len;
    self.selected = if (reverse) (self.selected + n - 1) % n else (self.selected + 1) % n;
    const target: f32 = @floatFromInt(self.selected * stride);
    if (opening) {
        // The gesture's first card lands already selected: no slide-in on
        // the opening frame, only on subsequent Tab presses while held.
        self.scroll = .{ .to = target };
    } else {
        self.scroll.retargetTo(@import("Taskbar.zig").nowMs(), target, anim.curveFor(.switcher_scroll));
    }
    self.output.?.wlr_output.scheduleFrame();
}

fn open(self: *Self, server: *Server) !void {
    server.input.window_menu.close();
    const output = server.getDefaultOutput() orelse return;
    if (!output.isLogicallyEnabled() or output.idle_blanked) return;
    const box = output.usableBox();
    if (box.width < 260 or box.height < height) return;
    self.output = output;
    self.width = @min(1500, box.width - 32);
    self.scale = output.wlr_output.scale;
    self.tree = try server.overlay_tree.createSceneTree();
    const bg = try PanelBuffer.create(self.width, height, self.scale);
    defer bg.base.drop();
    var r = Renderer.init(bg.pixels, bg.width, bg.height, self.scale);
    r.fillRect(0, 0, @floatFromInt(self.width), height, .{ .color = theme.global.switcher_bg, .radius = theme.global.switcher_radius, .border_width = 1, .border_color = theme.global.switcher_border });
    self.background = try self.makeNode(&bg.base, self.width, height);
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |tl| {
        if (!tl.isMapped() or tl.tab_hidden) continue;
        const image = try PanelBuffer.create(card_w, card_h, self.scale);
        defer image.base.drop();
        r = Renderer.init(image.pixels, image.width, image.height, self.scale);
        r.fillRect(0, 0, card_w, 156, .{ .color = theme.global.switcher_item_bg, .radius = theme.global.switcher_item_radius, .border_width = 1, .border_color = theme.global.switcher_item_border });
        r.drawIcon(92, 54, 40, 40, .{ .id = .generic, .color = theme.global.switcher_fg });
        r.drawText(8, 174, card_w - 16, 24, .{ .content = tl.title(), .font_size = theme.global.switcher_title_size, .color = theme.global.switcher_fg });
        r.drawText(8, 200, card_w - 16, 20, .{ .content = tl.appId(), .font_size = theme.global.switcher_app_size, .color = theme.global.switcher_dim });
        const label = try self.makeNode(&image.base, card_w, card_h);
        const icon_image = try PanelBuffer.create(40, 40, self.scale);
        defer icon_image.base.drop();
        var ir = Renderer.init(icon_image.pixels, icon_image.width, icon_image.height, self.scale);
        ir.fillRect(0, 0, 40, 40, .{ .color = theme.global.switcher_icon_bg, .radius = theme.global.switcher_icon_radius });
        ir.drawIcon(5, 5, 30, 30, .{ .id = .generic, .color = theme.global.switcher_fg });
        const icon = try self.makeNode(&icon_image.base, 40, 40);
        var card: Card = .{ .icon = icon, .icon_source = .{ .x = 0, .y = 0, .width = @floatFromInt(icon_image.width), .height = @floatFromInt(icon_image.height) }, .id = tl.id, .label = label, .label_source = .{ .x = 0, .y = 0, .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) } };
        card.preview = try self.tree.?.createSceneBuffer(null);
        card.preview.?.setFilterMode(.bilinear);
        card.preview.?.point_accepts_input = ignoreInput;
        updatePreview(&card, tl);
        icon.node.raiseToTop();
        try self.cards.append(gpa, card);
    }
    if (self.cards.items.len == 0) {
        self.cancel();
        return;
    }
    // The selection outline never moves. Only the row beneath it scrolls.
    const outline = try PanelBuffer.create(card_w + 8, 164, self.scale);
    defer outline.base.drop();
    r = Renderer.init(outline.pixels, outline.width, outline.height, self.scale);
    r.fillRect(1, 1, card_w + 6, 162, .{ .color = .{ 0, 0, 0, 0 }, .radius = theme.global.switcher_selection_radius, .border_width = 2, .border_color = theme.global.switcher_selected_border });
    const node = try self.makeNode(&outline.base, card_w + 8, 164);
    node.node.setPosition(@divTrunc(self.width - card_w, 2) - 4, 24);
    _ = self.tick(output, @import("Taskbar.zig").nowMs());
}

fn makeNode(self: *Self, buffer: *wlr.Buffer, w: i32, h: i32) !*wlr.SceneBuffer {
    // Keep storage alive for the entire gesture, including CPU buffers whose
    // scene node releases its reference after the GLES2 texture upload.
    try self.buffers.append(gpa, buffer);
    _ = buffer.lock();
    const node = try self.tree.?.createSceneBuffer(buffer);
    node.setDestSize(w, h);
    node.setFilterMode(.bilinear);
    node.point_accepts_input = ignoreInput;
    return node;
}

/// Crop in source coordinates so partial cards slide cleanly behind the
/// panel's edges, without allocating or repainting on animation frames.
fn place(node: *wlr.SceneBuffer, source: wlr.FBox, x: i32, y: i32, w: i32, h: i32, viewport: i32) void {
    const left = @max(x, 16);
    const right = @min(x + w, viewport - 16);
    node.node.setEnabled(right > left);
    if (right <= left) return;
    var crop = source;
    crop.x += source.width * @as(f64, @floatFromInt(left - x)) / @as(f64, @floatFromInt(w));
    crop.width = source.width * @as(f64, @floatFromInt(right - left)) / @as(f64, @floatFromInt(w));
    node.setSourceBox(&crop);
    node.setDestSize(right - left, h);
    node.node.setPosition(left, y);
}

pub fn tick(self: *Self, output: *Output, now: i64) bool {
    if (!self.active() or self.output != output) return false;
    const box = output.usableBox();
    if (output.server.locker != null or !output.isLogicallyEnabled() or output.idle_blanked or self.scale != output.wlr_output.scale or self.width != @min(1500, box.width - 32) or box.height < height) {
        self.cancel();
        return false;
    }
    // Never leave dead client pointers or a stale selectable preview behind.
    for (self.cards.items) |card| {
        if (output.server.findToplevelById(card.id) == null) {
            self.cancel();
            return false;
        }
    }
    self.background.?.setOpacity(output.server.config.compositor.switcher_opacity);
    self.tree.?.node.setPosition(box.x + @divTrunc(box.width - self.width, 2), box.y + @divTrunc(box.height - height, 2));
    const offset: i32 = @intFromFloat(@round(self.scroll.value(now)));
    for (self.cards.items, 0..) |*card, i| {
        if (!card.icon_ready) if (output.server.findToplevelById(card.id)) |tl| {
            switch (output.server.iconLookup(tl.appId(), @intFromFloat(card.icon_source.width))) {
                .ready => |entry| {
                    if (PanelBuffer.create(40, 40, self.scale)) |image| {
                        defer image.base.drop();
                        var r = Renderer.init(image.pixels, image.width, image.height, self.scale);
                        r.fillRect(0, 0, 40, 40, .{ .color = theme.global.switcher_icon_bg, .radius = theme.global.switcher_icon_radius });
                        const widget: @import("ui").layout.Widget = .{ .kind = .{ .image = .{ .pixels = entry.pixels, .width = entry.size, .height = entry.size } }, .computed_x = 3, .computed_y = 3, .computed_width = 34, .computed_height = 34 };
                        @import("ui").paint.paint(&widget, &r);
                        self.buffers.append(gpa, &image.base) catch continue;
                        _ = image.base.lock();
                        card.icon.setBuffer(&image.base);
                        card.icon_ready = true;
                    } else |_| {}
                },
                .missing => card.icon_ready = true,
                .pending => {},
            }
        };

        const x = @divTrunc(self.width - card_w, 2) + @as(i32, @intCast(i * stride)) - offset;
        place(card.label, card.label_source, x, 28, card_w, card_h, self.width);
        place(card.icon, card.icon_source, x + 92, 156, 40, 40, self.width);
        if (card.pw > 0) if (card.preview) |preview| place(preview, card.source, x + @divTrunc(card_w - card.pw, 2), 36 + @divTrunc(140 - card.ph, 2), card.pw, card.ph, self.width);
    }
    _ = self.scroll.sampleChanged(now, anim.quantum_px);
    return !self.scroll.settled(now);
}

// Replace the scene reference on every commit, including same-buffer damage.
// Old client buffers are released immediately; the gesture never accumulates
// video frames in the CPU buffer retention list.
fn updatePreview(card: *Card, tl: *@import("Toplevel.zig")) void {
    const preview = card.preview orelse return;
    card.pw = 0;
    if (tl.surface()) |surface| {
        if (surface.current.transform == .normal) if (surface.buffer) |buffer| {
            surface.getBufferSourceBox(&card.source);
            const sw: f32 = @floatFromInt(@max(1, surface.current.width));
            const sh: f32 = @floatFromInt(@max(1, surface.current.height));
            const fit = @min(208 / sw, 140 / sh);
            card.pw = @max(1, @as(i32, @intFromFloat(@round(sw * fit))));
            card.ph = @max(1, @as(i32, @intFromFloat(@round(sh * fit))));
            preview.setBuffer(&buffer.base);
            return;
        };
    }
    preview.setBuffer(null);
    preview.node.setEnabled(false);
}

pub fn committed(self: *Self, tl: *@import("Toplevel.zig")) void {
    if (!self.active()) return;
    for (self.cards.items) |*card| {
        if (card.id != tl.id) continue;
        updatePreview(card, tl);
        self.output.?.wlr_output.scheduleFrame();
        return;
    }
}

pub fn frameDone(self: *Self, output: *Output, when: *const std.posix.timespec) void {
    if (!self.active() or self.output != output) return;
    // The main scene may cull an occluded/minimized window. Visible previews
    // still pace that client's animation, using the same presentation clock.
    // Sending twice is harmless: wlroots consumes each callback only once.
    for (self.cards.items) |card| {
        const preview = card.preview orelse continue;
        if (card.pw == 0 or !preview.node.enabled) continue;
        const tl = output.server.findToplevelById(card.id) orelse continue;
        if (tl.surface()) |surface| surface.sendFrameDone(when);
    }
}

pub fn accept(self: *Self, server: *Server) void {
    if (!self.active()) return;
    const id = self.cards.items[self.selected].id;
    const output = self.output;
    self.cancel();
    if (server.findToplevelById(id)) |tl| {
        if (tl.minimized) tl.restore() else server.world.focus(tl);
        if (output) |out| server.world.navigateTo(tl, out);
    }
}

pub fn cancel(self: *Self) void {
    if (self.tree) |tree| tree.node.destroy();
    for (self.buffers.items) |buffer| buffer.unlock();
    self.buffers.deinit(gpa);
    self.cards.deinit(gpa);
    self.* = .{};
}

fn ignoreInput(_: *wlr.SceneBuffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}
