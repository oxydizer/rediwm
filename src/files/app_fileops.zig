//! Files clipboard and file operations: copy, cut, paste, size and delete.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const recent = @import("recent.zig");
const ops_mod = @import("ops.zig");
const clipboard_mod = @import("clipboard.zig");
const deletion = @import("../delete_dialog.zig");
const trash = @import("trash.zig");

pub fn copySelected(self: *App) void {
    if (self.history.archive_len > 0) return;
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
    const runner = self.job_runner orelse return false;
    runner.start(kind, paths, directory, .ask) catch {
        self.setStatusNotice(tr("Failed to start transfer job"), true);
        return false;
    };
    self.job_cut_revision = if (clipboard and kind == .move and self.clipboard_cut) self.clipboard_revision else null;
    self.job_was_running = true;
    self.invalidate();
    return true;
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

pub fn executeDeletion(self: *App) void {
    const state = &self.dialog.?.deletion;
    if (state.in_trash) return self.deleteFromTrash(state.paths.items);
    const result = if (state.empty_trash) ops_mod.emptyTrash(self.io) else if (state.permanent) ops_mod.deleteItems(self.io, state.paths.items) else ops_mod.trashItems(self.io, state.paths.items);
    result catch |err| {
        self.setStatusNotice(if (state.empty_trash) tr("Could not empty Trash") else if (state.permanent) tr("Could not delete all items") else if (err == error.GioNotAvailable) tr("Trash unavailable (gio not installed)") else tr("Could not move all items to Trash"), true);
        self.refresh();
        return;
    };
    // gio empties Trash; sweep what it leaves, so no metadata outlives its item.
    if (state.empty_trash) if (self.trash_dir) |dir| trash.sweepOrphans(self.allocator, dir);
    self.setStatusNotice(if (state.empty_trash) tr("Trash emptied") else if (state.permanent) tr("Items permanently deleted") else tr("Items moved to Trash"), false);
    self.refresh();
}

/// Permanently deletes entries of the Trash view with their metadata.
pub fn deleteFromTrash(self: *App, paths: []const []const u8) void {
    const dir = self.trash_dir orelse return;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var stray: usize = 0;
    for (paths) |path| {
        // Only top-level entries of the trash have metadata and may go this way.
        const parent = std.fs.path.dirname(path) orelse "";
        if (!std.mem.eql(u8, parent, dir)) {
            stray += 1;
            continue;
        }
        names.append(self.allocator, std.fs.path.basename(path)) catch {
            stray += 1;
        };
    }
    const removed = trash.deleteMany(self.allocator, dir, names.items);
    if (removed.failed + stray > 0) {
        self.setStatusNotice(tr("Could not delete all items"), true);
    } else {
        self.setStatusNotice(tr("Items permanently deleted"), false);
    }
    self.refresh();
}
