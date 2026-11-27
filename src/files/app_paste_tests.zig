//! Context-menu paste through the same service as ordinary clipboard paste.
const std = @import("std");
const c = @import("c.zig").api;
const App = @import("app.zig").App;
const Action = @import("app_model.zig").FileAction;
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");
const ServiceApp = @import("app_transfers_tests.zig").ServiceApp;
const allocator = std.testing.allocator;

fn selectedDirectory(app: *App, path: []const u8) !void {
    app.loading = false;
    try app.items.append(app.allocator, .{
        .name = std.fs.path.basename(path),
        .path = path,
        .is_dir = true,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 0,
        .mtime = 0,
        .mode = c.S_IFDIR,
        .icon_name = "",
        .selected = true,
    });
}

fn hasAction(app: *App, action: Action) bool {
    return std.mem.indexOfScalar(Action, app.fileActions(), action) != null;
}

fn requestFolderPaste(app: *App) ![]u8 {
    const row = std.mem.indexOfScalar(Action, app.fileActions(), .paste_into_folder) orelse
        return error.MissingFolderPaste;
    app.openMenu(.file, 0, 0);
    app.runMenu(row);
    const folder = app.paste_folder_requested orelse return error.MissingPasteRequest;
    app.paste_folder_requested = null;
    try std.testing.expect(!app.paste_requested);
    return folder;
}

fn idle(app: *App) bool {
    return app.service.transfers.len == 0;
}

fn conflictShown(app: *App) bool {
    return if (app.dialog) |dialog| dialog.kind == .conflict else false;
}

test "folder paste replaces Paste only for one directory and a file clipboard" {
    var app = try @import("app_tests.zig").testApp();
    defer app.deinit();
    try selectedDirectory(&app, "/tmp/subfolder");
    try std.testing.expect(hasAction(&app, .paste));
    app.clipboard_offer_files = true;
    try std.testing.expect(hasAction(&app, .paste_into_folder));
    try std.testing.expect(!hasAction(&app, .paste));
    try std.testing.expect(!hasAction(&app, .new_folder_from_selection));

    app.openMenu(.background, 0, 0);
    try std.testing.expectEqualStrings("Paste", app.menuLabels()[2]);
    app.items.items[0].is_dir = false;
    try std.testing.expect(hasAction(&app, .paste));
    try std.testing.expect(!hasAction(&app, .paste_into_folder));
    app.items.items[0].is_dir = true;
    try selectedDirectory(&app, "/tmp/other");
    try std.testing.expect(hasAction(&app, .paste));
    try std.testing.expect(!hasAction(&app, .paste_into_folder));
    try std.testing.expectEqual(Action.new_folder_from_selection, app.fileActions()[0]);
}

test "copy into selected folder keeps the clipboard and handles conflicts while Ctrl+V pastes here" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const source_dir = try support.join(allocator, temp, "source");
    defer allocator.free(source_dir);
    const source = try support.join(allocator, source_dir, "file.txt");
    defer allocator.free(source);
    const destination = try support.join(allocator, temp, "folder");
    defer allocator.free(destination);
    const nested = try support.join(allocator, destination, "file.txt");
    defer allocator.free(nested);
    const ordinary = try support.join(allocator, temp, "file.txt");
    defer allocator.free(ordinary);
    try support.makeDirectory(source_dir);
    try support.makeDirectory(destination);
    try support.writeFile(source, "copied");

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    try s.app.history.navigate(temp);
    try selectedDirectory(&s.app, destination);
    try s.app.clipboard_paths.append(allocator, try allocator.dupe(u8, source));

    const folder = try requestFolderPaste(&s.app);
    defer allocator.free(folder);
    s.app.executePasteLocal(folder);
    try s.until(idle);
    try support.waitForContents(nested, "copied");
    try std.testing.expect(!support.pathExists(ordinary));
    try std.testing.expect(support.pathExists(source));
    try std.testing.expectEqualStrings(source, s.app.clipboard_paths.items[0]);

    support.cleanup(nested, false);
    try support.writeFile(nested, "keep this");
    s.app.executePasteLocal(folder);
    try s.until(conflictShown);
    try std.testing.expectEqualStrings("file.txt", s.app.dialog.?.conflict_name.?);
    s.app.resolveConflictDialog(.skip);
    try s.until(idle);
    try support.waitForContents(nested, "keep this");

    s.app.ctrl = true;
    s.app.handleKey(c.XKB_KEY_v, "");
    try std.testing.expect(s.app.paste_requested and s.app.paste_folder_requested == null);
    s.app.executePasteLocal(null);
    try s.until(idle);
    try support.waitForContents(ordinary, "copied");
    try std.testing.expectEqualStrings(temp, s.app.history.current);
    try std.testing.expectEqualStrings(source, s.app.clipboard_paths.items[0]);
}

test "local and external cuts into the selected folder move items and clear the cut clipboard" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const destination = try support.join(allocator, temp, "folder");
    defer allocator.free(destination);
    try support.makeDirectory(destination);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    try s.app.history.navigate(temp);
    try selectedDirectory(&s.app, destination);

    for ([_][]const u8{ "local.txt", "external.txt" }, 0..) |name, index| {
        const source = try support.join(allocator, temp, name);
        defer allocator.free(source);
        const target = try support.join(allocator, destination, name);
        defer allocator.free(target);
        try support.writeFile(source, name);
        if (index == 0) {
            try s.app.clipboard_paths.append(allocator, try allocator.dupe(u8, source));
            s.app.clipboard_cut = true;
        } else s.app.clipboard_offer_files = true;

        s.app.loading = false;
        const folder = try requestFolderPaste(&s.app);
        defer allocator.free(folder);
        if (index == 0) {
            s.app.executePasteLocal(folder);
        } else {
            s.app.executePasteExternal(.cut, &.{source}, folder);
        }
        try s.until(idle);
        try support.waitForContents(target, name);
        try std.testing.expect(!support.pathExists(source));
        try std.testing.expectEqual(@as(usize, 0), s.app.clipboard_paths.items.len);
        try std.testing.expect(!s.app.clipboard_cut);
        try std.testing.expectEqualStrings(temp, s.app.history.current);
    }
}

test "directory copy and move reject an aliased descendant destination" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent = try support.join(a, temp, "parent");
    const source = try support.join(a, parent, "source");
    const child = try support.join(a, source, "child");
    const parent_alias = try support.join(a, temp, "parent-alias");
    const source_alias = try support.join(a, parent_alias, "source");
    const destination = try support.join(a, temp, "destination-alias");
    const unwanted = try support.join(a, child, "source");
    try support.makeDirectory(parent);
    try support.makeDirectory(source);
    try support.makeDirectory(child);
    try support.makeSymlink(parent, parent_alias);
    try support.makeSymlink(child, destination);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    try s.app.history.navigate(temp);
    try selectedDirectory(&s.app, destination);
    s.app.items.items[0].is_symlink = true;
    try s.app.clipboard_paths.append(allocator, try allocator.dupe(u8, source_alias));

    for ([_]bool{ false, true }) |cut| {
        s.app.clipboard_cut = cut;
        const folder = try requestFolderPaste(&s.app);
        defer allocator.free(folder);
        s.app.executePasteLocal(folder);
        try s.until(idle);
        try std.testing.expectEqualStrings("Cannot drop a folder into itself", s.app.status_notice.?);
        try std.testing.expectEqualStrings(source_alias, s.app.clipboard_paths.items[0]);
        try std.testing.expectEqual(cut, s.app.clipboard_cut);
        try std.testing.expect(support.pathExists(source));
        try std.testing.expect(!support.pathExists(unwanted));
    }
}

test "paste through an aliased source parent duplicates copies and preserves cuts" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent = try support.join(a, temp, "parent");
    const destination = try support.join(a, temp, "parent-alias");
    const source = try support.join(a, parent, "file.txt");
    const source_spelling = try std.fmt.allocPrint(a, "{s}//./file.txt", .{parent});
    const duplicate = try support.join(a, parent, "file (1).txt");
    const unexpected_copy = try support.join(a, parent, "file (2).txt");
    try support.makeDirectory(parent);
    try support.makeSymlink(parent, destination);
    try support.writeFile(source, "original");

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    try s.app.history.navigate(temp);
    try selectedDirectory(&s.app, destination);
    s.app.items.items[0].is_symlink = true;
    try s.app.clipboard_paths.append(allocator, try allocator.dupe(u8, source_spelling));

    const folder = try requestFolderPaste(&s.app);
    defer allocator.free(folder);
    s.app.executePasteLocal(folder);
    try s.until(idle);
    try support.waitForContents(source, "original");
    try support.waitForContents(duplicate, "original");

    s.app.clipboard_cut = true;
    s.app.executePasteLocal(folder);
    try s.until(idle);
    try std.testing.expectEqualStrings("The items are already here", s.app.status_notice.?);
    try support.waitForContents(source, "original");
    try std.testing.expect(!support.pathExists(unexpected_copy));
    try std.testing.expectEqualStrings(source_spelling, s.app.clipboard_paths.items[0]);
    try std.testing.expect(s.app.clipboard_cut);
}

test "paste accepts an unrelated directory alias and copies symlink entries literally" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try support.join(a, temp, "source");
    const destination = try support.join(a, temp, "destination");
    const parent_alias = try support.join(a, temp, "parent-alias");
    const source_alias = try support.join(a, parent_alias, "source");
    const alias = try support.join(a, source, "alias");
    const link = try support.join(a, temp, "dangling-link");
    const link_spelling = try std.fmt.allocPrint(a, "{s}/", .{link});
    const copied_dir = try support.join(a, destination, "source");
    const copied_link = try support.join(a, destination, "dangling-link");
    const move_source = try support.join(a, temp, "move-source");
    const move_alias = try support.join(a, parent_alias, "move-source");
    const moved = try support.join(a, destination, "move-source");
    const moved_file = try support.join(a, moved, "contents.txt");
    const contents = try support.join(a, move_source, "contents.txt");
    const move_link = try support.join(a, temp, "move-link");
    const move_link_alias = try support.join(a, parent_alias, "move-link");
    const moved_link = try support.join(a, destination, "move-link");
    try support.makeDirectory(source);
    try support.makeDirectory(destination);
    try support.makeSymlink(destination, alias);
    try support.makeSymlink(temp, parent_alias);
    try support.makeSymlink("missing-target", link);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    try s.app.history.navigate(source);
    try selectedDirectory(&s.app, alias);
    s.app.items.items[0].is_symlink = true;
    for ([_][]const u8{ source_alias, link_spelling }) |path|
        try s.app.clipboard_paths.append(allocator, try allocator.dupe(u8, path));

    const folder = try requestFolderPaste(&s.app);
    defer allocator.free(folder);
    s.app.executePasteLocal(folder);
    try s.until(idle);
    try std.testing.expectEqualStrings("Items copied", s.app.status_notice.?);
    try std.testing.expect(support.pathExists(copied_dir));
    const link_target = try support.readLink(a, copied_link);
    try std.testing.expectEqualStrings("missing-target", link_target);
    try support.makeDirectory(move_source);
    try support.writeFile(contents, "moved");
    try support.makeSymlink("missing-target", move_link);
    s.app.clearClipboard();
    s.app.clipboard_cut = true;
    for ([_][]const u8{ move_alias, move_link_alias }) |path|
        try s.app.clipboard_paths.append(allocator, try allocator.dupe(u8, path));

    s.app.executePasteLocal(folder);
    try s.until(idle);
    try std.testing.expectEqualStrings("Items moved", s.app.status_notice.?);
    try support.waitForContents(moved_file, "moved");
    try std.testing.expect(!support.pathExists(move_source));
    try std.testing.expect(!support.pathExists(move_link));
    try std.testing.expectEqualStrings("missing-target", try support.readLink(a, moved_link));
    try std.testing.expectEqual(@as(usize, 0), s.app.clipboard_paths.items.len);
    try std.testing.expectEqualStrings(source, s.app.history.current);
}
