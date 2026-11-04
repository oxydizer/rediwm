//! Files geometry: toolbar, sidebar width, grid and list columns.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const splitter = @import("ui").widgets.splitter;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const git = @import("git.zig");
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const ui_field = @import("ui").widgets.field;
const ui_theme = @import("ui").theme;
const BreadcrumbHit = App.BreadcrumbHit;
const GridCard = App.GridCard;
const column_labels = App.column_labels;
const setSource = @import("app_draw.zig").setSource;
const withAlpha = @import("app_draw.zig").withAlpha;
const roundedRect = @import("app_draw.zig").roundedRect;
const drawText = @import("app_draw.zig").drawText;
const measureText = @import("app_draw.zig").measureText;

/// Same measurement for drawing and hit testing. Long paths show their
/// rightmost components; Ctrl+L always exposes the complete path.
pub fn breadcrumbs(self: *App, target: ?*c.cairo_t, hit_x: ?f64) ?BreadcrumbHit {
    const surface = if (target == null) c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) else null;
    defer if (surface) |s| c.cairo_surface_destroy(s);
    const cr = target orelse (c.cairo_create(surface) orelse return null);
    defer if (target == null) c.cairo_destroy(cr);
    const r = header.field(self.w);
    var ends: [128]usize = undefined;
    var labels: [128][]const u8 = undefined;
    var widths: [128]f64 = undefined;
    var count: usize = 1;
    const path = self.history.current;
    const at_home = std.mem.eql(u8, path, self.home_dir) or (std.mem.startsWith(u8, path, self.home_dir) and path.len > self.home_dir.len and path[self.home_dir.len] == '/');
    const at_trash = if (self.trash_dir) |trash| std.mem.eql(u8, path, trash) or
        (std.mem.startsWith(u8, path, trash) and path.len > trash.len and path[trash.len] == '/') else false;
    ends[0] = if (self.isRecent()) path.len else if (at_trash) self.trash_dir.?.len else if (at_home) self.home_dir.len else 1;
    labels[0] = if (self.isRecent()) tr("Recent") else if (at_trash) tr("Trash") else if (at_home) tr("Home") else "/";
    var start = ends[0];
    while (start < path.len and count < ends.len) {
        if (path[start] == '/') {
            start += 1;
            continue;
        }
        const end = if (std.mem.indexOfScalarPos(u8, path, start, '/')) |n| n else path.len;
        ends[count] = end;
        labels[count] = path[start..end];
        count += 1;
        start = end;
    }
    var total: f64 = 0;
    for (labels[0..count], 0..) |label, i| {
        widths[i] = measureText(cr, label, shell_ui.textSize(), false) + 28 + @as(f64, if (ends[i] == self.history.archive_len) 22 else 0);
        total += widths[i];
    }
    var first: usize = 0;
    while (first + 1 < count and total > r.w - 16) : (first += 1) total -= widths[first];
    if (target != null) {
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse return null;
        _ = ui_field.paintFrame(&layer.renderer, layer.local(), .{}, .{});
        layer.finish();
        c.cairo_save(cr);
        c.cairo_rectangle(cr, r.x + 4, r.y, r.w - 8, r.h);
        c.cairo_clip(cr);
    }
    defer if (target != null) c.cairo_restore(cr);
    var x = r.x + 8;
    for (first..count) |i| {
        if (hit_x) |hit| {
            if (hit >= x and hit < @min(x + widths[i] - 10, r.x + r.w - 8)) return .{ .path = path[0..ends[i]], .index = i };
        }
        if (target != null) {
            const alpha = self.breadcrumb_hover[i].frame.alpha;
            if (alpha > 0) {
                roundedRect(cr, x, r.y + 4, @min(widths[i] - 10, r.x + r.w - 8 - x), r.h - 8, 5);
                setSource(cr, withAlpha(ui_theme.global.app_item_hover, alpha));
                c.cairo_fill(cr);
            }
            setSource(cr, ui_theme.global.window_fg);
            const archive_crumb = ends[i] == self.history.archive_len;
            if (archive_crumb) {
                if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(x + 4), .y = @floatCast(r.y + 10), .w = 18, .h = 18 })) |icon_layer| {
                    var layer = icon_layer;
                    layer.renderer.drawIcon(0, 0, 18, 18, .{ .id = .folder, .color = ui_theme.global.window_fg });
                    layer.finish();
                }
            }
            drawText(cr, labels[i], x + 4 + @as(f64, if (archive_crumb) 22 else 0), r.y + 23, shell_ui.textSize(), false);
            if (i + 1 < count) drawText(cr, "›", x + widths[i] - 20, r.y + 23, shell_ui.textSize(), false);
        }
        x += widths[i];
    }
    return null;
}

// Shared geometry for painting, pointer input and keyboard navigation.
pub fn footerHeight(self: *const App) i32 {
    return if (self.chooser) |opts| (if (self.w >= 800) @as(i32, 88) else 114) + @as(i32, @intCast(opts.choices.len)) * 36 else 26;
}

/// What the sidebar gives up at the bottom: nothing, so it reaches the
/// window edge beside the status bar; the chooser's panel spans the width.
pub fn sidebarFooter(self: *const App) i32 {
    return if (self.chooser != null) self.footerHeight() else 0;
}

pub fn contentTop(self: *App) i32 {
    if (self.transfer_view.active) return if (self.w < 500) 152 else 112;
    return header.height(self.w, self.inRepository());
}

pub fn viewTop(self: *App) i32 {
    return self.contentTop() + if (self.list_view or self.transfer_view.active) @as(i32, 30) else 0;
}

pub fn compactList(self: *App) bool {
    return (self.list_view or self.transfer_view.active) and self.contentBottom() - self.viewTop() < 80;
}

pub fn itemInset(self: *App) i32 {
    return if (self.compactList()) 0 else 20;
}

/// Outer left margin of the file rows; grid cards keep their wider gutter.
pub fn itemLeftInset(self: *App) i32 {
    return if (self.list_view and !self.transfer_view.active) 10 else 20;
}

pub fn rowHeight(self: *App) i32 {
    return if (self.compactList() or (self.list_view and !self.transfer_view.active)) 32 else if (self.list_view or self.transfer_view.active) 38 else GridCard.height + 8;
}

pub fn cardHeight(self: *App) i32 {
    return if (self.compactList() or (self.list_view and !self.transfer_view.active)) 30 else if (self.list_view or self.transfer_view.active) 36 else GridCard.height;
}

/// Text baseline of a list row, from the row's top.
pub fn listBaseline(self: *App) f64 {
    return if (self.compactList() or (self.list_view and !self.transfer_view.active)) 21 else 24;
}

pub fn sidebarTargetWidth(self: *App) i32 {
    if (self.w < 500) return 0;
    if (self.sidebar_requested) |width| return std.math.clamp(width, 160, @divTrunc(self.w, 2));
    return if (self.w >= 700) 208 else 160;
}

/// The width being drawn: it eases toward `sidebarTargetWidth` when a
/// resize crosses a threshold.
pub fn sidebarWidth(self: *App) i32 {
    return @min(@divTrunc(self.w, 2), if (self.sidebar_px >= 0) self.sidebar_px else self.sidebarTargetWidth());
}

pub fn syncSidebarWidth(self: *App) void {
    self.sidebar_px = self.sidebarTargetWidth();
    self.sidebar_glide.cancel(@floatFromInt(self.sidebar_px));
}

pub fn sidebarDivider(self: *App) ?splitter.Geometry {
    if (self.w < 500 or self.sidebarWidth() < 160) return null;
    return .{ .x = @floatFromInt(self.sidebarWidth()), .y = @floatFromInt(self.contentTop()), .h = @floatFromInt(@max(0, self.h - self.contentTop() - self.sidebarFooter())) };
}

pub fn overSidebarDivider(self: *App, x: f64, y: f64) bool {
    if (self.dialog != null or self.menu != null) return false;
    const divider = self.sidebarDivider() orelse return false;
    return divider.contains(x, y);
}

pub fn damageSidebarDivider(self: *App) void {
    const divider = self.sidebarDivider() orelse return;
    const rect = divider.line(true);
    self.addDamage(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h });
}

pub fn placeTargetStep(self: *App) i32 {
    return if (self.h - self.contentTop() < 480) 32 else 40;
}

/// Moves `px` toward `target` along the panel slide curve; true when the
/// whole-pixel value changed.
pub fn glideInt(glide: *anim.Anim, px: *i32, target: i32, now: i64) bool {
    if (px.* < 0) {
        glide.cancel(@floatFromInt(target));
        px.* = target;
        return false;
    }
    const target_f: f32 = @floatFromInt(target);
    if (glide.to != target_f) glide.retargetTo(now, target_f, anim.curveFor(.panel_slide));
    const next: i32 = if (glide.settled(now)) target else @intFromFloat(@round(glide.value(now)));
    const changed = next != px.*;
    px.* = next;
    return changed;
}

/// Eases the sidebar's compact steps (width and row pitch) instead of
/// snapping them. Once per loop, before painting.
pub fn stepLayout(self: *App, now: i64) void {
    const width_changed = glideInt(&self.sidebar_glide, &self.sidebar_px, self.sidebarTargetWidth(), now);
    const pitch_changed = glideInt(&self.place_glide, &self.place_px, self.placeTargetStep(), now);
    if (width_changed or pitch_changed) {
        self.clampScroll();
        self.clampSidebarScroll();
        self.invalidate();
    }
    self.layout_active = !self.sidebar_glide.settled(now) or !self.place_glide.settled(now);
}

pub fn clampSidebarScroll(self: *App) void {
    self.sidebar_scroll = std.math.clamp(self.sidebar_scroll, 0, @max(0, self.sidebarExtent() - (self.h - self.sidebarFooter())));
}

pub fn scrollbarGutter(self: *const App) i32 {
    return @intFromFloat(scrollbar.gutter(self.scrollbar_width));
}

pub fn columns(self: *App) i32 {
    return if (self.list_view or self.transfer_view.active) 1 else @max(1, @divTrunc(self.w - self.sidebarWidth() - self.itemLeftInset() - self.scrollbarGutter(), 210));
}

pub fn cellWidth(self: *App) i32 {
    return @divTrunc(self.w - self.sidebarWidth() - self.itemLeftInset() - self.scrollbarGutter(), self.columns());
}

pub fn contentHeight(self: *App) i32 {
    const count: i32 = @intCast(if (self.transfer_view.active) self.torrents.items().len else self.items.items.len);
    return 2 * self.itemInset() + @divTrunc(count + self.columns() - 1, self.columns()) * self.rowHeight();
}

pub fn itemAt(self: *App, x: f64, y: f64) ?usize {
    if (self.transfer_view.active) return null;
    const gx = @as(i32, @intFromFloat(x)) - self.sidebarWidth() - self.itemLeftInset();
    if (y < @as(f64, @floatFromInt(self.viewTop())) or y >= @as(f64, @floatFromInt(self.contentBottom()))) return null;
    const gy = @as(i32, @intFromFloat(y)) - self.viewTop() - self.itemInset() + self.scroll_y;
    if (gx < 0 or gy < 0) return null;
    const col = @divTrunc(gx, self.cellWidth());
    if (col >= self.columns() or @mod(gx, self.cellWidth()) >= self.cellWidth() - 20 or @mod(gy, self.rowHeight()) >= self.cardHeight()) return null;
    const idx: usize = @intCast(@divTrunc(gy, self.rowHeight()) * self.columns() + col);
    return if (idx < self.items.items.len) idx else null;
}

/// The repository the folder belongs to, whether or not Git View is on.
pub fn foundRepository(self: *App) ?git.Repository {
    if (self.chooser != null or self.transfer_view.active) return null;
    return if (self.snapshot) |snap| snap.repository else null;
}

/// The repository to present as such: none while Git View is off.
pub fn repository(self: *App) ?git.Repository {
    return if (self.git_view) self.foundRepository() else null;
}

pub fn inRepository(self: *App) bool {
    return self.foundRepository() != null;
}

pub fn changedOnly(self: *App) bool {
    return self.changed_only and self.repository() != null;
}

pub fn columnLabels(self: *App) []const []const u8 {
    const messages: []const i18n.Message = if (self.transfer_view.active)
        &.{ i18n.msg("Name"), i18n.msg("Status"), i18n.msg("Progress"), i18n.msg("Download"), i18n.msg("Upload") }
    else if (self.repository() != null)
        &.{ i18n.msg("Name"), i18n.msg("Git") }
    else if (self.isRecent())
        &.{ i18n.msg("Name"), i18n.msg("Size"), i18n.msg("Type"), i18n.msg("Opened"), i18n.msg("Permissions") }
    else
        &.{ i18n.msg("Name"), i18n.msg("Size"), i18n.msg("Type"), i18n.msg("Modified"), i18n.msg("Permissions") };
    for (messages, 0..) |message, i| self.column_label_text[i] = message.get();
    return self.column_label_text[0..messages.len];
}

pub fn columnMinimums(width: f64) [5]f64 {
    if (width < 224) {
        const scale = width / 224;
        return .{ 64 * scale, 40 * scale, 40 * scale, 40 * scale, 40 * scale };
    }
    // Keep enough room for the full date and time when the view is wide
    // enough; below that, let the Modified column yield space to Name.
    return .{ 64, 40, 40, @min(136, width - 184), 40 };
}

pub fn listWidths(self: *App) [5]f64 {
    const width: f64 = @floatFromInt(self.cellWidth() - 20);
    if (self.transfer_view.active) {
        return .{ width * 0.36, width * 0.25, width * 0.13, width * 0.13, width * 0.13 };
    }
    if (self.repository() != null) {
        if (self.git_column_widths) |widths| return widths;
        const minimum = gitColumnMinimums(width);
        const name = @max(minimum[0], width - 164);
        return .{ name, width - name, 0, 0, 0 };
    }
    if (self.column_widths) |widths| return widths;
    if (self.hasFolderTransfers()) return .{ width * 0.50, width * 0.10, width * 0.12, width * 0.18, width * 0.10 };
    const minimum = columnMinimums(width);
    const detail = @max(minimum[1], @min(110, width * 0.14));
    const modified = @max(minimum[3], @min(160, width * 0.20));
    const permissions = @min(200, width * 0.26);
    var widths: [5]f64 = .{ 0, detail, detail, modified, @max(minimum[4], permissions) };
    var overflow = widths[1] + widths[2] + widths[3] + widths[4] - (width - minimum[0]);
    for ([_]usize{ 4, 2, 1 }) |i| {
        const shrink = @min(@max(0, overflow), widths[i] - minimum[i]);
        widths[i] -= shrink;
        overflow -= shrink;
    }
    widths[0] = width - widths[1] - widths[2] - widths[3] - widths[4];
    return widths;
}

pub fn listColumn(self: *App, column: usize) header.Rect {
    const widths = self.listWidths();
    var x: f64 = @as(f64, @floatFromInt(self.sidebarWidth() + self.itemLeftInset())) - self.horizontalOffset();
    for (widths[0..column]) |width| x += width;
    return .{ .x = x, .y = @floatFromInt(self.contentTop()), .w = widths[column], .h = 30 };
}

pub fn columnBoundary(self: *App, x: f64, y: f64) ?usize {
    if (self.transfer_view.active or !self.list_view or self.dialog != null or self.menu != null) return null;
    if (x < @as(f64, @floatFromInt(self.sidebarWidth())) or x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) return null;
    for (0..self.columnLabels().len - 1) |i| {
        const rect = self.listColumn(i);
        if (y >= rect.y and y < rect.y + rect.h and @abs(x - (rect.x + rect.w)) <= 4) return i;
    }
    return null;
}

pub fn resizeColumn(self: *App, x: f64) void {
    const drag = self.column_resize orelse return;
    var widths = drag.widths;
    const minimum: f64 = if (self.repository() != null)
        (if (drag.column == 0) 96 else 64)
    else if (drag.column == 0) 64 else 40;
    widths[drag.column] = @max(minimum, widths[drag.column] + x - drag.x);
    if (self.repository() != null) self.git_column_widths = widths else self.column_widths = widths;
    self.clampScroll();
    self.invalidate();
}

pub fn gitColumnMinimums(width: f64) [2]f64 {
    const scale = @min(1, width / 160);
    return .{ 96 * scale, 64 * scale };
}

pub fn sizeButtonRect(self: *App, idx: usize) ?header.Rect {
    if (self.history.archive_len > 0) return null;
    if (self.repository() != null) return null;
    if (idx >= self.items.items.len) return null;
    const item = self.items.items[idx];
    if (!item.is_dir or item.is_symlink or item.transfer_stub) return null;
    const cols = self.columns();
    const cell = self.cellWidth();
    const i: i32 = @intCast(idx);
    const x: f64 = @floatFromInt(self.sidebarWidth() + self.itemLeftInset() + @mod(i, cols) * cell);
    const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(i, cols) * self.rowHeight() - self.scroll_y);
    if (self.list_view) {
        const sz = self.listColumn(1);
        const baseline = self.listBaseline();
        return .{
            .x = sz.x,
            .y = y + baseline - 15,
            .w = sz.w,
            .h = 22,
        };
    } else {
        const width: f64 = @floatFromInt(cell - 20);
        return .{
            .x = x + GridCard.padding_x - 4,
            .y = y + GridCard.detail_baseline - 15,
            .w = @max(32, width - 2 * (GridCard.padding_x - 4)),
            .h = 22,
        };
    }
}
