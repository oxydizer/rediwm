//! Pointer buttons in a Files window: `handleButton` routes a press or a
//! release to the dialog, the menu, the chrome or the file view.
const std = @import("std");
const App = @import("app.zig").App;
const Dialog = @import("app_model.zig").Dialog;
const scrollbar = @import("ui").widgets.scrollbar;
const header = @import("header.zig");
const nowMs = @import("app_draw.zig").nowMs;
const git_header_h = App.git_header_h;
const git_row_h = App.git_row_h;
const gitBranchRowCount = App.gitBranchRowCount;
const gitBranchRow = App.gitBranchRow;
const openFolderTab = @import("app_pointer.zig").openFolderTab;

pub fn handleButton(self: *App, button: u32, pressed: bool) void {
    if (@import("app_audio_playlist.zig").button(self, button, pressed)) return;
    if (button == 0x110 and !pressed and @import("app_audio_bar.zig").release(self)) return;
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
    // Middle click on a folder (or a place in the sidebar) opens it in a new tab.
    if (button == 0x112) {
        if (pressed and self.tabs_visible) openFolderTab(self);
        return;
    }
    if (button != 0x110 and button != 0x111) return;

    if (pressed) self.transfer_hover_priority = null;
    self.cancelWheel();
    if (button == 0x110) {
        if (self.dialog) |*dlg| {
            const consumed = switch (dlg.kind) {
                .properties => dlg.properties.?.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                .trash_properties => dlg.trash_properties.?.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                .open_with => dlg.applications.?.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                .trash_confirm => dlg.deletion.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                else => false,
            };
            if (consumed) return;
        }
    }
    if (!pressed) return releaseButton(self, button);

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
    if (self.dialog) |dlg| return dialogClick(self, dlg, x, y);

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
    if (button == 0x110 and self.inlineTorrentClick(x, y)) return;
    if (button == 0x110 and @import("app_torrent_browse.zig").checkClick(self, x, y)) return;
    if (button == 0x110 and @import("app_audio_bar.zig").click(self, x, y)) return;
    if (button == 0x110 and self.audioButtonClick(x, y)) return;
    if (button == 0x111) return secondaryClick(self, x, y);
    if (chromeClick(self, button, x, y)) return;

    // File view area
    if (y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.contentBottom())) and x < @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) {
        return contentPress(self, button, x, y, now);
    }

    // Click outside location bar unfocuses it
    if (self.focus == .location_bar) {
        self.focus = .file_view;
        self.invalidate();
    }
}

fn releaseButton(self: *App, button: u32) void {
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
            if (!self.ctrl and !self.shift and !self.alt and self.singleClickItemAt(self.mouse_x, self.mouse_y) == idx) {
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
}

fn dialogClick(self: *App, dlg: Dialog, x: f64, y: f64) void {
    if (dlg.kind == .properties) {
        const action = self.dialog.?.properties.?.click(self.w, self.h, x, y);
        self.propertiesAction(action);
        return;
    }
    if (dlg.kind == .trash_properties) {
        const action = self.dialog.?.trash_properties.?.click(self.w, self.h, x, y);
        self.trashPropertiesAction(action);
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
    const dh = self.smallDialogHeight();
    const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
    const dy = (@as(f64, @floatFromInt(self.h)) - dh) / 2.0;

    if (dlg.kind == .quit_jobs) {
        const button_w = (dw - 48) / 3;
        const choices = [_]@import("app_quit.zig").Choice{ .keep, .stop, .cancel };
        for (choices, 0..) |choice, i| {
            const left = dx + 16 + @as(f64, @floatFromInt(i)) * (button_w + 8);
            if (x >= left and x <= left + button_w and y >= dy + 84 and y <= dy + 112) {
                @import("app_quit.zig").choose(self, choice);
                return;
            }
        }
        if (x < dx or x > dx + dw or y < dy or y > dy + dh) @import("app_quit.zig").choose(self, .cancel);
        return;
    }
    if (dlg.kind == .conflict) {
        if (dlg.service_conflict and self.applyAllRect().contains(x, y)) {
            self.toggleApplyAll();
            return;
        }
        if (self.managerConflictCanMerge()) {
            const button_width = (dw - 56) / 4;
            if (x >= dx + 16 and x <= dx + 16 + button_width and y >= dy + 84 and y <= dy + 112) {
                self.resolveConflictDialog(.skip);
                return;
            }
            if (x >= dx + 24 + button_width and x <= dx + 24 + 2 * button_width and y >= dy + 84 and y <= dy + 112) {
                self.resolveConflictDialog(.merge);
                return;
            }
            if (x >= dx + 32 + 2 * button_width and x <= dx + 32 + 3 * button_width and y >= dy + 84 and y <= dy + 112) {
                self.resolveConflictDialog(.rename);
                return;
            }
            if (x >= dx + 40 + 3 * button_width and x <= dx + dw - 16 and y >= dy + 84 and y <= dy + 112) {
                self.resolveConflictDialog(.cancel);
                return;
            }
        } else {
            // Skip [dx + 16 .. dx + 16 + (dw - 48) / 3]
            if (x >= dx + 16 and x <= dx + 16 + (dw - 48) / 3 and y >= dy + 84 and y <= dy + 112) {
                self.resolveConflictDialog(.skip);
                return;
            }
            // Rename [dx + 24 + (dw - 48) / 3 .. dx + 24 + 2 * (dw - 48) / 3]
            if (x >= dx + 24 + (dw - 48) / 3 and x <= dx + 24 + 2 * (dw - 48) / 3 and y >= dy + 84 and y <= dy + 112) {
                self.resolveConflictDialog(.rename);
                return;
            }
            // Cancel [dx + 32 + 2 * (dw - 48) / 3 .. dx + dw - 16]
            if (x >= dx + 32 + 2 * (dw - 48) / 3 and x <= dx + dw - 16 and y >= dy + 84 and y <= dy + 112) {
                self.resolveConflictDialog(.cancel);
                return;
            }
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
        // A stray click must not cancel part of a transfer: a conflict
        // is answered with its buttons or keys only.
        if (dlg.kind == .conflict) return;
        self.closeDialog();
    }
}

/// The secondary button: the menu of a place, a file or the background.
fn secondaryClick(self: *App, x: f64, y: f64) void {
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
}

/// The header, the sidebar, column titles and scrollbars. True when the
/// press landed there (or anywhere in the sidebar), so the file view is not
/// asked.
fn chromeClick(self: *App, button: u32, x: f64, y: f64) bool {
    if (header.hit(self.w, self.inRepository(), x, y)) |action| {
        self.runHeader(action);
        return true;
    }
    if (header.field(self.w).contains(x, y)) {
        if (!self.search_visible and self.focus != .location_bar) {
            if (self.breadcrumbs(null, x)) |hit| {
                self.navigate(hit.path);
                return true;
            }
        }
        self.focus = if (self.search_visible) .search else .location_bar;
        self.placeCaret(x, self.shift);
        self.text_dragging = true;
        self.invalidate();
        return true;
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
            return true;
        }
    }
    if (button == 0x110) {
        if (self.sidebarHeaderAt(x, y)) |section| {
            const index = @backingInt(section);
            self.sidebar_expanded[index] = !self.sidebar_expanded[index];
            self.clampSidebarScroll();
            self.invalidate();
            return true;
        }
    }
    if (self.ejectAt(x, y)) |k| {
        self.ejectDevice(k);
        return true;
    }
    if (self.placeAt(x, y)) |index| {
        self.openPlace(index);
        return true;
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
            return true;
        }
    }
    if (x < @as(f64, @floatFromInt(self.sidebarWidth()))) return true;

    if (self.list_view and y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.viewTop()))) {
        for (self.columnLabels(), 0..) |_, i| {
            if (self.listColumn(i).contains(x, y)) {
                self.sortByColumn(i);
                return true;
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
            return true;
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
        return true;
    }
    return false;
}

/// A press in the file view: select, open, start a drag or a rubber band.
fn contentPress(self: *App, button: u32, x: f64, y: f64, now: i64) void {
    self.focus = .file_view;
    if (button == 0x110) {
        if (self.permissionHit(x, y)) |hit| {
            self.toggleInlinePermission(hit);
            return;
        }
    }
    if (self.itemAt(x, y)) |idx| {
        if (button == 0x110) {
            if (self.sizeButtonRect(idx)) |rect| {
                if (rect.contains(x, y) and self.folderSizeClickable(self.items.items[idx])) {
                    self.toggleFolderSize(idx);
                    return;
                }
            }
        }

        // Running an AppImage requires the second click even in single-click mode.
        const single_click = self.single_click_open and button == 0x110 and !self.ctrl and !self.shift and !self.alt and
            self.singleClickItemAt(x, y) == idx and !self.canRunAppImage(self.items.items[idx]);
        // A single click opens on release, so a double-click would open
        // the item twice: the second click only selects.
        const just_opened = single_click and self.last_open_index == idx and now - self.last_open_time < 400;
        // Icon clicks activate on release so they can still start a drag.
        if (!single_click and button == 0x110 and !self.ctrl and !self.shift and !self.alt and self.last_click_index == idx and (now - self.last_click_time < 400)) {
            self.activateDoubleClick(idx);
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
}
