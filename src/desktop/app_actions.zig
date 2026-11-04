//! Desktop actions: clipboard, context menus, renaming and deleting.

const std = @import("std");
const i18n = @import("i18n");
const App = @import("app.zig").App;
const grid = @import("grid.zig");
const watcher = @import("watcher.zig");
const rename = @import("rename.zig");
const deletion = @import("../delete_dialog.zig");
const trash_properties = @import("../files/trash_properties.zig");
const a = std.heap.c_allocator;

pub fn copy(self: *App, cut: bool) void {
    for (self.clipboard.items) |p| a.free(p);
    self.clipboard.clearRetainingCapacity();
    self.cut = cut;
    for (self.icons.items) |ic| if (ic.selected and ic.item.builtin == .none) {
        self.clipboard.append(a, a.dupe(u8, ic.item.path) catch continue) catch {};
    };
    self.host.publishSelection(self.clipboard.items, cut);
}

pub fn paste(self: *App) void {
    if (self.host.paste(self.worker.dir) == .local) self.pasteLocal();
}

pub fn pasteLocal(self: *App) void {
    for (self.clipboard.items) |path| {
        const dest = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, std.fs.path.basename(path) }) catch continue;
        defer a.free(dest);
        self.worker.enqueue(.{ .kind = if (self.cut) .move else .copy, .path = path, .value = dest });
    }
}

pub fn menuBuiltin(self: *const App) watcher.Builtin {
    const index = self.menu_icon orelse return .none;
    return if (index < self.icons.items.len) self.icons.items[index].item.builtin else .none;
}

pub fn menuLabels(self: *App) []const []const u8 {
    const icon_labels = [_]i18n.Message{ i18n.msg("Open"), i18n.msg("Open With…"), i18n.msg("Cut"), i18n.msg("Copy"), i18n.msg("Rename"), i18n.msg("Move to Trash"), i18n.msg("Properties"), i18n.msg("Allow Launching") };
    const desktop_labels = [_]i18n.Message{ i18n.msg("New Folder"), i18n.msg("New File"), i18n.msg("Add Application…"), i18n.msg("Paste"), i18n.msg("Refresh"), i18n.msg("Change Wallpaper"), i18n.msg("Desktop Settings") };
    const trash_labels = [_]i18n.Message{ i18n.msg("Open"), i18n.msg("Empty Trash…"), i18n.msg("Properties") };
    const messages: []const i18n.Message = switch (self.menuBuiltin()) {
        .home => icon_labels[0..1],
        .trash => &trash_labels,
        .none => if (self.menu_icon) |index| (if (self.untrustedLauncher(index)) &icon_labels else icon_labels[0 .. icon_labels.len - 1]) else &desktop_labels,
    };
    for (messages, 0..) |message, i| self.menu_labels[i] = message.get();
    return self.menu_labels[0..messages.len];
}

pub fn menuIcon(self: *App, row: usize) @import("ui").layout.IconId {
    const IconId = @import("ui").layout.IconId;
    if (self.menuBuiltin() != .none) return ([_]IconId{ .chevron_right, .trash, .view_list })[row];
    return if (self.menu_icon != null)
        ([_]IconId{ .chevron_right, .grid, .cut, .copy, .edit, .trash, .view_list, .checkmark })[row]
    else
        ([_]IconId{ .plus, .edit, .grid, .paste, .refresh, .display, .settings })[row];
}

pub fn menuHint(self: *App, row: usize) ?[]const u8 {
    if (self.menuBuiltin() != .none) return if (row == 0) "ENTER" else null;
    return if (self.menu_icon != null)
        ([_]?[]const u8{ "ENTER", null, "CTRL+X", "CTRL+C", "F2", "DELETE", null, null })[row]
    else if (row == 3) "CTRL+V" else null;
}

pub fn untrustedLauncher(self: *const App, index: usize) bool {
    return index < self.icons.items.len and self.icons.items[index].item.untrusted;
}

pub fn menuAction(self: *App, row: usize) void {
    const builtin = self.menuBuiltin();
    if (builtin != .none) {
        if (row == 0) self.openSelected() else if (builtin == .trash and row == 1) {
            self.deletion.deinit();
            self.deletion = .{ .permanent = true, .empty_trash = true };
            self.edit = .trash;
        } else if (builtin == .trash and row == 2) self.beginTrashProperties();
        return;
    }
    if (self.menu_icon != null) {
        switch (row) {
            0 => self.openSelected(),
            1 => self.beginEdit(.open_with),
            2 => self.copy(true),
            3 => self.copy(false),
            4 => self.beginEdit(.rename),
            5 => self.beginEdit(.trash),
            6 => self.beginEdit(.properties),
            // Allow Launching: the user marks the launcher executable,
            // after which it shows and runs as the application it names.
            7 => for (self.icons.items) |ic| if (ic.selected and ic.removed == null and ic.item.untrusted) {
                self.worker.enqueue(.{ .kind = .trust, .path = ic.item.path });
            },
            else => {},
        }
    } else {
        switch (row) {
            0 => self.beginEdit(.folder),
            1 => self.beginEdit(.file),
            2 => self.beginEdit(.add_app),
            3 => self.paste(),
            4 => self.worker.requestRefresh(),
            5 => self.host.openAppearance() catch |err| switch (err) {
                error.Unsupported => self.worker.enqueue(.{ .kind = .settings, .path = "" }),
                else => {
                    var message: [512]u8 = undefined;
                    self.notify("{s}", .{i18n.fmt(&message, i18n.tr("Could not open Appearance: {error}"), .{ .@"error" = @errorName(err) }) catch return});
                },
            },
            6 => self.host.openDesktopSettings() catch |err| switch (err) {
                error.Unsupported => self.worker.enqueue(.{ .kind = .settings, .path = "" }),
                else => {
                    var message: [512]u8 = undefined;
                    self.notify("{s}", .{i18n.fmt(&message, i18n.tr("Could not open Desktop Settings: {error}"), .{ .@"error" = @errorName(err) }) catch return});
                },
            },
            else => {},
        }
    }
}

pub fn closePicker(self: *App) void {
    if (self.applications) |*picker| picker.deinit();
    self.applications = null;
}

pub fn pickerAction(self: *App, action: @import("../files/open_with.zig").Action) void {
    switch (action) {
        .cancel => {
            self.closePicker();
            self.edit = .none;
        },
        .open => self.finishEdit(),
        .none => {},
    }
    self.invalidate();
}

pub fn beginEdit(self: *App, kind: @FieldType(App, "edit")) void {
    self.deletion.deinit();
    self.closePicker();
    self.closeTrashCard();
    self.edit = kind;
    if (kind == .folder) {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, i18n.tr("New Folder") }) catch {
            self.edit = .none;
            return;
        };
        defer a.free(path);
        self.folder_token +%= 1;
        self.worker.enqueue(.{ .kind = .folder, .path = path, .token = self.folder_token });
        return;
    }
    if (kind == .trash) {
        for (self.icons.items) |ic| {
            if (!ic.selected or ic.removed != null or ic.item.builtin != .none) continue;
            self.deletion.add(ic.item.path, ic.item.name, ic.item.folder, ic.item.bytes, if (self.deletion.paths.items.len == 0) ic.item.icon else null) catch {
                self.deletion.deinit();
                self.edit = .none;
                return;
            };
        }
        if (self.deletion.paths.items.len == 0) self.edit = .none;
        return;
    }
    if (kind == .add_app) self.applications = @import("../files/open_with.zig").State.initShortcuts(a, self.catalog);
    self.choice = 0;
    if (kind == .add_app or kind == .open_with) self.worker.enqueue(.{ .kind = .catalog, .path = "" });
    self.edit_text.clearRetainingCapacity();
    if (kind == .rename) {
        for (self.icons.items, 0..) |ic, i| if (ic.selected and ic.removed == null and ic.item.builtin == .none) {
            self.rename_editor.begin(std.fs.path.basename(ic.item.path), ic.item.folder) catch {
                self.edit = .none;
                return;
            };
            self.deselect();
            self.icons.items[i].selected = true;
            self.pressed = null;
            self.dragging = false;
            self.rubber = false;
            self.last_icon = null;
            return;
        };
        self.edit = .none;
    }
    if (kind == .file) self.edit_text.appendSlice(a, i18n.tr("New File")) catch {};
}

/// Opens the Trash's Properties window for the Trash icon the menu belongs to.
pub fn beginTrashProperties(self: *App) void {
    const index = self.menu_icon orelse return;
    if (index >= self.icons.items.len or self.icons.items[index].item.builtin != .trash) return;
    self.deletion.deinit();
    self.closePicker();
    self.closeTrashCard();
    self.trash_card = trash_properties.State.init(self.icons.items[index].item.path, self.worker.wake_main) catch {
        self.notify("{s}", .{i18n.tr("Could not read file properties")});
        return;
    };
    self.edit = .trash_properties;
    self.invalidate();
}

pub fn closeTrashCard(self: *App) void {
    if (self.trash_card) |*card| card.deinit();
    self.trash_card = null;
}

pub fn trashPropertiesAction(self: *App, action: trash_properties.Action) void {
    switch (action) {
        .none => {},
        .close => {
            self.closeTrashCard();
            self.edit = .none;
        },
        // The Trash icon stays selected under the window, as Open from its menu expects.
        .open => {
            self.closeTrashCard();
            self.edit = .none;
            self.openSelected();
        },
    }
    self.invalidate();
}

pub fn deleteAction(self: *App, action: deletion.Action) void {
    switch (action) {
        .cancel => {
            self.deletion.deinit();
            self.edit = .none;
        },
        .toggle => {
            if (self.deletion.empty_trash) return;
            self.deletion.permanent = !self.deletion.permanent;
            self.deletion.focus = .toggle;
        },
        .confirm => self.finishEdit(),
        .none => {},
    }
    self.invalidate();
}

pub fn finishEdit(self: *App) void {
    if (self.edit == .folder) return;
    if (self.edit == .rename) {
        if (self.renameGeometry() == null) {
            self.edit = .none;
            return;
        }
        self.edit_text.clearRetainingCapacity();
        self.edit_text.appendSlice(a, self.rename_editor.value()) catch return;
    }
    if (self.edit == .add_app) {
        const entry = if (self.applications) |*picker| picker.shortcut() orelse return else return;
        const dest = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, std.fs.path.basename(entry.desktop_file_path) }) catch return;
        defer a.free(dest);
        self.worker.enqueue(.{ .kind = .copy, .path = entry.desktop_file_path, .value = dest });
        self.closePicker();
        self.edit = .none;
        return;
    }
    if (self.edit == .open_with and self.choiceEntry(self.choice) == null) return;
    if (self.edit == .file or self.edit == .rename) {
        const name = self.edit_text.items;
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return;
    }
    defer self.edit = .none;
    if (self.edit == .trash) {
        if (self.deletion.empty_trash) {
            self.worker.enqueue(.{ .kind = .empty_trash, .path = "" });
        } else {
            for (self.deletion.paths.items) |path| {
                self.worker.enqueue(.{ .kind = if (self.deletion.permanent) .delete else .trash, .path = path });
            }
        }
        self.deletion.deinit();
        return;
    }
    if (self.edit == .open_with) {
        const entry = self.choiceEntry(self.choice) orelse return;
        for (self.icons.items) |ic| {
            if (ic.selected) self.worker.enqueue(.{ .kind = .launch, .path = ic.item.path, .value = entry.exec, .terminal = entry.terminal, .launch_file = true });
        }
        return;
    }
    if (self.edit == .properties) return;
    const name = self.edit_text.items;
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return;
    const dest = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, name }) catch return;
    defer a.free(dest);
    if (self.edit == .rename) {
        for (self.icons.items) |ic| if (ic.selected) {
            if (std.mem.eql(u8, ic.item.path, dest)) return;
            self.worker.enqueue(.{ .kind = .rename, .path = ic.item.path, .value = dest });
            break;
        };
    } else {
        self.worker.enqueue(.{ .kind = .file, .path = dest });
    }
}

pub fn choiceEntry(self: *App, index: usize) ?@import("dotdesktop.zig").parser.AppEntry {
    var n: usize = 0;
    for (self.catalog) |entry| {
        if (self.edit_text.items.len > 0 and std.ascii.findIgnoreCase(entry.name, self.edit_text.items) == null) continue;
        if (n == index) return entry;
        n += 1;
    }
    return null;
}
