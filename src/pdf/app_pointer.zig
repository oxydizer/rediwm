//! PDF viewer pointer input: motion, clicks, selection and toolbar.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const layout = @import("layout.zig");
const selection = @import("selection.zig");
const scrollbar = @import("ui").widgets.scrollbar;
const button_widget = @import("ui").widgets.button;
const ui_theme = @import("ui").theme;
const Action = @import("app.zig").Action;
const a = @import("app.zig").a;
const toolbar_buttons = @import("app.zig").toolbar_buttons;
const toolbar_button_y = @import("app.zig").toolbar_button_y;
const toolbar_button_h = @import("app.zig").toolbar_button_h;

pub fn buttonProximity(
    self: *const App,
    action: Action,
    x: f64,
    y: f64,
) button_widget.ProximitySample {
    const absent = button_widget.ProximitySample{
        .distance = std.math.inf(f32),
        .x = 0,
        .y = 0,
    };
    if (self.dialog != .none) return absent;

    for (toolbar_buttons) |item| {
        if (item.act != action) continue;

        return button_widget.sampleProximity(
            .{
                .x = @floatCast(item.x),
                .y = @floatCast(toolbar_button_y),
                .w = @floatCast(item.w),
                .h = @floatCast(toolbar_button_h),
            },
            @floatCast(x),
            @floatCast(y),
            .{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(self.w),
                .h = @floatCast(self.toolbarRect().h),
            },
        );
    }

    return absent;
}

fn toolbarProximityChanged(
    self: *const App,
    old_x: f64,
    old_y: f64,
    new_x: f64,
    new_y: f64,
) bool {
    const reach = ui_theme.global.border_glow_reach;
    if (!button_widget.proximityGlowVisible(ui_theme.global) or
        self.dialog != .none)
        return false;

    for (toolbar_buttons) |item| {
        const before = self.buttonProximity(item.act, old_x, old_y);
        const after = self.buttonProximity(item.act, new_x, new_y);
        if (@min(before.distance, after.distance) <= reach) return true;
    }

    return false;
}

pub fn handleMotion(self: *App, px: f64, py: f64) void {
    const old_x = self.px;
    const old_y = self.py;
    self.px = px;
    self.py = py;

    if (toolbarProximityChanged(self, old_x, old_y, px, py)) self.toolbar_dirty = true;

    if (self.hbar_drag.active) {
        if (self.hbar()) |bar| self.scroll_x = self.hbar_drag.offsetAt(bar, @floatCast(px), @floatCast(py));
        self.dirty = true;
        return;
    }

    if (self.dragging_canvas) {
        const dl = self.doc_layout orelse return;
        const cv = self.canvasRect();
        const dy = py - self.drag_start_y;
        const max_scroll = @max(0.0, dl.total_height - cv.h);
        self.scroll_y = std.math.clamp(self.drag_start_scroll_y - dy, 0.0, max_scroll);
        self.scroll_x = std.math.clamp(self.drag_start_scroll_x - (px - self.drag_start_x), 0.0, self.maxScrollX());
        self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, cv.h);
        self.current_page = self.anchor.page_index;
        self.updateTitle();
        self.dirty = true;
        return;
    }

    if (self.selection_dragging and self.selection_page != null and self.doc_layout != null) {
        const dl = self.doc_layout.?;
        const cv = self.canvasRect();
        const p_idx = self.selection_page.?;
        if (p_idx < dl.pages.len) {
            const p = dl.pages[p_idx];
            const page_x = self.pageX(cv, p);
            const page_y = cv.y + p.y_offset - self.scroll_y;
            const view_pt = layout.Point{ .x = px - page_x, .y = py - page_y };
            self.selection_end = layout.viewPointToPage(view_pt, p.pts_size, self.rotation, self.zoom);
            self.updateSelection();
            self.dirty = true;
            return;
        }
    }

    // Text and link hover detection
    self.hover_link = null;
    self.hover_text = false;
    if (self.doc_layout) |dl| {
        const cv = self.canvasRect();
        if (cv.contains(px, py)) {
            const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
            if (vis) |v| {
                for (v.start_index..v.end_index + 1) |i| {
                    const p = dl.pages[i];
                    const page_x = self.pageX(cv, p);
                    const page_y = cv.y + p.y_offset - self.scroll_y;
                    if (px >= page_x and px <= page_x + p.logical_width and py >= page_y and py <= page_y + p.logical_height) {
                        if (self.page_contents.get(i)) |content| {
                            const pt = layout.viewPointToPage(.{ .x = px - page_x, .y = py - page_y }, p.pts_size, self.rotation, self.zoom);
                            for (content.text_rects) |r| {
                                if (r.w > 0 and r.h > 0 and r.contains(pt)) {
                                    self.hover_text = true;
                                    break;
                                }
                            }
                            for (content.links) |lnk| {
                                if (lnk.area.contains(pt)) {
                                    self.hover_link = lnk;
                                    break;
                                }
                            }
                        }
                        break;
                    }
                }
            }
        }
    }

    // Sidebar hover detection
    const sb = self.sidebarRect();
    if (self.sidebar_open and sb.contains(px, py)) {
        if (self.sidebar_tab == .pages and self.sidebar_layout != null) {
            const sbl = self.sidebar_layout.?;
            const vis_sb = layout.findVisibleSidebarCards(sbl.cards, self.sidebar_scroll_y, sb.h);
            var found: ?usize = null;
            if (vis_sb) |vsb| {
                for (vsb.start_index..vsb.end_index + 1) |i| {
                    const card = sbl.cards[i];
                    const card_y = sb.y + card.y_offset - self.sidebar_scroll_y;
                    if (py >= card_y and py <= card_y + card.card_h) {
                        found = i;
                        break;
                    }
                }
            }
            if (self.hover_thumb != found) {
                self.hover_thumb = found;
                self.dirty = true;
            }
        } else if (self.sidebar_tab == .outline and self.outline != null) {
            const row_h = 28.0;
            const rel_y = py - (sb.y + 40.0) + self.sidebar_scroll_y;
            if (rel_y >= 0) {
                const idx: usize = @intFromFloat(rel_y / row_h);
                if (idx < self.outline.?.len and self.hover_outline != idx) {
                    self.hover_outline = idx;
                    self.dirty = true;
                }
            }
        }
    } else {
        if (self.hover_thumb != null or self.hover_outline != null) {
            self.hover_thumb = null;
            self.hover_outline = null;
            self.dirty = true;
        }
    }
}

pub fn handleButton(self: *App, button: u32, pressed: bool) void {
    if (button == 0x110) { // Left click
        if (pressed) {
            if (self.dialog != .none) {
                self.handleDialogClick();
                return;
            }

            if (self.search_open and self.searchBarRect().contains(self.px, self.py)) {
                self.handleSearchBarClick();
                return;
            }

            if (self.toolbarRect().contains(self.px, self.py)) {
                self.handleToolbarClick();
                return;
            }

            if (self.sidebar_open and self.sidebarRect().contains(self.px, self.py)) {
                self.handleSidebarClick();
                return;
            }

            // Canvas click
            const cv = self.canvasRect();
            if (cv.contains(self.px, self.py) and self.doc_layout != null) {
                if (self.hbar()) |bar| {
                    const scroll_x: f32 = @floatCast(self.scroll_x);
                    if (scrollbar.press(bar, @floatCast(self.px), @floatCast(self.py), scroll_x)) |action| {
                        switch (action) {
                            .grab => self.hbar_drag.begin(bar, @floatCast(self.px), @floatCast(self.py), scroll_x),
                            .page => |offset| self.scroll_x = offset,
                        }
                        self.dirty = true;
                        return;
                    }
                }
                // Check if clicked a hyperlink!
                if (self.hover_link) |lnk| {
                    switch (lnk.target) {
                        .goto_page => |target| self.goToPage(target),
                        .uri => |u| {
                            if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) return;
                            const copy = a.dupeSentinel(u8, u, 0) catch return;
                            if (self.clipboard_text) |old| a.free(old);
                            self.clipboard_text = copy;
                            self.clipboard_request = true;
                            self.dialog = .information;
                            self.error_message = tr("Link copied. Paste it into your browser.");
                            self.dirty = true;
                        },
                    }
                    return;
                }

                // Start text selection or drag pan
                const dl = self.doc_layout.?;
                const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
                if (vis) |v| {
                    for (v.start_index..v.end_index + 1) |i| {
                        const p = dl.pages[i];
                        const page_x = self.pageX(cv, p);
                        const page_y = cv.y + p.y_offset - self.scroll_y;
                        if (self.px >= page_x and self.px <= page_x + p.logical_width and self.py >= page_y and self.py <= page_y + p.logical_height) {
                            const pt = layout.viewPointToPage(.{ .x = self.px - page_x, .y = self.py - page_y }, p.pts_size, self.rotation, self.zoom);
                            self.selection_dragging = true;
                            self.selection_page = i;
                            self.selection_start = pt;
                            self.selection_end = pt;
                            self.clearSelectionText();
                            self.selection_range = null;
                            self.selection_active = false;
                            self.dirty = true;
                            return;
                        }
                    }
                }

                // Otherwise middle/left pan
                self.dragging_canvas = true;
                self.drag_start_y = self.py;
                self.drag_start_scroll_y = self.scroll_y;
                self.drag_start_x = self.px;
                self.drag_start_scroll_x = self.scroll_x;
            }
        } else {
            // Button release
            self.dragging_canvas = false;
            if (self.hbar_drag.active) {
                self.hbar_drag.end();
                self.dirty = true;
            }
            if (self.selection_dragging) {
                self.selection_dragging = false;
                self.updateSelection();
            }
        }
    }
}

pub fn clearSelectionText(self: *App) void {
    if (self.selected_text) |t| a.free(t);
    self.selected_text = null;
}

pub fn updateSelection(self: *App) void {
    self.dirty = true;
    self.clearSelectionText();
    self.selection_range = null;
    self.selection_active = false;
    const page = self.selection_page orelse return;
    const content = self.page_contents.get(page) orelse return;
    const range = selection.between(content.text_rects, self.selection_start, self.selection_end) orelse return;
    const text = content.text orelse return;
    const selected = range.text(text);
    if (selected.len == 0) return;
    self.selected_text = a.dupeSentinel(u8, selected, 0) catch return;
    self.selection_range = range;
    self.selection_active = true;
    self.dirty = true;
}

pub fn handleToolbarClick(self: *App) void {
    // Page number editor field click: x=124..204
    if (self.px >= 124.0 and self.px <= 204.0 and self.py >= 6.0 and self.py <= 38.0) {
        self.focus = .page_number;
        self.editor.text.clearRetainingCapacity();
        var buf: [16]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{self.current_page + 1}) catch "";
        self.editor.insert(a, str) catch {};
        self.dirty = true;
        return;
    }

    for (toolbar_buttons) |item| {
        if (self.px >= item.x and self.px <= item.x + item.w and self.py >= toolbar_button_y and self.py <= toolbar_button_y + toolbar_button_h) {
            self.triggerAction(item.act);
            return;
        }
    }
}

pub fn handleSidebarClick(self: *App) void {
    const sb = self.sidebarRect();
    // Check top tabs
    if (self.py >= sb.y and self.py <= sb.y + 36.0) {
        const half = sb.w / 2.0;
        if (self.px < half) {
            self.sidebar_tab = .pages;
        } else {
            self.sidebar_tab = .outline;
        }
        self.dirty = true;
        return;
    }

    if (self.sidebar_tab == .pages) {
        if (self.hover_thumb) |idx| {
            self.goToPage(idx);
        }
    } else if (self.sidebar_tab == .outline and self.outline != null) {
        if (self.hover_outline) |idx| {
            if (idx < self.outline.?.len) {
                if (self.outline.?[idx].target_page) |target| {
                    self.goToPage(target);
                }
            }
        }
    }
}

pub fn handleSearchBarClick(self: *App) void {
    const sr = self.searchBarRect();
    const close_x = sr.x + sr.w - 28.0;
    const next_x = close_x - 28.0;
    const prev_x = next_x - 28.0;

    if (self.px >= close_x and self.px <= sr.x + sr.w) {
        self.search_open = false;
        self.focus = .none;
        self.dirty = true;
    } else if (self.px >= next_x and self.px < close_x) {
        if (self.search_matches.items.len > 0) {
            self.scrollToMatch(self.search_match_idx + 1);
        }
    } else if (self.px >= prev_x and self.px < next_x) {
        if (self.search_matches.items.len > 0) {
            self.scrollToMatch(if (self.search_match_idx == 0) self.search_matches.items.len - 1 else self.search_match_idx - 1);
        }
    } else {
        self.focus = .search;
        self.dirty = true;
    }
}

pub fn handleDialogClick(self: *App) void {
    const dw: f64 = 440;
    const dh: f64 = 190;
    const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
    const dy = (@as(f64, @floatFromInt(self.h)) - dh) / 2.0;

    // Cancel button: x = dx + dw - 180..dx + dw - 100
    if (self.px >= dx + dw - 180.0 and self.px <= dx + dw - 100.0 and self.py >= dy + dh - 46.0 and self.py <= dy + dh - 14.0) {
        self.dialog = .none;
        self.focus = .none;
        self.password_input.clear();
        self.dirty = true;
        return;
    }

    // Action button: x = dx + dw - 90..dx + dw - 20
    if (self.px >= dx + dw - 90.0 and self.px <= dx + dw - 20.0 and self.py >= dy + dh - 46.0 and self.py <= dy + dh - 14.0) {
        if (self.dialog == .password) self.submitPassword() else self.dialog = .none;
        self.dirty = true;
    }
}

pub fn cancelDrag(self: *App) void {
    self.dragging_canvas = false;
    self.hbar_drag.end();
    self.selection_dragging = false;
}

test "PDF toolbar proximity samples buttons and detects redraws" {
    const saved_theme = ui_theme.global;
    defer ui_theme.global = saved_theme;

    ui_theme.global.button_hover_glow_enabled = true;
    ui_theme.global.border_glow_reach = 56;

    var app: App = undefined;
    app.w = 700;
    app.dialog = .none;

    const button = toolbar_buttons[1];
    const x = button.x + button.w / 2;
    const y = toolbar_button_y - 4;

    const sample = buttonProximity(&app, button.act, x, y);
    try std.testing.expectApproxEqAbs(@as(f32, 4), sample.distance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 16), sample.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), sample.y, 0.001);

    try std.testing.expect(toolbarProximityChanged(&app, x, y, 650, 500));
    try std.testing.expect(!toolbarProximityChanged(&app, 650, 500, 650, 500));

    app.dialog = .information;
    const hidden = buttonProximity(&app, button.act, x, y);
    try std.testing.expect(std.math.isInf(hidden.distance));
    try std.testing.expect(!toolbarProximityChanged(&app, x, y, 650, 500));
}

pub fn cursorName(self: *const App) [*:0]const u8 {
    if (self.hover_link != null) return "pointer";
    if (self.hover_text or self.selection_dragging) return "text";
    if (self.focus != .none) return "text";
    return "default";
}
