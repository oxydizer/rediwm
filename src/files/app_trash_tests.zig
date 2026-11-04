//! Files Trash view tests: which actions each location offers, and that the
//! Trash stays read-only apart from Restore and permanent deletion.

const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const FileAction = @import("app_model.zig").FileAction;
const app_tests = @import("app_tests.zig");
const testApp = app_tests.testApp;
const testItems = app_tests.testItems;

const trash_files = "/xdg/Trash/files";

fn backgroundLabels(app: *App) []const []const u8 {
    app.menu = .background;
    return app.menuLabels();
}

fn trashApp() !App {
    var app = try testApp();
    errdefer app.deinit();
    app.trash_dir = try std.testing.allocator.dupe(u8, trash_files);
    try testItems(&app, 2);
    app.items.items[0].selected = true;
    return app;
}

test "the item menu is Trash-specific only in the Trash" {
    var app = try trashApp();
    defer app.deinit();

    try std.testing.expect(std.mem.indexOfScalar(FileAction, app.fileActions(), .trash) != null);
    try std.testing.expect(std.mem.indexOfScalar(FileAction, app.fileActions(), .restore) == null);

    try app.history.navigate(trash_files);
    try std.testing.expectEqualSlices(FileAction, &.{ .open, .copy, .restore, .delete_permanently, .properties }, app.fileActions());

    try app.history.navigate(trash_files ++ "/Old Folder");
    try std.testing.expectEqualSlices(FileAction, &.{ .open, .copy, .properties }, app.fileActions());
}

test "Restore is faded when no selected entry has metadata" {
    var app = try trashApp();
    defer app.deinit();
    try app.history.navigate(trash_files);

    app.openMenu(.file, 100, 100);
    try std.testing.expect(!app.trash_restorable);
    const restore_row = std.mem.indexOfScalar(FileAction, app.fileActions(), .restore).?;
    try std.testing.expect(app.menuDisabled(restore_row));
    try std.testing.expect(!app.menuDisabled(restore_row + 1));
    // Activating it explains itself and leaves the menu open.
    app.runMenu(restore_row);
    try std.testing.expect(app.menu != null);
    try std.testing.expect(app.status_is_error);
}

test "the empty-space menu manages the Trash and only refreshes inside it" {
    var app = try trashApp();
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 4), backgroundLabels(&app).len);
    try app.history.navigate(trash_files);
    const labels = backgroundLabels(&app);
    try std.testing.expectEqual(@as(usize, 3), labels.len);
    try std.testing.expectEqualStrings("Empty Trash…", labels[0]);
    try std.testing.expectEqualStrings("Restore All", labels[1]);
    try std.testing.expectEqualStrings("Refresh", labels[2]);

    try app.history.navigate(trash_files ++ "/Old Folder");
    try std.testing.expectEqual(@as(usize, 1), backgroundLabels(&app).len);
}

test "toolbar buttons that create or move are off in the Trash" {
    var app = try trashApp();
    defer app.deinit();
    const header = @import("header.zig");

    for ([_]header.Action{ .new, .cut, .paste }) |action| try std.testing.expect(app.toolbarButtonEnabled(action));
    try app.history.navigate(trash_files);
    for ([_]header.Action{ .new, .cut, .paste }) |action| try std.testing.expect(!app.toolbarButtonEnabled(action));
    try std.testing.expect(app.toolbarButtonEnabled(.copy));
    try std.testing.expect(app.toolbarButtonEnabled(.trash));
    try app.history.navigate(trash_files ++ "/Old Folder");
    try std.testing.expect(!app.toolbarButtonEnabled(.trash));
}

test "Delete in the Trash asks for permanent deletion with no choice to make" {
    var app = try trashApp();
    defer app.deinit();
    try app.history.navigate(trash_files);

    for ([_]bool{ false, true }) |shift| {
        app.shift = shift;
        app.handleKey(c.XKB_KEY_Delete, "");
        try std.testing.expect(app.dialog != null);
        const state = app.dialog.?.deletion;
        try std.testing.expect(state.in_trash and state.permanent and state.fixedChoice());
        // The toggle has no area, so the dialog cannot be flipped to "Move to Trash".
        try std.testing.expectEqual(@as(f32, 0), state.geometry(800, 600).toggle.w);
        app.deleteAction(.toggle);
        try std.testing.expect(app.dialog.?.deletion.permanent);
        app.closeDialog();
    }

    // Inside a trashed folder the key explains instead of deleting.
    try app.history.navigate(trash_files ++ "/Old Folder");
    app.handleKey(c.XKB_KEY_Delete, "");
    try std.testing.expect(app.dialog == null);
}

test "the Trash refuses new, renamed, cut and pasted items" {
    var app = try trashApp();
    defer app.deinit();
    try app.history.navigate(trash_files);
    app.focused_index = 0;

    app.openNewFolderDialog();
    app.openNewFileDialog();
    app.openRenameDialog();
    try std.testing.expect(app.dialog == null);
    app.cutSelected();
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    // Copy still works, so items can be duplicated out of the Trash.
    app.copySelected();
    try std.testing.expectEqual(@as(usize, 1), app.clipboard_paths.items.len);

    // Neither a paste nor a drop lands in the Trash or in a folder inside it.
    try std.testing.expect(!app.executeTransfer(.copy, &.{"/tmp/a"}, trash_files, false));
    try std.testing.expect(!app.executeTransfer(.move, &.{"/tmp/a"}, trash_files ++ "/Old Folder", true));
    try std.testing.expect(app.status_is_error);
}
