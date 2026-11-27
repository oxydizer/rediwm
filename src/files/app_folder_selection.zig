//! Group the selected children of a real folder in a new subfolder.
const std = @import("std");
const tr = @import("i18n").tr;
const App = @import("app.zig").App;
const Dialog = @import("app_model.zig").Dialog;
const c = @import("c.zig").api;
const ops = @import("ops.zig");

pub const Selection = struct {
    paths: [][]u8,
    navigation: u32,

    pub fn deinit(self: Selection, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
    }
};

pub fn eligible(self: *App) bool {
    if (self.chooser != null or self.isRecent() or self.trashReadOnly() or
        self.history.archive_len != 0 or self.history.torrent or self.transfer_browse_root != null or
        self.changedOnly() or self.loading) return false;
    const dir = std.mem.trimEnd(u8, self.history.current, "/");
    var found = false;
    for (self.items.items) |item| {
        if (!item.selected) continue;
        if (item.missing or item.transfer_ghost or item.transfer_stub or item.is_broken) return false;
        switch (item.mode & c.S_IFMT) {
            c.S_IFREG, c.S_IFDIR, c.S_IFLNK => {},
            else => return false,
        }
        const parent = std.fs.path.dirname(item.path) orelse return false;
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, parent, "/"), dir)) return false;
        found = true;
    }
    return found;
}

fn commonPrefix(left: []const u8, right: []const u8) []const u8 {
    var len: usize = 0;
    while (len < @min(left.len, right.len) and left[len] == right[len]) : (len += 1) {}
    // The first differing byte can be partway through a UTF-8 character.
    while (len > 0 and len < left.len and left[len] & 0xc0 == 0x80) len -= 1;
    return left[0..len];
}

const separators = " \t\r\n-_.";

fn suggestion(prefix: []const u8, shortest_stem: usize) []const u8 {
    var trimmed = std.mem.trimEnd(u8, prefix, separators);
    // Omit the shared leading digits of a differing sequence number.
    if (trimmed.len == prefix.len and prefix.len < shortest_stem) {
        const number_start = std.mem.trimEnd(u8, trimmed, "0123456789").len;
        if (number_start > 0 and number_start < trimmed.len and
            std.mem.indexOfScalar(u8, separators, trimmed[number_start - 1]) != null)
            trimmed = std.mem.trimEnd(u8, trimmed[0..number_start], separators);
    }
    if (!std.unicode.utf8ValidateSlice(trimmed) or
        std.mem.trim(u8, trimmed, separators).len == 0) return tr("New Folder");
    return trimmed;
}

fn uniqueSuggestion(self: *App, base: []const u8) ![]u8 {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(self.allocator);
    if (self.snapshot) |snapshot| {
        for (snapshot.items) |item| try names.put(self.allocator, item.name, {});
    }
    for (self.items.items) |item| try names.put(self.allocator, item.name, {});

    if (!names.contains(base)) return self.allocator.dupe(u8, base);
    var suffix: usize = 1;
    while (true) : (suffix += 1) {
        const candidate = try ops.duplicateName(self.allocator, base, suffix, "");
        if (!names.contains(candidate)) return candidate;
        self.allocator.free(candidate);
    }
}

pub fn openDialog(self: *App) void {
    if (!eligible(self)) return;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(self.allocator);
    var prefix: ?[]const u8 = null;
    var shortest_stem: usize = std.math.maxInt(usize);
    for (self.items.items) |item| {
        if (!item.selected) continue;
        paths.append(self.allocator, item.path) catch return;
        const stem = if (item.is_dir and !item.is_symlink) item.name else std.fs.path.stem(item.name);
        shortest_stem = @min(shortest_stem, stem.len);
        prefix = if (prefix) |previous| commonPrefix(previous, stem) else stem;
    }
    const base = std.mem.trim(u8, suggestion(prefix orelse "", shortest_stem), " \t\r\n");
    const name = uniqueSuggestion(self, base) catch return;
    defer self.allocator.free(name);
    const selection: Selection = .{
        .paths = @import("app_requests.zig").dupeAll(self.allocator, paths.items) catch return,
        .navigation = self.navigation_count,
    };
    var dialog: Dialog = .{
        .kind = .new_folder_from_selection,
        .title = tr("Group in New Folder"),
        .folder_selection = selection,
    };
    dialog.edit.text.appendSlice(self.allocator, name) catch {
        selection.deinit(self.allocator);
        return;
    };
    dialog.edit.cursor = dialog.edit.text.items.len;
    dialog.edit.select_all = true;
    self.closeDialog();
    self.dialog = dialog;
    self.invalidate();
}

pub fn confirm(self: *App, dialog: *const Dialog) void {
    const selection = dialog.folder_selection orelse return;
    if (self.navigation_count != selection.navigation) {
        self.closeDialog();
        return;
    }
    const name = std.mem.trim(u8, dialog.edit.text.items, " \t\r\n");
    ops.validateFilename(name) catch {
        self.setStatusNotice(tr("Enter a valid folder name"), true);
        return;
    };
    const destination = std.fs.path.join(self.allocator, &.{ self.history.current, name }) catch return;
    defer self.allocator.free(destination);
    if (@import("app_transfers.zig").submitFolderMove(self, selection.paths, destination, selection.navigation))
        self.closeDialog();
}

/// Keep the new folder selected in the parent view when the user goes Back.
pub fn enterFolder(self: *App, destination: []const u8) bool {
    saveParentSelection(self, destination) catch return false;
    self.applyHistoryNav(self.history.current);
    return true;
}

fn saveParentSelection(self: *App, destination: []const u8) !void {
    var view: @import("history.zig").View = .{ .scroll = self.scroll_y };
    defer view.deinit(self.allocator);
    // Use the listing's spelling of the path, including its separator at "/".
    const path = try @import("worker_scan.zig").listingPath(self.allocator, self.history.current, std.fs.path.basename(destination));
    defer self.allocator.free(path);
    const selected = try self.allocator.dupe(u8, path);
    view.selected.append(self.allocator, selected) catch |err| {
        self.allocator.free(selected);
        return err;
    };
    view.focus = try self.allocator.dupe(u8, selected);
    view.anchor = try self.allocator.dupe(u8, selected);
    try self.history.navigate(destination);
    const parent = &self.history.back_stack.items[self.history.back_stack.items.len - 1];
    parent.view.deinit(self.allocator);
    parent.view = view;
    view = .{};
}

test "group name trims separators and never splits a UTF-8 character" {
    try std.testing.expectEqualStrings("Trip", suggestion(commonPrefix("Trip - 01", "Trip - 02"), 9));
    try std.testing.expectEqualStrings("Caf", suggestion(commonPrefix("Café", "Cafè"), 5));
    try std.testing.expectEqualStrings("New Folder", suggestion(commonPrefix("a", "b"), 1));
}

test {
    _ = @import("app_folder_selection_tests.zig");
}

test "Back restores the new folder selection using the root listing path" {
    var app = try @import("app_tests.zig").testApp();
    defer app.deinit();
    const root_history = try @import("history.zig").History.init(app.allocator, "/");
    app.history.deinit();
    app.history = root_history;
    try saveParentSelection(&app, "/Group");
    try std.testing.expectEqualStrings("/Group", app.history.current);
    try std.testing.expectEqualStrings("/", (try app.history.back()).?);

    const path = try @import("worker_scan.zig").listingPath(app.allocator, "/", "Group");
    defer app.allocator.free(path);
    try std.testing.expectEqualStrings("//Group", path);
    try app.items.append(app.allocator, .{
        .name = "Group",
        .path = path,
        .is_dir = true,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 0,
        .mtime = 0,
        .icon_name = "",
    });
    app.restoreView();
    try std.testing.expect(app.items.items[0].selected);
    try std.testing.expectEqual(@as(?usize, 0), app.focused_index);
    try std.testing.expectEqual(@as(?usize, 0), app.selection_anchor);
}
