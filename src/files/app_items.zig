//! Files item painting: grid and list rows, icons and thumbnails.

const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const thumbs_mod = @import("thumbs.zig");
const thumb_decode = @import("thumb_decode.zig");
const image_formats = @import("../images/formats.zig");
const icons = @import("../icon_cache.zig");
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const Editor = @import("editor.zig").Editor;
const GridCard = App.GridCard;
const ViewItem = @import("app_model.zig").ViewItem;
const ThumbRequest = @import("app_model.zig").ThumbRequest;
const formatSize = @import("app_draw.zig").formatSize;
const setSource = @import("app_draw.zig").setSource;
const withAlpha = @import("app_draw.zig").withAlpha;
const roundedRect = @import("app_draw.zig").roundedRect;
const drawSpinner = @import("app_draw.zig").drawSpinner;
const drawHeadEllipsis = @import("app_draw.zig").drawHeadEllipsis;
const drawEllipsis = @import("app_draw.zig").drawEllipsis;
const drawText = @import("app_draw.zig").drawText;
const measureText = @import("app_draw.zig").measureText;
const formatPermissions = @import("app_draw.zig").formatPermissions;
const itemType = App.itemType;

pub fn renderFileItems(self: *App, cr: *c.cairo_t, viewport_h: i32) void {
    const accent = ui_theme.shellPalette().accent;
    const job_progress = if (self.job_runner) |runner| runner.pollProgress() else null;
    const cols = self.columns();
    const cell = self.cellWidth();
    const first = @divTrunc(self.scroll_y, self.rowHeight()) * cols;
    const last = @min(@as(i32, @intCast(self.items.items.len)), (@divTrunc(self.scroll_y + viewport_h, self.rowHeight()) + 1) * cols);
    // The hover glide sits under every item, since mid-glide it straddles two.
    const glide = self.item_hover.frame;
    if (glide.alpha > 0) {
        const box = self.itemHighlight(glide);
        shell_ui.drawItemHighlight(cr, .{ .x = box.x, .y = box.y, .w = box.w, .h = box.h }, false, glide.alpha, glide.alpha);
    }
    var index = first;
    while (index < last) : (index += 1) {
        const idx: usize = @intCast(index);
        const item = self.items.items[idx];
        const baseline = self.listBaseline();
        const x: f64 = @floatFromInt(self.sidebarWidth() + self.itemLeftInset() + @mod(index, cols) * cell);
        const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(index, cols) * self.rowHeight() - self.scroll_y);
        const width: f64 = @floatFromInt(cell - 20);
        // Items sit on the list itself; only selection and keyboard focus
        // draw a card here (hover is the glide above).
        if (item.selection_fill.alpha > 0 or item.selection_border.alpha > 0) {
            shell_ui.drawItemHighlight(cr, .{ .x = x, .y = y, .w = width, .h = @floatFromInt(self.cardHeight()) }, true, item.selection_fill.alpha, item.selection_border.alpha);
        }
        if (self.folder_drop == idx) {
            roundedRect(cr, x, y, width, @floatFromInt(self.cardHeight()), 6);
            setSource(cr, accent);
            c.cairo_set_line_width(cr, 2);
            c.cairo_stroke(cr);
        }
        var cut = false;
        if (self.clipboard_cut) {
            for (self.clipboard_paths.items) |path| {
                if (std.mem.eql(u8, path, item.path)) {
                    cut = true;
                    break;
                }
            }
        }
        if (cut) c.cairo_push_group(cr);
        const icon = self.itemIconRect(index);
        self.drawItemIcon(cr, item, icon.x, icon.y, icon.w);
        if (job_progress) |progress| {
            if ((progress.state == .running or progress.state == .paused) and
                progress.current_file_path_len > 0 and
                progress.current_file_size > 0 and
                std.mem.eql(u8, progress.current_file_path[0..progress.current_file_path_len], item.path))
            {
                const fraction = @min(
                    1.0,
                    @as(f64, @floatFromInt(progress.current_file_bytes)) /
                        @as(f64, @floatFromInt(progress.current_file_size)),
                );
                const ring_size = @min(26.0, icon.w);
                shell_ui.drawProgressRing(cr, .{
                    .x = icon.x + (icon.w - ring_size) / 2,
                    .y = icon.y + (icon.w - ring_size) / 2,
                    .w = ring_size,
                    .h = ring_size,
                }, fraction, accent);
            }
        }
        if (item.is_dir and !item.is_symlink) {
            if (self.job_runner) |runner| {
                if (runner.progressForPath(item.path)) |progress| {
                    const ring_size = @min(26.0, icon.w);
                    shell_ui.drawProgressRing(cr, .{
                        .x = icon.x + (icon.w - ring_size) / 2,
                        .y = icon.y + (icon.w - ring_size) / 2,
                        .w = ring_size,
                        .h = ring_size,
                    }, progress, accent);
                }
            }
        }
        const label_x = x - self.horizontalOffset() + (if (self.list_view) @as(f64, 42) else GridCard.padding_x);
        setSource(cr, ui_theme.global.window_fg);
        const name_width = if (self.list_view) @max(0, self.listColumn(0).w - 46 - self.inlineTorrentWidth(idx) - self.audioButtonWidth(idx)) else width - 2 * GridCard.padding_x;
        // A path that does not fit loses its head, so the file's own name stays readable.
        const name_y = y + (if (self.list_view) baseline else GridCard.name_baseline);
        if (item.label.len > 0) drawHeadEllipsis(cr, item.label, label_x, name_y, name_width, shell_ui.textSize(), false) else drawEllipsis(cr, item.name, label_x, name_y, name_width, shell_ui.textSize(), false);
        var buf: [64]u8 = undefined;
        var size_buf: [64]u8 = undefined;
        const disp = if (item.transfer_stub) App.ItemSizeDisplay{ .text = formatSize((self.torrentForItem(idx) orelse continue).total, &size_buf), .is_running = false } else self.itemSizeDisplay(item, &size_buf);
        const is_size_hovered = (self.hoverKey() == 2_000_000 + idx);
        if (self.list_view and self.repository() != null) {
            self.renderGitStatus(cr, item, y);
        } else if (self.list_view) {
            const sz = self.listColumn(1);
            if (disp.is_running) {
                const text_w = @max(0.0, sz.w - 24);
                setSource(cr, ui_theme.global.window_fg);
                drawEllipsis(cr, disp.text, sz.x + 4, y + baseline, text_w, shell_ui.textSize(), false);
                drawSpinner(cr, sz.x + sz.w - 10, y + baseline - 4, 4.5);
            } else if (item.is_dir and !item.is_symlink and is_size_hovered and std.mem.eql(u8, disp.text, "—")) {
                roundedRect(cr, sz.x + 2, y + baseline - 14, 24, 18, 4);
                setSource(cr, ui_theme.global.surface_hover);
                c.cairo_fill(cr);
                setSource(cr, ui_theme.global.window_fg);
                drawEllipsis(cr, "—", sz.x + 8, y + baseline, sz.w - 12, shell_ui.textSize(), false);
            } else {
                setSource(cr, ui_theme.global.window_fg);
                drawEllipsis(cr, disp.text, sz.x + 4, y + baseline, sz.w - 8, shell_ui.textSize(), false);
            }
            setSource(cr, ui_theme.global.window_fg);
            const ty = self.listColumn(2);
            drawEllipsis(cr, if (item.transfer_stub) @import("i18n").tr("Download") else itemType(item), ty.x + 4, y + baseline, ty.w - 8, shell_ui.textSize(), false);
            const mt = self.listColumn(3);
            const timestamp = if (item.transfer_stub) "—" else @import("settings.zig").dateTime(if (self.isRecent()) item.opened else item.mtime, &buf);
            drawEllipsis(cr, timestamp, mt.x + 4, y + baseline, mt.w - 8, shell_ui.textSize(), false);
            const permissions = self.listColumn(4);
            const mode = formatPermissions(item.mode);
            drawEllipsis(cr, if (item.transfer_stub) "—" else if (item.permissions_text.len > 0) item.permissions_text else &mode, permissions.x + 4, y + baseline, permissions.w - 8, shell_ui.textSize(), false);
        } else if (self.torrentForItem(idx) != null) {
            // The transfer accessory occupies the grid card's detail line.
        } else {
            if (item.is_symlink) {
                setSource(cr, ui_theme.global.window_fg);
                drawText(cr, itemType(item), label_x, y + GridCard.detail_baseline, shell_ui.textSize(), false);
            } else if (item.is_dir) {
                if (disp.is_running) {
                    setSource(cr, ui_theme.global.window_fg);
                    drawText(cr, disp.text, label_x, y + GridCard.detail_baseline, shell_ui.textSize(), false);
                    const tw = measureText(cr, disp.text, shell_ui.textSize(), false);
                    drawSpinner(cr, label_x + tw + 10, y + GridCard.detail_baseline - 4, 4.5);
                } else if (is_size_hovered and std.mem.eql(u8, disp.text, "—")) {
                    roundedRect(cr, label_x - 4, y + GridCard.detail_baseline - 14, 24, 18, 4);
                    setSource(cr, ui_theme.global.surface_hover);
                    c.cairo_fill(cr);
                    setSource(cr, ui_theme.global.window_fg);
                    drawText(cr, "—", label_x + 2, y + GridCard.detail_baseline, shell_ui.textSize(), false);
                } else {
                    setSource(cr, ui_theme.global.window_fg);
                    drawText(cr, disp.text, label_x, y + GridCard.detail_baseline, shell_ui.textSize(), false);
                }
            } else {
                setSource(cr, ui_theme.global.window_fg);
                drawText(cr, formatSize(item.bytes, &buf), label_x, y + GridCard.detail_baseline, shell_ui.textSize(), false);
            }
        }
        self.renderInlineTorrent(cr, idx);
        self.renderAudioButton(cr, idx);
        if (cut) {
            c.cairo_pop_group_to_source(cr);
            c.cairo_paint_with_alpha(cr, 0.45);
        }
    }
}

pub fn renderFilenameTip(self: *App, cr: *c.cairo_t) void {
    if (self.inlineTorrentHit(self.mouse_x, self.mouse_y) != null or self.audioButtonHit(self.mouse_x, self.mouse_y) != null) return;
    const index = self.itemAt(self.mouse_x, self.mouse_y) orelse return;
    const name = self.items.items[index].text();
    const available: f64 = if (self.list_view) self.listColumn(0).w - 46 - self.inlineTorrentWidth(index) - self.audioButtonWidth(index) else @as(f64, @floatFromInt(self.cellWidth() - 62));
    if (measureText(cr, name, shell_ui.textSize(), false) <= available) return;
    const width = @min(@as(f64, @floatFromInt(self.w - 24)), @max(180, measureText(cr, name, shell_ui.textSize(), false) + 20));
    var lines: [32][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    while (start < name.len and count < lines.len) {
        var end = Editor.next(name, start);
        while (end < name.len) {
            const next = Editor.next(name, end);
            if (measureText(cr, name[start..next], shell_ui.textSize(), false) > width - 20) break;
            end = next;
        }
        lines[count] = name[start..end];
        count += 1;
        start = end;
    }
    const height: f64 = @floatFromInt(count * 17 + 10);
    // Anchor to the item, so motion within it does not require a repaint.
    const row = @divTrunc(@as(i32, @intCast(index)), self.columns());
    const y = std.math.clamp(@as(f64, @floatFromInt(self.viewTop() + self.itemInset() + row * self.rowHeight() - self.scroll_y + self.cardHeight())), 4, @max(4, @as(f64, @floatFromInt(self.h - self.footerHeight())) - height));
    const x: f64 = @floatFromInt(@min(self.sidebarWidth() + self.itemLeftInset(), self.w - @as(i32, @intFromFloat(width)) - 12));
    roundedRect(cr, x, y, width, height, 4);
    setSource(cr, ui_theme.global.app_divider);
    c.cairo_fill(cr);
    setSource(cr, ui_theme.global.window_fg);
    for (lines[0..count], 0..) |line, i| drawText(cr, line, x + 10, y + 17 + @as(f64, @floatFromInt(i * 17)), shell_ui.textSize(), false);
}

/// Where an item's icon (or thumbnail) is drawn, in window coordinates.
pub fn itemIconRect(self: *App, index: i32) header.Rect {
    const cols = self.columns();
    const size: f64 = if (self.list_view) 24 else GridCard.icon_size;
    return .{
        .x = @as(f64, @floatFromInt(self.sidebarWidth() + self.itemLeftInset() + @mod(index, cols) * self.cellWidth())) + (if (self.list_view) @as(f64, 12) else GridCard.padding_x) - self.horizontalOffset(),
        .y = @as(f64, @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(index, cols) * self.rowHeight() - self.scroll_y)) + (if (self.list_view) @as(f64, @floatFromInt(self.cardHeight() - 24)) / 2 else GridCard.padding_top),
        .w = size,
        .h = size,
    };
}

/// Files that show a picture of themselves instead of a type icon.
pub fn thumbnailable(item: ViewItem) bool {
    return !item.is_dir and !item.is_broken and image_formats.candidate(item.name);
}

pub fn thumbService(self: *App) ?*thumbs_mod.Service {
    if (!self.thumbs_enabled) return null;
    if (self.thumbs) |service| return service;
    const cache_dir = thumb_decode.cacheDir(self.allocator, self.environ);
    defer if (cache_dir) |dir| self.allocator.free(dir);
    self.thumbs = thumbs_mod.Service.create(cache_dir) catch {
        self.thumbs_enabled = false;
        return null;
    };
    return self.thumbs;
}

/// Readable when finished thumbnails wait in `drainThumbs`; -1 before any.
pub fn thumbWakeFd(self: *const App) c_int {
    return if (self.thumbs) |service| service.wakeFd() else -1;
}

pub fn collectThumbRow(self: *App, row: i32, cols: i32) void {
    const limit = 192;
    var col: i32 = 0;
    while (col < cols and self.thumb_wants.items.len < limit) : (col += 1) {
        const index = row * cols + col;
        if (index >= self.items.items.len) return;
        const item = self.items.items[@intCast(index)];
        if (!thumbnailable(item)) continue;
        self.thumb_wants.append(self.allocator, .{ .path = item.path, .mtime = item.mtime, .bytes = item.bytes, .is_symlink = item.is_symlink }) catch return;
    }
}

/// Asks for thumbnails of the visible files, then of a screenful on each
/// side, whenever the visible rows or the listing change. Cheap otherwise:
/// one comparison per loop.
pub fn stepThumbs(self: *App) void {
    if (self.history.archive_len > 0) return;
    if (!self.thumbs_enabled) return;
    const cols = self.columns();
    const row_h = self.rowHeight();
    const viewport_h = @max(0, self.contentBottom() - self.viewTop());
    const row0 = @divTrunc(self.scroll_y, row_h);
    const row1 = @divTrunc(self.scroll_y + viewport_h, row_h);
    const request: ThumbRequest = .{ .revision = self.view_revision, .row0 = row0, .row1 = row1, .cols = cols };
    if (std.meta.eql(request, self.thumb_request)) return;
    self.thumb_request = request;

    self.thumb_wants.clearRetainingCapacity();
    const margin = row1 - row0 + 1;
    var row = row0;
    while (row <= row1 + margin) : (row += 1) self.collectThumbRow(row, cols);
    row = row0 - 1;
    while (row >= @max(0, row0 - margin)) : (row -= 1) self.collectThumbRow(row, cols);
    // Nothing to show and no service to tell: do not start the workers.
    if (self.thumb_wants.items.len == 0 and self.thumbs == null) return;
    const service = self.thumbService() orelse return;
    service.request(self.thumb_wants.items);
}

/// Takes finished thumbnails and repaints only the icons they fill.
pub fn drainThumbs(self: *App) void {
    const service = self.thumbs orelse return;
    self.thumb_arrived.clearRetainingCapacity();
    service.drain(&self.thumb_arrived);
    if (self.thumb_arrived.items.len == 0) return;
    const cols = self.columns();
    const row_h = self.rowHeight();
    const viewport_h = @max(0, self.contentBottom() - self.viewTop());
    const first = @divTrunc(self.scroll_y, row_h) * cols;
    const last = @min(@as(i32, @intCast(self.items.items.len)), (@divTrunc(self.scroll_y + viewport_h, row_h) + 1) * cols);
    var index = first;
    while (index < last) : (index += 1) {
        const item = self.items.items[@intCast(index)];
        if (!thumbnailable(item)) continue;
        const hash = thumbs_mod.pathHash(item.path);
        if (std.mem.indexOfScalar(u64, self.thumb_arrived.items, hash) == null) continue;
        var rect = self.itemIconRect(index);
        rect.x -= 1;
        rect.y -= 1;
        rect.w += 2;
        rect.h += 2;
        self.addDamage(self.clipToViewport(rect));
    }
}

pub fn drawThumb(cr: *c.cairo_t, thumb: thumbs_mod.Thumb, x: f64, y: f64, size: f64) void {
    const tw: f64 = @floatFromInt(thumb.w);
    const th: f64 = @floatFromInt(thumb.h);
    const fit = size / @max(tw, th);
    const w = @max(1, @round(tw * fit));
    const h = @max(1, @round(th * fit));
    const ox = x + @floor((size - w) / 2);
    const oy = y + @floor((size - h) / 2);
    const surface = c.cairo_image_surface_create_for_data(
        @ptrCast(@constCast(thumb.pixels.ptr)),
        c.CAIRO_FORMAT_ARGB32,
        thumb.w,
        thumb.h,
        thumb.w * 4,
    ) orelse return;
    defer c.cairo_surface_destroy(surface);
    c.cairo_save(cr);
    roundedRect(cr, ox, oy, w, h, 3);
    c.cairo_clip(cr);
    c.cairo_translate(cr, ox, oy);
    c.cairo_scale(cr, w / tw, h / th);
    c.cairo_set_source_surface(cr, surface, 0, 0);
    const pattern = c.cairo_get_source(cr);
    c.cairo_pattern_set_filter(pattern, c.CAIRO_FILTER_GOOD);
    c.cairo_pattern_set_extend(pattern, c.CAIRO_EXTEND_PAD);
    c.cairo_paint(cr);
    c.cairo_restore(cr);
    // A hairline keeps pale pictures from dissolving into the list.
    roundedRect(cr, ox + 0.5, oy + 0.5, w - 1, h - 1, 2.5);
    setSource(cr, ui_theme.global.app_item_border);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

pub fn itemIcon(self: *App, item: ViewItem, raster_size: i32) ?icons.Entry {
    for (item.icon_candidates) |name| {
        if (icons.get(self.theme_cfg, self.io, name, raster_size)) |entry| return entry;
    }
    if (icons.get(self.theme_cfg, self.io, item.icon_name, raster_size)) |entry| return entry;
    return if (item.is_dir) icons.get(self.theme_cfg, self.io, "folder", raster_size) else null;
}

pub fn drawItemIcon(self: *App, cr: *c.cairo_t, item: ViewItem, x: f64, y: f64, size: f64) void {
    if (self.thumbs) |service| {
        if (thumbnailable(item)) {
            if (service.lookup(item.path, item.mtime, item.bytes)) |thumb| {
                drawThumb(cr, thumb, x, y, size);
                if (item.is_symlink) {
                    c.cairo_save(cr);
                    defer c.cairo_restore(cr);
                    c.cairo_translate(cr, x, y);
                    self.drawSymlinkEmblem(cr, size);
                }
                return;
            }
        }
    }
    const raster_size = @as(i32, @intFromFloat(size)) * self.scale;
    const maybe_icon = self.itemIcon(item, raster_size);

    if (maybe_icon) |entry| {
        const surf = c.cairo_image_surface_create_for_data(
            @ptrCast(@constCast(entry.pixels.ptr)),
            c.CAIRO_FORMAT_ARGB32,
            entry.size,
            entry.size,
            entry.size * 4,
        );
        if (surf != null) {
            defer c.cairo_surface_destroy(surf);
            c.cairo_save(cr);
            defer c.cairo_restore(cr);
            c.cairo_translate(cr, x, y);
            const s = size / @as(f64, @floatFromInt(entry.size));
            c.cairo_scale(cr, s, s);
            c.cairo_set_source_surface(cr, surf, 0, 0);
            c.cairo_paint(cr);
            if (item.is_symlink) self.drawSymlinkEmblem(cr, size);
            return;
        }
    }

    // Fallback vector icon
    if (item.is_broken) {
        setSource(cr, ui_theme.global.file_broken);
        roundedRect(cr, x + 2, y + 2, size - 4, size - 4, 4);
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.window_fg);
        drawText(cr, "!", x + 10, y + 17, 14, true);
    } else if (item.is_dir) {
        // Folder icon
        setSource(cr, ui_theme.global.file_folder_back);
        roundedRect(cr, x + 2, y + size * 0.1, size * 0.42, size * 0.25, size * 0.0625);
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.file_folder_front);
        roundedRect(cr, x + 2, y + size * 0.29, size - 4, size * 0.625, size * 0.0625);
        c.cairo_fill(cr);
    } else {
        // Document icon
        setSource(cr, ui_theme.global.file_document);
        roundedRect(cr, x + 4, y + 2, size - 8, size - 4, 2);
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.file_document_lines);
        c.cairo_rectangle(cr, x + 7, y + 8, size - 14, 2);
        c.cairo_rectangle(cr, x + 7, y + 13, size - 14, 2);
        c.cairo_rectangle(cr, x + 7, y + 18, size - 18, 2);
        c.cairo_fill(cr);
    }

    if (item.is_symlink) {
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_translate(cr, x, y);
        self.drawSymlinkEmblem(cr, size);
    }
}

pub fn drawSymlinkEmblem(_: *App, cr: *c.cairo_t, size: f64) void {
    const lx = size - 9;
    const ly = size - 9;
    const bg = ui_theme.global.app_bg;
    setSource(cr, .{ bg[0], bg[1], bg[2], 0.85 });
    c.cairo_arc(cr, lx + 4, ly + 4, 5, 0, 2 * std.math.pi);
    c.cairo_fill(cr);

    setSource(cr, ui_theme.shellPalette().accent);
    c.cairo_set_line_width(cr, 1.2);
    c.cairo_move_to(cr, lx + 2, ly + 6);
    c.cairo_line_to(cr, lx + 6, ly + 2);
    c.cairo_move_to(cr, lx + 3, ly + 2);
    c.cairo_line_to(cr, lx + 6, ly + 2);
    c.cairo_line_to(cr, lx + 6, ly + 5);
    c.cairo_stroke(cr);
}
