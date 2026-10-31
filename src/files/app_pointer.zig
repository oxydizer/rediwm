//! Files pointer input: motion, drags, the selection band and clicks.

const std = @import("std");
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const c = @import("c.zig").api;
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const ui_theme = @import("ui").theme;
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const git_header_h = App.git_header_h;
const git_row_h = App.git_row_h;
const nowMs = @import("app_draw.zig").nowMs;
const setSource = @import("app_draw.zig").setSource;
const gitBranchRowCount = App.gitBranchRowCount;
const gitBranchRow = App.gitBranchRow;

// Input handlers
pub fn hoverKey(self: *App) usize {
    if (self.dialog) |dlg| if (dlg.kind == .transfers) return self.transfersHover();
    if (self.dialog == null and self.torrentSidebarHit(self.mouse_x, self.mouse_y)) return std.math.maxInt(usize) - 2001;
    const x = self.mouse_x;
    const y = self.mouse_y;
    if (self.dialog) |dlg| {
        if (dlg.kind == .properties) return dlg.properties.?.hit(self.w, self.h, x, y);
        if (dlg.kind == .open_with) return dlg.applications.?.hit(self.w, self.h, x, y);
        if (dlg.kind == .trash_confirm) return @intFromEnum(dlg.deletion.geometry(self.w, self.h).target(x, y));
        const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
        const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2;
        const dy = (@as(f64, @floatFromInt(self.h)) - 130) / 2;
        if (y < dy + 84 or y > dy + 112) return 0;
        if (dlg.kind == .conflict) {
            for (0..3) |i| {
                const left = dx + 16 + @as(f64, @floatFromInt(i)) * ((dw - 48) / 3 + 8);
                if (x >= left and x <= left + (dw - 48) / 3) return i + 1;
            }
        } else {
            if (x >= dx + dw - 184 and x <= dx + dw - 104) return 1;
            if (x >= dx + dw - 96 and x <= dx + dw - 16) return 2;
        }
        return 0;
    }
    if (self.menu != null) return 100 + (self.menuHit(x, y) orelse 99);
    if (self.transfer_view.active and (y < @as(f64, @floatFromInt(self.contentTop())) or
        (x >= @as(f64, @floatFromInt(self.sidebarWidth())) and y < @as(f64, @floatFromInt(self.contentBottom()))))) return self.transferPaneHover();
    if (self.terminalHit(x, y)) |index| return 900 + index;
    if (self.sidebar_resize != null or self.overSidebarDivider(x, y)) return 0;
    if (self.chooser) |opts| {
        if (y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
            for (0..4 + opts.choices.len) |i| {
                if (self.chooserRect(i).contains(x, y)) return 501 + i;
            }
            return 500;
        }
    }
    if (header.hit(self.w, self.inRepository(), x, y)) |action| return 200 + @as(usize, @intFromEnum(action));
    if (self.list_view and x >= @as(f64, @floatFromInt(self.sidebarWidth())) and x < @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) {
        for (self.columnLabels(), 0..) |_, i| {
            if (i < 4 and self.listColumn(i).contains(x, y)) return 400 + i;
        }
    }
    if (x >= 0 and x < @as(f64, @floatFromInt(self.sidebarWidth())) and y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.sidebarFooter()))) {
        if (self.ejectAt(x, y)) |k| return 700 + k;
        for (0..self.rowCount()) |i| {
            if (!self.placeVisible(i)) continue;
            const row = self.placeRect(i);
            if (y >= row.y and y < row.y + row.h) return switch (self.rowKind(i)) {
                .builtin => |b| 300 + b,
                .pin => |j| 800 + j,
                .device => |k| 600 + k,
            };
        }
    }
    if (self.inlineTorrentHit(x, y)) |hit| return std.math.maxInt(usize) - 3000 - hit.index * 2 - @intFromBool(hit.toggle);
    if (self.itemAt(x, y)) |i| {
        if (self.sizeButtonRect(i)) |rect| {
            if (rect.contains(x, y)) {
                if (self.folder_sizes.get(self.items.items[i].path)) |sz| {
                    switch (sz) {
                        .running => return 2_000_000 + i,
                        .done => {},
                    }
                } else {
                    return 2_000_000 + i;
                }
            }
        }
        return 1000 + i;
    }
    return 0;
}

pub fn handleMotion(self: *App, x: f64, y: f64) void {
    if (self.terminalMotion(x, y)) {
        self.mouse_x = x;
        self.mouse_y = y;
        return;
    }
    if (self.overTerminalDivider(self.mouse_x, self.mouse_y) != self.overTerminalDivider(x, y)) self.terminalDamage();
    if (self.sidebar_resize) |drag| {
        self.mouse_x = x;
        self.mouse_y = y;
        const width = drag.widthAt(x, 160, @divTrunc(self.w, 2));
        if (width != self.sidebarWidth()) {
            self.sidebar_requested = width;
            self.syncSidebarWidth();
            self.clampScroll();
            self.clampSidebarScroll();
            self.invalidate();
        }
        return;
    }
    if (self.overSidebarDivider(self.mouse_x, self.mouse_y) != self.overSidebarDivider(x, y)) self.damageSidebarDivider();
    if (self.dialog) |*dlg| {
        const moved = switch (dlg.kind) {
            .properties => dlg.properties.?.motion(self.w, self.h, x, y),
            .open_with => dlg.applications.?.motion(self.w, self.h, x, y),
            .trash_confirm => dlg.deletion.motion(self.w, self.h, x, y),
            else => false,
        };
        if (moved) self.invalidate();
    }
    if (self.column_resize != null) {
        self.mouse_x = x;
        self.mouse_y = y;
        self.resizeColumn(x);
        return;
    }
    if (self.drag_origin) |origin| {
        const dx = x - origin.x;
        const dy = y - origin.y;
        if (dx * dx + dy * dy >= 64) {
            self.drag_ready = self.history.archive_len == 0;
            self.drag_origin = null;
            self.collapse_on_release = null;
            self.deselect_on_release = null;
            self.open_on_release = null;
            self.last_click_index = null;
        }
    }
    const old_hover = self.hoverKey();
    self.mouse_x = x;
    self.mouse_y = y;
    if (self.selection_band != null) self.updateSelectionBand();
    if (self.text_dragging) {
        self.placeCaret(x, true);
        self.edit_revision += 1;
        self.invalidate();
    }
    if (self.menu != null) {
        if (self.menuHit(x, y)) |row| self.menu_selected = row;
    }
    if (old_hover != self.hoverKey()) self.invalidateHover(old_hover, self.hoverKey());

    if (self.sidebar_scroll_drag.active) {
        if (self.sidebarScrollbar()) |bar| {
            const offset = self.sidebar_scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y));
            self.sidebar_scroll = @intFromFloat(@round(offset));
            self.invalidate();
        }
    }
    if (self.scroll_drag.active) {
        if (self.scrollbarGeometry()) |bar| {
            self.scroll_y = std.math.clamp(@as(i32, @intFromFloat(@round(self.scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y))))), 0, self.maxScroll());
            self.invalidate();
        }
    }
    if (self.horizontal_drag.active) {
        if (self.horizontalScrollbar()) |bar| {
            self.scroll_x = self.horizontal_drag.offsetAt(bar, @floatCast(x), @floatCast(y));
            self.invalidate();
        }
    }
}

pub fn cancelDrag(self: *App) void {
    self.terminalCancelPointer();
    self.terminal.resize = null;
    self.terminal.selecting = false;
    self.terminal.scroll_drag.end();
    if (self.dialog) |*dlg| {
        dlg.deletion.placement.grab = null;
        if (dlg.properties) |*props| props.placement.grab = null;
        if (dlg.applications) |*apps| apps.placement.grab = null;
    }
    self.column_resize = null;
    if (self.sidebar_resize != null) self.damageSidebarDivider();
    self.sidebar_resize = null;
    self.horizontal_drag.end();
    if (self.selection_band != null) self.invalidate();
    self.selection_band = null;
    self.drag_origin = null;
    self.drag_ready = false;
    self.collapse_on_release = null;
    self.deselect_on_release = null;
    self.open_on_release = null;
}

pub fn bandRect(self: *App) header.Rect {
    const band = self.selection_band.?;
    const x = std.math.clamp(self.mouse_x, @as(f64, @floatFromInt(self.sidebarWidth())), @as(f64, @floatFromInt(self.w - self.scrollbarGutter())));
    const y = std.math.clamp(self.mouse_y, @as(f64, @floatFromInt(self.viewTop())), @as(f64, @floatFromInt(self.contentBottom()))) + @as(f64, @floatFromInt(self.scroll_y));
    return .{ .x = @min(band.x, x), .y = @min(band.y, y), .w = @abs(x - band.x), .h = @abs(y - band.y) };
}

pub fn updateSelectionBand(self: *App) void {
    const band = if (self.selection_band) |*b| b else return;
    const rect = self.bandRect();
    if (!band.active and rect.w * rect.w + rect.h * rect.h < 16) return;
    band.active = true;
    const cols = self.columns();
    for (self.items.items, 0..) |*item, i| {
        const index: i32 = @intCast(i);
        const x: f64 = @floatFromInt(self.sidebarWidth() + 20 + @mod(index, cols) * self.cellWidth());
        const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(index, cols) * self.rowHeight());
        const hit = rect.x < x + @as(f64, @floatFromInt(self.cellWidth() - 20)) and rect.x + rect.w > x and
            rect.y < y + @as(f64, @floatFromInt(self.cardHeight())) and rect.y + rect.h > y;
        item.selected = if (band.toggle) item.selected_before_band != hit else hit or (band.extend and item.selected_before_band);
    }
    self.invalidate();
}

pub fn bandScrollDirection(self: *App) i32 {
    const band = self.selection_band orelse return 0;
    if (!band.active) return 0;
    if (self.mouse_y < @as(f64, @floatFromInt(self.viewTop() + 20)) and self.scroll_y > 0) return -1;
    if (self.mouse_y > @as(f64, @floatFromInt(self.contentBottom() - 20)) and self.scroll_y < self.maxScroll()) return 1;
    return 0;
}

pub fn selectionNeedsScroll(self: *App) bool {
    return self.bandScrollDirection() != 0;
}

pub fn stepSelection(self: *App, now: i64) void {
    const band = if (self.selection_band) |*b| b else return;
    const elapsed = std.math.clamp(now - band.last_ms, 0, 50);
    band.last_ms = now;
    const direction = self.bandScrollDirection();
    if (direction == 0 or elapsed == 0) return;
    self.scroll_y = std.math.clamp(self.scroll_y + direction * @as(i32, @intCast(@max(1, @divTrunc(elapsed * 600, 1000)))), 0, self.maxScroll());
    self.updateSelectionBand();
}

pub fn renderSelectionBand(self: *App, cr: *c.cairo_t) void {
    const band = self.selection_band orelse return;
    if (!band.active) return;
    const rect = self.bandRect();
    const palette = ui_theme.shellPalette();
    setSource(cr, palette.selectionColor());
    c.cairo_rectangle(cr, rect.x, rect.y - @as(f64, @floatFromInt(self.scroll_y)), rect.w, rect.h);
    c.cairo_fill_preserve(cr);
    setSource(cr, palette.accent);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

pub fn handleButton(self: *App, button: u32, pressed: bool) void {
    if (self.terminalButton(button, pressed)) return;
    if (pressed and self.dialog == null and self.menu == null and self.focus == .terminal) {
        self.focus = .file_view;
        self.terminalDamage();
    }
    // Mice report side buttons either as SIDE/EXTRA or BACK/FORWARD.
    if (button == 0x113 or button == 0x116 or button == 0x114 or button == 0x115) {
        if (!pressed or self.dialog != null) return;
        self.cancelWheel();
        self.cancelDrag();
        self.text_dragging = false;
        self.scroll_drag.end();
        self.sidebar_scroll_drag.end();
        if (self.menu != null) {
            self.menu = null;
            self.invalidate();
        }
        if (button == 0x113 or button == 0x116) self.back() else self.forward();
        return;
    }
    if (button != 0x110 and button != 0x111) return;

    self.cancelWheel();
    if (button == 0x110) {
        if (self.dialog) |*dlg| {
            const consumed = switch (dlg.kind) {
                .properties => dlg.properties.?.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                .open_with => dlg.applications.?.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                .trash_confirm => dlg.deletion.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                else => false,
            };
            if (consumed) return;
        }
    }
    if (!pressed) {
        if (button == 0x110) {
            const open_index = self.open_on_release;
            if (self.collapse_on_release) |idx| {
                for (self.items.items, 0..) |*it, i| it.selected = i == idx;
                self.invalidate();
            }
            if (self.deselect_on_release) |idx| {
                if (idx < self.items.items.len) self.items.items[idx].selected = false;
                self.invalidate();
            }
            self.cancelDrag();
            if (open_index) |idx| {
                if (!self.ctrl and !self.shift and !self.alt and self.singleClickIconAt(self.mouse_x, self.mouse_y) == idx) {
                    self.last_click_index = null;
                    self.last_click_time = 0;
                    self.last_open_index = idx;
                    self.last_open_time = nowMs();
                    self.activateItem(idx);
                }
            }
        }
        self.text_dragging = false;
        self.scroll_drag.end();
        self.sidebar_scroll_drag.end();
        return;
    }

    self.cancelDrag();
    self.edit_revision += 1;
    const now = nowMs();
    const x = self.mouse_x;
    const y = self.mouse_y;
    if (button == 0x110) {
        if (self.overSidebarDivider(x, y)) {
            self.sidebar_resize = .{ .origin = x, .width = self.sidebarWidth() };
            self.sidebar_requested = self.sidebarWidth();
            self.syncSidebarWidth();
            self.last_click_index = null;
            self.damageSidebarDivider();
            return;
        }
        if (self.columnBoundary(x, y)) |column| {
            self.column_resize = .{ .column = column, .x = x, .widths = self.listWidths() };
            self.last_click_index = null;
            return;
        }
    }
    if (self.chooser != null and self.dialog == null and self.menu == null) {
        if (self.chooserClick(x, y, button)) return;
        if (button == 0x111) return;
    }

    // Modal Dialog click handling
    if (self.dialog != null and button != 0x110) return;
    if (self.dialog) |dlg| {
        if (dlg.kind == .transfers) {
            self.transfersClick(x, y);
            return;
        }
        if (dlg.kind == .properties) {
            const action = self.dialog.?.properties.?.click(self.w, self.h, x, y);
            self.propertiesAction(action);
            return;
        }
        if (dlg.kind == .open_with) {
            const action = self.dialog.?.applications.?.click(self.w, self.h, x, y);
            self.openWithAction(action);
            return;
        }
        if (dlg.kind == .trash_confirm) {
            self.deleteAction(dlg.deletion.geometry(self.w, self.h).hit(x, y));
            return;
        }
        if (self.renameCard()) |card| {
            if (card.confirm.contains(x, y)) {
                self.confirmDialog();
            } else if (card.cancel.contains(x, y)) {
                self.closeDialog();
            } else if (card.field.contains(x, y)) {
                self.placeCaret(x, self.shift);
                self.text_dragging = true;
                self.invalidate();
            } else if (!card.panel.contains(x, y)) {
                self.closeDialog();
            }
            return;
        }
        const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
        const dh: f64 = 130;
        const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
        const dy = (@as(f64, @floatFromInt(self.h)) - dh) / 2.0;

        if (dlg.kind == .conflict) {
            // Skip [dx + 16 .. dx + 16 + (dw - 48) / 3]
            if (x >= dx + 16 and x <= dx + 16 + (dw - 48) / 3 and y >= dy + 84 and y <= dy + 112) {
                if (self.job_runner) |runner| runner.resolveConflict(.skip);
                self.closeDialog();
                return;
            }
            // Rename [dx + 24 + (dw - 48) / 3 .. dx + 24 + 2 * (dw - 48) / 3]
            if (x >= dx + 24 + (dw - 48) / 3 and x <= dx + 24 + 2 * (dw - 48) / 3 and y >= dy + 84 and y <= dy + 112) {
                if (self.job_runner) |runner| runner.resolveConflict(.rename);
                self.closeDialog();
                return;
            }
            // Cancel [dx + 32 + 2 * (dw - 48) / 3 .. dx + dw - 16]
            if (x >= dx + 32 + 2 * (dw - 48) / 3 and x <= dx + dw - 16 and y >= dy + 84 and y <= dy + 112) {
                if (self.job_runner) |runner| runner.resolveConflict(.cancel);
                self.closeDialog();
                return;
            }
        } else {
            // OK [dx + dw - 184 .. dx + dw - 104]
            if (x >= dx + dw - 184 and x <= dx + dw - 104 and y >= dy + 84 and y <= dy + 112) {
                self.confirmDialog();
                return;
            }
            // Cancel [dx + dw - 96 .. dx + dw - 16]
            if (x >= dx + dw - 96 and x <= dx + dw - 16 and y >= dy + 84 and y <= dy + 112) {
                self.closeDialog();
                return;
            }
        }

        if (self.activeEditor() != null and x >= dx + 16 and x < dx + dw - 16 and y >= dy + 42 and y < dy + 72) {
            self.placeCaret(x, self.shift);
            self.text_dragging = true;
            self.invalidate();
        }
        // Click outside dialog box closes
        if (x < dx or x > dx + dw or y < dy or y > dy + dh) {
            if (dlg.kind == .conflict) {
                if (self.job_runner) |runner| runner.resolveConflict(.cancel);
            }
            self.closeDialog();
        }
        return;
    }

    if (self.menu != null) {
        if (button == 0x110) {
            if (self.menuHit(x, y)) |row| {
                self.runMenu(row);
                return;
            }
        }
        self.menu = null;
        self.invalidate();
        if (button == 0x110) return;
    }
    if (self.transfer_view.active and self.transferPaneClick(x, y, button)) return;
    if (button == 0x110 and self.inlineTorrentClick(x, y)) return;
    if (button == 0x111) {
        if (self.placeAt(x, y)) |index| {
            self.menu_place = index;
            self.openMenu(if (self.isDeviceRow(index)) .device else .sidebar, x, y);
            return;
        }
        if (y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight())) and x >= @as(f64, @floatFromInt(self.sidebarWidth()))) {
            const hit = self.itemAt(x, y);
            if (hit) |idx| {
                if (!self.items.items[idx].selected) {
                    for (self.items.items, 0..) |*it, i| it.selected = i == idx;
                }
                self.focused_index = idx;
                self.selection_anchor = idx;
            } else {
                for (self.items.items) |*it| it.selected = false;
                self.focused_index = null;
                self.selection_anchor = null;
            }
            self.focus = .file_view;
            self.openMenu(if (hit != null) .file else .background, x, y);
        }
        return;
    }
    if (header.hit(self.w, self.inRepository(), x, y)) |action| {
        self.runHeader(action);
        return;
    }
    if (header.field(self.w).contains(x, y)) {
        if (!self.search_visible and self.focus != .location_bar) {
            if (self.breadcrumbs(null, x)) |hit| {
                self.navigate(hit.path);
                return;
            }
        }
        self.focus = if (self.search_visible) .search else .location_bar;
        self.placeCaret(x, self.shift);
        self.text_dragging = true;
        self.invalidate();
        return;
    }

    if (self.sidebarScrollbar()) |bar| {
        if (scrollbar.press(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.sidebar_scroll))) |action| {
            switch (action) {
                .grab => self.sidebar_scroll_drag.begin(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.sidebar_scroll)),
                .page => |offset| {
                    self.sidebar_scroll = @intFromFloat(@round(offset));
                    self.invalidate();
                },
            }
            return;
        }
    }
    if (self.torrentSidebarHit(x, y)) {
        self.openTransfers();
        return;
    }
    if (self.ejectAt(x, y)) |k| {
        self.ejectDevice(k);
        return;
    }
    if (self.placeAt(x, y)) |index| {
        self.openPlace(index);
        return;
    }
    if (self.repository()) |repo| {
        if (y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight())) and self.gitCard().contains(x, y)) {
            const card = self.gitCard();
            if (self.git_expanded and y >= card.y + git_header_h) {
                const row: usize = @intFromFloat((y - card.y - git_header_h) / git_row_h);
                const rows = gitBranchRowCount(repo);
                if (row == rows) {
                    self.openNewBranchDialog();
                } else if (row < rows) {
                    const branch = gitBranchRow(repo, row);
                    if (!branch.current) self.switchBranch(repo, branch.name, false);
                }
            } else if (x >= card.x + card.w - 24) {
                self.git_expanded = !self.git_expanded;
                self.clampSidebarScroll();
                self.invalidate();
            } else self.navigate(repo.root);
            return;
        }
    }
    if (x < @as(f64, @floatFromInt(self.sidebarWidth()))) return;

    if (self.list_view and y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.viewTop()))) {
        for (self.columnLabels(), 0..) |_, i| {
            if (self.listColumn(i).contains(x, y)) {
                self.sortByColumn(i);
                return;
            }
        }
    }

    if (self.horizontalScrollbar()) |bar| {
        if (bar.track.contains(@floatCast(x), @floatCast(y))) {
            if (button == 0x110) {
                if (scrollbar.press(bar, @floatCast(x), @floatCast(y), @floatCast(self.horizontalOffset()))) |action| switch (action) {
                    .grab => self.horizontal_drag.begin(bar, @floatCast(x), @floatCast(y), @floatCast(self.horizontalOffset())),
                    .page => |offset| {
                        self.scroll_x = offset;
                        self.invalidate();
                    },
                };
            }
            return;
        }
    }
    // Use the same scrollbar gutter for input and content layout.
    if (x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter())) and y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
        if (self.scrollbarGeometry()) |bar| {
            if (scrollbar.press(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.scroll_y))) |action| {
                switch (action) {
                    .grab => self.scroll_drag.begin(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.scroll_y)),
                    .page => |offset| {
                        self.scroll_y = @intFromFloat(@round(offset));
                        self.invalidate();
                    },
                }
            }
        }
        return;
    }

    // File view area
    if (y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.contentBottom())) and x < @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) {
        self.focus = .file_view;
        if (self.itemAt(x, y)) |idx| {
            if (button == 0x110) {
                if (self.sizeButtonRect(idx)) |rect| {
                    if (rect.contains(x, y)) {
                        if (self.folder_sizes.get(self.items.items[idx].path)) |sz| {
                            switch (sz) {
                                .running => {
                                    self.toggleFolderSize(idx);
                                    return;
                                },
                                .done => {},
                            }
                        } else {
                            self.toggleFolderSize(idx);
                            return;
                        }
                    }
                }
            }

            const single_click = button == 0x110 and !self.ctrl and !self.shift and !self.alt and self.singleClickIconAt(x, y) == idx;
            // A single click opens on release, so a double-click on an icon
            // would open it twice: the second click only selects.
            const just_opened = single_click and self.last_open_index == idx and now - self.last_open_time < 400;
            // Icon clicks activate on release so they can still start a drag.
            if (!single_click and button == 0x110 and !self.ctrl and !self.shift and !self.alt and self.last_click_index == idx and (now - self.last_click_time < 400)) {
                self.activateItem(idx);
                self.last_click_index = null;
                self.last_click_time = 0;
                return;
            }

            self.last_click_index = if (single_click or button != 0x110 or self.ctrl or self.shift or self.alt) null else idx;
            self.last_click_time = now;
            self.focused_index = idx;

            if (self.shift and self.selection_anchor != null and (self.chooser == null or self.chooser.?.multiple)) {
                const start = @min(self.selection_anchor.?, idx);
                const end = @max(self.selection_anchor.?, idx);
                for (self.items.items, 0..) |*it, i| {
                    it.selected = (i >= start and i <= end);
                }
            } else if (self.ctrl and (self.chooser == null or self.chooser.?.multiple)) {
                if (button == 0x110 and self.chooser == null and self.items.items[idx].selected) {
                    self.deselect_on_release = idx;
                } else {
                    self.items.items[idx].selected = !self.items.items[idx].selected;
                }
                self.selection_anchor = idx;
            } else {
                if (button == 0x110 and self.items.items[idx].selected) {
                    self.collapse_on_release = idx;
                } else {
                    for (self.items.items, 0..) |*it, i| it.selected = i == idx;
                }
                self.selection_anchor = idx;
            }
            if (self.chooser != null and !self.items.items[idx].is_dir) self.setChooserName(self.items.items[idx].name);
            if (self.chooser == null and button == 0x110 and self.items.items[idx].selected and !self.items.items[idx].missing) self.drag_origin = .{ .x = x, .y = y };
            if (single_click and !just_opened) self.open_on_release = idx;
        } else {
            // A background press starts a rubber-band selection; pressing
            // an item still starts an outgoing file drag.
            if (button == 0x110 and (self.chooser == null or self.chooser.?.multiple)) {
                for (self.items.items) |*it| it.selected_before_band = it.selected;
                self.selection_band = .{ .x = x, .y = y + @as(f64, @floatFromInt(self.scroll_y)), .toggle = self.ctrl, .extend = self.shift, .last_ms = now };
                self.last_click_index = null;
            }
            if (!self.ctrl and !self.shift) {
                for (self.items.items) |*it| it.selected = false;
                self.selection_anchor = null;
                self.focused_index = null;
            }
        }
        self.invalidate();
        return;
    }

    // Click outside location bar unfocuses it
    if (self.focus == .location_bar) {
        self.focus = .file_view;
        self.invalidate();
    }
}
