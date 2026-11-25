//! Files clipboard and file operations: copy, cut, paste, size and delete.

const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const recent = @import("recent.zig");
const ops_mod = @import("ops.zig");
const io_tree = @import("io_tree.zig");
const io_manager = @import("io_manager.zig");
const clipboard_mod = @import("clipboard.zig");
const deletion = @import("../delete_dialog.zig");
const trash = @import("trash.zig");
const c = @import("c.zig").api;

fn startArchiveExport(self: *App, purpose: App.ArchiveExportPurpose) !void {
    if (!self.hasSelectedArchiveMembers()) return error.NoSelectedArchiveMembers;
    if (purpose == .open_with) {
        for (self.items.items) |item| {
            if (item.selected and !item.transfer_ghost and item.is_dir)
                return error.NoSelectedArchiveMembers;
        }
    }
    if (self.active_io_copy_job != null) return error.Busy;
    if (self.job_runner) |runner| {
        const state = runner.pollProgress().state;
        if (state == .running or state == .paused or state == .waiting_conflict)
            return error.Busy;
    }

    const archive_len = self.history.archive_len;
    const archive_path = self.history.current[0..archive_len];
    var members: std.ArrayList([]const u8) = .empty;
    defer {
        for (members.items) |member| self.allocator.free(member);
        members.deinit(self.allocator);
    }

    for (self.items.items) |item| {
        if (!item.selected or item.transfer_ghost) continue;
        const member = try self.allocator.dupe(
            u8,
            item.path[archive_len + 1 ..],
        );
        members.append(self.allocator, member) catch |err| {
            self.allocator.free(member);
            return err;
        };
    }

    try self.startOperations();
    const manager = self.io_manager orelse return error.OperationManagerUnavailable;
    try self.archive_exports.ensureUnusedCapacity(self.allocator, 1);

    const job_id = try manager.createJob(null);
    errdefer _ = manager.discardPlanningJob(job_id);
    const operation_id = try manager.addArchiveOperation(
        job_id,
        .archive_extract,
        .{
            .source_path = archive_path,
            .staging_parent = "/tmp",
            .member_paths = members.items,
        },
    );
    try manager.setDestinationDirectory(job_id, "/tmp");
    try manager.queueJob(job_id);

    self.archive_exports.appendAssumeCapacity(.{
        .job_id = job_id,
        .operation_id = operation_id,
        .member_paths = members,
        .purpose = purpose,
    });
    members = .empty;

    self.active_io_copy_job = job_id;
    self.active_io_copy_is_directory = false;
    self.active_io_copy_is_move = false;
    self.active_io_copy_is_archive = false;
    self.active_io_copy_is_archive_member = false;
    self.active_io_copy_is_archive_clipboard = purpose == .clipboard;
    self.active_io_copy_is_archive_drag = purpose == .drag;
    self.active_io_copy_is_archive_open_with = purpose == .open_with;
    self.active_io_copy_item_count = self.archive_exports.items[
        self.archive_exports.items.len - 1
    ].member_paths.items.len;
    self.setStatusNotice(switch (purpose) {
        .clipboard => "Preparing archive members for clipboard",
        .drag => "Preparing files for drag…",
        .open_with => "Preparing archive members for Open With…",
    }, false);
    self.invalidate();
}

pub fn startArchiveDragExport(self: *App) !void {
    try startArchiveExport(self, .drag);
}

pub fn startArchiveOpenWith(self: *App) !void {
    try startArchiveExport(self, .open_with);
}

pub fn copySelected(self: *App) void {
    if (self.history.archive_len > 0) {
        startArchiveExport(self, .clipboard) catch |err| {
            self.setStatusNotice(
                if (err == error.Busy)
                    tr("A file operation is already running")
                else
                    tr("Could not copy archive members"),
                true,
            );
        };
        return;
    }
    if (!self.hasSelection()) return;
    self.clipboard_is_text = false;
    self.clearClipboard();
    for (self.items.items) |it| {
        if (it.selected and !it.missing) {
            self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
        }
    }
    if (self.clipboard_paths.items.len > 0) {
        self.clipboard_cut = false;
        self.clipboard_revision += 1;
        var buf: [128]u8 = undefined;
        const count = self.clipboard_paths.items.len;
        const msg = i18n.fmt(&buf, i18n.trn("Copied {count} item", "Copied {count} items", count), .{ .count = count }) catch tr("Copied");
        self.setStatusNotice(msg, false);
        self.invalidate();
    }
}

pub fn cutSelected(self: *App) void {
    if (self.history.archive_len > 0 or self.trashReadOnly()) return;
    if (!self.hasSelection()) return;
    self.clipboard_is_text = false;
    self.clearClipboard();
    for (self.items.items) |it| {
        if (it.selected and !it.missing) {
            self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
        }
    }
    if (self.clipboard_paths.items.len > 0) {
        self.clipboard_cut = true;
        self.clipboard_revision += 1;
        var buf: [128]u8 = undefined;
        const count = self.clipboard_paths.items.len;
        const msg = i18n.fmt(&buf, i18n.trn("Cut {count} item", "Cut {count} items", count), .{ .count = count }) catch tr("Cut");
        self.setStatusNotice(msg, false);
        self.invalidate();
    }
}

pub fn calculateSizeSelected(self: *App) void {
    if (self.history.archive_len > 0) return;
    var any = false;
    for (self.items.items, 0..) |it, idx| {
        if (it.selected and it.is_dir and !it.is_symlink) {
            self.startFolderSize(idx);
            any = true;
        }
    }
    if (!any) {
        if (self.focused_index) |idx| {
            if (idx < self.items.items.len) {
                const it = self.items.items[idx];
                if (it.is_dir and !it.is_symlink) {
                    self.startFolderSize(idx);
                }
            }
        }
    }
}

pub fn executePaste(self: *App, kind: ops_mod.OpKind, paths: []const []const u8) bool {
    if (self.isRecent()) return false;
    return self.executeTransfer(kind, paths, self.history.current, true);
}

pub fn executeTransfer(self: *App, kind: ops_mod.OpKind, paths: []const []const u8, directory: []const u8, clipboard: bool) bool {
    if (self.history.archive_len > 0 or recent.isLocation(directory)) return false;
    if (paths.len == 0) return false;
    // Nothing is pasted or dropped into the Trash: Move to Trash is how items get there.
    if (self.trash_dir) |dir| if (trash.relation(dir, directory) != .none) {
        self.setStatusNotice(tr("Use Move to Trash to put items in Trash"), true);
        return false;
    };
    // The service checks sources and destination off this thread and runs
    // the job; the window learns the end from the job's record.
    return self.submitTransfer(kind, paths, directory, clipboard);
}

pub fn executePasteLocal(self: *App) void {
    if (self.clipboard_paths.items.len == 0) return;
    const kind: ops_mod.OpKind = if (self.clipboard_cut) .move else .copy;
    _ = self.executePaste(kind, self.clipboard_paths.items);
}

pub fn executePasteExternal(self: *App, mode: clipboard_mod.ClipboardMode, paths: []const []const u8) void {
    const kind: ops_mod.OpKind = if (mode == .cut) .move else .copy;
    if (!self.executePaste(kind, paths)) return;
    // Retain external cut entries too; completion republishes only remaining items.
    if (mode == .cut) {
        self.clearClipboard();
        for (paths) |path| {
            const owned = self.allocator.dupe(u8, path) catch continue;
            self.clipboard_paths.append(self.allocator, owned) catch self.allocator.free(owned);
        }
        self.clipboard_cut = true;
        self.clipboard_is_text = false;
        self.clipboard_revision += 1;
        self.job_cut_revision = self.clipboard_revision;
    }
}

pub fn deleteAction(self: *App, action: deletion.Action) void {
    switch (action) {
        .cancel => self.closeDialog(),
        .confirm => self.confirmDialog(),
        .toggle => {
            if (self.dialog.?.deletion.fixedChoice()) return;
            self.dialog.?.deletion.permanent = !self.dialog.?.deletion.permanent;
            self.dialog.?.deletion.focus = .toggle;
        },
        .none => {},
    }
    self.invalidate();
}

/// Starts the confirmed deletion as a service job; its end is reported
/// when the job's record says so (`app_service.zig`).
pub fn executeDeletion(self: *App) void {
    const state = &self.dialog.?.deletion;
    if (state.in_trash) return self.deleteFromTrash(state.paths.items);
    if (state.empty_trash) return self.submitDeletion(.empty_trash, &.{}, self.trash_dir);
    self.submitDeletion(if (state.permanent) .delete else .trash, state.paths.items, null);
}

/// Permanently deletes entries of the Trash view with their metadata.
pub fn deleteFromTrash(self: *App, paths: []const []const u8) void {
    const dir = self.trash_dir orelse return;
    self.submitDeletion(.delete_from_trash, paths, dir);
}
