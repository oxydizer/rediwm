//! Held-modifier window switcher. IDs freeze MRU order for the duration of a
//! gesture; scene buffers retain preview storage independently of clients.
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("node.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const Renderer = @import("ui").paint.Renderer;
const anim = @import("ui").anim;
const Anim = anim.Anim;
const gpa = @import("main.zig").gpa;
const Self = @This();
const theme = @import("ui").theme;
const circular = @import("switcher/circular.zig");
const preview_binding = @import("switcher/preview.zig");
const card_w = 224;
const card_h = 220;
const stride = 244;
const height = 284;

pub const Card = struct {
    id: u64,
    label: ?*sn.Buffer = null,
    label_source: wlr.FBox = undefined,
    icon: *sn.Buffer,
    icon_buffer: *wlr.Buffer,
    icon_source: wlr.FBox,
    icon_ready: bool = false,
    /// The window's content: its surface and any subsurfaces, or a `.shell`
    /// window's body. `pw` is zero while there is nothing to show.
    content: preview_binding.Stack = .{},
    pw: i32 = 0,
    ph: i32 = 0,
    aspect: f64 = 1,
    tree: ?*sn.Tree = null,
    fill: ?*sn.Rect = null,
    group: usize = 0,
    member: usize = 0,
    /// Circular style only: this card's animated distance from the front of
    /// its group's stack, so bringing a different member forward (`Tab`)
    /// slides the stack into place instead of snapping.
    stack: Anim = .{},
    /// Circular sector border intensity, eased independently for hover exits.
    hover: Anim = .{ .property = .opacity },
};

pub const Trigger = enum { alt, ctrl };
trigger: Trigger = .alt,
tree: ?*sn.Tree = null,
output: ?*Output = null,
background: ?*sn.Buffer = null,
cards: std.ArrayList(Card) = .empty,
buffers: std.ArrayList(*wlr.Buffer) = .empty,
selected: usize = 0,
scroll: Anim = .{},
width: i32 = 0,
scale: f32 = 1,
style: @import("config").types.SwitcherStyle = .linear,
circle: circular.State = .{},
/// The card under the pointer, recomputed every tick from the last known
/// cursor position so it tracks reflow (scroll offset, Tab) even when the
/// mouse itself hasn't moved since.
hovered: ?usize = null,
last_cursor_x: f64 = 0,
last_cursor_y: f64 = 0,
/// Linear style only: a single reusable ring repositioned over whichever
/// card is hovered, distinct from the fixed Tab-selection outline.
hover_outline: ?*sn.Buffer = null,

pub fn active(self: *const Self) bool {
    return self.tree != null;
}

pub fn triggerHeld(self: *const Self, server: *Server) bool {
    var it = server.input.keyboards.iterator(.forward);
    while (it.next()) |keyboard| {
        // The input method's own virtual keyboard echoes what the compositor
        // forwarded to it; while the switcher owns input that echo can lag or
        // go stale, so counting it could leave a released trigger looking
        // held. Only real devices keep the gesture alive.
        if (server.text_input) |relay| if (relay.isMethodEcho(keyboard.device)) continue;
        const mods = keyboard.device.toKeyboard().getModifiers();
        if (switch (self.trigger) {
            .alt => mods.alt,
            .ctrl => mods.ctrl,
        }) return true;
    }
    return false;
}

pub fn step(self: *Self, server: *Server, reverse: bool, trigger: Trigger) void {
    // A still-fading-out instance can only be here because a new gesture
    // (the previous one already ended via `dismiss`) just started: finish
    // the old teardown now so `opening` below sees a clean slate, rather
    // than silently dropping this Tab or stepping a zombie instance.
    if (self.circle.closing) self.cancel();
    const opening = !self.active();
    if (opening) {
        self.trigger = trigger;
        self.open(server) catch |err| {
            std.log.warn("window switcher: {}", .{err});
            self.cancel();
            return;
        };
        if (self.active()) takePointer(server);
    }
    if (self.cards.items.len == 0) return;
    if (self.circle.enabled) {
        circular.advance(self, reverse);
        circular.select(self, opening);
        self.output.?.wlr_output.scheduleFrame();
        return;
    }
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

/// The switcher owns the pointer while it is up. The client under it would
/// otherwise keep pointer focus without hearing any motion, and with it the
/// cursor it last set: hidden by a terminal or a player since the last key or
/// frame, a text beam, and nothing would bring the arrow back over the cards.
/// A press or a grab in progress is left alone; it ends where it started.
fn takePointer(server: *Server) void {
    const input = &server.input;
    if (input.active_buttons != 0 or input.seat.drag != null or input.cursor_mode != .passthrough) return;
    input.seat.pointerClearFocus();
    input.pointer_constraints.sync();
    input.setDefaultCursor();
}

/// The gesture is over: tear down, then let the pointer find what is under it
/// again (a client sets its own cursor on that enter). Only for ends that come
/// from the user or the frame loop; forced teardowns call `cancel` alone, from
/// places where input may already be shutting down or locked.
pub fn close(self: *Self, server: *Server) void {
    self.cancel();
    server.input.processCursorMotion(0);
}

/// Circular style only: the key above Tab or Up/Down steps through the
/// selected app's own windows while the switcher is held open.
pub fn stepWindow(self: *Self, reverse: bool) void {
    if (!self.active() or !self.circle.enabled or self.circle.closing or self.cards.items.len == 0) return;
    const before = self.selected;
    circular.advanceMember(self, reverse);
    if (self.selected == before) return;
    circular.select(self, false);
    self.output.?.wlr_output.scheduleFrame();
}

fn open(self: *Self, server: *Server) !void {
    server.input.window_menu.close();
    const output = server.getDefaultOutput() orelse return;
    if (!output.isLogicallyEnabled() or output.idle_blanked) return;
    const box = output.usableBox();
    if (box.width < 260 or box.height < height) return;
    self.output = output;
    self.last_cursor_x = server.input.cursor.x;
    self.last_cursor_y = server.input.cursor.y;
    self.style = server.config.compositor.switcher_style;
    self.circle.enabled = self.style == .circular and circular.layout.diameter(box.width, box.height) >= 360 and @import("chrome.zig").polygonsReady();
    self.width = if (self.circle.enabled) circular.layout.diameter(box.width, box.height) else @min(1500, box.width - 32);
    self.scale = output.wlr_output.scale;
    self.tree = try server.overlay_tree.createSceneTree();
    if (self.circle.enabled) {
        try circular.open(self, server);
        if (self.cards.items.len == 0) self.cancel();
        return;
    }
    const bg = try PanelBuffer.create(self.width, height, self.scale);
    defer bg.base.drop();
    var r = Renderer.init(bg.pixels, bg.width, bg.height, self.scale);
    r.fillRect(0, 0, @floatFromInt(self.width), height, .{ .color = theme.global.switcher_bg, .radius = theme.global.switcher_radius, .border_width = 1, .border_color = theme.global.switcher_border });
    self.background = try self.makeNode(&bg.base, self.width, height);
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |tl| {
        if (!tl.isMapped() or tl.tab_hidden or !@import("workspaces.zig").visible(tl)) continue;
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
        const card: Card = .{ .icon = icon, .icon_buffer = &icon_image.base, .icon_source = .{ .x = 0, .y = 0, .width = @floatFromInt(icon_image.width), .height = @floatFromInt(icon_image.height) }, .id = tl.id, .label = label, .label_source = .{ .x = 0, .y = 0, .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) } };
        // Stored first: `cancel` then owns the card's content on any error.
        try self.cards.append(gpa, card);
        const stored = &self.cards.items[self.cards.items.len - 1];
        _ = try stored.content.addNode(self.tree.?, ignoreInput);
        updatePreview(stored, tl);
        icon.node.raiseToTop();
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
    // A second, subtler ring reused across frames and just repositioned over
    // whichever card the pointer sits on; unlike `outline` it isn't fixed.
    const hover = try PanelBuffer.create(card_w + 8, 164, self.scale);
    defer hover.base.drop();
    r = Renderer.init(hover.pixels, hover.width, hover.height, self.scale);
    r.fillRect(1, 1, card_w + 6, 162, .{ .color = .{ 0, 0, 0, 0 }, .radius = theme.global.switcher_selection_radius, .border_width = 2, .border_color = theme.global.border_hover });
    self.hover_outline = try self.makeNode(&hover.base, card_w + 8, 164);
    self.hover_outline.?.node.setEnabled(false);
    _ = self.tick(output, @import("Taskbar.zig").nowMs());
}

pub fn makeNode(self: *Self, buffer: *wlr.Buffer, w: i32, h: i32) !*sn.Buffer {
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
fn place(node: *sn.Buffer, source: wlr.FBox, x: i32, y: i32, w: i32, h: i32, viewport: i32) void {
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

/// Linear style: the window's surfaces inside its thumbnail at (x, y), each
/// cut to the window's own bounds like the scene cuts a real one.
fn placeContent(card: *Card, x: i32, y: i32, viewport: i32) void {
    const stack = &card.content;
    const fx = @as(f64, @floatFromInt(card.pw)) / @as(f64, @floatFromInt(stack.width));
    const fy = @as(f64, @floatFromInt(card.ph)) / @as(f64, @floatFromInt(stack.height));
    for (stack.active()) |layer| {
        const x1 = @max(layer.x, 0);
        const y1 = @max(layer.y, 0);
        const x2 = @min(layer.x + layer.width, stack.width);
        const y2 = @min(layer.y + layer.height, stack.height);
        const left: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(x1)) * fx));
        const top: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(y1)) * fy));
        const right: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(x2)) * fx));
        const bottom: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(y2)) * fy));
        if (right <= left or bottom <= top) {
            layer.node.node.setEnabled(false);
            continue;
        }
        const w: f64 = @floatFromInt(layer.width);
        const h: f64 = @floatFromInt(layer.height);
        const crop: wlr.FBox = .{
            .x = layer.source.x + layer.source.width * @as(f64, @floatFromInt(x1 - layer.x)) / w,
            .y = layer.source.y + layer.source.height * @as(f64, @floatFromInt(y1 - layer.y)) / h,
            .width = layer.source.width * @as(f64, @floatFromInt(x2 - x1)) / w,
            .height = layer.source.height * @as(f64, @floatFromInt(y2 - y1)) / h,
        };
        place(layer.node, crop, x + left, y + top, right - left, bottom - top, viewport);
    }
}

pub fn tick(self: *Self, output: *Output, now: i64) bool {
    if (!self.active() or self.output != output) return false;
    const box = output.usableBox();
    const expected_width = if (self.circle.enabled) circular.layout.diameter(box.width, box.height) else @min(1500, box.width - 32);
    if (output.server.locker != null or !output.isLogicallyEnabled() or output.idle_blanked or self.scale != output.wlr_output.scale or self.width != expected_width or box.height < height or self.style != output.server.config.compositor.switcher_style) {
        self.close(output.server);
        return false;
    }
    // Never leave dead client pointers or a stale selectable preview behind.
    for (self.cards.items) |*card| {
        const tl = output.server.findToplevelById(card.id) orelse {
            self.close(output.server);
            return false;
        };
        // A subsurface maps, moves or resizes on commits its toplevel never
        // makes: what the window is made of is read again every frame. A
        // `.shell` body is shared again only when it is presented (`committed`).
        if (tl.backend != .shell) updatePreview(card, tl);
    }
    // Recomputed every frame (not just on pointer motion) so Tab reflowing
    // the layout under a stationary mouse still tracks the right card.
    // Suppressed while closing: nothing should light up as it collapses.
    self.hovered = if (self.circle.closing) null else self.hit(output, now, self.last_cursor_x, self.last_cursor_y);
    if (self.circle.enabled) return circular.tick(self, output, now);
    self.background.?.setOpacity(output.server.config.compositor.switcher_opacity);
    self.tree.?.node.setPosition(box.x + @divTrunc(box.width - self.width, 2), box.y + @divTrunc(box.height - height, 2));
    const offset: i32 = @intFromFloat(@round(self.scroll.value(now)));
    var hover_shown = false;
    for (self.cards.items, 0..) |*card, i| {
        refreshIcon(self, card);

        const x = @divTrunc(self.width - card_w, 2) + @as(i32, @intCast(i * stride)) - offset;
        place(card.label.?, card.label_source, x, 28, card_w, card_h, self.width);
        place(card.icon, card.icon_source, x + 92, 156, 40, 40, self.width);
        if (card.pw > 0) placeContent(card, x + @divTrunc(card_w - card.pw, 2), 36 + @divTrunc(140 - card.ph, 2), self.width);
        // The fixed selection outline already marks this card; a second ring
        // on top of it would just look like a doubled border.
        if (self.hovered == i and i != self.selected) {
            self.hover_outline.?.node.setPosition(x - 4, 24);
            hover_shown = true;
        }
    }
    self.hover_outline.?.node.setEnabled(hover_shown);
    _ = self.scroll.sampleChanged(now, anim.quantum_px);
    return !self.scroll.settled(now);
}

pub fn refreshIcon(self: *Self, card: *Card) void {
    const output = self.output orelse return;
    if (!card.icon_ready) if (output.server.findToplevelById(card.id)) |tl| {
        switch (output.server.iconLookup(tl.appId(), @intFromFloat(card.icon_source.width))) {
            .ready => |entry| {
                if (PanelBuffer.create(40, 40, self.scale)) |image| {
                    defer image.base.drop();
                    var r = Renderer.init(image.pixels, image.width, image.height, self.scale);
                    r.fillRect(0, 0, 40, 40, .{ .color = theme.global.switcher_icon_bg, .radius = theme.global.switcher_icon_radius });
                    const widget: @import("ui").layout.Widget = .{ .kind = .{ .image = .{ .pixels = entry.pixels, .width = entry.size, .height = entry.size } }, .computed_x = 3, .computed_y = 3, .computed_width = 34, .computed_height = 34 };
                    @import("ui").paint.paint(&widget, &r);
                    self.buffers.append(gpa, &image.base) catch return;
                    _ = image.base.lock();
                    card.icon.setBuffer(&image.base);
                    card.icon_buffer = &image.base;
                    card.icon_ready = true;
                } else |_| {}
            },
            .missing => card.icon_ready = true,
            .pending => {},
        }
    };
}

/// What the card shows of its window, read from the window as it is now. The
/// nodes follow their surfaces' commits themselves (old client buffers are
/// released at once, so a gesture never accumulates video frames); this keeps
/// which surfaces there are, where they sit and the thumbnail's size.
pub fn updatePreview(card: *Card, tl: *@import("Toplevel.zig")) void {
    const stack = &card.content;
    card.pw = 0;
    if (tl.backend == .shell) {
        // Settings has no wl_surface: share the body it presents instead.
        const cc = tl.backend.shell.control_center orelse return stack.clear();
        const body = cc.buffer_node;
        if (stack.layers.items.len == 0 or body.buffer_width <= 0 or body.buffer_height <= 0 or cc.panel_box.width <= 0 or cc.panel_box.height <= 0) return stack.clear();
        const layer = &stack.layers.items[0];
        if (!preview_binding.setOwned(layer.node, body)) return stack.clear();
        layer.* = .{ .node = layer.node, .width = cc.panel_box.width, .height = cc.panel_box.height, .source = .{ .x = 0, .y = 0, .width = @floatFromInt(body.buffer_width), .height = @floatFromInt(body.buffer_height) } };
        stack.shown = 1;
        stack.width = cc.panel_box.width;
        stack.height = cc.panel_box.height;
        fit(card, @floatFromInt(cc.panel_box.width), @floatFromInt(cc.panel_box.height));
        return;
    }
    const surface = tl.surface() orelse return stack.clear();
    if (stack.follow(surface)) fit(card, @floatFromInt(stack.width), @floatFromInt(stack.height));
}

/// Size the linear card's thumbnail for content of `sw`×`sh` logical pixels.
fn fit(card: *Card, sw: f32, sh: f32) void {
    card.aspect = sw / sh;
    const factor = @min(208 / sw, 140 / sh);
    card.pw = @max(1, @as(i32, @intFromFloat(@round(sw * factor))));
    card.ph = @max(1, @as(i32, @intFromFloat(@round(sh * factor))));
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
    for (self.cards.items) |*card| {
        if (card.pw == 0) continue;
        // Each surface paces itself: a browser's content subsurface asks for
        // its own callbacks, not its toplevel's.
        for (card.content.active()) |layer| {
            if (!layer.node.node.visible()) continue;
            if (preview_binding.getSurface(layer.node)) |surface| surface.sendFrameDone(when);
        }
    }
}

/// Pointer moved while the switcher is up: only schedules a frame (which
/// recomputes `hovered` in `tick`) when that would actually change it, so
/// jiggling the mouse over empty space stays idle.
pub fn motion(self: *Self, x: f64, y: f64) void {
    if (!self.active() or self.circle.closing) return;
    const output = self.output orelse return;
    self.last_cursor_x = x;
    self.last_cursor_y = y;
    const now = @import("Taskbar.zig").nowMs();
    if (self.hit(output, now, x, y) == self.hovered) return;
    output.wlr_output.scheduleFrame();
}

/// A left click on a card jumps straight to it, same as Tab-ing there and
/// releasing the modifier; anything else (a miss, another button) cancels,
/// matching the switcher's prior any-click-dismisses behavior.
pub fn press(self: *Self, server: *Server, x: f64, y: f64, button: u32) void {
    if (!self.active() or self.circle.closing) return;
    if (button == 0x110) {
        if (self.output) |output| {
            const now = @import("Taskbar.zig").nowMs();
            if (self.hit(output, now, x, y)) |index| {
                self.selected = index;
                self.accept(server);
                return;
            }
        }
    }
    self.dismiss();
}

fn hit(self: *Self, output: *Output, now: i64, x: f64, y: f64) ?usize {
    const box = output.usableBox();
    const lx = x - @as(f64, @floatFromInt(box.x + @divTrunc(box.width - self.width, 2)));
    if (self.circle.enabled) {
        const ly = y - @as(f64, @floatFromInt(box.y + @divTrunc(box.height - self.width, 2)));
        return circular.hit(self, now, lx, ly);
    }
    const ly = y - @as(f64, @floatFromInt(box.y + @divTrunc(box.height - height, 2)));
    if (ly < 28 or ly >= 28 + card_h) return null;
    const offset: f64 = self.scroll.value(now);
    for (0..self.cards.items.len) |i| {
        const cx: f64 = @floatFromInt(@divTrunc(self.width - card_w, 2) + @as(i32, @intCast(i * stride)));
        const left = @max(cx - offset, 16);
        const right = @min(cx - offset + card_w, @as(f64, @floatFromInt(self.width - 16)));
        if (lx >= left and lx < right) return i;
    }
    return null;
}

pub fn accept(self: *Self, server: *Server) void {
    if (!self.active() or self.circle.closing) return;
    const id = self.cards.items[self.selected].id;
    const output = self.output;
    self.dismiss();
    if (server.findToplevelById(id)) |tl| {
        if (tl.minimized) tl.restore() else server.world.focus(tl);
        if (output) |out| server.world.navigateTo(tl, out);
    }
    // The chosen window may now be the one under the pointer. An animated
    // close does this when it settles (`circular.tick`).
    if (!self.active()) server.input.processCursorMotion(0);
}

/// Ends the switcher the way the user asked for it to end: releasing the
/// modifier, Escape, or a click (through `accept`/`press`). The circular
/// style plays its close animation first (`circular.beginClose`); `tick`
/// finishes the real teardown once it settles, which `Anim.settled` reports
/// as already true this same call when animations are off, reduced, or the
/// linear style has nothing to animate, so this still closes synchronously
/// then. A forced teardown (output loss, session lock, a card's window
/// gone, ...) must stay instant and calls `cancel` directly instead.
pub fn dismiss(self: *Self) void {
    if (!self.active()) return;
    const server = self.output.?.server;
    if (self.circle.closing or !self.circle.enabled) {
        self.close(server);
        return;
    }
    const now = @import("Taskbar.zig").nowMs();
    circular.beginClose(self, now);
    if (self.circle.appear.settled(now)) {
        self.close(server);
        return;
    }
    self.output.?.wlr_output.scheduleFrame();
}

pub fn cancel(self: *Self) void {
    if (self.tree) |tree| tree.node.destroy();
    self.circle.deinit();
    for (self.buffers.items) |buffer| buffer.unlock();
    self.buffers.deinit(gpa);
    for (self.cards.items) |*card| card.content.deinit();
    self.cards.deinit(gpa);
    self.* = .{};
}

pub fn ignoreInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}
