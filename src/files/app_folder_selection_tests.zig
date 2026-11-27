const std = @import("std");
const c = @import("c.zig").api;
const grouping = @import("app_folder_selection.zig");

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
    try std.testing.expect(!grouping.eligible(&app));
    app.items.items[1].transfer_stub = false;
    app.transfer_browse_root = try app.allocator.dupe(u8, "/tmp");
    try std.testing.expect(!grouping.eligible(&app));
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

test "group suggestion skips names from the view and the underlying listing" {
    var app = try @import("app_tests.zig").testApp();
    defer app.deinit();
    app.loading = false;
    const snapshot = try std.heap.c_allocator.create(@import("worker.zig").Snapshot);
    snapshot.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .request_id = 0,
        .dir = "/tmp",
        .items = &.{},
    };
    app.snapshot = snapshot;
    const listing = try snapshot.arena.allocator().alloc(@import("worker.zig").Item, 2);
    for (listing, [_][]const u8{ "Trip", "Trip (1)" }) |*item, name| {
        item.* = .{ .name = name, .path = name, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "" };
    }
    snapshot.items = listing;

    for ([_]struct {
        names: []const []const u8,
        expected: []const u8,
        is_dir: bool = false,
    }{
        .{ .names = &.{"Photos"}, .expected = "Photos (1)", .is_dir = true },
        .{ .names = &.{"README"}, .expected = "README (1)" },
        .{ .names = &.{ "Trip 01.jpg", "Trip 02.jpg" }, .expected = "Trip (2)" },
    }) |case| {
        app.items.clearRetainingCapacity();
        for (case.names) |name| {
            const path = try std.fs.path.join(app.items_arena.allocator(), &.{ "/tmp", name });
            try app.items.append(app.allocator, .{
                .name = name,
                .path = path,
                .mode = if (case.is_dir) c.S_IFDIR else c.S_IFREG,
                .is_dir = case.is_dir,
                .is_symlink = false,
                .is_broken = false,
                .bytes = 0,
                .mtime = 0,
                .icon_name = "",
                .selected = true,
            });
        }
        grouping.openDialog(&app);
        try std.testing.expectEqualStrings(case.expected, app.dialog.?.edit.text.items);
        try std.testing.expect(app.dialog.?.edit.select_all);
        app.closeDialog();
    }
}
