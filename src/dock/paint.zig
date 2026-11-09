//! Painting: look keys, the retained raster with per-item cells, items, marks and the background.

const std = @import("std");
const ui = @import("ui");
const IconEntry = @import("../icon_service.zig").Entry;
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const glass = @import("../glass.zig");
const config = @import("config").loader;
const anim = ui.anim;
const gpa = @import("../main.zig").gpa;
const Self = @import("../Dock.zig");
const max_items = Self.max_items;
const Metrics = Self.Metrics;

/// Hashes a value field by field; floats by their bits, slices by contents.
pub fn hashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| {
            hasher.update(&.{1});
            hashValue(hasher, v);
        } else hasher.update(&.{0}),
        .@"struct" => |info| inline for (info.field_names) |name| hashValue(hasher, @field(value, name)),
        .pointer => {
            hasher.update(std.mem.asBytes(&value.len));
            hasher.update(std.mem.sliceAsBytes(value));
        },
        else => hasher.update(std.mem.asBytes(&value)),
    }
}

/// What one button shows.
pub const Look = struct {
    focused: bool,
    window_count: usize,
    icon: ?IconEntry,
    pill_width: f32,
    pill_opacity: f32,
    zoom: f32,
};

pub fn paint(self: *Self, now_ms: i64) !void {
    const output = self.output.?;
    const m = self.metrics();
    const pal = ui.theme.shellPalette();
    const bg = background(&output.server.config.compositor, pal);
    const focused = @import("../ipc/handlers.zig").findFocusedToplevel(output.server);
    var looks: [max_items]Look = undefined;
    var item_keys: [max_items]u64 = undefined;
    self.animating = false;
    // Dock-wide state: a change repaints the whole raster. Each item's own look is
    // keyed apart, so a hover repaints only the icons it moves.
    var base_hasher = std.hash.Wyhash.init(0);
    hashValue(&base_hasher, .{ pal, bg, self.scale, self.position, self.box.width, self.box.height, self.count, self.offset, self.windows, self.pin_base, self.drop_slot, output.server.config.compositor.dock_hover_zoom, output.server.config.compositor.dock_active_highlight });
    const base_key = base_hasher.final();
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&base_key));
    for (self.buttons[0..self.count], looks[0..self.count], 0..) |button, *look, index| {
        const top = self.topAt(index);
        const icon_name = if (self.shortcuts[index]) |shortcut| switch (shortcut) {
            .applications => "builtin:redi-logo",
            .files => "rediwm-files",
            .terminal => "utilities-terminal",
            .settings => ui.shell_icons.settings_icon_name,
            .trash => "user-trash",
        } else if (self.pin_of[index]) |p| self.pins[p].icon else if (top) |t| t.appId() else "";
        // Retain one raster at the largest zoom, not a new size each frame.
        const hover_zoom = output.server.config.compositor.dock_hover_zoom;
        const range = self.zoomRange();
        const lookup = output.server.iconLookup(icon_name, self.iconRaster(m));
        const active = top != null and top == focused;
        const width: f32 = if (top == null) 0 else if (active) 22 else 10;
        const opacity: f32 = if (top) |t| if (t.minimized) 0.4 else 1 else 0;
        const pill = &self.animations[index];
        const zoom: f32 = if (self.dispatcher.hovered == &self.buttons[index]) hover_zoom else 1;
        if (hover_zoom == 1) {
            pill.zoom.cancel(1);
        } else if (pill.zoom.to != zoom) pill.zoom.retargetTo(now_ms, zoom, anim.curveFor(.dock_hover));
        if (pill.width.to != width) pill.width.retargetTo(now_ms, width, anim.curveFor(.taskbar_hover));
        if (pill.opacity.to != opacity) pill.opacity.retargetTo(now_ms, opacity, anim.curveFor(.taskbar_hover));
        _ = pill.width.sampleChanged(now_ms, anim.rasterPixelQuantum(self.scale) / (4 * m.size(1)));
        _ = pill.opacity.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        _ = pill.zoom.sampleChanged(now_ms, anim.rasterPixelQuantum(self.scale) / (4 * m.size(36)));
        self.animating = self.animating or !pill.width.settled(now_ms) or !pill.opacity.settled(now_ms) or !pill.zoom.settled(now_ms);
        look.* = .{
            .focused = active,
            .window_count = self.window_counts[index],
            .icon = if (lookup == .ready) lookup.ready else null,
            .pill_width = @max(0, pill.width.last_quantised),
            .pill_opacity = std.math.clamp(pill.opacity.last_quantised, 0, 1),
            .zoom = std.math.clamp(pill.zoom.last_quantised, range.min, range.max),
        };
        // Input covers both the resting button and the growing icon. Centres
        // along the row stay fixed when moving between neighbours.
        self.setButtonZoom(index, look.zoom);
        const icon_id: ?u64 = if (look.icon) |icon| icon.id else null;
        var item_hasher = std.hash.Wyhash.init(0);
        hashValue(&item_hasher, .{ self.shortcuts[index], self.pin_of[index], button.kind.button.state, look.focused, look.window_count, icon_id, look.pill_width, look.pill_opacity, look.zoom });
        item_keys[index] = item_hasher.final();
        hasher.update(std.mem.asBytes(&item_keys[index]));
    }
    const key = hasher.final();
    if (key != self.drawn) try self.paintDock(pal, bg, looks[0..self.count], base_key, item_keys[0..self.count]);
    self.drawn = key;
    try self.paintTooltip();
}

/// Device pixels of the icon raster the dock asks for: the largest size an icon
/// is drawn at, so hovering never needs another.
pub fn iconRaster(self: *const Self, m: Metrics) i32 {
    const zoom = self.zoomRange().max;
    return @import("../geometry.zig").devicePixels(@intFromFloat(@ceil(@as(f32, @floatFromInt(m.length(36))) * zoom)), self.scale);
}

/// The dock's background: the theme's `dock_bg`, else the taskbar's with a
/// floor on its alpha. `dock_opacity`, when set, replaces the alpha of either.
pub fn background(c: *const config.CompositorConfig, pal: ui.theme.Theme) [4]f32 {
    var bg = pal.dock_bg orelse ui.theme.taskbar(.taskbar_bg);
    if (pal.dock_bg == null) bg[3] = @max(bg[3], 0.86);
    if (c.dock_opacity) |opacity| bg[3] = std.math.clamp(opacity, 0, 1);
    return bg;
}

/// The dock's corner radius: the theme's `dock_radius`, or the window frame's
/// (Appearance's Radius) while that is zero. Painting caps it at half the dock.
pub fn cornerRadius(pal: ui.theme.Theme) f32 {
    return if (pal.dock_radius > 0) pal.dock_radius else ui.window_chrome.frameRadius();
}

/// A device-pixel rectangle of the dock raster.
pub const DeviceRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn area(self: DeviceRect) i64 {
        return @as(i64, self.x1 - self.x0) * @as(i64, self.y1 - self.y0);
    }

    fn overlaps(self: DeviceRect, other: DeviceRect) bool {
        return self.x0 < other.x1 and other.x0 < self.x1 and self.y0 < other.y1 and other.y0 < self.y1;
    }

    fn join(self: DeviceRect, other: DeviceRect) DeviceRect {
        return .{ .x0 = @min(self.x0, other.x0), .y0 = @min(self.y0, other.y0), .x1 = @max(self.x1, other.x1), .y1 = @max(self.y1, other.y1) };
    }
};

/// Everything item `index` can paint, at the largest hover zoom, across the dock's
/// thickness: the cell a repaint of that item must restore. Neighbours' cells
/// may overlap at the top of a large zoom's bounce; a partial repaint redraws
/// every item whose cell meets the dirty box, so that stays exact.
pub fn itemCell(self: *const Self, m: Metrics, index: usize, width: i32, height: i32) DeviceRect {
    const base: f32 = @floatFromInt(m.length(48));
    const side = @max(base, @as(f32, @floatFromInt(m.length(36))) * self.zoomRange().max);
    const centre = @as(f32, @floatFromInt(@as(i32, @intCast(index)) * m.itemStep() + m.padding())) + base / 2;
    const lo: i32 = @intFromFloat(@floor((centre - side / 2) * self.scale));
    const hi: i32 = @intFromFloat(@ceil((centre + side / 2) * self.scale));
    return if (self.position.vertical())
        .{ .x0 = 0, .y0 = @max(0, lo), .x1 = width, .y1 = @min(height, hi) }
    else
        .{ .x0 = @max(0, lo), .y0 = 0, .x1 = @min(width, hi), .y1 = height };
}

/// The cells whose items changed since the retained raster, or null when the whole
/// dock must be painted: nothing retained, dock-wide state moved, or the changed
/// cells cover most of it anyway.
pub fn changedCells(self: *const Self, m: Metrics, base_key: u64, item_keys: []const u64, width: i32, height: i32) ?DeviceRect {
    if (self.retained.len != @as(usize, @intCast(width)) * @as(usize, @intCast(height)) or
        self.base_drawn != base_key or self.items_drawn != item_keys.len) return null;
    var dirty: ?DeviceRect = null;
    for (item_keys, self.item_drawn[0..item_keys.len], 0..) |key, drawn, index| {
        if (key == drawn) continue;
        const cell = self.itemCell(m, index, width, height);
        dirty = if (dirty) |d| d.join(cell) else cell;
    }
    const box = dirty orelse return null;
    if (box.area() * 2 > @as(i64, width) * height) return null;
    return box;
}

pub fn paintDock(self: *Self, pal: ui.theme.Theme, bg: [4]f32, looks: []const Look, base_key: u64, item_keys: []const u64) !void {
    const m = self.metrics();
    const geometry = @import("../geometry.zig");
    const raster = self.rasterBox();
    const ox: f32 = @floatFromInt(-raster.x);
    const oy: f32 = @floatFromInt(-raster.y);
    const width = geometry.devicePixels(raster.width, self.scale);
    const height = geometry.devicePixels(raster.height, self.scale);
    const dirty = self.changedCells(m, base_key, item_keys, width, height);
    const image = if (dirty != null)
        try PanelBuffer.createUninitialized(raster.width, raster.height, self.scale)
    else
        try PanelBuffer.create(raster.width, raster.height, self.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
    r.palette = pal;
    const stride: usize = @intCast(image.width);
    if (dirty) |box| {
        // Start from what is on screen and paint the changed cells again, from
        // clear, exactly as a whole paint would. A quarter pixel in from the cell
        // edge keeps every shape on whole device pixels.
        @memcpy(image.pixels, self.retained);
        for (@as(usize, @intCast(box.y0))..@as(usize, @intCast(box.y1))) |y| @memset(image.pixels[y * stride + @as(usize, @intCast(box.x0)) .. y * stride + @as(usize, @intCast(box.x1))], 0);
        const x0: f32 = @floatFromInt(box.x0);
        const y0: f32 = @floatFromInt(box.y0);
        r.damage_clip = .{
            .x = (x0 + 0.25) / self.scale,
            .y = (y0 + 0.25) / self.scale,
            .w = (@as(f32, @floatFromInt(box.x1)) - x0 - 0.5) / self.scale,
            .h = (@as(f32, @floatFromInt(box.y1)) - y0 - 0.5) / self.scale,
        };
    }
    var border = pal.accent;
    border[3] = 0.55;
    border = pal.dock_border orelse border;
    const half = @as(f32, @floatFromInt(m.height)) / 2;
    const radius = @min(cornerRadius(pal), half);
    const bevel = @min(@max(0, pal.dock_bevel), half);
    // The blur only rounds: deep enough to stay inside a cut corner (a circle
    // of radius r clears a cut of b when 0.586 r >= b).
    self.glass_radius = if (bevel > 0) @min(half, bevel * 1.71) else radius;
    glass.Effect.configure(self.glass_effect, self.glass_radius, std.math.clamp(self.reveal.value(anim.nowMs()), 0, 1));
    r.fillRect(ox, oy, @floatFromInt(self.box.width), @floatFromInt(self.box.height), .{ .color = bg, .radius = radius, .bevel = bevel, .border_width = 1, .border_color = border });
    for (looks, 0..) |look, index| {
        if (dirty) |box| if (!box.overlaps(self.itemCell(m, index, width, height))) continue;
        self.paintItem(&r, pal, m, index, look, ox, oy);
    }
    self.paintMarks(&r, pal, m, ox, oy);
    if (dirty) |box| {
        for (@as(usize, @intCast(box.y0))..@as(usize, @intCast(box.y1))) |y| {
            const row = y * stride;
            @memcpy(self.retained[row + @as(usize, @intCast(box.x0)) .. row + @as(usize, @intCast(box.x1))], image.pixels[row + @as(usize, @intCast(box.x0)) .. row + @as(usize, @intCast(box.x1))]);
        }
        var region: @import("pixman").Region32 = undefined;
        region.initRect(box.x0, box.y0, @intCast(box.x1 - box.x0), @intCast(box.y1 - box.y0));
        defer region.deinit();
        self.node.?.setBufferWithDamage(&image.base, &region);
    } else {
        self.retained = gpa.realloc(self.retained, image.pixels.len) catch blk: {
            // Without a copy the next paint is a whole one.
            gpa.free(self.retained);
            break :blk &.{};
        };
        if (self.retained.len == image.pixels.len) @memcpy(self.retained, image.pixels);
        self.node.?.setBuffer(&image.base);
    }
    self.base_drawn = base_key;
    self.items_drawn = item_keys.len;
    @memcpy(self.item_drawn[0..item_keys.len], item_keys);
    self.node.?.node.setPosition(raster.x, raster.y);
    self.node.?.setDestSize(raster.width, raster.height);
    self.glass_anchor.?.setDestSize(self.box.width, self.box.height);
}

/// One button: its backdrop, icon, window count and running pill.
pub fn paintItem(self: *Self, r: *ui.paint.Renderer, pal: ui.theme.Theme, m: Metrics, index: usize, look: Look, ox: f32, oy: f32) void {
    const zooms = self.output.?.server.config.compositor.dock_hover_zoom > 1;
    const button = &self.buttons[index];
    const x = button.computed_x + ox;
    const y = button.computed_y + oy;
    const resting = self.iconBox(index, 1, 36);
    const cx = resting.x + resting.w / 2 + ox;
    const cy = resting.y + resting.h / 2 + oy;
    const selected = look.focused and self.output.?.server.config.compositor.dock_active_highlight;
    const lit = selected or button.kind.button.state == .hover or button.kind.button.state == .press;
    if (pal.dock_item_bg) |tile| {
        // A theme's tile: always there, outlined in the accent while lit.
        const hover_border = pal.dock_item_hover_border orelse pal.accent;
        r.fillRect(x, y, button.computed_width, button.computed_height, .{
            .color = tile,
            .radius = m.size(12),
            .bevel = m.size(pal.dock_item_bevel),
            .border_width = if (lit) @max(1, m.size(2)) else 1,
            .border_color = if (lit) hover_border else pal.dock_item_border orelse pal.border_soft,
        });
    } else {
        // An enlarging icon is the hover feedback: no rectangle behind it.
        const pointer: ui.layout.ButtonState = if (zooms) .idle else button.kind.button.state;
        ui.widgets.button.paintBackground(r, .{ .x = x, .y = y, .w = button.computed_width, .h = button.computed_height }, .{ .variant = .ghost, .radius = m.size(12) }, .{ .pointer = pointer, .selected = selected });
    }
    if (look.icon) |icon| {
        const rect = self.iconBox(index, look.zoom, 36);
        const image: ui.paint.Image = .{ .pixels = icon.pixels, .width = icon.size, .height = icon.size };
        const grey = if (lit) 0 else std.math.clamp(pal.dock_icon_grey, 0, 1);
        // The launcher's logo takes the start button's tint, like the taskbar's.
        const logo_tint = if (self.shortcuts[index] == .applications) pal.start_button_logo_color else null;
        const drained = if (logo_tint) |tint| tinted(image, tint) else if (grey > 0) greyed(image, grey) else null;
        defer if (drained) |pixels| gpa.free(pixels);
        r.drawImageSmooth(rect.x + ox, rect.y + oy, rect.w, rect.h, 0, if (drained) |pixels| .{ .pixels = pixels, .width = image.width, .height = image.height } else image);
    } else {
        const rect = self.iconBox(index, look.zoom, 34);
        r.drawIcon(rect.x + ox, rect.y + oy, rect.w, rect.h, .{ .id = if (self.shortcuts[index]) |shortcut| switch (shortcut) {
            .applications => .grid,
            .files => .folder,
            .terminal => .terminal,
            .settings => .settings,
            .trash => .trash_can,
        } else .generic, .color = pal.window_fg });
    }
    if (look.window_count >= 2) {
        // Stay inside the icon's square, hence inside itemCell even at the
        // spring's largest overshoot. A count change only repaints this cell.
        const rect = self.iconBox(index, look.zoom, 36);
        const diameter = m.size(18) * look.zoom;
        const bx = rect.x + rect.w - diameter + ox;
        const by = rect.y + oy;
        var label_buf: [3]u8 = undefined;
        const count_text = if (look.window_count > 99) "99+" else std.fmt.bufPrint(&label_buf, "{d}", .{look.window_count}) catch unreachable;
        const font_size = m.size(if (count_text.len > 2) 8 else 10) * look.zoom;
        const text_width = ui.text.measureWidthF(count_text, .manrope_heavy, font_size, self.scale) catch diameter;
        const text_x = bx + @max(0, (diameter - text_width) / 2);
        r.fillRect(bx, by, diameter, diameter, .{ .color = pal.accent, .radius = diameter / 2 });
        r.drawText(text_x, by, bx + diameter - text_x, diameter, .{
            .content = count_text,
            .font_size = font_size,
            .weight = 700,
            .color = pal.on_accent,
        });
    }
    if (look.pill_width > 0 and look.pill_opacity > 0) {
        var accent = pal.accent;
        accent[3] *= look.pill_opacity;
        const width = m.size(look.pill_width);
        const thickness = @max(2, m.size(4));
        const cross: f32 = if (self.position == .top or self.position == .left) @as(f32, @floatFromInt(m.height - m.length(58))) - thickness else @floatFromInt(m.length(58));
        if (self.position.vertical()) {
            r.fillRect(cross + ox, cy - width / 2, thickness, width, .{ .color = accent, .radius = @min(width, thickness) / 2 });
        } else r.fillRect(cx - width / 2, cross + oy, width, thickness, .{ .color = accent, .radius = @min(width, thickness) / 2 });
    }
}

/// A copy of `image` moved `amount` of the way to its luminance (Rec. 709 on
/// the stored premultiplied values, which keeps them premultiplied). Null, and
/// the icon drawn in colour, if the copy cannot be made.
fn greyed(image: ui.paint.Image, amount: f32) ?[]u32 {
    const copy = gpa.alloc(u32, image.pixels.len) catch return null;
    const keep: u32 = @intFromFloat(@round((1 - amount) * 256));
    for (image.pixels, copy) |pixel, *out| {
        const r = (pixel >> 16) & 0xff;
        const g = (pixel >> 8) & 0xff;
        const b = pixel & 0xff;
        const y = (r * 54 + g * 183 + b * 19) >> 8;
        const mix = struct {
            fn f(c: u32, lum: u32, k: u32) u32 {
                return (lum * (256 - k) + c * k) >> 8;
            }
        }.f;
        out.* = (pixel & 0xff000000) | (mix(r, y, keep) << 16) | (mix(g, y, keep) << 8) | mix(b, y, keep);
    }
    return copy;
}

/// A copy of `image` in one colour, keeping each pixel's coverage, as the
/// taskbar's start button tints the logo. Null if the copy cannot be made.
fn tinted(image: ui.paint.Image, tint: [4]f32) ?[]u32 {
    const copy = gpa.alloc(u32, image.pixels.len) catch return null;
    for (image.pixels, copy) |pixel, *out| {
        const a = @as(f32, @floatFromInt(pixel >> 24)) / 255 * tint[3];
        const channel = struct {
            fn f(v: f32, alpha: f32) u32 {
                return @intFromFloat(@round(std.math.clamp(v * alpha, 0, 1) * 255));
            }
        }.f;
        out.* = (channel(1, a) << 24) | (channel(tint[0], a) << 16) | (channel(tint[1], a) << 8) | channel(tint[2], a);
    }
    return copy;
}

/// What lies between and beside the buttons: the drop gap, the divider after the
/// launcher and the scroll chevrons.
pub fn paintMarks(self: *Self, r: *ui.paint.Renderer, pal: ui.theme.Theme, m: Metrics, ox: f32, oy: f32) void {
    if (self.drop_slot) |slot| {
        // A dragged application lands in this gap between two buttons.
        const gap: f32 = @floatFromInt(m.itemStep() - m.length(48));
        const along = @as(f32, @floatFromInt(m.padding() + @as(i32, @intCast(self.pin_base + slot)) * m.itemStep())) - gap / 2;
        const thickness = @max(2, m.size(3));
        const length = m.size(36);
        const cross = (@as(f32, @floatFromInt(m.height)) - length) / 2;
        if (self.position.vertical()) {
            r.fillRect(cross + ox, along - thickness / 2 + oy, length, thickness, .{ .color = pal.accent, .radius = thickness / 2 });
        } else r.fillRect(along - thickness / 2 + ox, cross + oy, thickness, length, .{ .color = pal.accent, .radius = thickness / 2 });
    }
    var divider = pal.window_fg;
    divider[3] = 0.16;
    if (self.count > 1 and self.shortcuts[0] == .applications) {
        const along: f32 = @floatFromInt(m.itemStep() + m.padding() - m.length(4));
        if (self.position.vertical()) r.fillRect(m.size(18) + ox, along + oy, m.size(30), 1, .{ .color = divider }) else r.fillRect(along + ox, m.size(18) + oy, 1, m.size(30), .{ .color = divider });
    }
    if (self.count > 1 and self.shortcuts[self.count - 1] == .trash) {
        const along: f32 = @floatFromInt(@as(i32, @intCast(self.count - 1)) * m.itemStep() + m.padding() - m.length(4));
        if (self.position.vertical()) r.fillRect(m.size(18) + ox, along + oy, m.size(30), 1, .{ .color = divider }) else r.fillRect(along + ox, m.size(18) + oy, 1, m.size(30), .{ .color = divider });
    }
    if (self.offset > 0) {
        if (self.position.vertical()) r.drawIcon(m.size(28) + ox, 1 + oy, m.size(12), m.size(10), .{ .id = .chevron_up, .color = pal.accent }) else r.drawIcon(1 + ox, m.size(28) + oy, m.size(10), m.size(12), .{ .id = .chevron_left, .color = pal.accent });
    }
    if (self.offset + self.count - self.fixedCount() < self.windows) {
        if (self.position.vertical()) r.drawIcon(m.size(28) + ox, @as(f32, @floatFromInt(self.box.height)) - m.size(11) + oy, m.size(12), m.size(10), .{ .id = .chevron_down, .color = pal.accent }) else r.drawIcon(@as(f32, @floatFromInt(self.box.width)) - m.size(11) + ox, m.size(28) + oy, m.size(10), m.size(12), .{ .id = .chevron_right, .color = pal.accent });
    }
}
