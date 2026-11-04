//! Files menus: header actions, context menus and their geometry.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const archive = @import("archive.zig");
const c = @import("c.zig").api;
const header = @import("header.zig");
const context_menu = @import("ui").context_menu;
const IconId = @import("ui").layout.IconId;
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const places_start = App.places_start;
const MenuKind = @import("app_model.zig").MenuKind;
const PlaceAction = @import("app_model.zig").PlaceAction;
const FileAction = @import("app_model.zig").FileAction;
const nowMs = @import("app_draw.zig").nowMs;
const placePinnable = App.placePinnable;

pub fn runHeader(self: *App, action: header.Action) void {
    if (!self.toolbarButtonEnabled(action)) return;
    if (self.chooser != null) switch (action) {
        .cut, .copy, .paste, .trash => return,
        .new => {
            self.openNewFolderDialog();
            return;
        },
        else => {},
    };
    if ((action == .cut or action == .copy or action == .trash) and !self.hasSelection()) return;
    self.focus = .file_view;
    switch (action) {
        .back => self.back(),
        .forward => self.forward(),
        .up => self.up(),
        .refresh => self.refresh(),
        .cut => self.cutSelected(),
        .copy => self.copySelected(),
        .paste => self.paste_requested = true,
        .trash => self.openTrashConfirmDialog(),
        .git_view => {
            self.setGitView(!self.git_view);
        },
        .grid, .list => {
            if (self.repository() != null) return;
            self.list_view = action == .list;
            self.savePreferences();
            self.last_click_index = null;
            self.clampScroll();
            if (self.focused_index) |idx| self.revealIndex(idx);
        },
        .new, .sort, .filter => {
            const r = header.rect(self.w, self.inRepository(), action);
            self.openMenu(switch (action) {
                .new => .new,
                .sort => .sort,
                else => .filter,
            }, r.x, r.y + r.h + 4);
        },
        .search => {
            self.search_visible = !self.search_visible;
            if (self.search_visible) {
                self.focus = .search;
                self.search.select_all = true;
            } else {
                self.search.text.clearRetainingCapacity();
                self.search.cursor = 0;
                self.rebuildView();
            }
        },
    }
    self.invalidate();
}

pub fn menuRowHeight(self: *App) usize {
    if (self.isContextMenu()) {
        // Keep all actions reachable at the client's minimum height.
        const available: usize = @intCast(@max(0, self.h - 8));
        const spacing = 2 * self.menuPadding() + self.menuSeparatorSpace();
        return @min(context_menu.row_height, (available -| spacing) / self.menuLabels().len);
    }
    return if (self.menu == .sort) 24 else 30;
}

pub fn isContextMenu(self: *App) bool {
    return self.menu == .file or self.menu == .background or self.menu == .sidebar or self.menu == .device;
}

pub fn menuWidth(self: *App) f64 {
    return if (self.isContextMenu()) context_menu.width else 220;
}

pub fn menuPadding(_: *App) usize {
    return context_menu.padding;
}

pub fn menuSeparatorBefore(self: *App, row: usize) bool {
    return switch (self.menu orelse return false) {
        .file => switch (self.fileActions()[row]) {
            .cut, .extract, .restore, .properties => true,
            else => false,
        },
        .background => row == 2,
        .sidebar => self.placeActions()[row] == .properties,
        else => false,
    };
}

pub fn menuSeparatorSpace(self: *App) usize {
    var count: usize = 0;
    for (0..self.menuLabels().len) |row| {
        if (self.menuSeparatorBefore(row)) count += 7;
    }
    return count;
}

pub fn menuHeight(self: *App) f64 {
    return @floatFromInt(self.menuLabels().len * self.menuRowHeight() +
        2 * self.menuPadding() + self.menuSeparatorSpace());
}

// Painting and hit testing share the row geometry, including separator gaps.
pub fn menuRowRect(self: *App, row: usize) header.Rect {
    var offset = self.menuPadding() + row * self.menuRowHeight();
    for (0..row + 1) |i| {
        if (self.menuSeparatorBefore(i)) offset += 7;
    }
    const pad: f64 = @floatFromInt(self.menuPadding());
    return .{
        .x = self.menu_x + pad,
        .y = self.menu_y + @as(f64, @floatFromInt(offset)),
        .w = self.menuWidth() - 2 * pad,
        .h = @floatFromInt(self.menuRowHeight()),
    };
}

pub fn menuIcon(self: *App, row: usize) ?IconId {
    // Reuse the shell glyphs until dedicated file-action artwork is available.
    return switch (self.menu orelse return null) {
        .file => self.fileActions()[row].icon(),
        .background => switch (self.backgroundMenu()) {
            .refresh_only => .refresh,
            .trash => ([_]IconId{ .trash, .undo, .refresh })[row],
            .normal => ([_]IconId{ .plus, .edit, .paste, .refresh })[row],
        },
        else => null,
    };
}

/// What the empty-space menu offers: Recent and archives only refresh, the
/// Trash view manages its contents, other folders create and paste.
pub fn backgroundMenu(self: *App) enum { normal, refresh_only, trash } {
    if (self.history.archive_len > 0 or self.isRecent()) return .refresh_only;
    return switch (self.trashRelation()) {
        .none => .normal,
        .root => .trash,
        .inside => .refresh_only,
    };
}

/// Restore stays visible but faded when no selected entry has the metadata
/// to say where it belongs.
pub fn menuDisabled(self: *App, row: usize) bool {
    return switch (self.menu orelse return false) {
        .file => row < self.fileActions().len and self.fileActions()[row] == .restore and !self.trash_restorable,
        else => false,
    };
}

// Faint shortcut text shown on the right of a context-menu row.
pub fn menuHint(self: *App, row: usize) ?[]const u8 {
    const label = self.menuLabels()[row];
    if (std.mem.eql(u8, label, tr("Properties"))) return "ALT+ENTER";
    if (self.menu != .file and self.menu != .background) return null;
    const hints = [_][2][]const u8{
        .{ tr("Open"), "CTRL+O" },
        .{ tr("Cut"), "CTRL+X" },
        .{ tr("Copy"), "CTRL+C" },
        .{ tr("Paste"), "CTRL+V" },
        .{ tr("Rename"), "F2" },
        .{ tr("Move to Trash"), "DELETE" },
        .{ tr("Refresh"), "F5" },
    };
    for (hints) |hint| {
        if (std.mem.eql(u8, label, hint[0])) return hint[1];
    }
    return null;
}

pub fn hasSizeSelection(self: *App) bool {
    for (self.items.items) |item| {
        if (item.selected and item.is_dir and !item.is_symlink and !item.transfer_stub) return true;
    }
    return false;
}

pub fn selectedArchive(self: *App) ?[]const u8 {
    if (self.chooser != null or self.history.archive_len > 0) return null;
    var selected: ?[]const u8 = null;
    for (self.items.items) |item| {
        if (!item.selected) continue;
        if (selected != null or item.is_dir or item.is_broken or item.missing or !archive.candidate(item.name)) return null;
        selected = item.path;
    }
    return selected;
}

pub fn selectedAppImage(self: *App) ?[]const u8 {
    if (self.chooser != null or self.history.archive_len > 0 or self.transfer_view.active) return null;
    var selected: ?[]const u8 = null;
    for (self.items.items) |item| {
        if (!item.selected) continue;
        if (selected != null or item.is_dir or item.is_broken or item.missing or item.transfer_stub or !@import("appimage.zig").candidate(item.name)) return null;
        selected = item.path;
    }
    return selected;
}

pub fn fileActions(self: *App) []const FileAction {
    var only_transfers = false;
    for (self.items.items) |item| {
        if (!item.selected) continue;
        if (!item.transfer_stub) {
            only_transfers = false;
            break;
        }
        only_transfers = true;
    }
    if (only_transfers) return &.{.open};
    if (self.history.archive_len > 0) return &.{.open};
    // Entries here are already deleted: put back or remove for good, but never
    // cut, rename, paste or trash again. Folders inside a trashed folder have
    // no metadata, so they only open, copy and show properties.
    switch (self.trashRelation()) {
        .root => return &.{ .open, .copy, .restore, .delete_permanently, .properties },
        .inside => return &.{ .open, .copy, .properties },
        .none => {},
    }
    if (self.isRecent()) {
        if (self.selectedAppImage() != null) return &.{ .open, .open_with, .add_application, .cut, .copy, .rename, .trash, .properties };
        if (self.selectedArchive() != null) return &.{ .open, .open_with, .extract, .extract_to, .cut, .copy, .rename, .trash, .properties };
        if (self.canOpenWith()) return &.{ .open, .open_with, .cut, .copy, .rename, .trash, .properties };
        return &.{ .open, .cut, .copy, .rename, .trash, .properties };
    }
    if (self.selectedAppImage() != null) return &.{ .open, .open_with, .add_application, .cut, .copy, .paste, .rename, .trash, .properties };
    if (self.selectedArchive() != null) return &.{ .open, .open_with, .extract, .extract_to, .cut, .copy, .paste, .rename, .trash, .properties };
    if (self.canOpenWith()) return &.{ .open, .open_with, .cut, .copy, .paste, .rename, .trash, .properties };
    if (self.hasSizeSelection()) return &.{ .open, .cut, .copy, .paste, .rename, .trash, .size, .properties };
    return &.{ .open, .cut, .copy, .paste, .rename, .trash, .properties };
}

pub fn placeActions(self: *App) []const PlaceAction {
    const new_window = self.chooser == null;
    return switch (self.rowKind(self.menu_place)) {
        .builtin => |index| switch (index) {
            1 => if (new_window) &.{ .open, .open_window, .empty_trash, .properties } else &.{ .open, .empty_trash, .properties },
            2 => if (new_window) &.{ .open, .open_window } else &.{.open},
            else => if (placePinnable(index))
                (if (new_window) &.{ .open, .open_window, .unpin, .properties } else &.{ .open, .unpin, .properties })
            else
                (if (new_window) &.{ .open, .open_window, .properties } else &.{ .open, .properties }),
        },
        .pin => |j| if (new_window and self.pins.items.items[j].kind == .dir)
            &.{ .open, .open_window, .remove_pin, .properties }
        else
            &.{ .open, .remove_pin, .properties },
        .device => if (self.deviceAt(self.menu_place)) |volume|
            (if (volume.mount == null) &.{.mount} else if (new_window) &.{ .open, .open_window, .eject } else &.{ .open, .eject })
        else
            &.{},
    };
}

pub fn menuLabels(self: *App) []const []const u8 {
    const messages: []const i18n.Message = switch (self.menu orelse return &.{}) {
        .new => &.{ i18n.msg("New Folder"), i18n.msg("New File") },
        .sort => &.{ i18n.msg("Name: A to Z"), i18n.msg("Name: Z to A"), i18n.msg("Largest first"), i18n.msg("Newest first"), i18n.msg("Type: A to Z"), i18n.msg("Smallest first"), i18n.msg("Oldest first"), i18n.msg("Type: Z to A") },
        .filter => if (self.repository() != null)
            &.{ i18n.msg("Folders only"), i18n.msg("Show hidden files"), i18n.msg("Show changed files"), i18n.msg("Show full paths") }
        else
            &.{ i18n.msg("Folders only"), i18n.msg("Show hidden files") },
        .file => {
            const actions = self.fileActions();
            for (actions, 0..) |action, i| self.file_menu_labels[i] = action.label();
            return self.file_menu_labels[0..actions.len];
        },
        .sidebar, .device => {
            const actions = self.placeActions();
            for (actions, 0..) |action, i| self.place_menu_labels[i] = action.label();
            return self.place_menu_labels[0..actions.len];
        },
        .background => switch (self.backgroundMenu()) {
            .refresh_only => &.{i18n.msg("Refresh")},
            .trash => &.{ i18n.msg("Empty Trash…"), i18n.msg("Restore All"), i18n.msg("Refresh") },
            .normal => &.{ i18n.msg("New Folder"), i18n.msg("New File"), i18n.msg("Paste"), i18n.msg("Refresh") },
        },
        .chooser_filter => return self.chooser_filter_labels.items,
    };
    for (messages, 0..) |message, i| self.menu_label_text[i] = message.get();
    return self.menu_label_text[0..messages.len];
}

pub fn openMenu(self: *App, kind: MenuKind, x: f64, y: f64) void {
    self.menu = kind;
    if (kind == .file) self.refreshTrashRestorable();
    const height = self.menuHeight();
    self.menu_x = std.math.clamp(x, 4, @max(4, @as(f64, @floatFromInt(self.w)) - self.menuWidth() - 4));
    self.menu_y = std.math.clamp(y, 4, @max(4, @as(f64, @floatFromInt(self.h)) - height - 4));
    self.menu_selected = 0;
    self.last_click_index = null;
    self.invalidate();
}

pub fn menuHit(self: *App, x: f64, y: f64) ?usize {
    for (0..self.menuLabels().len) |row| {
        if (self.menuRowRect(row).contains(x, y)) return row;
    }
    return null;
}

pub fn runMenu(self: *App, row: usize) void {
    const kind = self.menu orelse return;
    const place_action: ?PlaceAction = if ((kind == .sidebar or kind == .device) and row < self.placeActions().len) self.placeActions()[row] else null;
    const file_action: ?FileAction = if (kind == .file and row < self.fileActions().len) self.fileActions()[row] else null;
    if (file_action == .restore and !self.trash_restorable) {
        self.setStatusNotice(tr("Original location unknown: these items have no Trash information"), true);
        return;
    }
    self.menu = null;
    switch (kind) {
        .sidebar, .device => if (place_action) |action| switch (action) {
            .open => self.openPlace(self.menu_place),
            .open_window => self.openPlaceWindow(self.menu_place),
            .empty_trash => self.openEmptyTrashDialog(),
            .unpin => {
                self.unpinned_places |= @as(u8, 1) << @as(u3, @intCast(self.menu_place - places_start));
                self.sidebar_scroll = std.math.clamp(self.sidebar_scroll, 0, @max(0, self.sidebarExtent() - (self.h - self.sidebarFooter())));
                self.nav_hover = .{};
                self.savePreferences();
            },
            .remove_pin => {
                self.removePin(self.pinIndex(self.menu_place).?);
            },
            .properties => {
                var buf: [4096]u8 = undefined;
                // The Trash (built-in row 1) is not a folder with permissions: it has its own window.
                const trash_row = switch (self.rowKind(self.menu_place)) {
                    .builtin => |index| index == 1,
                    else => false,
                };
                if (trash_row) self.openTrashProperties() else if (self.placePath(self.menu_place, &buf)) |path| self.openProperties(path, null);
            },
            .mount => self.activateDevice(self.menu_place - self.deviceBase()),
            .eject => self.ejectDevice(self.menu_place - self.deviceBase()),
        },
        .chooser_filter => {
            if (row < self.chooser.?.filters.len) self.chooser.?.filter_index = row;
            self.rebuildView();
        },
        .new => switch (row) {
            0 => self.openNewFolderDialog(),
            1 => self.openNewFileDialog(),
            else => {},
        },
        .sort => {
            if (row < 8) self.setSort(@enumFromInt(row));
            self.rebuildView();
            self.savePreferences();
            self.scroll_y = 0;
            if (self.focused_index) |idx| self.revealIndex(idx);
            self.startSortFeedback(nowMs());
        },
        .filter => {
            if (row == 0) {
                self.folders_only = !self.folders_only;
                self.scroll_y = 0;
                self.rebuildView();
            } else if (row == 1) {
                self.toggleHidden();
            } else if (row == 2 and self.repository() != null) {
                self.changed_only = !self.changed_only;
                self.scroll_y = 0;
                self.rebuildView();
            } else if (row == 3 and self.repository() != null) {
                self.full_paths = !self.full_paths;
                self.rebuildView();
            }
        },
        .file => if (file_action) |action| switch (action) {
            .open => self.activateSelected(),
            .open_with => self.openWithDialog(),
            .add_application => self.addApplication(),
            .extract => if (self.selectedArchive()) |path| self.startExtraction(path, std.fs.path.dirname(path) orelse "/"),
            .extract_to => self.chooseExtractionFolder(),
            .cut => self.cutSelected(),
            .copy => self.copySelected(),
            .paste => self.paste_requested = true,
            .rename => self.openRenameDialog(),
            .trash, .delete_permanently => self.openTrashConfirmDialog(),
            .restore => self.restoreSelected(),
            .size => self.calculateSizeSelected(),
            .properties => self.openSelectedProperties(),
        },
        .background => switch (self.backgroundMenu()) {
            .refresh_only => self.refresh(),
            .trash => switch (row) {
                0 => self.openEmptyTrashDialog(),
                1 => self.restoreAll(),
                2 => self.refresh(),
                else => {},
            },
            .normal => switch (row) {
                0 => self.openNewFolderDialog(),
                1 => self.openNewFileDialog(),
                2 => self.paste_requested = true,
                3 => self.refresh(),
                else => {},
            },
        },
    }
    self.invalidate();
}

pub fn renderMenu(self: *App, cr: *c.cairo_t) void {
    const labels = self.menuLabels();
    const context = self.isContextMenu();
    const width = self.menuWidth();
    const height = self.menuHeight();
    context_menu.frame(cr, .{ .x = self.menu_x, .y = self.menu_y, .w = width, .h = height }, context);
    for (labels, 0..) |label, i| {
        const row = self.menuRowRect(i);
        const checked = (self.menu == .sort and i == @intFromEnum(self.effectiveSort())) or
            (self.menu == .filter and ((i == 0 and self.folders_only) or (i == 1 and self.show_hidden) or (i == 2 and self.changed_only) or (i == 3 and self.full_paths)));
        context_menu.row(cr, .{ .x = row.x, .y = row.y, .w = row.w, .h = row.h }, .{
            .label = label,
            .icon = self.menuIcon(i) orelse if (checked) @as(?IconId, .checkmark) else null,
            .hint = if (context) self.menuHint(i) else null,
            .selected = self.menu_selected == i,
            .separator = self.menuSeparatorBefore(i),
            .disabled = self.menuDisabled(i),
        }, context);
    }
}
