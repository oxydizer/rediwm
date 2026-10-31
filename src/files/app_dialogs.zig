//! Files dialogs: opening, confirming and keyboard handling of the modal cards.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const git = @import("git.zig");
const ops_mod = @import("ops.zig");
const icons = @import("../icon_cache.zig");
const deletion = @import("../delete_dialog.zig");
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const ViewItem = @import("app_model.zig").ViewItem;
const Dialog = @import("app_model.zig").Dialog;

pub fn closeDialog(self: *App) void {
    self.text_dragging = false;
    self.edit_revision += 1;
    if (self.dialog) |*dlg| {
        dlg.deletion.deinit();
        if (dlg.applications) |*apps| apps.deinit();
        if (dlg.properties) |*props| props.deinit();
        dlg.edit.text.deinit(self.allocator);
        if (dlg.target_path) |tp| self.allocator.free(tp);
        if (dlg.conflict_name) |cn| self.allocator.free(cn);
        self.dialog = null;
        self.invalidate();
    }
}

pub fn openProperties(self: *App, path: []const u8, preview: ?icons.Entry) void {
    const state = properties.State.init(self.allocator, path, preview) catch {
        self.setStatusNotice(tr("Could not read file properties"), true);
        return;
    };
    self.closeDialog();
    self.dialog = .{ .kind = .properties, .title = tr("Properties"), .properties = state };
    self.invalidate();
}

pub fn openSelectedProperties(self: *App) void {
    if (self.history.archive_len > 0) return;
    var selected: ?ViewItem = null;
    for (self.items.items) |item| {
        if (!item.selected or item.missing) continue;
        if (selected != null) {
            self.setStatusNotice(tr("Select one item to view its properties"), false);
            return;
        }
        selected = item;
    }
    if (selected) |item| self.openProperties(item.path, self.itemIcon(item, 48 * self.scale));
}

pub fn propertiesAction(self: *App, action: properties.Action) void {
    switch (action) {
        .none => self.invalidate(),
        .close => {
            const changed = self.dialog.?.properties.?.changed;
            self.closeDialog();
            if (changed) self.refresh();
        },
        .open => {
            const props = &self.dialog.?.properties.?;
            const path = self.allocator.dupe(u8, props.path) catch return;
            defer self.allocator.free(path);
            const folder = props.isDirectory();
            const changed = props.changed;
            self.closeDialog();
            if (folder) self.navigate(path) else {
                if (changed) self.refresh();
                self.openFile(path);
            }
        },
    }
}

pub fn canOpenWith(self: *const App) bool {
    if (self.history.archive_len > 0) return false;
    if (self.chooser != null) return false;
    var found = false;
    for (self.items.items) |item| {
        if (!item.selected) continue;
        if (item.is_dir or item.missing or item.is_broken) return false;
        found = true;
    }
    return found;
}

pub fn openWithDialog(self: *App) void {
    if (!self.canOpenWith()) return;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(self.allocator);
    for (self.items.items) |item| {
        if (item.selected) paths.append(self.allocator, item.path) catch return;
    }
    const state = open_with.State.init(self.allocator, paths.items) catch {
        self.setStatusNotice(tr("Could not load applications"), true);
        return;
    };
    self.closeDialog();
    self.dialog = .{ .kind = .open_with, .title = tr("Open With"), .applications = state };
    self.invalidate();
}

pub fn openWithAction(self: *App, action: open_with.Action) void {
    switch (action) {
        .cancel => self.closeDialog(),
        .open => {
            if (self.dialog.?.applications.?.open()) {
                const message = self.dialog.?.applications.?.message;
                if (message.len == 0) {
                    for (self.dialog.?.applications.?.apps.paths) |path| self.worker.recordOpened(path);
                }
                self.closeDialog();
                if (message.len > 0) self.setStatusNotice(message, true);
                self.refresh();
            }
        },
        .none => {},
    }
    self.invalidate();
}

pub fn openNewFolderDialog(self: *App) void {
    if (self.isRecent() or self.history.archive_len > 0) return;
    self.closeDialog();
    var dlg = Dialog{
        .kind = .new_folder,
        .title = tr("New Folder"),
    };
    dlg.edit.text.appendSlice(self.allocator, tr("New Folder")) catch return;
    dlg.edit.cursor = dlg.edit.text.items.len;
    dlg.edit.select_all = true;
    self.dialog = dlg;
    self.invalidate();
}

pub fn openNewBranchDialog(self: *App) void {
    self.closeDialog();
    self.dialog = Dialog{ .kind = .new_branch, .title = tr("New Branch") };
    self.invalidate();
}

pub fn switchBranch(self: *App, repo: git.Repository, name: []const u8, create: bool) void {
    const outcome = git.switchBranch(self.allocator, self.io, self.environ, repo.directory, name, create);
    var buf: [256]u8 = undefined;
    if (outcome.ok) {
        const msg = i18n.fmt(&buf, if (create) tr("Created and switched to {name}") else tr("Switched to {name}"), .{ .name = name }) catch tr("Switched branch");
        self.setStatusNotice(msg, false);
    } else {
        self.setStatusNotice(outcome.text(), true);
    }
    self.refresh();
}

pub fn openNewFileDialog(self: *App) void {
    if (self.isRecent() or self.history.archive_len > 0) return;
    self.closeDialog();
    var dlg = Dialog{
        .kind = .new_file,
        .title = tr("New File"),
    };
    dlg.edit.text.appendSlice(self.allocator, tr("New File.txt")) catch return;
    dlg.edit.cursor = dlg.edit.text.items.len;
    dlg.edit.select_all = true;
    self.dialog = dlg;
    self.invalidate();
}

pub fn openRenameDialog(self: *App) void {
    if (self.history.archive_len > 0) return;
    const idx = self.focused_index orelse blk: {
        for (self.items.items, 0..) |it, i| {
            if (it.selected) break :blk i;
        }
        return;
    };
    if (idx >= self.items.items.len) return;
    const item = self.items.items[idx];
    if (item.missing) return;

    self.closeDialog();
    const target_path = self.allocator.dupe(u8, item.path) catch return;
    var dlg = Dialog{
        .kind = .rename,
        .title = tr("Rename"),
        .target_path = target_path,
    };
    dlg.edit.text.appendSlice(self.allocator, item.name) catch {
        self.allocator.free(target_path);
        return;
    };
    // Select the stem, so typing keeps the extension; folders and dotfiles
    // select the whole name.
    const dot = std.mem.lastIndexOfScalar(u8, item.name, '.') orelse item.name.len;
    const end = if (!item.is_dir and dot > 0) dot else item.name.len;
    dlg.edit.cursor = end;
    dlg.edit.anchor = 0;
    self.dialog = dlg;
    self.invalidate();
}

pub fn openEmptyTrashDialog(self: *App) void {
    self.closeDialog();
    self.dialog = .{
        .kind = .trash_confirm,
        .title = tr("Empty Trash?"),
        .deletion = .{ .permanent = true, .empty_trash = true },
    };
    self.invalidate();
}

pub fn openTrashConfirmDialog(self: *App) void {
    self.openTrashConfirmDialogWithMode(false);
}

pub fn openTrashConfirmDialogWithMode(self: *App, permanent: bool) void {
    if (self.history.archive_len > 0) return;
    var count: usize = 0;
    for (self.items.items) |it| {
        if (it.selected and !it.missing) count += 1;
    }
    if (count == 0) {
        if (self.focused_index) |idx| {
            if (idx < self.items.items.len and !self.items.items[idx].missing) {
                self.items.items[idx].selected = true;
                count = 1;
            }
        }
    }
    if (count == 0) return;

    self.closeDialog();
    self.dialog = Dialog{
        .kind = .trash_confirm,
        .title = tr("Move to Trash?"),
        .deletion = .{ .permanent = permanent },
    };
    for (self.items.items) |it| {
        if (!it.selected or it.missing) continue;
        const preview = if (self.dialog.?.deletion.paths.items.len == 0) self.itemIcon(it, 64 * self.scale) else null;
        self.dialog.?.deletion.add(it.path, it.name, it.is_dir and !it.is_symlink, it.bytes, preview) catch {
            self.closeDialog();
            self.setStatusNotice(tr("Unable to prepare deletion"), true);
            return;
        };
    }
    self.invalidate();
}

pub fn openConflictDialog(self: *App, conflict_name: []const u8) void {
    self.closeDialog();
    self.dialog = Dialog{
        .kind = .conflict,
        .title = tr("File Conflict"),
        .conflict_name = self.allocator.dupe(u8, conflict_name) catch null,
    };
    self.invalidate();
}

pub fn confirmDialog(self: *App) void {
    const dlg = self.dialog orelse return;
    switch (dlg.kind) {
        .transfers => {},
        .torrent_source, .torrent_destination => self.confirmTorrent(),
        .terminal_close => self.terminalConfirmClose(),
        .open_with => self.openWithAction(.open),
        .properties => {},
        .new_folder => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            ops_mod.createFolder(self.allocator, self.history.current, name) catch |err| {
                const msg = switch (err) {
                    error.PathAlreadyExists => tr("Folder already exists"),
                    error.AccessDenied => tr("Permission denied"),
                    error.EmptyName => tr("Name cannot be empty"),
                    error.InvalidCharacter => tr("Invalid characters in name"),
                    error.ReservedName => tr("Reserved folder name"),
                    else => tr("Failed to create folder"),
                };
                self.setStatusNotice(msg, true);
                self.closeDialog();
                return;
            };
            self.closeDialog();
            self.setStatusNotice(tr("Folder created"), false);
            self.refresh();
        },
        .new_branch => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            // `name` borrows the dialog's text: use it before closing.
            if (self.repository()) |repo| self.switchBranch(repo, name, true);
            self.closeDialog();
        },
        .new_file => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            ops_mod.createFile(self.allocator, self.history.current, name) catch |err| {
                const msg = switch (err) {
                    error.PathAlreadyExists => tr("File already exists"),
                    error.AccessDenied => tr("Permission denied"),
                    error.EmptyName => tr("Name cannot be empty"),
                    error.InvalidCharacter => tr("Invalid characters in name"),
                    error.ReservedName => tr("Reserved file name"),
                    else => tr("Failed to create file"),
                };
                self.setStatusNotice(msg, true);
                self.closeDialog();
                return;
            };
            self.closeDialog();
            self.setStatusNotice(tr("File created"), false);
            self.refresh();
        },
        .rename => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            const target = dlg.target_path orelse "";
            ops_mod.renameItem(self.allocator, target, name) catch |err| {
                const msg = switch (err) {
                    error.PathAlreadyExists => tr("Target name already exists"),
                    error.AccessDenied => tr("Permission denied"),
                    error.EmptyName => tr("Name cannot be empty"),
                    error.InvalidCharacter => tr("Invalid characters in name"),
                    else => tr("Failed to rename"),
                };
                self.setStatusNotice(msg, true);
                self.closeDialog();
                return;
            };
            self.closeDialog();
            self.setStatusNotice(tr("Renamed successfully"), false);
            self.refresh();
        },
        .trash_confirm => {
            self.executeDeletion();
            self.closeDialog();
        },
        .conflict => {
            if (self.job_runner) |runner| {
                runner.resolveConflict(.skip);
            }
            self.closeDialog();
        },
    }
}

pub fn handleDialogKey(self: *App, sym: u32, utf8: []const u8) void {
    var dlg = &(self.dialog orelse return);
    if (dlg.kind == .transfers) {
        self.transfersKey(sym);
        return;
    }

    if (dlg.kind == .properties) {
        const action = self.dialog.?.properties.?.key(sym, self.shift, self.w, self.h);
        self.propertiesAction(action);
        return;
    }
    if (dlg.kind == .open_with) {
        const action = self.dialog.?.applications.?.key(sym, self.shift, self.w, self.h);
        self.openWithAction(action);
        return;
    }
    if (dlg.kind == .trash_confirm) {
        self.deleteAction(self.dialog.?.deletion.key(sym));
        return;
    }
    if (dlg.kind == .conflict) {
        if (sym == c.XKB_KEY_s or sym == c.XKB_KEY_S) {
            if (self.job_runner) |runner| runner.resolveConflict(.skip);
            self.closeDialog();
            return;
        } else if (sym == c.XKB_KEY_r or sym == c.XKB_KEY_R) {
            if (self.job_runner) |runner| runner.resolveConflict(.rename);
            self.closeDialog();
            return;
        } else if (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C or sym == c.XKB_KEY_Escape) {
            if (self.job_runner) |runner| runner.resolveConflict(.cancel);
            self.closeDialog();
            return;
        }
        return;
    }

    if (sym == c.XKB_KEY_Escape) {
        self.closeDialog();
        return;
    } else if (sym == c.XKB_KEY_Return) {
        self.confirmDialog();
        return;
    }

    if (dlg.kind != .terminal_close) self.editKey(&dlg.edit, sym, utf8);
}
