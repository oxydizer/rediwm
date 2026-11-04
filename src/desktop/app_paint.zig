//! Desktop painting: icons, selection band, prompts and overlays.

const i18n = @import("i18n");
const std = @import("std");
const App = @import("app.zig").App;
const appearance_theme = @import("ui").theme;
const shell_cairo = @import("ui").cairo;
const c = @import("c.zig").api;
const grid = @import("grid.zig");
const damage_mod = @import("damage.zig");
const Damage = damage_mod.Damage;
const rename = @import("rename.zig");
const deletion = @import("../delete_dialog.zig");
const context_menu = @import("ui").context_menu;
const Menu = @import("menu.zig").Menu;
const iconPattern = @import("app_draw.zig").iconPattern;
const nowMs = @import("app_draw.zig").nowMs;
const rounded = @import("app_draw.zig").rounded;
const IconRaster = @import("app_draw.zig").IconRaster;
const label = @import("app_draw.zig").label;

/// The selection band rasterized with its own bounds as the only clip. A
/// repair can split the band's corners across several rectangular clips,
/// and Cairo's arc coverage depends on the clip, so drawing it per pass
/// left pixels one level off a freshly drawn band.
pub fn rasterBand(self: *App, cr: *c.cairo_t) ?*c.cairo_pattern_t {
    const bounds = damage_mod.expand(self.selectionRect(), 2);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_reset_clip(cr);
    c.cairo_rectangle(cr, @floatFromInt(bounds.x), @floatFromInt(bounds.y), @floatFromInt(bounds.w), @floatFromInt(bounds.h));
    c.cairo_clip(cr);
    c.cairo_push_group(cr);
    self.drawBand(cr);
    const band = c.cairo_pop_group(cr) orelse return null;
    if (c.cairo_pattern_status(band) != c.CAIRO_STATUS_SUCCESS) {
        c.cairo_pattern_destroy(band);
        return null;
    }
    return band;
}

pub fn drawBand(self: *App, cr: *c.cairo_t) void {
    const r = self.selectionRect();
    const rad: f64 = @min(@as(f64, damage_mod.rubberband_radius), @as(f64, @floatFromInt(@min(r.w, r.h))) / 2.0);
    rounded(cr, r.x, r.y, r.w, r.h, rad);
    shell_cairo.setSource(cr, appearance_theme.global.desktop_selection);
    c.cairo_fill_preserve(cr);
    shell_cairo.setSource(cr, appearance_theme.global.desktop_selection_border);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

pub fn paint(self: *App, cr: *c.cairo_t, damage: *const Damage) void {
    self.paintAt(cr, damage, nowMs(), true);
}

pub fn paintAt(self: *App, cr: *c.cairo_t, damage: *const Damage, now: i64, cached: bool) void {
    const context = IconRaster.Context.from(cr);
    // One band raster for every repair pass: see `rasterBand`.
    self.band = if (self.rubber) self.rasterBand(cr) else null;
    defer if (self.band) |band| {
        c.cairo_pattern_destroy(band);
        self.band = null;
    };
    if (damage.full) return self.render(cr, damage, now, context, cached);
    // Union overlapping damage without turning disjoint regions into one
    // complex Cairo clip: each pixel needs one rectangular repaint pass.
    const region = c.cairo_region_create();
    defer c.cairo_region_destroy(region);
    for (damage.rects[0..damage.len]) |r| {
        const rect = c.cairo_rectangle_int_t{ .x = r.x, .y = r.y, .width = r.w, .height = r.h };
        _ = c.cairo_region_union_rectangle(region, &rect);
    }
    if (c.cairo_region_status(region) != c.CAIRO_STATUS_SUCCESS) {
        for (damage.rects[0..damage.len]) |r| self.paintRect(cr, r, now, context, cached);
        return;
    }
    var i: c_int = 0;
    while (i < c.cairo_region_num_rectangles(region)) : (i += 1) {
        var r: c.cairo_rectangle_int_t = undefined;
        c.cairo_region_get_rectangle(region, i, &r);
        self.paintRect(cr, .{ .x = r.x, .y = r.y, .w = r.width, .h = r.height }, now, context, cached);
    }
}

pub fn paintRect(self: *App, cr: *c.cairo_t, r: grid.Rect, now: i64, context: IconRaster.Context, cached: bool) void {
    // Complex clips change Cairo stroke coverage. Keep one timestamp and a
    // rectangular clip per pass, while sharing icon rasters across passes.
    c.cairo_save(cr);
    c.cairo_new_path(cr);
    // Snap the clip outward to whole device pixels. At a fractional scale
    // a logical edge would otherwise blend half-covered pixels with the
    // stale contents underneath. Paths live in device space, so building
    // it under the identity matrix survives restoring the transform.
    var x0: f64 = @floatFromInt(r.x);
    var y0: f64 = @floatFromInt(r.y);
    var x1: f64 = @floatFromInt(r.x + r.w);
    var y1: f64 = @floatFromInt(r.y + r.h);
    c.cairo_user_to_device(cr, &x0, &y0);
    c.cairo_user_to_device(cr, &x1, &y1);
    c.cairo_save(cr);
    c.cairo_identity_matrix(cr);
    c.cairo_rectangle(cr, @floor(@min(x0, x1)), @floor(@min(y0, y1)), @ceil(@max(x0, x1)) - @floor(@min(x0, x1)), @ceil(@max(y0, y1)) - @floor(@min(y0, y1)));
    c.cairo_restore(cr);
    c.cairo_clip(cr);
    var part = Damage{};
    part.clear();
    // Snapping can reach up to a device pixel past the logical rect.
    part.add(damage_mod.expand(r, 1));
    self.render(cr, &part, now, context, cached);
    c.cairo_restore(cr);
}

pub fn render(self: *App, cr: *c.cairo_t, damage: *const Damage, now: i64, context: IconRaster.Context, cached: bool) void {
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    if (self.wallpaper) |im| @import("wallpaper.zig").render(im, cr, self.geometry.w, self.geometry.h);
    for (self.icons.items, 0..) |*ic, i| {
        const r = self.iconRect(i);
        if (!damage.intersects(r)) continue;
        const alpha = if (ic.removed) |t| 1 - std.math.clamp(@as(f64, @floatFromInt(now - t)) / 150, 0, 1) else std.math.clamp(@as(f64, @floatFromInt(now - ic.born)) / 200, 0, 1);
        const opacity = alpha * (if (self.dragging and self.pressed == i) @as(f64, 0.85) else 1);
        const name = ic.item.name;
        const raster_key = IconRaster.Key{
            .context = context,
            .rect = r,
            .hover = ic.hover_amount,
            .selection = ic.selection_amount,
            .pulse = if (now < self.launching_until and ic.selected) 1 + 0.035 * @sin(@as(f64, @floatFromInt(@mod(now, 800))) / 800.0 * 2 * std.math.pi) else 1,
            .renaming = self.edit == .rename and ic.selected,
        };
        const group = iconPattern(cr, ic, raster_key, name, cached);
        c.cairo_set_source(cr, group);
        c.cairo_paint_with_alpha(cr, opacity);
        c.cairo_pattern_destroy(group);
    }
    if (self.dragging) {
        const r = self.geometry.rect(self.geometry.snap(self.x, self.y));
        rounded(cr, r.x, r.y, r.w, r.h, 8);
        shell_cairo.setSource(cr, appearance_theme.global.desktop_drop_border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    }
    if (self.rubber) {
        if (self.band) |band| {
            c.cairo_set_source(cr, band);
            c.cairo_paint(cr);
        } else self.drawBand(cr);
    }
    if (!self.separate_overlays) self.paintOverlay(cr, now);
}

/// Prompt geometry is shared by painting, scene allocation and input.
pub fn promptRect(self: *App) ?grid.Rect {
    if (self.renameGeometry()) |g| return damage_mod.expand(g.panel, 2);
    if (self.edit == .trash) {
        const g = self.deletion.geometry(self.geometry.w, self.geometry.h - self.geometry.bottom);
        return .{ .x = @intFromFloat(@floor(g.x)), .y = @intFromFloat(@floor(g.y)), .w = @intFromFloat(@ceil(g.width)), .h = @intFromFloat(@ceil(g.height)) };
    }
    if (self.edit == .trash_properties) {
        const card = self.trash_card orelse return null;
        const g = card.geometry(self.geometry.w, self.geometry.h - self.geometry.bottom);
        return .{ .x = @intFromFloat(@floor(g.box.x)), .y = @intFromFloat(@floor(g.box.y)), .w = @intFromFloat(@ceil(g.box.w)), .h = @intFromFloat(@ceil(g.box.h)) };
    }
    if (self.edit == .add_app) {
        if (self.applications) |*picker| {
            const r = picker.geometry(self.geometry.w, self.geometry.h - self.geometry.bottom).box;
            return .{ .x = @intFromFloat(@floor(r.x)), .y = @intFromFloat(@floor(r.y)), .w = @intFromFloat(@ceil(r.x + r.w) - @floor(r.x)), .h = @intFromFloat(@ceil(r.y + r.h) - @floor(r.y)) };
        }
    }
    if (self.edit == .open_with) return .{ .x = @divTrunc(self.geometry.w - 480, 2), .y = @divTrunc(self.geometry.h - 360, 2), .w = 480, .h = 360 };
    if (self.edit != .none and self.edit != .folder) return .{ .x = @divTrunc(self.geometry.w - 420, 2), .y = @divTrunc(self.geometry.h - 120, 2), .w = 420, .h = 120 };
    if (self.menu) return .{ .x = self.menu_x, .y = self.menu_y, .w = context_menu.width, .h = Menu.height(self.menuLabels().len, self.menu_icon != null) };
    return null;
}

pub fn overlayRect(self: *App) ?grid.Rect {
    var rect = self.promptRect();
    if (self.notice_until > nowMs()) {
        const notice_rect = grid.Rect{ .x = 24, .y = @max(24, self.geometry.h - self.geometry.bottom - 50), .w = @min(500, self.geometry.w - 48), .h = 36 };
        if (rect) |r| {
            const x = @min(r.x, notice_rect.x);
            const y = @min(r.y, notice_rect.y);
            rect = .{ .x = x, .y = y, .w = @max(r.x + r.w, notice_rect.x + notice_rect.w) - x, .h = @max(r.y + r.h, notice_rect.y + notice_rect.h) - y };
        } else rect = notice_rect;
    }
    // Context-menu shadows extend five pixels sideways and eight below.
    return if (rect) |r| damage_mod.expand(r, 8) else null;
}

pub fn paintOverlay(self: *App, cr: *c.cairo_t, now: i64) void {
    if (self.renameGeometry()) |g| {
        // Rasterize the complete overlay independently of the repair clip,
        // just like icons: clipping Cairo arcs changes their edge coverage.
        const bounds = damage_mod.expand(g.panel, 2);
        c.cairo_save(cr);
        c.cairo_reset_clip(cr);
        c.cairo_rectangle(cr, @floatFromInt(bounds.x), @floatFromInt(bounds.y), @floatFromInt(bounds.w), @floatFromInt(bounds.h));
        c.cairo_clip(cr);
        c.cairo_push_group(cr);
        self.rename_editor.draw(cr, g, self.x, self.y);
        const overlay = c.cairo_pop_group(cr);
        c.cairo_restore(cr);
        c.cairo_set_source(cr, overlay);
        c.cairo_paint(cr);
        c.cairo_pattern_destroy(overlay);
    }
    if (self.menu) {
        const labels = self.menuLabels();
        context_menu.frame(cr, .{
            .x = @floatFromInt(self.menu_x),
            .y = @floatFromInt(self.menu_y),
            .w = context_menu.width,
            .h = @floatFromInt(Menu.height(labels.len, self.menu_icon != null)),
        }, true);
        for (labels, 0..) |s, i| {
            const row = self.menu_layout.rows[i];
            context_menu.row(cr, .{ .x = row.computed_x, .y = row.computed_y, .w = row.computed_width, .h = row.computed_height }, .{
                .label = s,
                .icon = self.menuIcon(i),
                .hint = self.menuHint(i),
                .selected = i == self.menu_selected,
                .separator = Menu.separatorBefore(self.menu_icon != null, i),
            }, true);
        }
    }
    if (self.edit == .add_app) {
        if (self.applications) |*picker| picker.drawWindow(@ptrCast(cr), self.geometry.w, self.geometry.h - self.geometry.bottom, self.x, self.y, self.picker_theme, self.worker.io);
    } else if (self.edit == .open_with) {
        const px = @divTrunc(self.geometry.w - 480, 2);
        const py = @divTrunc(self.geometry.h - 360, 2);
        rounded(cr, px, py, 480, 360, 10);
        shell_cairo.setSource(cr, appearance_theme.global.desktop_dialog_bg);
        c.cairo_fill(cr);
        label(cr, if (self.edit_text.items.len == 0) i18n.tr("Type to search applications — Enter chooses") else self.edit_text.items, px + 12, py + 12, 456, 40, false);
        var row: usize = 0;
        while (row < 8) : (row += 1) {
            const index = (self.choice / 8) * 8 + row;
            const entry = self.choiceEntry(index) orelse break;
            const y = py + 64 + @as(i32, @intCast(row)) * 32;
            if (index == self.choice) {
                rounded(cr, px + 8, y, 464, 32, 4);
                shell_cairo.setSource(cr, appearance_theme.global.desktop_selection);
                c.cairo_fill(cr);
            }
            label(cr, entry.name, px + 12, y, 456, 32, false);
        }
    } else if (self.edit == .trash) {
        if (self.separate_overlays)
            self.deletion.drawWindow(cr, self.geometry.w, self.geometry.h - self.geometry.bottom, self.x, self.y, null)
        else
            self.deletion.draw(cr, self.geometry.w, self.geometry.h - self.geometry.bottom, self.x, self.y, null);
    } else if (self.edit == .trash_properties) {
        if (self.trash_card) |*card| {
            const w = self.geometry.w;
            const h = self.geometry.h - self.geometry.bottom;
            if (self.separate_overlays)
                card.drawWindow(cr, w, h, self.x, self.y, null, self.picker_theme, self.worker.io)
            else
                card.draw(cr, w, h, self.x, self.y, null, self.picker_theme, self.worker.io);
        }
    } else if (self.edit != .none and self.edit != .rename and self.edit != .folder) {
        const x = @divTrunc(self.geometry.w - 420, 2);
        const y = @divTrunc(self.geometry.h - 120, 2);
        rounded(cr, x, y, 420, 120, 10);
        shell_cairo.setSource(cr, appearance_theme.global.desktop_dialog_bg);
        c.cairo_fill(cr);
        const title: []const u8 = switch (self.edit) {
            .properties => i18n.tr("Properties — Escape closes"),
            .rename => i18n.tr("Rename — Enter saves, Escape cancels"),
            .file => i18n.tr("New File — Enter creates"),
            else => "",
        };
        label(cr, title, x + 12, y + 12, 396, 32, false);
        var property_path = self.worker.dir;
        var details_buf: [128]u8 = undefined;
        var details: []const u8 = "";
        if (self.edit == .properties) for (self.icons.items) |ic| {
            if (ic.selected) {
                property_path = ic.item.path;
                details = i18n.fmt(&details_buf, i18n.tr("{kind} · {bytes} bytes"), .{ .kind = if (ic.item.folder) i18n.tr("Folder") else i18n.tr("File"), .bytes = ic.item.bytes }) catch "";
                break;
            }
        };
        label(cr, if (self.edit == .properties) property_path else self.edit_text.items, x + 12, y + 44, 396, 32, false);
        if (self.edit == .properties) label(cr, details, x + 12, y + 78, 396, 26, false);
    }
    if (self.notice_until > now) {
        const w = @min(500, self.geometry.w - 48);
        const y = @max(24, self.geometry.h - self.geometry.bottom - 50);
        rounded(cr, 24, y, w, 36, 8);
        shell_cairo.setSource(cr, appearance_theme.global.desktop_notice_bg);
        c.cairo_fill(cr);
        label(cr, self.notice[0..self.notice_len], 32, y, w - 16, 36, false);
    }
}
