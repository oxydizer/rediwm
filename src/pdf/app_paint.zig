//! PDF viewer painting: canvas, sidebar, toolbar, search bar and dialogs.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig");
const document = @import("document.zig");
const layout = @import("layout.zig");
const cache = @import("cache.zig");
const shell_ui = @import("ui").cairo;
const ui_button = @import("ui").widgets.button;
const ui_field = @import("ui").widgets.field;
const ui_dialog = @import("ui").widgets.dialog;
const ui_theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const IconId = @import("ui").layout.IconId;
const a = @import("app.zig").a;
const toolbar_buttons = @import("app.zig").toolbar_buttons;
const toolbar_button_y = @import("app.zig").toolbar_button_y;
const toolbar_button_h = @import("app.zig").toolbar_button_h;

pub fn render(self: *App, cr: *c.api.cairo_t) void {
    // Render reading canvas
    self.renderCanvas(cr);

    // Render sidebar
    if (self.sidebar_open) {
        self.renderSidebar(cr);
    }

    // Render top toolbar
    self.renderToolbar(cr);

    // Render in-page search bar
    if (self.search_open) {
        self.renderSearchBar(cr);
    }

    // Render modal dialog
    if (self.dialog != .none) {
        self.renderDialog(cr);
    }
}

pub fn renderCanvas(self: *App, cr: *c.api.cairo_t) void {
    const cv = self.canvasRect();
    if (cv.w <= 0 or cv.h <= 0) return;

    c.api.cairo_save(cr);
    defer c.api.cairo_restore(cr);

    c.api.cairo_rectangle(cr, cv.x, cv.y, cv.w, cv.h);
    c.api.cairo_clip(cr);

    // Canvas neutral background
    shell_ui.setSource(cr, ui_theme.global.app_bg);
    c.api.cairo_paint(cr);

    if (self.loading) {
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        const msg = tr("Opening document...");
        shell_ui.drawText(cr, msg, cv.x + @max(20.0, (cv.w - shell_ui.measureText(cr, msg, shell_ui.textSize(), false)) / 2.0), cv.y + cv.h / 2.0, shell_ui.textSize(), false);
        return;
    }

    if (self.doc_layout == null or self.n_pages == 0) {
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        const msg = if (self.error_message) |m| m else tr("No document open. Click 'Open' or press Ctrl+O.");
        shell_ui.drawText(cr, msg, cv.x + @max(20.0, (cv.w - shell_ui.measureText(cr, msg, shell_ui.textSize(), false)) / 2.0), cv.y + cv.h / 2.0, shell_ui.textSize(), false);
        return;
    }

    const dl = self.doc_layout.?;
    const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
    if (vis == null) return;

    const effective_scale = self.zoom * @as(f64, @floatFromInt(self.scale));

    for (vis.?.start_index..vis.?.end_index + 1) |i| {
        const p = dl.pages[i];
        const page_x = self.pageX(cv, p);
        const page_y = cv.y + p.y_offset - self.scroll_y;

        // Page drop shadow
        shell_ui.setSource(cr, ui_theme.global.pdf_page_shadow);
        c.api.cairo_rectangle(cr, page_x + 2.0, page_y + 3.0, p.logical_width, p.logical_height);
        c.api.cairo_fill(cr);

        // White paper background
        c.api.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
        c.api.cairo_rectangle(cr, page_x, page_y, p.logical_width, p.logical_height);
        c.api.cairo_fill(cr);

        // Check page cache
        var painted_pixels = false;
        if (self.tileSpan(cv, p)) |span| {
            var tiles: [64]?*cache.CachedPage = undefined;
            var n: usize = 0;
            var complete = true;
            for (span.y0..span.y1) |ty| for (span.x0..span.x1) |tx| {
                const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, span.key(tx, ty));
                const cp = self.page_cache.get(pk);
                complete = complete and cp != null;
                if (n < tiles.len) {
                    tiles[n] = cp;
                    n += 1;
                }
            };
            // An older whole-page raster stands in under missing tiles.
            if (!complete) {
                if (self.page_cache.findBest(self.generation, i, self.rotation)) |best| {
                    self.drawCachedSurface(cr, best, page_x, page_y, p.logical_width, p.logical_height);
                    painted_pixels = true;
                }
            }
            n = 0;
            for (span.y0..span.y1) |ty| for (span.x0..span.x1) |tx| {
                if (n >= tiles.len) break;
                defer n += 1;
                const cp = tiles[n] orelse continue;
                const tk = span.key(tx, ty);
                self.drawRaster(cr, cp, page_x, page_y, @floatFromInt(tk.x), @floatFromInt(tk.y));
                painted_pixels = true;
            };
        } else {
            const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, null);
            if (self.page_cache.get(pk)) |cp| {
                self.drawRaster(cr, cp, page_x, page_y, 0, 0);
                painted_pixels = true;
            }
        }

        // Fallback: draw best cached scale while sharp zoom renders!
        if (!painted_pixels) {
            if (self.page_cache.findBest(self.generation, i, self.rotation)) |best| {
                self.drawCachedSurface(cr, best, page_x, page_y, p.logical_width, p.logical_height);
            } else {
                // Placeholder while page is rendering
                shell_ui.setSource(cr, ui_theme.global.pdf_loading);
                var buf: [32]u8 = undefined;
                const loading_msg = i18n.fmt(&buf, tr("Rendering page {value}..."), .{ .value = i + 1 }) catch "";
                shell_ui.drawText(cr, loading_msg, page_x + @max(20.0, (p.logical_width - shell_ui.measureText(cr, loading_msg, shell_ui.textSize(), false)) / 2.0), page_y + p.logical_height / 2.0, shell_ui.textSize(), false);
            }
        }

        // Page border
        shell_ui.setSource(cr, ui_theme.global.pdf_page_border);
        c.api.cairo_set_line_width(cr, 1.0);
        c.api.cairo_rectangle(cr, page_x, page_y, p.logical_width, p.logical_height);
        c.api.cairo_stroke(cr);

        // Paint search matches on this page
        if (self.search_open) {
            for (self.search_matches.items, 0..) |m, m_idx| {
                if (m.page_index == i) {
                    const vr = layout.pageRectToView(m.rect, p.pts_size, self.rotation, self.zoom);
                    const is_active = m_idx == self.search_match_idx;
                    if (is_active) {
                        shell_ui.setSource(cr, ui_theme.global.pdf_search_match_active);
                    } else {
                        shell_ui.setSource(cr, ui_theme.global.pdf_search_match);
                    }
                    c.api.cairo_rectangle(cr, page_x + vr.x, page_y + vr.y, vr.w, vr.h);
                    c.api.cairo_fill(cr);
                }
            }
        }

        // Paint text selection highlight on this page
        if (self.selection_page == i) {
            if (self.selection_range) |range| {
                if (self.page_contents.get(i)) |content| {
                    shell_ui.setSource(cr, ui_theme.shellPalette().selectionColor());
                    for (content.text_rects[range.start..range.end]) |r| {
                        const vr = layout.pageRectToView(r, p.pts_size, self.rotation, self.zoom);
                        c.api.cairo_rectangle(cr, page_x + vr.x, page_y + vr.y, vr.w, vr.h);
                    }
                    c.api.cairo_fill(cr);
                }
            }
        }
    }

    if (self.hbar()) |bar| shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.hbar_appearance, ui_theme.global.scrollbar_width, ui_theme.shellPalette()));
}

/// Draws a raster at the current zoom one pixel per device pixel, with
/// the page origin on the device grid: resampling would soften text and
/// leave seams between tiles. `x`, `y` place it within the page raster.
pub fn drawRaster(self: *App, cr: *c.api.cairo_t, cp: *cache.CachedPage, page_x: f64, page_y: f64, x: f64, y: f64) void {
    const s: f64 = @floatFromInt(self.scale);
    const origin_x = @round(page_x * s);
    const origin_y = @round(page_y * s);
    self.drawCachedSurface(cr, cp, (origin_x + x) / s, (origin_y + y) / s, @as(f64, @floatFromInt(cp.width)) / s, @as(f64, @floatFromInt(cp.height)) / s);
}

pub fn drawCachedSurface(self: *App, cr: *c.api.cairo_t, cp: *cache.CachedPage, x: f64, y: f64, target_w: f64, target_h: f64) void {
    _ = self;
    const surf = c.api.cairo_image_surface_create_for_data(
        @ptrCast(cp.pixels.ptr),
        c.api.CAIRO_FORMAT_ARGB32,
        cp.width,
        cp.height,
        cp.stride,
    );
    if (surf == null or c.api.cairo_surface_status(surf) != c.api.CAIRO_STATUS_SUCCESS) return;
    defer c.api.cairo_surface_destroy(surf);

    c.api.cairo_save(cr);
    defer c.api.cairo_restore(cr);

    c.api.cairo_translate(cr, x, y);
    const sx = target_w / @as(f64, @floatFromInt(cp.width));
    const sy = target_h / @as(f64, @floatFromInt(cp.height));
    c.api.cairo_scale(cr, sx, sy);
    c.api.cairo_set_source_surface(cr, surf, 0, 0);
    c.api.cairo_paint(cr);
}

pub fn renderSidebar(self: *App, cr: *c.api.cairo_t) void {
    const sb = self.sidebarRect();
    c.api.cairo_save(cr);
    defer c.api.cairo_restore(cr);

    c.api.cairo_rectangle(cr, sb.x, sb.y, sb.w, sb.h);
    c.api.cairo_clip(cr);

    // Sidebar background
    shell_ui.setSource(cr, ui_theme.global.app_sidebar);
    c.api.cairo_paint(cr);

    // Top tabs: [ Pages ] [ Outline ]
    const tab_w = sb.w / 2.0;
    const tab_h = 32.0;
    const idle_tab = if (ui_theme.global.app_sidebar_fg != null) ui_theme.global.app_sidebar else ui_theme.global.app_item;
    shell_ui.setSource(cr, if (self.sidebar_tab == .pages) ui_theme.global.sidebarSelected() else idle_tab);
    c.api.cairo_rectangle(cr, sb.x + 4.0, sb.y + 4.0, tab_w - 6.0, tab_h - 8.0);
    c.api.cairo_fill(cr);

    shell_ui.setSource(cr, if (self.sidebar_tab == .outline) ui_theme.global.sidebarSelected() else idle_tab);
    c.api.cairo_rectangle(cr, sb.x + tab_w + 2.0, sb.y + 4.0, tab_w - 6.0, tab_h - 8.0);
    c.api.cairo_fill(cr);

    // The selected tab is told apart by its fill, not by a dimmer label.
    shell_ui.setSource(cr, ui_theme.global.sidebarForeground());
    shell_ui.drawText(cr, tr("Pages"), sb.x + (tab_w - shell_ui.measureText(cr, tr("Pages"), shell_ui.textSize(), true)) / 2.0, sb.y + 20.0, shell_ui.textSize(), true);
    shell_ui.drawText(cr, tr("Outline"), sb.x + tab_w + (tab_w - shell_ui.measureText(cr, tr("Outline"), shell_ui.textSize(), true)) / 2.0, sb.y + 20.0, shell_ui.textSize(), true);

    // Divider under tabs
    shell_ui.setSource(cr, ui_theme.global.app_divider);
    c.api.cairo_set_line_width(cr, 1.0);
    c.api.cairo_move_to(cr, sb.x, sb.y + tab_h);
    c.api.cairo_line_to(cr, sb.x + sb.w, sb.y + tab_h);
    c.api.cairo_stroke(cr);

    // Right vertical divider
    c.api.cairo_move_to(cr, sb.x + sb.w - 0.5, sb.y);
    c.api.cairo_line_to(cr, sb.x + sb.w - 0.5, sb.y + sb.h);
    c.api.cairo_stroke(cr);

    if (self.sidebar_tab == .pages) {
        self.renderThumbnailCards(cr);
    } else {
        self.renderOutlineList(cr);
    }
}

pub fn renderThumbnailCards(self: *App, cr: *c.api.cairo_t) void {
    const sb = self.sidebarRect();
    const sbl = self.sidebar_layout orelse return;
    const vis = layout.findVisibleSidebarCards(sbl.cards, self.sidebar_scroll_y, sb.h - 36.0);
    const vis_cards = vis orelse return;

    const card_w = self.sidebar_w - 32.0;

    for (vis_cards.start_index..vis_cards.end_index + 1) |i| {
        const card = sbl.cards[i];
        const card_x = sb.x + 16.0;
        const card_y = sb.y + 36.0 + card.y_offset - self.sidebar_scroll_y;

        // Card shadow
        shell_ui.setSource(cr, ui_theme.global.pdf_thumbnail_shadow);
        c.api.cairo_rectangle(cr, card_x + 1.0, card_y + 2.0, card_w, card.card_h);
        c.api.cairo_fill(cr);

        // White thumbnail paper
        shell_ui.setSource(cr, ui_theme.global.pdf_thumbnail_bg);
        c.api.cairo_rectangle(cr, card_x, card_y, card_w, card.card_h);
        c.api.cairo_fill(cr);

        // Render thumbnail from cache
        const tk = cache.ThumbKey{
            .generation = self.generation,
            .page_index = i,
            .rotation = self.rotation,
            .card_w = @intFromFloat(card_w),
            .card_h = @intFromFloat(card.card_h),
        };
        if (self.thumb_cache.get(tk)) |ct| {
            const surf = c.api.cairo_image_surface_create_for_data(
                @ptrCast(ct.pixels.ptr),
                c.api.CAIRO_FORMAT_ARGB32,
                ct.width,
                ct.height,
                ct.stride,
            );
            if (surf != null and c.api.cairo_surface_status(surf) == c.api.CAIRO_STATUS_SUCCESS) {
                defer c.api.cairo_surface_destroy(surf);
                c.api.cairo_save(cr);
                c.api.cairo_translate(cr, card_x, card_y);
                const sx = card_w / @as(f64, @floatFromInt(ct.width));
                const sy = card.card_h / @as(f64, @floatFromInt(ct.height));
                c.api.cairo_scale(cr, sx, sy);
                c.api.cairo_set_source_surface(cr, surf, 0, 0);
                c.api.cairo_paint(cr);
                c.api.cairo_restore(cr);
            }
        }

        // Highlight border if active or hover
        const is_current = i == self.current_page;
        const is_hover = self.hover_thumb == i;
        if (is_current) {
            shell_ui.setSource(cr, ui_theme.shellPalette().accent);
            c.api.cairo_set_line_width(cr, 2.5);
        } else if (is_hover) {
            shell_ui.setSource(cr, ui_theme.global.window_dim);
            c.api.cairo_set_line_width(cr, 1.5);
        } else {
            shell_ui.setSource(cr, ui_theme.global.pdf_page_border);
            c.api.cairo_set_line_width(cr, 1.0);
        }
        c.api.cairo_rectangle(cr, card_x, card_y, card_w, card.card_h);
        c.api.cairo_stroke(cr);

        // Page number badge
        var badge: [16]u8 = undefined;
        const badge_str = std.fmt.bufPrint(&badge, "{d}", .{i + 1}) catch "";
        const bw = shell_ui.measureText(cr, badge_str, shell_ui.textSize(), is_current);
        shell_ui.setSource(cr, ui_theme.global.sidebarForeground());
        shell_ui.drawText(cr, badge_str, card_x + (card_w - bw) / 2.0, card_y + card.card_h + 15.0, shell_ui.textSize(), is_current);
    }
}

pub fn renderOutlineList(self: *App, cr: *c.api.cairo_t) void {
    const sb = self.sidebarRect();
    const items = self.outline orelse {
        shell_ui.setSource(cr, ui_theme.global.sidebarForeground());
        shell_ui.drawText(cr, tr("No outline in document"), sb.x + 16.0, sb.y + 60.0, shell_ui.textSize(), false);
        return;
    };

    const row_h = 28.0;
    for (items, 0..) |it, idx| {
        const row_y = sb.y + 40.0 + @as(f64, @floatFromInt(idx)) * row_h - self.sidebar_scroll_y;
        if (row_y + row_h < sb.y + 36.0 or row_y > sb.y + sb.h) continue;

        const is_hover = self.hover_outline == idx;
        if (is_hover) {
            shell_ui.setSource(cr, if (ui_theme.global.app_sidebar_fg != null) ui_theme.global.sidebarSelected() else ui_theme.global.app_item_hover);
            c.api.cairo_rectangle(cr, sb.x + 4.0, row_y, sb.w - 8.0, row_h);
            c.api.cairo_fill(cr);
        }

        const indent = @as(f64, @floatFromInt(it.level)) * 12.0;
        shell_ui.setSource(cr, ui_theme.global.sidebarForeground());
        c.api.cairo_save(cr);
        c.api.cairo_rectangle(cr, sb.x + 12.0 + indent, row_y, @max(0.0, sb.w - 24.0 - indent), row_h);
        c.api.cairo_clip(cr);
        shell_ui.drawText(cr, it.title, sb.x + 12.0 + indent, row_y + 18.0, shell_ui.textSize(), is_hover);
        c.api.cairo_restore(cr);
    }
}

pub fn renderToolbar(self: *App, cr: *c.api.cairo_t) void {
    const tb = self.toolbarRect();

    // Background & bottom border
    shell_ui.setSource(cr, ui_theme.global.app_toolbar);
    c.api.cairo_rectangle(cr, tb.x, tb.y, tb.w, tb.h);
    c.api.cairo_fill(cr);

    shell_ui.setSource(cr, ui_theme.global.app_divider);
    c.api.cairo_set_line_width(cr, 1.0);
    c.api.cairo_move_to(cr, tb.x, tb.h - 0.5);
    c.api.cairo_line_to(cr, tb.x + tb.w, tb.h - 0.5);
    c.api.cairo_stroke(cr);

    for (toolbar_buttons) |item| {
        const x = item.x;
        const y = toolbar_button_y;
        const w = item.w;
        const h = toolbar_button_h;
        switch (item.act) {
            .toggle_sidebar => self.renderButtonIcon(cr, x, y, w, h, .view_grid, tr("Toggle sidebar")),
            .prev_page => self.renderButtonText(cr, x, y, w, h, "◀"),
            .next_page => self.renderButtonText(cr, x, y, w, h, "▶"),
            .zoom_out => self.renderButtonText(cr, x, y, w, h, "−"),
            .zoom_in => self.renderButtonText(cr, x, y, w, h, "+"),
            .fit_width => self.renderToggle(cr, x, y, w, h, tr("Fit width"), self.zoom_mode == .fit_width),
            .fit_page => self.renderToggle(cr, x, y, w, h, tr("Fit page"), self.zoom_mode == .fit_page),
            .rotate => self.renderButtonIcon(cr, x, y, w, h, .rotate, tr("Rotate")),
            .find_toggle => self.renderButtonText(cr, x, y, w, h, if (self.search_open) tr("Find ▲") else tr("Find")),
            .print => self.renderButtonIcon(cr, x, y, w, h, .print, tr("Print")),
            else => {},
        }
    }

    // Page number field: [ 3 ] / 42
    var pbuf: [32]u8 = undefined;
    const cur_str = if (self.focus == .page_number)
        self.editor.text.items
    else
        std.fmt.bufPrint(&pbuf, "{d}", .{self.current_page + 1}) catch "1";

    shell_ui.setSource(cr, ui_theme.global.field_bg);
    c.api.cairo_rectangle(cr, 126.0, 8.0, 48.0, 28.0);
    c.api.cairo_fill(cr);

    shell_ui.setSource(cr, if (self.focus == .page_number) ui_theme.shellPalette().fieldFocusColor() else ui_theme.global.field_border);
    c.api.cairo_set_line_width(cr, 1.0);
    c.api.cairo_rectangle(cr, 126.0, 8.0, 48.0, 28.0);
    c.api.cairo_stroke(cr);

    shell_ui.setSource(cr, ui_theme.global.window_fg);
    const cw = shell_ui.measureText(cr, cur_str, shell_ui.textSize(), true);
    shell_ui.drawText(cr, cur_str, 126.0 + (48.0 - cw) / 2.0, 26.0, shell_ui.textSize(), true);

    var total_buf: [32]u8 = undefined;
    const total_str = std.fmt.bufPrint(&total_buf, "/ {d}", .{self.n_pages}) catch "";
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    shell_ui.drawText(cr, total_str, 180.0, 26.0, shell_ui.textSize(), false);

    // Zoom level between − and +
    var zbuf: [16]u8 = undefined;
    const zstr = std.fmt.bufPrint(&zbuf, "{d}%", .{@as(i32, @intFromFloat(@round(self.zoom * 100.0)))}) catch "100%";
    const zw = shell_ui.measureText(cr, zstr, shell_ui.textSize(), true);
    shell_ui.drawText(cr, zstr, 246.0 + (36.0 - zw) / 2.0, 26.0, shell_ui.textSize(), true);
}

pub fn renderSearchBar(self: *App, cr: *c.api.cairo_t) void {
    const sr = self.searchBarRect();

    // Search bar card background & shadow
    shell_ui.setSource(cr, ui_theme.global.pdf_search_shadow);
    c.api.cairo_rectangle(cr, sr.x + 2.0, sr.y + 2.0, sr.w, sr.h);
    c.api.cairo_fill(cr);

    shell_ui.setSource(cr, ui_theme.global.window_bg);
    c.api.cairo_rectangle(cr, sr.x, sr.y, sr.w, sr.h);
    c.api.cairo_fill(cr);

    shell_ui.setSource(cr, ui_theme.global.field_border);
    c.api.cairo_set_line_width(cr, 1.0);
    c.api.cairo_rectangle(cr, sr.x, sr.y, sr.w, sr.h);
    c.api.cairo_stroke(cr);

    // Search input text
    const qtxt = self.search_editor.text.items;
    // Half-strength white, not the shell's blue-grey `faint`.
    const fg = ui_theme.global.window_fg;
    shell_ui.setSource(cr, if (qtxt.len > 0) fg else .{ fg[0], fg[1], fg[2], fg[3] * 0.5 });
    const display_txt = if (qtxt.len > 0) qtxt else tr("Find in document...");
    c.api.cairo_save(cr);
    c.api.cairo_rectangle(cr, sr.x + 10.0, sr.y, sr.w - 110.0, sr.h);
    c.api.cairo_clip(cr);
    shell_ui.drawText(cr, display_txt, sr.x + 10.0, sr.y + 22.0, shell_ui.textSize(), qtxt.len > 0);
    c.api.cairo_restore(cr);

    // Result count
    var cbuf: [32]u8 = undefined;
    const count_str = if (self.search_matches.items.len > 0)
        std.fmt.bufPrint(&cbuf, "{d}/{d}", .{ self.search_match_idx + 1, self.search_matches.items.len }) catch ""
    else if (qtxt.len > 0)
        "0"
    else
        "";
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    shell_ui.drawText(cr, count_str, sr.x + sr.w - 95.0, sr.y + 22.0, shell_ui.statusSize(), false);

    // Prev, Next, Close glyphs
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    shell_ui.drawText(cr, "▲", sr.x + sr.w - 55.0, sr.y + 22.0, 11, true);
    shell_ui.drawText(cr, "▼", sr.x + sr.w - 38.0, sr.y + 22.0, 11, true);
    shell_ui.drawText(cr, "✕", sr.x + sr.w - 18.0, sr.y + 22.0, 11, true);
}

pub fn renderDialog(self: *App, cr: *c.api.cairo_t) void {
    const dw: f64 = 440;
    const dh: f64 = 190;
    const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
    const dy = (@as(f64, @floatFromInt(self.h)) - dh) / 2.0;

    // Dim overlay
    shell_ui.setSource(cr, ui_theme.global.pdf_dialog_backdrop);
    c.api.cairo_rectangle(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h));
    c.api.cairo_fill(cr);

    // The shared card stays opaque when the window background is glass.
    if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(dx), .y = @floatCast(dy), .w = @floatCast(dw), .h = @floatCast(dh) })) |value| {
        var frame = value;
        ui_dialog.paintFrame(&frame.renderer, frame.local());
        frame.finish();
    }

    // Title
    const title = switch (self.dialog) {
        .information => tr("PDF Viewer"),
        .password => tr("Password Required"),
        .none => "",
    };
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    shell_ui.drawText(cr, title, dx + 24.0, dy + 32.0, shell_ui.textSize(), true);

    // Prompt / error message
    if (self.error_message) |msg| {
        shell_ui.setSource(cr, ui_theme.global.danger);
        shell_ui.drawText(cr, msg, dx + 24.0, dy + 58.0, shell_ui.textSize(), false);
    } else {
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        const prompt = switch (self.dialog) {
            .information => tr("Open another PDF from Files in a new window."),
            .password => tr("Document is encrypted. Enter password:"),
            .none => "",
        };
        shell_ui.drawText(cr, prompt, dx + 24.0, dy + 58.0, shell_ui.textSize(), false);
    }

    if (self.dialog == .password) {
        if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(dx + 24), .y = @floatCast(dy + 80), .w = @floatCast(dw - 48), .h = 44 })) |value| {
            var field = value;
            _ = ui_field.paintSecret(&field.renderer, field.local(), .{}, .{ .focused = true, .external_caret = true }, &self.password_input, tr("Password"));
            field.finish();
        }
    }

    self.renderButtonText(cr, dx + dw - 180, dy + dh - 46, 80, 32, tr("Cancel"));
    const btn_label = if (self.dialog == .password) tr("Unlock") else tr("OK");
    self.renderButtonText(cr, dx + dw - 90, dy + dh - 46, 70, 32, btn_label);
}

pub fn renderButtonText(self: *App, cr: *c.api.cairo_t, x: f64, y: f64, w: f64, h: f64, label: []const u8) void {
    const is_hover = self.px >= x and self.px <= x + w and self.py >= y and self.py <= y + h;
    var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
    defer layer.finish();
    ui_button.paint(&layer.renderer, layer.local(), .{
        .variant = .secondary,
        .label = label,
    }, .{ .pointer = if (is_hover) .hover else .idle });
}

/// A text button shown selected while its mode is active.
pub fn renderToggle(self: *App, cr: *c.api.cairo_t, x: f64, y: f64, w: f64, h: f64, label: []const u8, selected: bool) void {
    const is_hover = self.px >= x and self.px <= x + w and self.py >= y and self.py <= y + h;
    var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
    defer layer.finish();
    ui_button.paint(&layer.renderer, layer.local(), .{
        .variant = .ghost,
        .label = label,
    }, .{ .pointer = if (is_hover) .hover else .idle, .selected = selected });
}

pub fn renderButtonIcon(self: *App, cr: *c.api.cairo_t, x: f64, y: f64, w: f64, h: f64, icon: IconId, tooltip: []const u8) void {
    const is_hover = self.px >= x and self.px <= x + w and self.py >= y and self.py <= y + h;
    var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
    defer layer.finish();
    ui_button.paint(&layer.renderer, layer.local(), .{
        .variant = .ghost,
        .icon = icon,
        .label = tooltip,
    }, .{ .pointer = if (is_hover) .hover else .idle });
}
