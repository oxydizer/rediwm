const std = @import("std");
const tree = @import("torrent_tree.zig");
const Entry = @import("torrents.zig").Entry;

const files = [_]Entry{
    .{ .index = 0, .path = "Show/S1/e1.mkv", .size = 100, .done = 100 },
    .{ .index = 1, .path = "Show/S1/e2.mkv", .size = 100, .done = 40 },
    .{ .index = 2, .path = "Show/S2/e1.mkv", .size = 200 },
    .{ .index = 3, .path = "Show/readme.txt", .size = 5, .done = 5 },
};

fn wantedOf(indices: []const usize) tree.Wanted {
    var w = tree.Wanted.empty;
    for (indices) |i| w.set(i);
    return w;
}

test "a multi-file torrent is browsed from inside its folder" {
    try std.testing.expectEqualStrings("Show", tree.base(&files));
    try std.testing.expectEqualStrings("", tree.base(&.{.{ .index = 0, .path = "disk.iso", .size = 1 }}));
    try std.testing.expectEqualStrings("", tree.base(&.{
        .{ .index = 0, .path = "a/x", .size = 1 },
        .{ .index = 1, .path = "b/y", .size = 1 },
    }));
    // A file named like the folder's prefix is not inside it.
    try std.testing.expectEqualStrings("", tree.base(&.{
        .{ .index = 0, .path = "a/x", .size = 1 },
        .{ .index = 1, .path = "ab", .size = 1 },
    }));
}

test "folders sum what is under them and show three states" {
    const wanted = wantedOf(&.{ 0, 3 });
    const rows = try tree.children(std.testing.allocator, &files, "Show", "", &wanted);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("S1", rows[0].name);
    try std.testing.expect(rows[0].is_dir);
    try std.testing.expectEqual(tree.Check.some, rows[0].check);
    try std.testing.expectEqual(@as(i64, 200), rows[0].size);
    try std.testing.expectEqual(@as(i64, 140), rows[0].done);
    try std.testing.expectEqual(@as(i64, 100), rows[0].wanted_size);
    try std.testing.expect(!rows[0].finished);
    try std.testing.expectEqual(tree.Check.none, rows[1].check);
    try std.testing.expectEqualStrings("readme.txt", rows[2].name);
    try std.testing.expect(!rows[2].is_dir and rows[2].finished);
    try std.testing.expectEqual(tree.Check.all, rows[2].check);
    try std.testing.expectEqual(@as(usize, 3), rows[2].index);

    const season = try tree.children(std.testing.allocator, &files, "Show", "S1", &wanted);
    defer std.testing.allocator.free(season);
    try std.testing.expectEqual(@as(usize, 2), season.len);
    try std.testing.expectEqual(tree.Check.all, season[0].check);
    try std.testing.expect(season[0].finished);
    try std.testing.expectEqual(tree.Check.none, season[1].check);
}

test "a folder's checkbox ticks everything inside it, then unticks it" {
    var wanted = wantedOf(&.{0});
    try std.testing.expect(tree.toggle(&files, "Show", "S1", &wanted));
    try std.testing.expect(wanted.isSet(0) and wanted.isSet(1) and !wanted.isSet(2));
    try std.testing.expect(tree.toggle(&files, "Show", "S1", &wanted));
    try std.testing.expect(!wanted.isSet(0) and !wanted.isSet(1));
    // A file name sharing a folder's prefix is not under it.
    try std.testing.expect(!tree.under("Show", "S1", "Show/S10/x"));
    try std.testing.expect(tree.toggle(&files, "Show", "readme.txt", &wanted));
    try std.testing.expect(wanted.isSet(3));
    try std.testing.expect(!tree.toggle(&files, "Show", "nothing", &wanted));
    // The whole torrent.
    try std.testing.expect(tree.toggle(&files, "Show", "", &wanted));
    try std.testing.expectEqual(@as(usize, 4), wanted.count());
}

test "totals count what is ticked" {
    const wanted = wantedOf(&.{ 1, 2 });
    const t = tree.totals(&files, &wanted);
    try std.testing.expectEqual(@as(usize, 4), t.files);
    try std.testing.expectEqual(@as(usize, 2), t.ticked);
    try std.testing.expectEqual(@as(i64, 300), t.wanted_size);
    try std.testing.expectEqual(@as(i64, 40), t.wanted_done);
    try std.testing.expect(tree.hasFolder(&files, "Show", "S2"));
    try std.testing.expect(!tree.hasFolder(&files, "Show", "S3"));
    try std.testing.expect(!tree.hasFolder(&files, "Show", "readme.txt"));
}
