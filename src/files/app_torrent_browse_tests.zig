//! A torrent browsed as a folder: rows, checkboxes, Space, the status bar,
//! and a painted window (REDIWM_FILES_SHOTS=<dir> keeps the pictures).
const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const browse = @import("app_torrent_browse.zig");
const torrents = @import("torrents.zig");
const app_tests = @import("app_tests.zig");

const files = [_]torrents.Entry{
    .{ .index = 0, .path = "Show/Season 1/e1.mkv", .size = 700 << 20, .done = 700 << 20, .wanted = true },
    .{ .index = 1, .path = "Show/Season 1/e2.mkv", .size = 700 << 20, .done = 210 << 20, .wanted = true },
    .{ .index = 2, .path = "Show/Season 2/e1.mkv", .size = 800 << 20, .done = 300 << 20, .wanted = true },
    .{ .index = 5, .path = "Show/Season 2/e2.mkv", .size = 800 << 20 },
    .{ .index = 3, .path = "Show/cover.jpg", .size = 90 << 10, .done = 90 << 10, .wanted = true },
    .{ .index = 4, .path = "Show/notes.txt", .size = 4 << 10 },
};

fn enter(app: *App) !*browse.Browse {
    // Wide enough for the names.
    app.column_widths = .{ 250, 90, 80, 120, 100 };
    try app.history.navigateTorrent("/tmp/Show.torrent");
    const b = try browse.Browse.create(app.allocator, "/tmp/Show.torrent");
    app.torrent_browse = b;
    try b.take(.{ .id = "abc", .name = "Show", .files = &files }, true);
    b.phase = .ready;
    app.loading = false;
    app.rebuildView();
    return b;
}

fn row(app: *App, name: []const u8) usize {
    for (app.items.items, 0..) |item, i| if (std.mem.eql(u8, item.name, name)) return i;
    unreachable;
}

test "a torrent's top shows its folders and files as ghosts with ticks" {
    var app = try app_tests.testApp();
    defer app.deinit();
    const b = try enter(&app);
    try std.testing.expect(browse.active(&app));
    try std.testing.expectEqual(@as(usize, 4), app.items.items.len);
    const season1 = app.items.items[row(&app, "Season 1")];
    try std.testing.expect(season1.is_dir and season1.transfer_ghost);
    try std.testing.expect(season1.transfer_progress != null);
    const cover = app.items.items[row(&app, "cover.jpg")];
    // Finished: a real file.
    try std.testing.expect(!cover.transfer_ghost and !cover.missing);
    const notes = app.items.items[row(&app, "notes.txt")];
    try std.testing.expect(notes.transfer_ghost and notes.transfer_state.? == .pending);
    try std.testing.expectEqualStrings("Show", browse.crumbLabel(&app, "Show.torrent"));
    var buf: [512]u8 = undefined;
    const status = browse.statusText(&app, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, status, "4 of 6 files ticked") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "into /tmp") != null);

    // A folder's checkbox ticks everything in it; then unticks it.
    try std.testing.expect(browse.toggleItem(&app, row(&app, "Season 2")));
    try std.testing.expect(b.wanted.isSet(2) and b.wanted.isSet(5));
    try std.testing.expect(browse.toggleItem(&app, row(&app, "Season 2")));
    try std.testing.expect(!b.wanted.isSet(2) and !b.wanted.isSet(5));
    try std.testing.expect(browse.toggleItem(&app, row(&app, "Season 1")));
    try std.testing.expect(!b.wanted.isSet(0) and !b.wanted.isSet(1));

    // Space ticks the selected rows; again unticks them.
    for (app.items.items) |*item| item.selected = std.mem.eql(u8, item.name, "notes.txt") or std.mem.eql(u8, item.name, "Season 1");
    try std.testing.expect(browse.toggleSelected(&app));
    try std.testing.expect(b.wanted.isSet(0) and b.wanted.isSet(1) and b.wanted.isSet(4));
    try std.testing.expect(browse.toggleSelected(&app));
    try std.testing.expect(!b.wanted.isSet(0) and !b.wanted.isSet(4));

    // Into a folder of the torrent: the browse stays.
    app.navigate("/tmp/Show.torrent/Season 1");
    try std.testing.expect(app.torrent_browse == b);
    try std.testing.expectEqual(@as(usize, 2), app.items.items.len);
    // Out of the torrent (the listing worker is not in this test): it goes.
    _ = try app.history.back();
    _ = try app.history.back();
    try std.testing.expect(!browse.active(&app));
    browse.leave(&app);
    try std.testing.expect(app.torrent_browse == null);
}

test "checkbox geometry sits in front of list rows and in grid corners" {
    var app = try app_tests.testApp();
    defer app.deinit();
    app.w = 760;
    app.h = 520;
    _ = try enter(&app);
    for ([_]bool{ true, false }) |list| {
        app.list_view = list;
        for (0..app.items.items.len) |i| {
            const r = browse.checkRect(&app, i).?;
            const icon = app.itemIconRect(@intCast(i));
            try std.testing.expect(r.x + r.w <= icon.x or r.x >= icon.x + icon.w);
            try std.testing.expectEqual(@as(?usize, i), browse.checkHit(&app, r.x + r.w / 2, r.y + r.h / 2));
        }
    }
}

test "a painted torrent folder" {
    var app = try app_tests.testApp();
    defer app.deinit();
    app.w = 760;
    app.h = 420;
    _ = try enter(&app);
    const shots = std.c.getenv("REDIWM_FILES_SHOTS");
    for ([_]bool{ true, false }) |list| {
        app.list_view = list;
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, app.w, app.h).?;
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf).?;
        defer c.cairo_destroy(cr);
        app.render(cr);
        if (shots) |dir| {
            var path: [512]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&path, "{s}/torrent-{s}.png", .{ std.mem.span(dir), if (list) "list" else "grid" }, 0) catch continue;
            _ = c.cairo_surface_write_to_png(surf, name.ptr);
        }
    }
}
