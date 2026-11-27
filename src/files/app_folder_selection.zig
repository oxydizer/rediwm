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
    const selection: Selection = .{
        .paths = @import("app_requests.zig").dupeAll(self.allocator, paths.items) catch return,
        .navigation = self.navigation_count,
    };
    var dialog: Dialog = .{
        .kind = .new_folder_from_selection,
        .title = tr("New Folder from Selection"),
        .folder_selection = selection,
    };
    dialog.edit.text.appendSlice(self.allocator, suggestion(prefix orelse "", shortest_stem)) catch {
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
    var view: @import("history.zig").View = .{ .scroll = self.scroll_y };
    defer view.deinit(self.allocator);
    // Use the listing's spelling of the path, including its separator at "/".
    const selected = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
        self.history.current, std.fs.path.basename(destination),
    }) catch return false;
    view.selected.append(self.allocator, selected) catch {
        self.allocator.free(selected);
        return false;
    };
    view.focus = self.allocator.dupe(u8, selected) catch return false;
    view.anchor = self.allocator.dupe(u8, selected) catch return false;
    self.history.navigate(destination) catch return false;
    const parent = &self.history.back_stack.items[self.history.back_stack.items.len - 1];
    parent.view.deinit(self.allocator);
    parent.view = view;
    view = .{};
    self.applyHistoryNav(self.history.current);
    return true;
}

test "group name trims separators and never splits a UTF-8 character" {
    try std.testing.expectEqualStrings("Trip", suggestion(commonPrefix("Trip - 01", "Trip - 02"), 9));
    try std.testing.expectEqualStrings("Caf", suggestion(commonPrefix("Café", "Cafè"), 5));
    try std.testing.expectEqualStrings("New Folder", suggestion(commonPrefix("a", "b"), 1));
}

test "file menu suggests a selected name and excludes ineligible selections" {
    var app = try @import("app_tests.zig").testApp();
    defer app.deinit();
    app.loading = false;
    const Action = @import("app_model.zig").FileAction;
    for ([_][]const u8{ "Trip - 01.jpg", "Trip - 02.png" }, [_][]const u8{ "/tmp/Trip - 01.jpg", "/tmp/Trip - 02.png" }) |name, path| {
        try app.items.append(app.allocator, .{
            .name = name,
            .path = path,
            .is_dir = false,
            .is_symlink = false,
            .is_broken = false,
            .bytes = 0,
            .mtime = 0,
            .mode = c.S_IFREG,
            .icon_name = "",
            .selected = true,
        });
    }
    const row = std.mem.indexOfScalar(Action, app.fileActions(), .new_folder_from_selection).?;
    app.openMenu(.file, 0, 0);
    app.runMenu(row);
    try std.testing.expectEqualStrings("Trip", app.dialog.?.edit.text.items);
    try std.testing.expect(app.dialog.?.edit.select_all);
    try std.testing.expectEqual(@as(usize, 2), app.dialog.?.folder_selection.?.paths.len);
    app.closeDialog();

    app.items.items[1].transfer_stub = true;
    try std.testing.expect(!eligible(&app));
    app.items.items[1].transfer_stub = false;
    app.transfer_browse_root = try app.allocator.dupe(u8, "/tmp");
    try std.testing.expect(!eligible(&app));
}

test "group move completion does not navigate after a tab or folder change" {
    var app = try @import("app_tests.zig").testApp();
    defer app.deinit();
    const tag = 1;
    app.service.transfers.items[0] = .{
        .tag = tag,
        .move = true,
        .destination = try app.allocator.dupe(u8, "/tmp/old-tab/Trip"),
        .sources = try @import("app_requests.zig").dupeAll(app.allocator, &.{"/tmp/old-tab/Trip 01.jpg"}),
        .cut_revision = null,
        .folder_navigation = app.navigation_count,
    };
    app.service.transfers.len = 1;
    app.navigation_count += 1;
    try std.testing.expect(@import("app_transfers.zig").onRecord(&app, .{
        .submit_tag = tag,
        .state = .completed,
    }));
    try std.testing.expectEqualStrings("/tmp", app.history.current);
    try std.testing.expect(!app.history.canBack());
}
