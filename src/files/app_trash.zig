//! Files' Trash view: where we are relative to the trash, what is offered
//! there, and restoring or deleting its entries (the work is in trash.zig).

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const trash = @import("trash.zig");
const ops = @import("ops.zig");
const header = @import("header.zig");

/// Where the current location lies relative to the home trash.
pub fn trashRelation(self: *const App) trash.Relation {
    const dir = self.trash_dir orelse return .none;
    return trash.relation(dir, self.history.current);
}

/// The Trash view or a folder inside it.
pub fn inTrash(self: *const App) bool {
    return trashRelation(self) != .none;
}

/// Nothing is created in, renamed in or moved out of the Trash by hand: new
/// entries would have no metadata and moved ones would leave theirs behind.
/// Restore puts items back, Copy takes a duplicate. Says why when it applies.
pub fn trashReadOnly(self: *App) bool {
    if (!inTrash(self)) return false;
    self.setStatusNotice(tr("Trash can't be edited. Restore items to change them."), false);
    return true;
}

/// Whether the file menu may offer Restore: at least one selected entry has
/// usable metadata. Worked out when the menu opens, not on every paint.
pub fn refreshTrashRestorable(self: *App) void {
    self.trash_restorable = false;
    if (trashRelation(self) != .root) return;
    const dir = self.trash_dir.?;
    for (self.items.items) |item| {
        if (!item.selected or item.missing) continue;
        if (trash.restorable(self.allocator, dir, std.fs.path.basename(item.path))) {
            self.trash_restorable = true;
            return;
        }
    }
}

pub fn restoreSelected(self: *App) void {
    if (trashRelation(self) != .root) return;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    for (self.items.items) |item| {
        if (!item.selected or item.missing) continue;
        names.append(self.allocator, std.fs.path.basename(item.path)) catch {
            self.setStatusNotice(tr("Could not restore the selected items"), true);
            return;
        };
    }
    if (names.items.len == 0) return;
    restore(self, names.items);
}

pub fn restoreAll(self: *App) void {
    if (trashRelation(self) != .root) return;
    const names = trash.listEntries(self.allocator, self.trash_dir.?) catch {
        self.setStatusNotice(tr("Could not restore the items in Trash"), true);
        return;
    };
    defer self.allocator.free(names);
    defer trash.freeNames(self.allocator, names);
    if (names.len == 0) {
        self.setStatusNotice(tr("Trash is empty"), false);
        return;
    }
    const view: []const []const u8 = @ptrCast(names);
    restore(self, view);
}

/// Whether a drag at (`x`, `y`) is over the sidebar's Trash row, where a
/// drop moves the items to the Trash at once, without the delete dialog.
pub fn trashDropAt(self: *App, x: f64, y: f64) bool {
    if (self.chooser != null or self.dialog != null or self.menu != null) return false;
    return self.placeAt(x, y) == App.trash_place;
}

pub fn setTrashDrop(self: *App, on: bool) void {
    if (self.trash_drop == on) return;
    self.trash_drop = on;
    const area: header.Rect = .{ .x = 0, .y = @floatFromInt(self.contentTop()), .w = @floatFromInt(self.sidebarWidth()), .h = @floatFromInt(self.h - self.contentTop() - self.sidebarFooter()) };
    var row = self.placeRect(App.trash_place);
    row.x -= 2;
    row.y -= 2;
    row.w += 4;
    row.h += 4;
    self.damageHighlight(area, row, null);
}

/// The drop happened: whether it was on the Trash row, with the outline gone.
pub fn takeTrashDrop(self: *App) bool {
    const on = self.trash_drop;
    setTrashDrop(self, false);
    return on;
}

/// Moves what was dropped on the Trash row to the Trash. What is in the
/// Trash already stays where it is.
pub fn trashDropped(self: *App, paths: []const []const u8) void {
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(self.allocator);
    for (paths) |path| {
        if (self.trash_dir) |dir| if (trash.relation(dir, path) != .none) continue;
        kept.append(self.allocator, path) catch {
            self.setStatusNotice(tr("Could not move all items to Trash"), true);
            return;
        };
    }
    if (kept.items.len == 0) return;
    ops.trashItems(self.io, kept.items) catch |err| {
        self.setStatusNotice(if (err == error.GioNotAvailable) tr("Trash unavailable (gio not installed)") else tr("Could not move all items to Trash"), true);
        self.refresh();
        return;
    };
    self.setStatusNotice(tr("Items moved to Trash"), false);
    self.refresh();
}

fn restore(self: *App, names: []const []const u8) void {
    const summary = trash.restoreMany(self.allocator, self.trash_dir.?, names);
    reportRestore(self, summary);
    self.refresh();
}

/// "Restored 3 items. 1 kept under a new name. 1 has no Trash information."
pub fn reportRestore(self: *App, summary: trash.Summary) void {
    var buf: [384]u8 = undefined;
    var len: usize = 0;
    var piece: [128]u8 = undefined;
    if (summary.restored > 0) {
        const text = i18n.fmt(&piece, i18n.trn("Restored {count} item", "Restored {count} items", summary.restored), .{ .count = summary.restored }) catch tr("Restored");
        len = append(&buf, len, text);
    }
    if (summary.renamed > 0) {
        const text = i18n.fmt(&piece, tr("{count} kept under a new name"), .{ .count = summary.renamed }) catch tr("Some kept under a new name");
        len = append(&buf, len, text);
    }
    if (summary.no_metadata > 0) {
        const text = i18n.fmt(&piece, i18n.trn("{count} has no Trash information", "{count} have no Trash information", summary.no_metadata), .{ .count = summary.no_metadata }) catch tr("Some have no Trash information");
        len = append(&buf, len, text);
    }
    if (summary.failed > 0) {
        const text = i18n.fmt(&piece, tr("{count} could not be restored"), .{ .count = summary.failed }) catch tr("Some could not be restored");
        len = append(&buf, len, text);
    }
    if (len == 0) return;
    self.setStatusNotice(buf[0..len], summary.no_metadata > 0 or summary.failed > 0);
}

fn append(buf: []u8, len: usize, text: []const u8) usize {
    var at = len;
    if (at > 0 and at + 2 <= buf.len) {
        buf[at] = '.';
        buf[at + 1] = ' ';
        at += 2;
    }
    const room = @min(text.len, buf.len - at);
    @memcpy(buf[at .. at + room], text[0..room]);
    return at + room;
}
