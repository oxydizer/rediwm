//! Files dialogs: opening, confirming and keyboard handling of the modal cards.

const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const git = @import("git.zig");
const ops_mod = @import("ops.zig");
const icons = @import("../icon_cache.zig");
const app_requests = @import("app_requests.zig");
const app_transfers = @import("app_transfers.zig");
const deletion = @import("../delete_dialog.zig");
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const trash_properties = @import("trash_properties.zig");
const ViewItem = @import("app_model.zig").ViewItem;
const Dialog = @import("app_model.zig").Dialog;

pub const ConflictAction = enum { skip, merge, rename, cancel };

/// Conflict accelerators are deliberately Alt-only: bare letters remain
/// available for normal typing and cannot resolve a conflict accidentally.
pub fn conflictShortcut(sym: u32, alt: bool, can_merge: bool) ?ConflictAction {
    if (!alt) return null;
    return switch (sym) {
        c.XKB_KEY_s, c.XKB_KEY_S => .skip,
        c.XKB_KEY_m, c.XKB_KEY_M => if (can_merge) .merge else null,
        c.XKB_KEY_r, c.XKB_KEY_R => .rename,
        c.XKB_KEY_c, c.XKB_KEY_C => .cancel,
        else => null,
    };
}

/// The small modal's height: a service conflict has an "Apply to all" row.
pub fn smallDialogHeight(self: *const App) f64 {
    const dlg = self.dialog orelse return 130;
    return if (dlg.kind == .conflict and dlg.service_conflict) 162 else 130;
}

/// Where the "Apply to all" checkbox of a service conflict sits.
pub fn applyAllRect(self: *const App) @import("header.zig").Rect {
    const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
    const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
    const dy = (@as(f64, @floatFromInt(self.h)) - smallDialogHeight(self)) / 2.0;
    return .{ .x = dx + 16, .y = dy + 122, .w = dw - 32, .h = 24 };
}

pub fn toggleApplyAll(self: *App) void {
    if (self.dialog) |*dlg| if (dlg.kind == .conflict and dlg.service_conflict) {
        dlg.conflict_apply_all = !dlg.conflict_apply_all;
        self.invalidate();
    };
}

pub fn closeDialog(self: *App) void {
    if (self.dialog) |open| if (open.service_conflict)
        std.log.info("Files conflict dialog {d} closed", .{open.manager_conflict_id orelse 0});
    self.text_dragging = false;
    _ = self.dialog_surface.pointerMotion(null);
    self.edit_revision += 1;
    if (self.dialog) |*dlg| {
        dlg.deletion.deinit();
        if (dlg.applications) |*apps| apps.deinit();
        if (dlg.properties) |*props| props.deinit();
        if (dlg.trash_properties) |*props| props.release(self.reaper);
        dlg.edit.text.deinit(self.allocator);
        if (dlg.target_path) |tp| self.allocator.free(tp);
        if (dlg.conflict_name) |cn| self.allocator.free(cn);
        if (dlg.conflict_destination) |path| self.allocator.free(path);
        self.dialog = null;
        self.open_with_archive_paths = false;
        self.invalidate();
    }
}

/// The dialog opens when the service has read the item (`app_requests`).
pub fn openProperties(self: *App, path: []const u8, preview: ?icons.Entry) void {
    if (app_requests.waiting(self, .properties)) return;
    _ = app_requests.send(self, .{ .properties = .{ .path = path } }, .{ .properties = .{ .preview = preview } });
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
                _ = self.openFile(path);
            }
        },
    }
}

/// Properties of the Trash itself (the sidebar's Trash row), not of an item in it.
pub fn openTrashProperties(self: *App) void {
    const path = self.trash_dir orelse {
        self.setStatusNotice(tr("Could not read file properties"), true);
        return;
    };
    const state = trash_properties.State.init(path, self.worker.wake_main) catch {
        self.setStatusNotice(tr("Could not read file properties"), true);
        return;
    };
    self.closeDialog();
    self.dialog = .{ .kind = .trash_properties, .title = tr("Properties"), .trash_properties = state };
    self.invalidate();
}

pub fn trashPropertiesAction(self: *App, action: trash_properties.Action) void {
    switch (action) {
        .none => self.invalidate(),
        .close => self.closeDialog(),
        .open => {
            const path = self.allocator.dupe(u8, self.dialog.?.trash_properties.?.path) catch return;
            defer self.allocator.free(path);
            self.closeDialog();
            self.navigate(path);
        },
    }
}

pub fn canOpenWith(self: *const App) bool {
    if (self.history.archive_len > 0) {
        if (!self.hasSelectedArchiveMembers()) return false;
        for (self.items.items) |item| {
            if (item.selected and !item.transfer_ghost and item.is_dir) return false;
        }
        return true;
    }
    if (self.chooser != null) return false;
    var found = false;
    for (self.items.items) |item| {
        if (!item.selected or item.transfer_ghost) continue;
        if (item.is_dir or item.missing or item.is_broken) return false;
        found = true;
    }
    return found;
}

pub fn openWithDialog(self: *App) void {
    if (!self.canOpenWith()) return;
    if (self.history.archive_len > 0) {
        self.startArchiveOpenWith() catch |err| {
            self.setStatusNotice(
                if (err == error.Busy)
                    tr("A file operation is already running")
                else
                    tr("Could not load applications"),
                true,
            );
        };
        return;
    }
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(self.allocator);
    for (self.items.items) |item| {
        if (item.selected and !item.transfer_ghost) paths.append(self.allocator, item.path) catch return;
    }
    _ = self.openWithPaths(paths.items, false);
}

pub fn openWithPaths(self: *App, paths: []const []const u8, archive_paths: bool) bool {
    const state = open_with.State.init(self.allocator, paths) catch {
        self.setStatusNotice(tr("Could not load applications"), true);
        return false;
    };
    self.closeDialog();
    self.dialog = .{ .kind = .open_with, .title = tr("Open With"), .applications = state };
    self.open_with_archive_paths = archive_paths;
    self.invalidate();
    return true;
}

pub fn openWithAction(self: *App, action: open_with.Action) void {
    switch (action) {
        .cancel => self.closeDialog(),
        .open => {
            const archive_paths = self.open_with_archive_paths;
            if (self.dialog.?.applications.?.open()) {
                const message = self.dialog.?.applications.?.message;
                if (message.len == 0 and !archive_paths) {
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
    if (self.isRecent() or self.history.archive_len > 0 or self.trashReadOnly()) return;
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
    if (self.isRecent() or self.history.archive_len > 0 or self.trashReadOnly()) return;
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
    if (self.history.archive_len > 0 or self.trashReadOnly()) return;
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

pub fn openTrashConfirmDialogWithMode(self: *App, permanent_requested: bool) void {
    if (self.history.archive_len > 0) return;
    // Entries already in Trash can only be deleted for good; the ones inside
    // a trashed folder belong to it and go with it.
    const in_trash = switch (self.trashRelation()) {
        .none => false,
        .root => true,
        .inside => {
            self.setStatusNotice(tr("Restore the folder to change what is inside it"), false);
            return;
        },
    };
    const permanent = permanent_requested or in_trash;
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
        .title = if (in_trash) tr("Delete permanently?") else tr("Move to Trash?"),
        .deletion = .{ .permanent = permanent, .in_trash = in_trash },
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

/// A service job's conflict, the head of the queue: `destination` is where
/// the conflicting item would go.
pub fn openServiceConflictDialog(self: *App, conflict_id: u64, job_id: u64, destination: []const u8, can_merge: bool) void {
    if (self.dialog != null) return;
    self.dialog = Dialog{
        .kind = .conflict,
        .title = tr("File Conflict"),
        .conflict_name = self.allocator.dupe(u8, std.fs.path.basename(destination)) catch null,
        .manager_conflict_id = conflict_id,
        .service_conflict = true,
        .conflict_can_merge = can_merge,
        .conflict_destination = self.allocator.dupe(u8, destination) catch null,
        .conflict_job_id = job_id,
    };
    self.invalidate();
}

/// Merge is offered for directory-onto-directory conflicts only.
pub fn managerConflictCanMerge(self: *const App) bool {
    const dlg = self.dialog orelse return false;
    return dlg.service_conflict and dlg.conflict_can_merge;
}

/// Answers the conflict dialog through the service.
pub fn resolveConflictDialog(self: *App, action: ConflictAction) void {
    const dlg = self.dialog orelse return;
    if (dlg.kind != .conflict) return;

    if (dlg.service_conflict) {
        const answer: @import("io_service.zig").ConflictAction = switch (action) {
            .skip => .skip,
            .merge => .merge,
            .rename => .rename,
            .cancel => .cancel,
        };
        if (dlg.conflict_apply_all and action != .cancel)
            app_transfers.standFor(self, dlg.conflict_job_id, dlg.conflict_can_merge, answer);
        if (dlg.manager_conflict_id) |conflict_id| app_transfers.resolveConflict(self, conflict_id, dlg.conflict_destination orelse "", answer);
    }

    self.closeDialog();
}

pub fn confirmDialog(self: *App) void {
    const dlg = self.dialog orelse return;
    switch (dlg.kind) {
        .torrent_source, .torrent_destination => self.confirmTorrent(),
        .terminal_close => self.terminalConfirmClose(),
        .open_with => self.openWithAction(.open),
        .properties, .trash_properties => {},
        .new_folder => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            _ = app_requests.send(self, .{ .create_folder = .{ .dir = self.history.current, .name = name } }, .create_folder);
            self.closeDialog();
        },
        .new_branch => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            // `name` borrows the dialog's text: use it before closing.
            if (self.repository()) |repo| self.switchBranch(repo, name, true);
            self.closeDialog();
        },
        .new_file => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            _ = app_requests.send(self, .{ .create_file = .{ .dir = self.history.current, .name = name } }, .create_file);
            self.closeDialog();
        },
        .rename => {
            const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
            const target = dlg.target_path orelse "";
            _ = app_requests.send(self, .{ .rename = .{ .target = target, .name = name } }, .rename);
            self.closeDialog();
        },
        .trash_confirm => {
            self.executeDeletion();
            self.closeDialog();
        },
        .conflict => {
            self.resolveConflictDialog(.skip);
        },
        .quit_jobs => @import("app_quit.zig").choose(self, .keep),
    }
}

pub fn handleDialogKey(self: *App, sym: u32, utf8: []const u8) void {
    var dlg = &(self.dialog orelse return);
    if (dlg.kind == .properties) {
        const action = self.dialog.?.properties.?.key(sym, self.shift, self.w, self.h);
        self.propertiesAction(action);
        return;
    }
    if (dlg.kind == .trash_properties) {
        self.trashPropertiesAction(self.dialog.?.trash_properties.?.key(sym));
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
    if (dlg.kind == .quit_jobs) {
        if (sym == c.XKB_KEY_Escape) @import("app_quit.zig").choose(self, .cancel);
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) @import("app_quit.zig").choose(self, .keep);
        return;
    }
    if (dlg.kind == .conflict) {
        if (self.alt and (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A)) {
            toggleApplyAll(self);
            return;
        }
        if (conflictShortcut(sym, self.alt, self.managerConflictCanMerge())) |action| {
            self.resolveConflictDialog(action);
            return;
        }
        if (sym == c.XKB_KEY_Escape) self.resolveConflictDialog(.cancel);
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
