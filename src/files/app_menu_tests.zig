const std = @import("std");
const App = @import("app.zig").App;
const listing = @import("app_listing.zig");
const places = @import("app_places.zig");
const fixtures = @import("app_tests.zig");
const worker = @import("worker.zig");
const c = @import("c.zig").api;
const FileAction = @import("app_model.zig").FileAction;
const Volume = @import("volumes.zig").Volume;

const repeated: worker.Item = .{
    .name = "000-repeat",
    .path = "/tmp/000-repeat",
    .is_dir = true,
    .is_symlink = false,
    .is_broken = false,
    .entry_key = .{ .dev = 1, .ino = 1 },
    .bytes = 0,
    .mtime = 0,
    .icon_name = "",
};
const archive: worker.Item = .{
    .name = "Archive",
    .path = "/tmp/Archive",
    .is_dir = true,
    .is_symlink = false,
    .is_broken = false,
    .entry_key = .{ .dev = 1, .ino = 2 },
    .bytes = 0,
    .mtime = 0,
    .icon_name = "",
};

fn refresh(app: *App, items: []const worker.Item) !void {
    const allocator = std.heap.c_allocator;
    const snapshot = try allocator.create(worker.Snapshot);
    var arena = std.heap.ArenaAllocator.init(allocator);
    const rows = arena.allocator().dupe(worker.Item, items) catch |err| {
        arena.deinit();
        allocator.destroy(snapshot);
        return err;
    };
    snapshot.* = .{
        .arena = arena,
        .request_id = app.active_request_id,
        .dir = "/tmp",
        .items = rows,
    };
    listing.applySnapshot(app, snapshot);
}

fn rightClick(app: *App, index: usize) void {
    const point = fixtures.pointOnItem(app, index);
    app.handleMotion(point[0], point[1]);
    app.handleButton(0x111, true);
    app.handleButton(0x111, false);
}

test "empty context menu geometry and keyboard and pointer input are safe" {
    var app = try fixtures.testApp();
    defer app.deinit();
    app.openMenu(.file, 400, 150);
    try std.testing.expect(app.menu == null);
    app.menu_place = app.deviceBase();
    app.openMenu(.device, 400, 150);
    try std.testing.expect(app.menu == null);
    app.openMenu(.chooser_filter, 400, 150);
    try std.testing.expect(app.menu == null);

    app.menu = .file;
    app.menu_selected = 20;
    try std.testing.expectEqual(@as(usize, 0), app.menuRowHeight());
    try std.testing.expectEqual(@as(f64, 0), app.menuHeight());
    try std.testing.expectEqual(@as(f64, 0), app.menuRowRect(0).h);
    app.dirty = false;
    app.handleKey(c.XKB_KEY_Down, "");
    try std.testing.expect(app.menu == null and app.menu_selected == 0);
    try std.testing.expect(app.dirty and app.paint_damage == null);
    app.handleKey(c.XKB_KEY_Return, "");
    try std.testing.expect(app.dialog == null);

    try refresh(&app, &.{archive});
    rightClick(&app, 0);
    try std.testing.expect(app.menu == .file);
    app.items.items[0].selected = false;
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(app.menu == null and app.dialog == null);
    try std.testing.expect(!app.items.items[0].selected);
}

test "directory refresh dismisses the file menu when the clicked folder disappears" {
    var app = try fixtures.testApp();
    defer app.deinit();
    try refresh(&app, &.{ repeated, archive });
    rightClick(&app, 0);
    try std.testing.expect(app.menu == .file);
    try std.testing.expectEqualStrings(repeated.path, app.items.items[app.focused_index.?].path);
    const rename = std.mem.indexOfScalar(FileAction, app.fileActions(), .rename).?;
    const old_row = app.menuRowRect(rename);
    app.menu_selected = rename;
    app.dirty = false;
    app.addDamage(old_row);

    try refresh(&app, &.{archive});
    try std.testing.expect(app.menu == null and app.menu_selected == 0);
    try std.testing.expect(app.dirty and app.paint_damage == null);
    try std.testing.expect(app.focused_index == null and !app.hasSelection());
    app.runMenu(rename);
    app.handleKey(c.XKB_KEY_Return, "");
    app.handleMotion(old_row.x + 10, old_row.y + 5);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(app.dialog == null);
    try std.testing.expectEqualStrings(archive.path, app.items.items[0].path);
}

test "directory refresh keeps the context rename target when its row moves" {
    var app = try fixtures.testApp();
    defer app.deinit();
    try refresh(&app, &.{ repeated, archive });
    rightClick(&app, 1);
    try std.testing.expect(app.menu == .file);
    const rename = std.mem.indexOfScalar(FileAction, app.fileActions(), .rename).?;

    try refresh(&app, &.{archive});
    try std.testing.expect(app.menu == .file and app.items.items[0].selected);
    try std.testing.expectEqual(@as(?usize, 0), app.focused_index);
    const row = app.menuRowRect(rename);
    app.handleMotion(row.x + 10, row.y + 5);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expectEqualStrings(archive.path, app.dialog.?.target_path.?);
}

test "context menu closes when a selected path is replaced even if another target remains" {
    var app = try fixtures.testApp();
    defer app.deinit();
    try refresh(&app, &.{ repeated, archive });
    for (app.items.items) |*item| item.selected = true;
    rightClick(&app, 1);
    try std.testing.expect(app.menu == .file);
    var replacement = archive;
    replacement.entry_key.?.ino = 3;

    try refresh(&app, &.{ repeated, replacement });
    try std.testing.expect(app.menu == null);
    try std.testing.expect(app.items.items[0].selected);
    try std.testing.expect(!app.items.items[1].selected and app.focused_index == null);
}

test "device list refresh dismisses a menu at a reused sidebar index" {
    var app = try fixtures.testApp();
    defer app.deinit();
    const devices = [_]Volume{
        .{ .id = "/first", .label = "First", .mount = "/media/first", .size = 1, .kind = .stick },
        .{ .id = "/second", .label = "Second", .mount = null, .size = 1, .kind = .stick },
    };
    app.device_list.items = &devices;
    app.menu_place = app.deviceBase();
    app.openMenu(.device, 400, 150);
    try std.testing.expect(app.menu == .device);
    const row = app.menuRowRect(0);
    app.menu_selected = 2;
    app.dirty = false;
    app.addDamage(row);

    app.device_list.items = devices[1..];
    places.devicesChanged(&app);
    try std.testing.expect(app.menu == null and app.menu_selected == 0);
    try std.testing.expect(app.dirty and app.paint_damage == null);
    app.runMenu(0);
    app.handleMotion(row.x + 10, row.y + 5);
    try std.testing.expect(app.device_op == null);
}

test "an old file menu row cannot dispatch a changed action" {
    var app = try fixtures.testApp();
    defer app.deinit();
    try refresh(&app, &.{archive});
    rightClick(&app, 0);
    try std.testing.expect(app.menu == .file);
    const paste = std.mem.indexOfScalar(FileAction, app.fileActions(), .paste).?;
    app.clipboard_offer_files = true;
    try std.testing.expectEqual(FileAction.paste_into_folder, app.fileActions()[paste]);
    app.runMenu(paste);
    try std.testing.expect(app.menu == null and !app.paste_requested and app.paste_folder_requested == null);
}
