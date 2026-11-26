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
const c = @import("c.zig").api;

fn startArchiveExport(self: *App, purpose: App.ArchiveExportPurpose) !void {
    _ = try @import("app_archives.zig").startExport(self, purpose);
}

/// The export's tag, for the drag to wait on.
pub fn startArchiveDragExport(self: *App) !u64 {
    return @import("app_archives.zig").startExport(self, .drag);
}

pub fn startArchiveOpenWith(self: *App) !void {
    try startArchiveExport(self, .open_with);
}

pub fn copySelected(self: *App) void {
    // A torrent's files are not here to copy (an arrived one opens).
    if (self.history.torrent) return;
    if (self.history.archive_len > 0) {
        startArchiveExport(self, .clipboard) catch {
            self.setStatusNotice(
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
