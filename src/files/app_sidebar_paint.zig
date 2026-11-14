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
const header = @import("header.zig");
const pins_mod = @import("pins.zig");
const app_model = @import("app_model.zig");
const places = App.places;
const places_start = App.places_start;
const pin_base = App.pin_base;
const setSource = @import("app_draw.zig").setSource;
const withAlpha = @import("app_draw.zig").withAlpha;
const roundedRect = @import("app_draw.zig").roundedRect;
const drawEllipsis = @import("app_draw.zig").drawEllipsis;
const drawText = @import("app_draw.zig").drawText;
const fontMetrics = @import("app_draw.zig").fontMetrics;
const sidebar_controls = @import("app_sidebar_controls.zig");
const deviceLabel = App.deviceLabel;
const transferTip = @import("app_transfer_tip.zig");

/// A quiet surface separating the sidebar's four functional sections.
fn drawSidebarCard(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    if (w <= 0 or h <= 0) return;
    roundedRect(cr, x, y, w, h, 9);
    setSource(cr, withAlpha(ui_theme.global.app_item_hover, 0.18));
    c.cairo_fill_preserve(cr);
    setSource(cr, withAlpha(ui_theme.global.sidebarForeground(), 0.08));
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

fn drawSidebarHeader(
    cr: *c.cairo_t,
    label: []const u8,
    y: i32,
    content_width: f64,
    expanded: bool,
) void {
    setSource(cr, ui_theme.global.sidebarForeground());
    drawText(cr, label, 24, @as(f64, @floatFromInt(y)) + 21, shell_ui.headingSize(), true);
    if (shell_ui.Layer.begin(cr, .{
        .x = @floatCast(content_width - 28),
        .y = @floatFromInt(y + 9),
        .w = 14,
        .h = 14,
    })) |icon_layer| {
        var layer = icon_layer;
        layer.renderer.drawIcon(0, 0, 14, 14, .{
            .id = if (expanded) .chevron_down else .chevron_right,
            .color = ui_theme.global.sidebarForeground(),
        });
        layer.finish();
    }
}

/// Draws the same theme-configured edge light used by sidebar rows.
fn drawSidebarHeaderProximity(
    self: *App,
    cr: *c.cairo_t,
    bounds: header.Rect,
) void {
    shell_ui.drawProximityGlow(
        cr,
        .{
            .x = 12,
            .y = @floatCast(bounds.y + 2),
            .w = @floatCast(@max(@as(f64, 0), bounds.w - 8)),
            .h = 28,
        },
        ui_theme.global.app_sidebar_item_radius,
        .{ .x = self.mouse_x, .y = self.mouse_y },
        .{
            .x = 8,
            .y = @floatCast(bounds.y),
            .w = @floatCast(bounds.w),
            .h = @floatCast(bounds.h),
        },
    );
}

/// Draws the theme-configured edge light in the section's legacy row
/// coordinate space. The pointer is translated to match the Cairo context.
fn drawSidebarRowProximity(
    self: *App,
    cr: *c.cairo_t,
    index: usize,
    card: app_model.SidebarCardGeometry,
    source_top: i32,
) void {
    const row = self.placeRect(index);
    const translation = card.y + card.header_height - source_top;
    const clip: shell_ui.Rect = .{
        .x = 8,
        .y = @floatFromInt(source_top),
        .w = @floatFromInt(@max(0, self.sidebarWidth() - self.scrollbarGutter() - 8)),
        .h = @floatFromInt(card.body_height),
    };
    shell_ui.drawProximityGlow(
        cr,
        .{
            .x = @floatCast(row.x),
            .y = @floatCast(row.y),
            .w = @floatCast(row.w),
            .h = @floatCast(row.h),
        },
        ui_theme.global.app_sidebar_item_radius,
        .{
            .x = self.mouse_x,
            .y = self.mouse_y - @as(f64, @floatFromInt(translation)),
        },
        clip,
    );
}

/// The shared accordion geometry. Every expanded visible card receives
/// its body, with all cards stacked in section order.
pub fn sidebarLayout(self: *App) app_model.SidebarLayout {
    const top = self.contentTop() - self.sidebar_scroll;
    const pin_bottom = self.pinRowY(self.pins.items.items.len);
    const old_places_top = self.contentTop() - self.sidebar_scroll;
    const places_body = @max(0, pin_bottom + 16 - old_places_top);
    const disks_body = @max(0, self.deviceBlock() - app_model.SidebarLayout.header_height);
    const git_body: i32 = if (self.repository() != null)
        @intFromFloat(self.gitCardHeight())
    else
        0;
    const torrent_height = self.torrentSidebarHeight();
    const file_ops_height = self.fileOpsSidebarHeight();
    const transfers_body = torrent_height +
        (if (file_ops_height > 0) @as(i32, app_model.SidebarLayout.gap) + file_ops_height else 0);

    return app_model.SidebarLayout.init(
        top,
        .{ places_body, disks_body, git_body, transfers_body },
        .{ true, true, self.repository() != null, torrent_height > 0 or file_ops_height > 0 },
        self.sidebar_expanded,
    );
}

/// The content width used by sidebar painting: the scrollbar track when it
/// exists, otherwise the final target width while the panel is animating.
fn sidebarContentWidth(self: *App) f64 {
    return if (self.sidebarScrollbar()) |bar|
        @as(f64, @floatCast(bar.track.x))
    else
        @as(f64, @floatFromInt(self.sidebarTargetWidth()));
}

/// The visible header bounds after applying the same right edge as painting
/// and the sidebar's current animated clip width.
pub fn sidebarHeaderBounds(self: *App, card: app_model.SidebarCardGeometry) ?header.Rect {
    if (!card.visible or self.sidebarWidth() <= 8) return null;
    const right = @min(
        sidebarContentWidth(self) - 8,
        @as(f64, @floatFromInt(self.sidebarWidth())),
    );
    const width = right - 8;
    if (width <= 0) return null;
    return .{
        .x = 8,
        .y = @floatFromInt(card.y),
        .w = width,
        .h = @floatFromInt(card.header_height),
    };
}

/// Returns the visible accordion header under the pointer. Card bodies are
/// deliberately excluded so section selection cannot steal their controls.
pub fn sidebarHeaderAt(self: *App, x: f64, y: f64) ?app_model.SidebarSection {
    if (y < @as(f64, @floatFromInt(self.contentTop())) or
        y >= @as(f64, @floatFromInt(self.h - self.sidebarFooter()))) return null;

    const layout = self.sidebarLayout();
    for (layout.cards, 0..) |card, i| {
        const bounds = sidebarHeaderBounds(self, card) orelse continue;
        if (bounds.contains(x, y)) return @enumFromInt(i);
    }
    return null;
}

/// Maps a pointer position in an expanded card body back to the coordinate
/// space used by that section's existing content. Sections already rendered
/// in accordion coordinates (Git and Transfers) pass through unchanged.
pub fn sidebarBodyY(self: *App, section: app_model.SidebarSection, x: f64, y: f64) ?f64 {
    const layout = self.sidebarLayout();
    const card = layout.cards[@intFromEnum(section)];
    if (!card.visible or !card.expanded or card.body_height <= 0) return null;

    const left: f64 = 8;
    const right = @as(f64, @floatFromInt(self.sidebarWidth() - self.scrollbarGutter() - 8));
    if (x < left or x >= right) return null;

    const body_top: f64 = @floatFromInt(card.y + card.header_height);
    const body_bottom = body_top + @as(f64, @floatFromInt(card.body_height));
    if (y < body_top or y >= body_bottom) return null;

    const source_top: i32 = switch (section) {
        .places => self.contentTop() - self.sidebar_scroll,
        .disks => self.pinRowY(self.pins.items.items.len) + 24,
        .git, .transfers => card.y + card.header_height,
    };
    return y - body_top + @as(f64, @floatFromInt(source_top));
}

/// DEVICES: a heading and one row per volume, dimmed while unmounted, with
/// an eject button on the mounted ones.
pub fn renderDevices(self: *App, cr: *c.cairo_t, content_width: f64) void {
    if (self.device_list.items.len == 0) {
        drawText(cr, tr("No removable volumes"), 32, @floatFromInt(self.placeY(self.deviceBase()) + 20), shell_ui.statusSize(), false);
        return;
    }
    const hovered = self.hoverKey();
    const disks_card = self.sidebarLayout().cards[@intFromEnum(app_model.SidebarSection.disks)];
    const metrics = fontMetrics(cr, shell_ui.textSize());
    for (self.device_list.items, 0..) |*volume, k| {
        const index = self.deviceBase() + k;
        const y: f64 = @floatFromInt(self.placeY(index));
        const mounted = volume.mount != null;
        const alpha: f32 = if (mounted) 1 else 0.5;
        if (self.placeActive(index)) {
            const row = self.placeRect(index);
            shell_ui.drawSidebarSelected(cr, .{ .x = @floatCast(row.x), .y = @floatCast(row.y), .w = @floatCast(row.w), .h = @floatCast(row.h) });
        }
        drawSidebarRowProximity(self, cr, index, disks_card, self.pinRowY(self.pins.items.items.len) + 24);
        if (shell_ui.Layer.begin(cr, .{ .x = 21, .y = @floatCast(y + 3), .w = 24, .h = 24 })) |icon_layer| {
            var layer = icon_layer;
            layer.renderer.drawIcon(0, 0, 24, 24, .{ .id = if (volume.kind == .stick) .usb_stick else .drive, .color = withAlpha(ui_theme.global.app_icon, alpha) });
            layer.finish();
        }
        setSource(cr, withAlpha(ui_theme.global.sidebarForeground(), alpha));
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
    // Labels keep their final layout while the panel grows or shrinks.
    const content_width = sidebarContentWidth(self);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, 0, @floatFromInt(self.contentTop()), width, @floatFromInt(self.h - self.contentTop() - self.sidebarFooter()));
    c.cairo_clip(cr);
    setSource(cr, ui_theme.global.app_sidebar);
    // The sidebar's alpha describes the window, not a tint over app_bg.
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const layout = self.sidebarLayout();
    const section_names = [_][]const u8{
        tr("PLACES"),
        tr("DISKS"),
        "GIT",
        tr("TRANSFERS"),
    };
    for (layout.cards, 0..) |card, i| {
        if (!card.visible) continue;
        const height = card.height();
        drawSidebarCard(
            cr,
            8,
            @floatFromInt(card.y),
            @max(0, content_width - 16),
            @floatFromInt(height),
        );
        if (sidebarHeaderBounds(self, card)) |bounds| {
            drawSidebarHeaderProximity(self, cr, bounds);
        }
        drawSidebarHeader(cr, section_names[i], card.y, content_width, card.expanded);
    }

    const places_card = layout.cards[@intFromEnum(app_model.SidebarSection.places)];
    if (places_card.expanded) {
        const old_top = self.contentTop() - self.sidebar_scroll;
        c.cairo_save(cr);
        c.cairo_translate(cr, 0, @floatFromInt(places_card.y + places_card.header_height - old_top));
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
            const alpha: f32 = if (pin != null and pin.?.kind == .missing) 0.5 else 1;
            const active = !self.transfer_view.active and std.mem.eql(u8, path, self.history.current);
            if (active) {
                const row = self.placeRect(i);
                shell_ui.drawSidebarSelected(cr, .{ .x = @floatCast(row.x), .y = @floatCast(row.y), .w = @floatCast(row.w), .h = @floatCast(row.h) });
            }
            drawSidebarRowProximity(self, cr, i, places_card, old_top);
            setSource(cr, withAlpha(ui_theme.global.app_icon, alpha));
            if (!self.drawPackPlaceIcon(cr, i, y, alpha)) {
                if (i < places_start) {
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
            }
            setSource(cr, withAlpha(ui_theme.global.sidebarForeground(), alpha));
            const metrics = fontMetrics(cr, shell_ui.textSize());
            drawEllipsis(cr, label, 54, y + (30 - metrics.ascent - metrics.descent) / 2 + metrics.ascent, content_width - 64, shell_ui.textSize(), false);
        }
        self.renderPinDrop(cr);
        if (self.trash_drop) {
            const row = self.placeRect(App.trash_place);
            roundedRect(cr, row.x, row.y, row.w, row.h, 6);
            setSource(cr, ui_theme.shellPalette().accent);
            c.cairo_set_line_width(cr, 2);
            c.cairo_stroke(cr);
        }
        c.cairo_restore(cr);
    }

    const disks_card = layout.cards[@intFromEnum(app_model.SidebarSection.disks)];
    if (disks_card.expanded) {
        const old_top = self.pinRowY(self.pins.items.items.len) + 24;
        c.cairo_save(cr);
        c.cairo_translate(cr, 0, @floatFromInt(disks_card.y + disks_card.header_height - old_top));
        self.renderDevices(cr, content_width);
        c.cairo_restore(cr);
    }

    const git_card = layout.cards[@intFromEnum(app_model.SidebarSection.git)];
    if (git_card.expanded) self.renderGitSidebar(cr, content_width);

    const transfers_card = layout.cards[@intFromEnum(app_model.SidebarSection.transfers)];
    if (transfers_card.expanded) {
        self.renderTorrentSidebar(cr);
        self.renderFileOpsSidebar(cr);
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
    const layout = self.sidebarLayout();
    var bottom = self.contentTop() - self.sidebar_scroll;
    for (layout.cards) |card| {
        if (card.visible) bottom = @max(bottom, card.y + card.height());
    }
    return bottom + self.sidebar_scroll + app_model.SidebarLayout.gap;
}

pub fn fileOpsBox(self: *App) shell_ui.Rect {
    const card = self.sidebarLayout().cards[@intFromEnum(app_model.SidebarSection.transfers)];
    return .{
        .x = 12,
        .y = @floatFromInt(card.y + card.header_height + self.torrentSidebarHeight() + app_model.SidebarLayout.gap),
        .w = @floatFromInt(@max(0, self.sidebarWidth() - 24 - self.scrollbarGutter())),
        .h = 52,
    };
}

fn fileOpsPauseRect(area: shell_ui.Rect) shell_ui.Rect {
    return sidebar_controls.buttonRect(area, 54, 2);
}

fn fileOpsCancelRect(area: shell_ui.Rect) shell_ui.Rect {
    return sidebar_controls.buttonRect(area, 26, 2);
}

fn fileOpsRectContains(rect: shell_ui.Rect, x: f64, y: f64) bool {
    return sidebar_controls.contains(rect, x, y);
}

pub fn fileOpsSidebarHeight(self: *App) i32 {
    const runner = self.job_runner orelse return 0;
    const state = runner.pollProgress().state;
    return if (state == .running or state == .paused or state == .waiting_conflict) 60 else 0;
}

pub fn fileOpsSidebarHit(self: *App, x: f64, y: f64) bool {
    if (self.fileOpsSidebarHeight() == 0 or self.chooser != null or self.dialog != null) return false;
    if (self.sidebarWidth() == 0 or y < @as(f64, @floatFromInt(self.contentTop())) or
        y >= @as(f64, @floatFromInt(self.h - self.sidebarFooter()))) return false;
    const area = fileOpsBox(self);
    return x >= area.x and x < area.x + area.w and y >= area.y and y < area.y + area.h;
}

pub fn fileOpsSidebarHover(self: *App, x: f64, y: f64) usize {
    if (!self.fileOpsSidebarHit(x, y)) return 0;
    const area = fileOpsBox(self);
    if (fileOpsRectContains(fileOpsCancelRect(area), x, y)) {
        return std.math.maxInt(usize) - 2004;
    }
    if (self.job_runner) |runner| {
        const progress = runner.pollProgress();
        const can_pause = (progress.kind == .copy or progress.kind == .move) and
            (progress.state == .running or progress.state == .paused);
        if (can_pause and fileOpsRectContains(fileOpsPauseRect(area), x, y)) {
            return std.math.maxInt(usize) - 2003;
        }
    }
    return std.math.maxInt(usize) - 2002;
}

pub fn fileOpsSidebarClick(self: *App, x: f64, y: f64) bool {
    if (!self.fileOpsSidebarHit(x, y)) return false;
    const runner = self.job_runner orelse return true;
    const progress = runner.pollProgress();
    const area = fileOpsBox(self);
    if (fileOpsRectContains(fileOpsCancelRect(area), x, y)) {
        runner.cancel();
    } else if ((progress.kind == .copy or progress.kind == .move) and
        (progress.state == .running or progress.state == .paused) and
        fileOpsRectContains(fileOpsPauseRect(area), x, y))
    {
        if (progress.state == .paused) {
            runner.resumeJob();
        } else if (progress.state == .running) {
            runner.pause();
        }
    } else {
        self.openTransfers();
    }
    self.invalidate();
    return true;
}

pub fn renderFileOpsSidebar(self: *App, cr: *c.cairo_t) void {
    const runner = self.job_runner orelse return;
    const progress = runner.pollProgress();
    if (progress.state != .running and progress.state != .paused and progress.state != .waiting_conflict) return;
    const area = fileOpsBox(self);
    if (area.w < 120) return;

    const palette = ui_theme.shellPalette();
    const fraction: ?f64 = if (progress.total_bytes_known and progress.total_bytes > 0)
        @min(1.0, @as(f64, @floatFromInt(progress.transferred_bytes)) / @as(f64, @floatFromInt(progress.total_bytes)))
    else
        null;

    @import("app_draw.zig").drawTransferProgressRow(
        cr,
        area,
        if (progress.current_name.len > 0) progress.current_name else tr("Preparing…"),
        fraction,
        ui_theme.global.sidebarForeground(),
        palette.accent,
        shell_ui.statusSize(),
    );

    const can_pause = (progress.kind == .copy or progress.kind == .move) and
        (progress.state == .running or progress.state == .paused);
    if (can_pause) {
        const rect = fileOpsPauseRect(area);
        sidebar_controls.render(
            cr,
            rect,
            if (progress.state == .paused) .play else .pause,
            fileOpsRectContains(rect, self.mouse_x, self.mouse_y),
        );
    }
    const cancel_rect = fileOpsCancelRect(area);
    sidebar_controls.render(
        cr,
        cancel_rect,
        .close,
        fileOpsRectContains(cancel_rect, self.mouse_x, self.mouse_y),
    );
}

pub fn renderSidebarScrollbar(self: *App, cr: *c.cairo_t) void {
    const bar = self.sidebarScrollbar() orelse return;
    shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.sidebar_scroll_appearance, self.scrollbar_width, ui_theme.shellPalette()));
}
pub fn renderFileOpsTip(self: *App, cr: *c.cairo_t) void {
    if (self.hoverKey() != std.math.maxInt(usize) - 2002) return;

    var speed_buf: [96]u8 = undefined;
    var bytes_buf: [96]u8 = undefined;
    const speed = i18n.fmt(&speed_buf, tr("{rate} KiB/s"), .{
        .rate = @divTrunc(self.job_bytes_per_second, 1024),
    }) catch "";
    const transferred = i18n.fmt(&bytes_buf, tr("{value} transferred"), .{
        .value = @divTrunc(self.job_transferred_bytes, 1024),
    }) catch "";
    const details = [_][]const u8{ speed, transferred };
    transferTip.render(cr, self.w, self.h, self.mouse_x, self.mouse_y, tr("File transfer"), &details);
}
