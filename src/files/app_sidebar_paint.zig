//! Files sidebar painting.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const c = @import("c.zig").api;
const recent = @import("recent.zig");
const icons = @import("../icon_cache.zig");
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const pins_mod = @import("pins.zig");
const places = App.places;
const places_start = App.places_start;
const pin_base = App.pin_base;
const setSource = @import("app_draw.zig").setSource;
const withAlpha = @import("app_draw.zig").withAlpha;
const roundedRect = @import("app_draw.zig").roundedRect;
const drawEllipsis = @import("app_draw.zig").drawEllipsis;
const drawText = @import("app_draw.zig").drawText;
const fontMetrics = @import("app_draw.zig").fontMetrics;
const deviceLabel = App.deviceLabel;

/// DEVICES: a heading and one row per volume, dimmed while unmounted, with
/// an eject button on the mounted ones.
pub fn renderDevices(self: *App, cr: *c.cairo_t, content_width: f64) void {
    if (self.device_list.items.len == 0) return;
    setSource(cr, ui_theme.global.sidebarForeground());
    drawText(cr, tr("DEVICES"), 24, @floatFromInt(self.placeY(self.deviceBase()) - 12), shell_ui.headingSize(), true);
    const hovered = self.hoverKey();
    for (self.device_list.items, 0..) |*volume, k| {
        const index = self.deviceBase() + k;
        const y: f64 = @floatFromInt(self.placeY(index));
        const mounted = volume.mount != null;
        const alpha: f32 = if (mounted) 1 else 0.5;
        if (self.placeActive(index)) {
            const row = self.placeRect(index);
            shell_ui.drawSidebarSelected(cr, .{ .x = @floatCast(row.x), .y = @floatCast(row.y), .w = @floatCast(row.w), .h = @floatCast(row.h) });
        }
        if (shell_ui.Layer.begin(cr, .{ .x = 21, .y = @floatCast(y + 3), .w = 24, .h = 24 })) |icon_layer| {
            var layer = icon_layer;
            layer.renderer.drawIcon(0, 0, 24, 24, .{ .id = if (volume.kind == .stick) .usb_stick else .drive, .color = withAlpha(ui_theme.global.app_icon, alpha) });
            layer.finish();
        }
        setSource(cr, withAlpha(ui_theme.global.sidebarForeground(), alpha));
        const metrics = fontMetrics(cr, shell_ui.textSize());
        var label_buf: [96]u8 = undefined;
        const reserve: f64 = if (mounted) 28 else 0;
        drawEllipsis(cr, deviceLabel(volume, &label_buf), 54, y + (30 - metrics.ascent - metrics.descent) / 2 + metrics.ascent, content_width - 64 - reserve, shell_ui.textSize(), false);
        if (!mounted) continue;
        const button = self.ejectRect(index);
        if (hovered == 700 + k) {
            roundedRect(cr, button.x, button.y, button.w, button.h, 5);
            setSource(cr, ui_theme.global.app_item_hover);
            c.cairo_fill(cr);
        }
        if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(button.x + 5), .y = @floatCast(button.y + 5), .w = 16, .h = 16 })) |icon_layer| {
            var layer = icon_layer;
            layer.renderer.drawIcon(0, 0, 16, 16, .{ .id = .eject, .color = ui_theme.global.app_icon });
            layer.finish();
        }
    }
}

pub fn placeY(self: *App, index: usize) i32 {
    const step = self.placeStep();
    switch (self.rowKind(index)) {
        .pin => |j| return self.pinRowY(j),
        .device => |k| return self.pinRowY(self.pins.items.items.len) + 44 + @as(i32, @intCast(k)) * step,
        .builtin => {},
    }
    var hidden: i32 = 0;
    for (0..index) |i| {
        if (!self.placeVisible(i)) hidden += 1;
    }
    return self.contentTop() - self.sidebar_scroll - hidden * step + (if (index < places_start) 16 + @as(i32, @intCast(index)) * step else 80 + @as(i32, @intCast(index - 1)) * step);
}

/// Where pin `j` is drawn; `j` == the pin count is the slot under the last
/// one, where the next section's heading gap starts.
pub fn pinRowY(self: *App, j: usize) i32 {
    const step = self.placeStep();
    var hidden: i32 = 0;
    for (0..pin_base) |i| {
        if (!self.placeVisible(i)) hidden += 1;
    }
    return self.contentTop() - self.sidebar_scroll - hidden * step + 80 + @as(i32, @intCast(pin_base - 1 + j)) * step;
}

/// The sidebar's bar, along its right edge; null while its places fit.
pub fn sidebarScrollbar(self: *App) ?scrollbar.Geometry {
    const width = self.sidebarWidth();
    if (width == 0) return null;
    const viewport: f32 = @floatFromInt(self.h - self.contentTop() - self.sidebarFooter());
    const gutter: f32 = @floatFromInt(self.scrollbarGutter());
    const track: scrollbar.Rect = .{ .x = @as(f32, @floatFromInt(width)) - gutter, .y = @floatFromInt(self.contentTop()), .w = gutter, .h = viewport };
    return scrollbar.Geometry.compute(.vertical, track, viewport, @floatFromInt(self.sidebarExtent() - self.contentTop()), @floatFromInt(self.sidebar_scroll));
}

pub fn placePath(self: *App, index: usize, buf: []u8) ?[]const u8 {
    return switch (self.rowKind(index)) {
        .builtin => |i| switch (i) {
            0 => self.home_dir,
            1 => self.trash_dir orelse std.fmt.bufPrint(buf, "{s}/.local/share/Trash/files", .{self.home_dir}) catch null,
            2 => recent.location,
            else => std.fmt.bufPrint(buf, "{s}/{s}", .{ self.home_dir, places[i] }) catch null,
        },
        .pin => |j| self.pins.items.items[j].path,
        .device => null,
    };
}

pub fn drawPackPlaceIcon(self: *App, cr: *c.cairo_t, index: usize, y: f64, alpha: f32) bool {
    const name: []const u8 = switch (self.rowKind(index)) {
        .builtin => |i| ([_][]const u8{ "user-home", "user-trash", "document-open-recent", "user-desktop", "folder-documents", "folder-download", "folder-pictures", "folder-music", "folder-videos", "folder" })[i],
        .pin => |i| if (self.pins.items.items[i].kind == .file) "text-x-generic" else "folder",
        .device => return false,
    };
    const size = 24 * self.scale;
    const entry = icons.getPack(self.theme_cfg, self.io, name, size) orelse
        (if (index >= places_start and std.mem.startsWith(u8, name, "folder-")) icons.getPack(self.theme_cfg, self.io, "folder", size) else null) orelse return false;
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(@constCast(entry.pixels.ptr)), c.CAIRO_FORMAT_ARGB32, entry.size, entry.size, entry.size * 4) orelse return false;
    defer c.cairo_surface_destroy(surface);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, 21, y + 3);
    const scale = 24 / @as(f64, @floatFromInt(entry.size));
    c.cairo_scale(cr, scale, scale);
    c.cairo_set_source_surface(cr, surface, 0, 0);
    c.cairo_paint_with_alpha(cr, alpha);
    return true;
}

pub fn renderSidebar(self: *App, cr: *c.cairo_t) void {
    const width: f64 = @floatFromInt(self.sidebarWidth());
    if (width == 0) return;
    const bar = self.sidebarScrollbar();
    // Labels keep their final layout while the panel grows or shrinks.
    const content_width = if (bar) |b| @as(f64, b.track.x) else @as(f64, @floatFromInt(self.sidebarTargetWidth()));
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, 0, @floatFromInt(self.contentTop()), width, @floatFromInt(self.h - self.contentTop() - self.sidebarFooter()));
    c.cairo_clip(cr);
    setSource(cr, ui_theme.global.app_sidebar);
    // The sidebar's alpha describes the window, not a tint over app_bg.
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    self.renderTorrentSidebar(cr);
    self.renderGitSidebar(cr, content_width);
    // Under the labels: the glide passes over the PLACES heading.
    const glide = self.nav_hover.frame;
    if (glide.alpha > 0) {
        const box = self.navHighlight(glide);
        shell_ui.drawSidebarHover(cr, .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) }, glide.alpha);
    }
    setSource(cr, ui_theme.global.sidebarForeground());
    drawText(cr, tr("PLACES"), 24, @floatFromInt(self.placeY(places_start) - 12), shell_ui.headingSize(), true);
    for (0..self.deviceBase()) |i| {
        if (!self.placeVisible(i)) continue;
        const y: f64 = @floatFromInt(self.placeY(i));
        var buf: [4096]u8 = undefined;
        const path = self.placePath(i, &buf) orelse continue;
        const pin: ?pins_mod.Pin = if (self.pinIndex(i)) |j| self.pins.items.items[j] else null;
        const label = switch (self.rowKind(i)) {
            .builtin => |b| App.place_labels[b].get(),
            .pin => pin.?.name(),
            .device => unreachable,
        };
        // A pin whose target is gone stays, dimmed, until it is removed.
        const alpha: f32 = if (pin != null and pin.?.kind == .missing) 0.5 else 1;
        const active = !self.transfer_view.active and std.mem.eql(u8, path, self.history.current);
        if (active) {
            const row = self.placeRect(i);
            shell_ui.drawSidebarSelected(cr, .{ .x = @floatCast(row.x), .y = @floatCast(row.y), .w = @floatCast(row.w), .h = @floatCast(row.h) });
        }
        setSource(cr, withAlpha(ui_theme.global.app_icon, alpha));
        if (self.drawPackPlaceIcon(cr, i, y, alpha)) {
            // The pack's colour artwork replaces this place's plain glyph.
        } else if (i < places_start) {
            if (shell_ui.Layer.begin(cr, .{ .x = 21, .y = @floatCast(y + 3), .w = 24, .h = 24 })) |icon_layer| {
                var layer = icon_layer;
                layer.renderer.drawIcon(0, 0, 24, 24, .{ .id = switch (i) {
                    0 => .home,
                    1 => .trash,
                    else => .clock,
                }, .color = withAlpha(ui_theme.global.app_icon, alpha) });
                layer.finish();
            }
        } else if (pin != null and pin.?.kind == .file) {
            // A page with a folded corner, like the folder beside it a plain shape.
            c.cairo_save(cr);
            c.cairo_set_line_width(cr, 1.5);
            c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
            c.cairo_move_to(cr, 29, y + 6.5);
            c.cairo_line_to(cr, 34.5, y + 6.5);
            c.cairo_line_to(cr, 39.5, y + 11.5);
            c.cairo_line_to(cr, 39.5, y + 21.5);
            c.cairo_line_to(cr, 29, y + 21.5);
            c.cairo_close_path(cr);
            c.cairo_fill_preserve(cr);
            c.cairo_stroke(cr);
            setSource(cr, withAlpha(ui_theme.global.app_icon, alpha * 0.5));
            c.cairo_move_to(cr, 34.5, y + 6.5);
            c.cairo_line_to(cr, 39.5, y + 11.5);
            c.cairo_line_to(cr, 34.5, y + 11.5);
            c.cairo_close_path(cr);
            c.cairo_fill(cr);
            c.cairo_restore(cr);
        } else {
            roundedRect(cr, 25, y + 7.5, 8, 5, 1);
            c.cairo_fill(cr);
            roundedRect(cr, 25, y + 10.5, 17, 12, 2);
            c.cairo_fill(cr);
        }
        setSource(cr, withAlpha(ui_theme.global.sidebarForeground(), alpha));
        const metrics = fontMetrics(cr, shell_ui.textSize());
        drawEllipsis(cr, label, 54, y + (30 - metrics.ascent - metrics.descent) / 2 + metrics.ascent, content_width - 64, shell_ui.textSize(), false);
    }
    self.renderDevices(cr, content_width);
    self.renderPinDrop(cr);
    if (self.trash_drop) {
        // The drop target outline, as on a folder in the content area.
        const row = self.placeRect(App.trash_place);
        roundedRect(cr, row.x, row.y, row.w, row.h, 6);
        setSource(cr, ui_theme.shellPalette().accent);
        c.cairo_set_line_width(cr, 2);
        c.cairo_stroke(cr);
    }
}

/// The line a drag shows between pins: where a drop would put its pin.
pub fn renderPinDrop(self: *App, cr: *c.cairo_t) void {
    const slot = self.pin_drop orelse return;
    const y = self.pinBoundary(slot);
    const row = self.placeRect(0);
    setSource(cr, ui_theme.shellPalette().accent);
    roundedRect(cr, row.x + 5, y - 1.5, row.w - 10, 3, 1.5);
    c.cairo_fill(cr);
    c.cairo_arc(cr, row.x + 5, y, 3.5, 0, 2 * std.math.pi);
    c.cairo_fill(cr);
}

// Bottom of the sidebar content in scrolled coordinates: the Git card is the last section.
pub fn sidebarExtent(self: *App) i32 {
    return self.pinRowY(self.pins.items.items.len) + self.sidebar_scroll + 8 + self.deviceBlock() + self.gitSidebarHeight() + self.torrentSidebarHeight();
}

pub fn renderSidebarScrollbar(self: *App, cr: *c.cairo_t) void {
    const bar = self.sidebarScrollbar() orelse return;
    shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.sidebar_scroll_appearance, self.scrollbar_width, ui_theme.shellPalette()));
}
