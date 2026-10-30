//! Rendering: the caret, tabs and their menu, buttons, text lines and the close prompt.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const button = @import("ui").widgets.button;
const field = @import("ui").widgets.field;
const dialog = @import("ui").widgets.dialog;
const menu = @import("ui").context_menu;
const p = @import("pango.zig");
const caret_mod = @import("caret.zig");
const view = @import("view.zig");
const lines = @import("lines.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const top = app_mod.top;
const status_h = app_mod.status_h;
const labels = app_mod.labels;
const Tab = app_mod.Tab;
const fill = app_mod.fill;
const drawEllipsis = @import("../files/app_draw.zig").drawEllipsis;

pub const CaretState = struct {
    active: bool,
    tab: usize,
    revision: usize,
    cursor: usize,
    anchor: usize,
    find: bool,
    search_focus: @import("app_search.zig").Control,
    query_hash: u64,
    activity: usize,
    top: usize,
    dy: f64,
    scroll_x: f64,
    width: i32,
    height: i32,
    scale: i32,
};

pub fn caretState(self: *App) CaretState {
    const d = self.document();
    const r = self.inputRectangle();
    const editor = self.searchEditor();
    const in_view = @as(f64, @floatFromInt(r.y + r.height)) > self.viewTop() and @as(f64, @floatFromInt(r.y)) < self.viewTop() + self.viewHeight();
    return .{
        .active = self.focused and !self.menu_open and self.close_tab == null and self.preedit.items.len == 0 and (editor != null or (!self.find_open and d.cursor == d.anchor and in_view)),
        .tab = self.tabId(),
        .revision = d.revision,
        .cursor = if (editor) |e| e.cursor else d.cursor,
        .anchor = if (editor) |e| e.anchor else d.anchor,
        .find = self.find_open,
        .search_focus = self.search_focus,
        .activity = self.caret_activity,
        .top = d.top,
        .dy = self.current().dy,
        .scroll_x = self.current().scroll_x,
        .width = self.w,
        .height = self.h,
        .scale = self.scale,
        .query_hash = if (editor) |e| std.hash.Wyhash.hash(0, e.text.items) else 0,
    };
}

pub fn stepCaret(self: *App, now: i64, active: bool, restart: bool, snap: bool) void {
    const r = self.caretRect();
    var target: caret_mod.Rect = .{
        .x = @floatCast(@as(f64, @floatFromInt(r.x)) / 1024 + 16 - self.current().scroll_x),
        .y = @floatCast(@as(f64, @floatFromInt(r.y)) / 1024 + self.viewTop()),
        .h = @as(f32, @floatFromInt(r.height)) / 1024,
    };
    if (self.find_open) {
        if (self.layouts.cr) |cr| target = self.searchCaret(cr);
    }
    if (self.caret.update(now, active, restart, target, snap or self.caret_snap)) self.caret_dirty = true;
    self.caret_snap = false;
}

pub fn caretDamage(self: *App) p.Rectangle {
    const before = self.caret_painted;
    const after = self.caret.box;
    const x: i32 = @intFromFloat(@floor(@min(before.x, after.x)) - 1);
    const y: i32 = @intFromFloat(@floor(@min(before.y, after.y)) - 1);
    return .{
        .x = x,
        .y = y,
        .width = @as(i32, @intFromFloat(@ceil(@max(before.x + before.w, after.x + after.w)) + 1)) - x,
        .height = @as(i32, @intFromFloat(@ceil(@max(before.y + before.h, after.y + after.h)) + 1)) - y,
    };
}

pub fn paintCaret(self: *App, cr: *c.cairo_t) void {
    if (!self.caret.visible) return;
    const r = self.caret.box;
    fill(cr, r.x, r.y, r.w, r.h, theme.global.window_fg);
}

pub fn tabRight(self: *const App) f64 {
    return @as(f64, @floatFromInt(self.w)) - @as(f64, if (self.has_titlebar) 40 else 80);
}

pub fn dismissMenu(self: *App) void {
    if (!self.menu_open) return;
    self.menu_open = false;
    self.dirty = true;
}

pub fn toggleMenu(self: *App, anchor: f64) void {
    if (self.close_tab != null) return;
    self.cancelDrag();
    self.menu_anchor = anchor;
    self.menu_open = !self.menu_open;
    self.menu_selected = null;
    self.dirty = true;
}

pub fn menuBox(self: *const App) menu.Rect {
    const height = labels.len * menu.row_height + 2 * menu.padding + 2 * menu.separator_space;
    return .{
        .x = std.math.clamp(self.menu_anchor - menu.width, 6, @max(6, @as(f64, @floatFromInt(self.w)) - menu.width - 6)),
        .y = @min(if (self.has_titlebar) @as(f64, 6) else top + 4, @max(6, @as(f64, @floatFromInt(self.h)) - height - 6)),
        .w = menu.width,
        .h = height,
    };
}

pub fn menuRow(self: *const App, i: usize) menu.Rect {
    const box = self.menuBox();
    const separators: usize = @as(usize, if (i >= 2) 1 else 0) + @as(usize, if (i >= 4) 1 else 0);
    return .{ .x = box.x + menu.padding, .y = box.y + @as(f64, @floatFromInt(menu.padding + i * menu.row_height + separators * menu.separator_space)), .w = box.w - 2 * menu.padding, .h = menu.row_height };
}

pub fn menuHit(self: *const App, x: f64, y: f64) ?usize {
    for (0..labels.len) |i| if (self.menuRow(i).contains(x, y)) return i;
    return null;
}

pub fn paintMenu(self: *App, cr: *c.cairo_t) void {
    menu.frame(cr, self.menuBox(), true);
    const IconId = @import("ui").layout.IconId;
    const icons = [_]?IconId{ .plus, .open, .save, .save, .search, .search, if (self.wrap) .checkmark else null };
    const hints = [_]?[]const u8{ "CTRL+N", "CTRL+O", "CTRL+S", "CTRL+SHIFT+S", "CTRL+F", "CTRL+H", null };
    for (labels, 0..) |label, i| menu.row(cr, self.menuRow(i), .{
        .label = label.get(),
        .hint = hints[i],
        .icon = icons[i],
        .selected = self.menu_selected == i,
        .separator = i == 2 or i == 4,
    }, true);
}

pub fn paintButton(self: *App, cr: *c.cairo_t, r: field.Rect, label: []const u8, selected: bool) void {
    var layer = ui.Layer.begin(cr, r) orelse return;
    defer layer.finish();
    layer.renderer.palette = theme.shellPalette();
    button.paint(&layer.renderer, layer.local(), .{ .label = label, .variant = .ghost, .size = .sm }, .{ .selected = selected, .pointer = if (self.px >= r.x and self.px < r.x + r.w and self.py >= r.y and self.py < r.y + r.h) .hover else .idle });
}

pub fn render(self: *App, cr: *c.cairo_t) void {
    const t = theme.global;
    fill(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h), t.app_bg);
    fill(cr, 0, 0, @floatFromInt(self.w), 38, t.app_bar);
    c.cairo_save(cr);
    c.cairo_rectangle(cr, 0, 0, self.tabRight(), 38);
    c.cairo_clip(cr);
    const width = self.tabWidth();
    for (self.tabs.items, 0..) |tab, i| {
        const x = self.tabX(i);
        if (x + width <= 0 or x >= self.tabRight()) continue;
        if (i == self.selected) {
            fill(cr, x, 0, width, 38, t.app_bg);
            fill(cr, x + 8, 35, width - 16, 2, theme.shellPalette().accent);
        } else if (i + 1 != self.selected and i + 1 < self.tabs.items.len) fill(cr, x + width - 1, 10, 1, 18, t.app_divider);
        // The name gives way to the close button; the unsaved mark never does.
        const name = if (std.unicode.utf8ValidateSlice(tab.name())) tab.name() else tr("Text file");
        const mark: f64 = if (tab.doc.modified()) 14 else 0;
        const room = width - 48 - mark;
        ui.setSource(cr, t.window_fg);
        drawEllipsis(cr, name, x + 12, 24, room, ui.textSize(), false);
        if (mark > 0) {
            ui.drawText(cr, "•", x + 12 + @min(ui.measureText(cr, name, ui.textSize(), false), room) + 5, 24, ui.textSize(), false);
        }
        self.paintIcon(cr, self.tabCloseBox(i), .close, tr("Close tab"), false);
    }
    c.cairo_restore(cr);
    self.paintIcon(cr, self.newButtonBox(), .plus, tr("New tab"), false);
    if (!self.has_titlebar) self.paintIcon(cr, self.menuButtonBox(), .more, tr("Menu"), self.menu_open);
    if (self.find_open) self.paintSearch(cr);
    self.layouts.beginFrame();
    const pt = self.port();
    pt.clamp();
    pt.visible(&self.rows);
    const tab = self.current();
    const sel = tab.doc.selection();
    c.cairo_save(cr);
    c.cairo_rectangle(cr, 12, self.viewTop(), @floatFromInt(self.w - 30), self.viewHeight());
    c.cairo_clip(cr);
    for (self.rows.items) |row| self.paintLine(cr, tab, row, sel);
    if (!self.find_open) self.paintCaret(cr);
    c.cairo_restore(cr);
    if (self.scrollbarGeometry()) |bar| ui.drawScrollbar(cr, scrollbar.look(bar, self.bar_appearance, theme.global.scrollbar_width, theme.shellPalette()));
    fill(cr, 0, @as(f64, @floatFromInt(self.h)) - status_h, @floatFromInt(self.w), status_h, t.app_bar);
    var info: [256]u8 = undefined;
    if (tab.status.revision != tab.doc.revision or tab.status.cursor != tab.doc.cursor) {
        const d = &tab.doc;
        tab.status = .{
            .revision = d.revision,
            .cursor = d.cursor,
            .line = d.linesBefore(d.cursor) + 1,
            .column = (std.unicode.utf8CountCodepoints(d.text.items[d.lineStart(d.cursor)..d.cursor]) catch 0) + 1,
        };
    }
    const text = if (self.notice_len > 0) self.notice[0..self.notice_len] else i18n.fmt(&info, tr("Line {line}, Column {column}    ·    UTF-8{bom}    ·    {ending}"), .{ .line = tab.status.line, .column = tab.status.column, .bom = if (tab.doc.bom) " BOM" else "", .ending = if (tab.doc.crlf) "CRLF" else "LF" }) catch "";
    ui.setSource(cr, t.window_fg);
    ui.drawText(cr, text, 12, @floatFromInt(self.h - 8), ui.statusSize(), false);
    if (self.menu_open) self.paintMenu(cr);
    if (self.close_tab != null) self.paintClose(cr);
}

/// Draws one segment's selection, text and any preedit at the cursor.
pub fn paintLine(self: *App, cr: *c.cairo_t, tab: *Tab, row: view.Row, sel: [2]usize) void {
    const t = theme.global;
    const l = row.line;
    const seg = l.seg;
    const iter = p.pango_layout_get_iter(l.layout) orelse return;
    defer p.pango_layout_iter_free(iter);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, 16 - tab.scroll_x, self.viewTop() + row.y);
    const text_len = l.textLen();
    // The selection as indices into this layout, which holds the text
    // without its line break. With wrapping, a selected break is drawn as
    // highlight out to the right margin, as Pango does when the break is
    // in the layout; without it Pango stops at the end of the text.
    const margin: f64 = @floatFromInt(self.w - 40);
    const s0 = sel[0] -| seg.start;
    const s1 = @min(sel[1] -| seg.start, text_len);
    const covers_break = seg.terminated() and sel[0] <= seg.text_end and sel[1] > seg.text_end;
    var accent = theme.shellPalette().accent;
    accent[3] = 0.35;
    var line_index: c_int = 0;
    while (true) : (line_index += 1) {
        var rect: p.Rectangle = undefined;
        p.pango_layout_iter_get_line_extents(iter, null, &rect);
        const y = @as(f64, @floatFromInt(rect.y)) / 1024;
        const h = @as(f64, @floatFromInt(rect.height)) / 1024;
        if (row.y + y > self.viewHeight()) break;
        if (row.y + y + h >= 0) {
            const line = p.pango_layout_iter_get_line_readonly(iter);
            const first: usize = @intCast(p.pango_layout_line_get_start_index(line));
            const next = p.pango_layout_get_line_readonly(l.layout, line_index + 1);
            const end: usize = if (next) |n| @intCast(p.pango_layout_line_get_start_index(n)) else text_len;
            // Pango extends ranges to the right margin even for lines
            // entirely before the selection, so only ask for lines it intersects.
            if (sel[0] != sel[1] and s0 < s1 and s0 < end and s1 > first) {
                var ranges: ?[*]c_int = null;
                var count: c_int = 0;
                p.pango_layout_line_get_x_ranges(line, @intCast(s0), @intCast(s1), &ranges, &count);
                if (ranges) |r| {
                    defer p.g_free(r);
                    var n: usize = 0;
                    while (n < @as(usize, @intCast(count))) : (n += 1) {
                        fill(cr, @as(f64, @floatFromInt(r[n * 2])) / 1024, y, @as(f64, @floatFromInt(r[n * 2 + 1] - r[n * 2])) / 1024, h, accent);
                    }
                }
            }
            if (covers_break and next == null and self.wrap) {
                const x = @as(f64, @floatFromInt(rect.x + rect.width)) / 1024;
                if (margin > x) fill(cr, x, y, margin - x, h, accent);
            }
            ui.setSource(cr, t.window_fg);
            c.cairo_move_to(cr, @as(f64, @floatFromInt(rect.x)) / 1024, @as(f64, @floatFromInt(p.pango_layout_iter_get_baseline(iter))) / 1024);
            p.pango_cairo_show_layout_line(cr, line);
        }
        if (p.pango_layout_iter_next_line(iter) == 0) break;
    }
    if (self.focused and !self.find_open and self.close_tab == null and lines.holds(seg, tab.doc.cursor, tab.doc.text.items.len)) {
        var r: p.Rectangle = undefined;
        p.pango_layout_get_cursor_pos(l.layout, l.index(tab.doc.cursor), &r, null);
        if (self.preedit.items.len > 0) {
            const x = @as(f64, @floatFromInt(r.x)) / 1024;
            const py = @as(f64, @floatFromInt(r.y + r.height)) / 1024;
            ui.setSource(cr, t.window_fg);
            ui.drawText(cr, self.preedit.items, x, py, ui.textSize(), false);
            fill(cr, x, py + 2, ui.measureText(cr, self.preedit.items, ui.textSize(), false), 1, theme.shellPalette().accent);
        }
    }
}

pub fn paintClose(self: *App, cr: *c.cairo_t) void {
    fill(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h), .{ 0, 0, 0, 0.45 });
    const x: f32 = @as(f32, @floatFromInt(self.w - 420)) / 2;
    const y: f32 = @as(f32, @floatFromInt(self.h - 170)) / 2;
    if (ui.Layer.begin(cr, .{ .x = x, .y = y, .w = 420, .h = 170 })) |l| {
        var layer = l;
        dialog.paintFrame(&layer.renderer, layer.local());
        layer.finish();
    }
    ui.setSource(cr, theme.global.window_fg);
    ui.drawText(cr, tr("Save changes before closing?"), x + 20, y + 36, ui.textSize(), true);
    ui.drawText(cr, tr("Your unsaved changes will be lost if you discard them."), x + 20, y + 72, ui.textSize(), false);
    self.paintButton(cr, .{ .x = x + 20, .y = y + 112, .w = 115, .h = 38 }, tr("Cancel"), self.close_choice == 0);
    self.paintButton(cr, .{ .x = x + 145, .y = y + 112, .w = 125, .h = 38 }, tr("Discard"), self.close_choice == 1);
    self.paintButton(cr, .{ .x = x + 280, .y = y + 112, .w = 120, .h = 38 }, tr("Save"), self.close_choice == 2);
}
