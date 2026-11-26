const std = @import("std");
const folder_views = @import("folder_views.zig");
const Store = folder_views.Store;
const files_tests = @import("../files_tests.zig");
const ops_mod = @import("ops.zig");

test "folder views round-trip, forget empty views and skip bad lines" {
    var store: Store = undefined;
    try store.start(std.testing.io, null);
    defer store.deinit();
    store.set("/home/u/Pictures", .{ .list = false, .sort = 3 });
    store.set("/home/u/src", .{ .folders_first = false });
    store.set("/bad\nname", .{ .list = true });
    store.set("/home/u/gone", .{ .list = true });
    store.set("/home/u/gone", .{});
    try std.testing.expectEqual(@as(u32, 2), store.map.count());

    const bytes = try store.serialize();
    defer std.heap.c_allocator.free(bytes);
    try std.testing.expectEqualStrings("rediwm-folder-views 1\n0 3 -\t/home/u/Pictures\n- - 0\t/home/u/src\n", bytes);

    var copy: Store = undefined;
    try copy.start(std.testing.io, null);
    defer copy.deinit();
    copy.parse(bytes);
    copy.parse("rediwm-folder-views 1\n9 3 -\t/x\n- - -\t/y\n");
    try std.testing.expectEqual(@as(u32, 2), copy.map.count());
    try std.testing.expectEqual(folder_views.View{ .list = false, .sort = 3 }, copy.get("/home/u/Pictures"));
    try std.testing.expectEqual(folder_views.View{}, copy.get("/home/u"));
}

test "folder views evict the folder changed longest ago" {
    var store: Store = undefined;
    try store.start(std.testing.io, null);
    defer store.deinit();
    var buf: [32]u8 = undefined;
    for (0..folder_views.capacity + 1) |i| store.set(try std.fmt.bufPrint(&buf, "/d{d}", .{i}), .{ .list = true });
    try std.testing.expectEqual(@as(u32, folder_views.capacity), store.map.count());
    try std.testing.expectEqual(folder_views.View{}, store.get("/d0"));
    try std.testing.expectEqual(folder_views.View{ .list = true }, store.get("/d1"));
}

test "folder views reach the disk from the writer thread" {
    var tmp_buf: [256]u8 = undefined;
    const tmp = try files_tests.makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(std.testing.allocator, tmp) catch {};
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state/views", .{tmp});
    defer std.testing.allocator.free(path);
    {
        var store: Store = undefined;
        try store.start(std.testing.io, path);
        defer store.deinit();
        store.set("/home/u", .{ .sort = 2 });
    }
    var again: Store = undefined;
    try again.start(std.testing.io, path);
    defer again.deinit();
    try std.testing.expectEqual(folder_views.View{ .sort = 2 }, again.get("/home/u"));
}
