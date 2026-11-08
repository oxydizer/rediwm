//! Files painting: header, toolbar, location bar, rename card and the frame.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const recent = @import("recent.zig");
const ops_mod = @import("ops.zig");
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const ui_field = @import("ui").widgets.field;
const ui_button = @import("ui").widgets.button;
const ui_checkbox = @import("ui").widgets.checkbox;
const ui_dialog = @import("ui").widgets.dialog;
const ui_theme = @import("ui").theme;
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const Editor = @import("editor.zig").Editor;
const RenameCard = @import("app_model.zig").RenameCard;
const formatSize = @import("app_draw.zig").formatSize;
const nowMs = @import("app_draw.zig").nowMs;
const setSource = @import("app_draw.zig").setSource;
const withAlpha = @import("app_draw.zig").withAlpha;
const drawEllipsis = @import("app_draw.zig").drawEllipsis;
const drawText = @import("app_draw.zig").drawText;
const fontMetrics = @import("app_draw.zig").fontMetrics;
const measureText = @import("app_draw.zig").measureText;

pub fn renderHeader(self: *App, cr: *c.cairo_t) void {
    const width: f64 = @floatFromInt(self.w);
    setSource(cr, ui_theme.global.app_toolbar);
    c.cairo_rectangle(cr, 0, 0, width, @floatFromInt(self.contentTop()));
    c.cairo_fill(cr);
    setSource(cr, ui_theme.global.app_divider);
    c.cairo_set_line_width(cr, 1);
    c.cairo_move_to(cr, 0, 54.5);
    c.cairo_line_to(cr, width, 54.5);
    c.cairo_move_to(cr, 0, @as(f64, @floatFromInt(self.contentTop())) - 0.5);
    c.cairo_line_to(cr, width, @as(f64, @floatFromInt(self.contentTop())) - 0.5);
    c.cairo_stroke(cr);
    if (self.transfer_view.active) {
        self.renderTransferToolbar(cr);
        return;
    }
    const in_repo = self.inRepository();
    for ([_]bool{ false, true }) |content| {
        if (content) self.renderToolbarHover(cr);
        for (std.meta.tags(header.Action)) |action| {
            if (!self.toolbarButtonVisible(action)) continue;
            const r = header.rect(self.w, in_repo, action);
            const enabled = self.toolbarButtonEnabled(action);
            const active = (action == .grid and !self.list_view) or (action == .list and self.list_view) or
                (action == .filter and (self.folders_only or self.show_hidden or self.changedOnly())) or (action == .search and self.search_visible);
            const opts: ui_button.Options = switch (action) {
                .new => .{ .leading_icon = .plus, .label = tr("New") },
                .sort => .{ .leading_icon = .sort, .label = switch (self.effectiveSort()) {
                    .name, .name_desc => tr("Name"),
                    .size, .size_asc => tr("Size"),
                    .modified, .modified_asc => tr("Date"),
                    .type, .type_desc => tr("Type"),
                } },
                .filter => .{ .leading_icon = .filter, .label = tr("Filter") },
                else => .{ .variant = .ghost, .icon = header.glyph(action), .icon_scale = 0.56, .label = @tagName(action) },
            };
            var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse continue;
            const proximity = self.toolbarButtonProximity(action, self.mouse_x, self.mouse_y);
            const reach = ui_theme.global.border_glow_reach;
            const elevation = if (enabled and reach > 0 and proximity.distance < std.math.inf(f32))
                std.math.clamp(1 - proximity.distance / reach, 0, 1)
            else
                0;
            const state: ui_button.State = .{
                .pointer = if (enabled) .idle else .disabled,
                .selected = active,
                // Glow is painted separately above the sliding chip.
                .proximity_distance = std.math.inf(f32),
                .proximity_x = proximity.x,
                .proximity_y = proximity.y,
                .hover_elevation = elevation,
            };
            if (content) ui_button.paintContent(&layer.renderer, layer.local(), opts, state) else ui_button.paintBackground(&layer.renderer, layer.local(), opts, state);
            layer.finish();
        }
    }
    if (header.visible(self.w, in_repo, .git_view)) self.renderGitViewToggle(cr);
    @import("app_audio_bar.zig").paint(self, cr);
    const field = header.field(self.w);
    self.renderLocationBar(cr, field.x, field.y, field.w, field.h);
}

pub fn renderToolbarHover(self: *App, cr: *c.cairo_t) void {
    const hover = self.toolbar_hover;
    if (hover.opacity > 0) {
        const r = hover.frame;
        if (shell_ui.Layer.begin(cr, .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] })) |value| {
            var layer = value;
            var palette = layer.renderer.palette.?;
            palette.surface_hover[3] *= hover.opacity;
            layer.renderer.palette = palette;
            ui_button.paintBackground(&layer.renderer, layer.local(), .{ .variant = .ghost }, .{ .pointer = .hover });
            layer.finish();
        }
    }

    // The glow sits above the sliding chip but below the button ink.
    if (!ui_theme.global.button_hover_glow_enabled) return;
    for (std.meta.tags(header.Action)) |action| {
        if (!self.toolbarButtonVisible(action) or !self.toolbarButtonEnabled(action)) continue;
        const r = header.rect(self.w, self.inRepository(), action);
        const sample = self.toolbarButtonProximity(action, self.mouse_x, self.mouse_y);
        if (sample.distance >= std.math.inf(f32)) continue;

        var layer = shell_ui.Layer.begin(cr, .{
            .x = @floatCast(r.x),
            .y = @floatCast(r.y),
            .w = @floatCast(r.w),
            .h = @floatCast(r.h),
        }) orelse continue;
        ui_button.paintBackground(&layer.renderer, layer.local(), .{ .variant = .ghost }, .{
            .proximity_distance = sample.distance,
            .proximity_x = sample.x,
            .proximity_y = sample.y,
        });
        layer.finish();
    }
}

/// "Git View" checkbox and the faint rule that sets it apart from the view buttons.
pub fn renderGitViewToggle(self: *App, cr: *c.cairo_t) void {
    const rule = header.gitSeparator(self.w);
    setSource(cr, ui_theme.global.app_divider);
    c.cairo_set_line_width(cr, 1);
    c.cairo_move_to(cr, rule.x + 0.5, rule.y);
    c.cairo_line_to(cr, rule.x + 0.5, rule.y + rule.h);
    c.cairo_stroke(cr);
    const r = header.rect(self.w, true, .git_view);
    var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse return;
    ui_checkbox.paint(&layer.renderer, layer.local(), tr("Git View"), .{
        .checked = self.git_view,
        .focused = r.contains(self.mouse_x, self.mouse_y),
    });
    layer.finish();
}

// Cairo Rendering
pub fn render(self: *App, cr: *c.cairo_t) void {
    const w_f = @as(f64, @floatFromInt(self.w));
    const h_f = @as(f64, @floatFromInt(self.h));

    // 1. Background
    setSource(cr, ui_theme.global.app_bg);
    c.cairo_paint(cr);

    self.renderHeader(cr);

    self.renderSidebar(cr);
    self.renderSidebarScrollbar(cr);

    // 3. Content Area (Files View)
    const viewport_h = self.contentBottom() - self.viewTop();
    c.cairo_save(cr);
    c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @floatFromInt(self.viewTop()), w_f - @as(f64, @floatFromInt(self.sidebarWidth() + self.scrollbarGutter())), @as(f64, @floatFromInt(viewport_h)));
    c.cairo_clip(cr);

    if (self.transfer_view.active) {
        self.renderTransferList(cr);
    } else {
        if (self.list_view) {
            const column = self.listColumn(if (self.repository() != null) 0 else self.sortColumn());
            setSource(cr, ui_theme.global.surface);
            c.cairo_rectangle(cr, column.x, @floatFromInt(self.viewTop()), column.w, @floatFromInt(viewport_h));
            c.cairo_fill(cr);
            self.paintSortFeedback(cr, .{ .x = column.x, .y = @floatFromInt(self.viewTop()), .w = column.w, .h = @floatFromInt(viewport_h) });
        }

        if (self.error_message) |err| {
            setSource(cr, ui_theme.global.file_broken);
            drawText(cr, err, @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.viewTop() + 36), shell_ui.textSize(), true);
        } else if (self.loading and self.items.items.len == 0) {
            // A quick listing never shows this; see `scan_notice_delay_ms`.
            if (self.scan_notice_shown) {
                setSource(cr, ui_theme.global.window_fg);
                drawText(cr, tr("Scanning folder..."), @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.viewTop() + 36), shell_ui.textSize(), false);
            }
        } else if (self.items.items.len == 0) {
            setSource(cr, ui_theme.global.window_fg);
            drawText(cr, if (self.search.text.items.len > 0 or self.folders_only) tr("No matching items") else if (self.changedOnly()) tr("No changed files") else if (self.isRecent()) tr("No recent files") else tr("This folder is empty"), @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.viewTop() + 36), shell_ui.textSize(), false);
        } else {
            self.renderFileItems(cr, viewport_h);
        }
    }
    self.renderSelectionBand(cr);
    self.renderScrollEdges(cr, viewport_h);
    c.cairo_restore(cr);

    self.renderColumns(cr);

    if (self.sidebarDivider()) |divider| {
        shell_ui.drawSplitter(cr, divider, self.sidebar_resize != null or self.overSidebarDivider(self.mouse_x, self.mouse_y));
    }

    // 4. Scrollbar
    self.renderScrollbar(cr);

    // 5. Status Bar
    if (self.chooser != null) self.renderChooser(cr) else self.renderStatusBar(cr, h_f);
    self.renderTerminal(cr);

    if (!self.audio_bar.playlist_open and !self.transfer_view.active and self.menu == null and self.dialog == null and self.selection_band == null) self.renderFilenameTip(cr);
    if (self.menu != null) self.renderMenu(cr);
    if (!self.audio_bar.playlist_open and self.menu == null and self.dialog == null) self.renderTorrentTip(cr);

    @import("app_audio_playlist.zig").paint(self, cr);

    // 6. Modal Dialog
    if (self.dialog != null) {
        self.renderDialog(cr);
    }
}

pub fn renderButton(self: *App, cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, label_text: []const u8, enabled: bool, target_id: usize) void {
    const hovered = enabled and if (self.dialog_surface.hovered) |target|
        target.id == target_id
    else
        false;
    var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
    ui_button.paint(&layer.renderer, layer.local(), .{ .label = label_text }, .{ .pointer = if (!enabled) .disabled else if (hovered) .hover else .idle });
    layer.finish();
}

// The field's text size. Everything positioned against the text — the
// caret, the select-all highlight — must be measured at this same size:
// measuring at one size and drawing at another puts the caret a
// proportion of the prefix width away from the glyph it belongs to, so
// the error grows with every character typed.
pub fn fieldFontSize() f64 {
    return shell_ui.textSize();
}

pub fn renderLocationBar(self: *App, cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    if (!self.search_visible and self.focus != .location_bar) {
        _ = self.breadcrumbs(cr, null);
        return;
    }
    const is_focused = if (self.search_visible) self.focus == .search else self.focus == .location_bar;
    self.renderEditor(cr, if (self.search_visible) &self.search else &self.location, .{ .x = x, .y = y, .w = w, .h = h }, is_focused, self.search_visible);
}

/// The shared field look: the search box carries the search icon.
pub fn fieldOptions(search: bool) ui_field.Options {
    return .{ .leading_icon = if (search) .search else null };
}

/// Where an editor's text runs inside its field.
pub fn textArea(rect: header.Rect, search: bool) header.Rect {
    const area = ui_field.arrange(.{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) }, fieldOptions(search), ui_theme.shellPalette()).text;
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h };
}

/// The active editor's text area, for pointer hit testing.
pub fn editorTextArea(self: *App) header.Rect {
    return textArea(self.editorRect(), self.dialog == null and self.focus == .search);
}

pub fn pointerCursor(self: *App, x: f64, y: f64) [*:0]const u8 {
    if (@import("app_audio_playlist.zig").cursor(self)) |cursor| return cursor;
    if (self.terminal.resize != null or self.overTerminalDivider(x, y)) return "row-resize";
    if (self.dialog == null and self.menu == null) {
        if (self.terminalHit(x, y) != null) return "pointer";
        if (self.terminalHeight() > 0 and self.terminalBody().contains(x, y)) return "text";
    }
    if (self.sidebar_resize != null) return "col-resize";
    if (self.text_dragging) return "text";
    if (self.menu != null or self.selection_band != null or self.drag_origin != null or self.scroll_drag.active or self.sidebar_scroll_drag.active or self.horizontal_drag.active) return "default";
    if (self.dialog != null) {
        return if (self.activeEditor() != null and self.editorRect().contains(x, y)) "text" else "default";
    }
    if (self.column_resize != null or self.columnBoundary(x, y) != null) return "col-resize";
    if (self.overSidebarDivider(x, y)) return "col-resize";
    if (self.chooser != null and self.chooserRect(0).contains(x, y)) return "text";
    if (self.focus != .location_bar and !self.search_visible and header.field(self.w).contains(x, y)) return "pointer";
    if (@import("app_audio_bar.zig").hit(self, x, y) != null or self.inlineTorrentHit(x, y) != null or self.audioButtonHit(x, y) != null) return "pointer";
    if (self.singleClickIconAt(x, y) != null) return "pointer";
    return if (header.field(self.w).contains(x, y)) "text" else "default";
}

pub fn singleClickIconAt(self: *App, x: f64, y: f64) ?usize {
    if (!self.single_click_open or self.chooser != null or self.dialog != null or self.menu != null) return null;
    if (x < @as(f64, @floatFromInt(self.sidebarWidth())) or x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) return null;
    const idx = self.itemAt(x, y) orelse return null;
    return if (self.itemIconRect(@intCast(idx)).contains(x, y)) idx else null;
}

/// The rename card, anchored to the item being renamed: the same inline
/// popover the desktop uses (field plus confirm / cancel buttons), clamped
/// to the file view.
pub fn renameCard(self: *App) ?RenameCard {
    const dlg = self.dialog orelse return null;
    if (dlg.kind != .rename) return null;
    const left: f64 = @floatFromInt(self.sidebarWidth());
    const right: f64 = @floatFromInt(self.w);
    const top: f64 = @floatFromInt(self.viewTop());
    const bottom: f64 = @floatFromInt(self.h - self.footerHeight());
    const w = @min(340, right - left - 16);
    const h: f64 = 44;
    var x = left + 8;
    var y = top + 8;
    if (dlg.target_path) |target| for (self.items.items, 0..) |item, i| {
        if (!std.mem.eql(u8, item.path, target)) continue;
        const icon = self.itemIconRect(@intCast(i));
        if (self.list_view) {
            x = left + 8;
            y = icon.y + icon.h / 2 - h / 2;
        } else {
            x = icon.x + icon.w / 2 - w / 2;
            y = icon.y + 54;
        }
        break;
    };
    x = std.math.clamp(x, left + 4, @max(left + 4, right - w - 4));
    y = std.math.clamp(y, top + 4, @max(top + 4, bottom - h - 4));
    return .{
        .panel = .{ .x = x, .y = y, .w = w, .h = h },
        .field = .{ .x = x + 6, .y = y + 6, .w = w - 70, .h = 32 },
        .confirm = .{ .x = x + w - 62, .y = y + 6, .w = 28, .h = 32 },
        .cancel = .{ .x = x + w - 34, .y = y + 6, .w = 28, .h = 32 },
    };
}

pub fn renderRenameCard(self: *App, cr: *c.cairo_t, card: RenameCard) void {
    const p = card.panel;
    if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(p.x), .y = @floatCast(p.y), .w = @floatCast(p.w), .h = @floatCast(p.h) })) |begun| {
        var layer = begun;
        ui_dialog.paintFrameWithBackground(&layer.renderer, layer.local(), ui_theme.global.app_toolbar);
        layer.finish();
    }
    self.renderEditor(cr, &self.dialog.?.edit, card.field, true, false);
    for ([_]header.Rect{ card.confirm, card.cancel }, 0..) |rect, i| {
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) }) orelse continue;
        ui_button.paint(&layer.renderer, layer.local(), .{
            .variant = .secondary,
            .icon = if (i == 0) .checkmark else .close,
            .icon_scale = 0.55,
            .label = if (i == 0) tr("Rename") else tr("Cancel"),
        }, .{ .pointer = if (self.dialog_surface.hovered) |target|
            if (target.id == i + 1) .hover else .idle
        else
            .idle });
        layer.finish();
    }
}

pub fn editorRect(self: *App) header.Rect {
    if (self.renameCard()) |card| return card.field;
    if (self.dialog != null) {
        const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
        return .{ .x = (@as(f64, @floatFromInt(self.w)) - dw) / 2 + 16, .y = (@as(f64, @floatFromInt(self.h)) - 130) / 2 + 42, .w = dw - 32, .h = 30 };
    }
    if (self.focus == .filename and self.chooser != null) return self.chooserRect(0);
    return header.field(self.w);
}

pub fn placeCaret(self: *App, x: f64, extend: bool) void {
    const edit = self.activeEditor() orelse return;
    const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) orelse return;
    defer c.cairo_surface_destroy(surf);
    const cr = c.cairo_create(surf) orelse return;
    defer c.cairo_destroy(cr);
    // Measure at the buffer scale, as renderEditor does: hinting moves
    // advances per ppem.
    c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));
    const rect = self.editorTextArea();
    if (self.text_dragging) edit.scroll = @max(0, edit.scroll + if (x < rect.x) @as(f64, -24) else if (x > rect.x + rect.w) @as(f64, 24) else @as(f64, 0));
    const target = x - rect.x + edit.scroll;
    var p: usize = 0;
    var previous: f64 = 0;
    while (p < edit.text.items.len) {
        const n = Editor.next(edit.text.items, p);
        const pen = measureText(cr, edit.text.items[0..n], fieldFontSize(), false);
        if (target < (previous + pen) / 2) break;
        previous = pen;
        p = n;
    }
    edit.move(p, extend);
}

/// A whole text field: the shared frame (ui/widgets/field.zig), then the
/// editor's text, selection and caret in the theme's colours.
pub fn renderEditor(self: *App, cr: *c.cairo_t, edit: *Editor, rect: header.Rect, focused: bool, search: bool) void {
    _ = self;
    if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) })) |begun| {
        var layer = begun;
        _ = ui_field.paintFrame(&layer.renderer, layer.local(), fieldOptions(search), .{ .focused = focused });
        layer.finish();
    }
    const t = ui_theme.shellPalette();
    const area = textArea(rect, search);
    const text = edit.text.items;
    const sel = edit.selection();
    const metrics = fontMetrics(cr, fieldFontSize());
    const ink_h = metrics.ascent + metrics.descent;
    const top = area.y + (area.h - ink_h) / 2;
    const view_w = area.w;
    const text_w = measureText(cr, text, fieldFontSize(), false);
    const pen = measureText(cr, text[0..@min(edit.cursor, text.len)], fieldFontSize(), false);
    if (focused) {
        const margin = @min(view_w / 4, 12);
        if (pen - edit.scroll > view_w - margin) edit.scroll = pen - view_w + margin;
        if (pen - edit.scroll < margin) edit.scroll = pen - margin;
        edit.scroll = @round(std.math.clamp(edit.scroll, 0, @max(0, text_w - view_w + margin)));
    }
    const x = area.x - if (focused) edit.scroll else 0;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, area.x, area.y + 2, view_w, area.h - 4);
    c.cairo_clip(cr);
    if (focused and sel[0] != sel[1]) {
        const left = measureText(cr, text[0..sel[0]], fieldFontSize(), false);
        const right = measureText(cr, text[0..sel[1]], fieldFontSize(), false);
        setSource(cr, t.selectionColor());
        c.cairo_rectangle(cr, x + left, top, right - left, ink_h);
        c.cairo_fill(cr);
    }
    const placeholder = search and text.len == 0;
    // Half-strength white, not the shell's blue-grey `faint`.
    setSource(cr, if (placeholder) withAlpha(t.fg, 0.5) else t.fg);
    drawText(cr, if (placeholder) tr("Search this folder") else text, x, top + metrics.ascent, fieldFontSize(), false);
    if (focused) {
        setSource(cr, t.caretColor());
        c.cairo_rectangle(cr, x + pen, top, t.caret_width, ink_h);
        c.cairo_fill(cr);
    }
}

pub fn renderStatusBar(self: *App, cr: *c.cairo_t, h_f: f64) void {
    const w_f = @as(f64, @floatFromInt(self.w));
    const y = h_f - 26;
    // The sidebar runs to the bottom edge; the bar sits beside it.
    const x0: f64 = @floatFromInt(self.sidebarWidth());

    const accent = ui_theme.shellPalette().accent;
    setSource(cr, ui_theme.global.app_bar);
    c.cairo_rectangle(cr, x0, y, w_f - x0, 26);
    c.cairo_fill(cr);

    setSource(cr, ui_theme.global.app_divider);
    c.cairo_set_line_width(cr, 1);
    c.cairo_move_to(cr, x0, y + 0.5);
    c.cairo_line_to(cr, w_f, y + 0.5);
    c.cairo_stroke(cr);

    var status_buf: [256]u8 = undefined;
    var status_text: []const u8 = "";

    var prog: ?ops_mod.ProgressInfo = null;
    if (self.job_runner) |runner| {
        const p = runner.pollProgress();
        if (p.state == .running or p.state == .waiting_conflict) {
            prog = p;
        }
    }

    if (self.transfer_view.active) {
        setSource(cr, if (self.torrents.message().len > 0) ui_theme.global.danger else ui_theme.global.window_fg);
        const count = self.torrents.items().len;
        status_text = if (self.torrents.message().len > 0) self.torrents.message() else if (self.torrents.retry_at != null) tr("Connecting…") else i18n.fmt(&status_buf, i18n.trn("{count} transfer · Downloads continue after closing Files.", "{count} transfers · Downloads continue after closing Files.", count), .{ .count = count }) catch tr("Transfers");
    } else if (prog) |p| {
        setSource(cr, accent);
        const pattern = if (self.job_runner.?.kind == .extract or self.job_runner.?.kind == .open_archive_member) tr("Extracting {current}/{total}: {name}... (Esc to cancel)") else tr("Transferring {current}/{total}: {name}... (Esc to cancel)");
        status_text = i18n.fmt(&status_buf, pattern, .{ .current = p.processed_items + 1, .total = p.total_items, .name = p.current_name }) catch tr("Transferring...");
    } else if (self.status_notice != null and nowMs() < self.status_notice_until) {
        if (self.status_is_error) {
            setSource(cr, ui_theme.global.danger);
        } else {
            setSource(cr, accent);
        }
        status_text = self.status_notice.?;
    } else if (self.error_message) |err| {
        setSource(cr, ui_theme.global.danger);
        status_text = i18n.fmt(&status_buf, tr("Error: {value}"), .{ .value = err }) catch err;
    } else {
        setSource(cr, ui_theme.global.window_fg);
        var sel_count: usize = 0;
        var sel_bytes: i64 = 0;
        for (self.items.items) |it| {
            if (it.selected and !it.missing) {
                sel_count += 1;
                if (!it.is_dir) sel_bytes += it.bytes;
            }
        }

        if (sel_count > 0) {
            var size_buf: [64]u8 = undefined;
            const sz = formatSize(sel_bytes, &size_buf);
            status_text = i18n.fmt(&status_buf, i18n.trn("{count} item selected  ·  {size}", "{count} items selected  ·  {size}", sel_count), .{ .count = sel_count, .size = sz }) catch tr("Selected items");
        } else {
            const more = if (self.changedOnly() and self.snapshot != null and self.snapshot.?.changed_truncated) "+" else "";
            const count = self.items.items.len;
            status_text = i18n.fmt(&status_buf, i18n.trn("{count}{more} item", "{count}{more} items", if (more.len > 0) @max(2, count) else count), .{ .count = count, .more = more }) catch tr("Items");
        }
    }

    drawEllipsis(cr, status_text, x0 + 14, y + 17, @max(0, w_f - x0 - 52), shell_ui.statusSize(), false);
}

pub fn renderDialog(self: *App, cr: *c.cairo_t) void {
    const dlg = self.dialog orelse return;
    if (dlg.kind == .transfers) {
        self.renderTransfers(cr);
        return;
    }
    if (dlg.kind == .properties) {
        self.dialog.?.properties.?.draw(cr, self.w, self.h, self.mouse_x, self.mouse_y, self.theme_cfg, self.io);
        return;
    }
    if (dlg.kind == .trash_properties) {
        self.dialog.?.trash_properties.?.draw(cr, self.w, self.h, self.mouse_x, self.mouse_y, ui_theme.global.app_toolbar, self.theme_cfg, self.io);
        return;
    }
    if (dlg.kind == .open_with) {
        self.dialog.?.applications.?.draw(cr, self.w, self.h, self.mouse_x, self.mouse_y, self.theme_cfg, self.io);
        return;
    }
    if (dlg.kind == .trash_confirm) {
        dlg.deletion.draw(cr, self.w, self.h, self.mouse_x, self.mouse_y, ui_theme.global.app_toolbar);
        return;
    }
    if (self.renameCard()) |card| {
        self.renderRenameCard(cr, card);
        return;
    }
    const w_f = @as(f64, @floatFromInt(self.w));
    const h_f = @as(f64, @floatFromInt(self.h));

    // Dim backdrop
    @import("ui").cairo.setSource(cr, ui_dialog.backdropColor());
    c.cairo_rectangle(cr, 0, 0, w_f, h_f);
    c.cairo_fill(cr);

    // Modal box
    const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
    const dh: f64 = 130;
    const dx = (w_f - dw) / 2.0;
    const dy = (h_f - dh) / 2.0;

    if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(dx), .y = @floatCast(dy), .w = @floatCast(dw), .h = @floatCast(dh) })) |begun| {
        var layer = begun;
        ui_dialog.paintFrameWithBackground(&layer.renderer, layer.local(), ui_theme.global.app_toolbar);
        layer.finish();
    }
    const t = ui_theme.shellPalette();

    // Title
    setSource(cr, t.fg);
    drawText(cr, dlg.title, dx + 16, dy + 26, shell_ui.textSize(), true);

    var buf: [256]u8 = undefined;

    if (dlg.kind == .terminal_close) {
        drawEllipsis(cr, tr("Closing ends this shell and its running jobs."), dx + 16, dy + 56, dw - 32, shell_ui.textSize(), false);
        self.renderButton(cr, dx + dw - 184, dy + 84, 80, 28, tr("Close"), true, 1);
        self.renderButton(cr, dx + dw - 96, dy + 84, 80, 28, tr("Cancel"), true, 2);
    } else if (dlg.kind == .conflict) {
        const conflict_str = dlg.conflict_name orelse "";
        const conflict_msg = i18n.fmt(&buf, tr("File '{value}' already exists in destination."), .{ .value = conflict_str }) catch tr("Conflict");
        setSource(cr, t.fg);
        drawEllipsis(cr, conflict_msg, dx + 16, dy + 56, dw - 32, shell_ui.textSize(), false);

        self.renderButton(cr, dx + 16, dy + 84, (dw - 48) / 3, 28, tr("Skip (S)"), true, 1);
        self.renderButton(cr, dx + 24 + (dw - 48) / 3, dy + 84, (dw - 48) / 3, 28, tr("Rename (R)"), true, 2);
        self.renderButton(cr, dx + 32 + 2 * (dw - 48) / 3, dy + 84, (dw - 48) / 3, 28, tr("Cancel (C)"), true, 3);
    } else {
        self.renderEditor(cr, &self.dialog.?.edit, self.editorRect(), true, false);

        setSource(cr, t.fg);
        if (dw >= 420) drawText(cr, tr("Enter confirms · Esc cancels"), dx + 16, dy + 102, shell_ui.textSize(), false);

        self.renderButton(cr, dx + dw - 184, dy + 84, 80, 28, tr("OK"), true, 1);
        self.renderButton(cr, dx + dw - 96, dy + 84, 80, 28, tr("Cancel"), true, 2);
    }
}
