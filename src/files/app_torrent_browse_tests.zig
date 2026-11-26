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

/// The helper's end of a window's connection.
const FakeHelper = struct {
    fds: [2]c_int,

    fn init(app: *App) !FakeHelper {
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_NONBLOCK, 0, &fds) != 0) return error.SocketPair;
        app.torrents.fd = fds[0];
        return .{ .fds = fds };
    }

    fn deinit(self: *FakeHelper) void {
        _ = c.close(self.fds[1]);
    }

    /// The next request, parsed; the caller frees it.
    fn request(self: *FakeHelper) !std.json.Parsed(std.json.Value) {
        var buf: [65536]u8 = undefined;
        const n = c.recv(self.fds[1], &buf, buf.len, c.MSG_DONTWAIT);
        if (n <= 0) return error.NoRequest;
        return std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf[0..@intCast(n)], .{});
    }

    fn expect(self: *FakeHelper, op: []const u8) !std.json.Parsed(std.json.Value) {
        const parsed = try self.request();
        errdefer parsed.deinit();
        try std.testing.expectEqualStrings(op, parsed.value.object.get("op").?.string);
        return parsed;
    }

    fn send(self: *FakeHelper, app: *App, json: []const u8) void {
        _ = c.send(self.fds[1], json.ptr, json.len, 0);
        app.torrents.drain();
        browse.step(app);
    }
};

const transfer_json =
    \\{"transfers":[{"id":"abc","name":"bundle","source":"/tmp/dl/bundle.torrent","download_directory":"/tmp/dl",
    \\"destination":"/tmp/dl","storage":"/tmp/dl/.rediwm-partials/abc","pending":false,"metadata":true,"paused":false,
    \\"finished":false,"published":false,"progress":0,"download_rate":0,"upload_rate":0,"total":0,"done":0,
    \\"ratio":1,"limit":1048576,"error":"","files":[]}]}
;

test "a torrent file is looked into, its first tick adds it, later ticks select" {
    var app = try app_tests.testApp();
    defer app.deinit();
    var helper = try FakeHelper.init(&app);
    defer helper.deinit();
    try app.history.navigateTorrent("/tmp/dl/bundle.torrent");
    app.loading = false;
    browse.enter(&app);
    {
        const asked = try helper.expect("inspect");
        defer asked.deinit();
        try std.testing.expectEqualStrings("/tmp/dl/bundle.torrent", asked.value.object.get("source").?.string);
    }
    try std.testing.expectEqualStrings("Reading torrent…", browse.emptyText(&app).?);
    helper.send(&app,
        \\{"inspect":{"id":"abc","source":"/tmp/dl/bundle.torrent","name":"bundle","files":[
        \\{"index":0,"path":"bundle/a.bin","size":10},{"index":1,"path":"bundle/sub/b.bin","size":20},
        \\{"index":2,"path":"bundle/sub/c.bin","size":30}]}}
    );
    try std.testing.expectEqual(@as(usize, 2), app.items.items.len);
    try std.testing.expect(app.items.items[row(&app, "a.bin")].transfer_ghost);

    // The first tick adds it, with what is ticked, into the file's folder.
    try std.testing.expect(browse.toggleItem(&app, row(&app, "sub")));
    {
        const added = try helper.expect("add");
        defer added.deinit();
        try std.testing.expectEqualStrings("/tmp/dl", added.value.object.get("destination").?.string);
        const indices = added.value.object.get("files").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), indices.len);
        try std.testing.expectEqual(@as(i64, 1), indices[0].integer);
        try std.testing.expectEqual(@as(i64, 2), indices[1].integer);
    }
    // Ticked before the helper lists it: kept, and sent once it does.
    try std.testing.expect(browse.toggleItem(&app, row(&app, "a.bin")));
    try std.testing.expectError(error.NoRequest, helper.request());
    helper.send(&app, transfer_json);
    {
        const selected = try helper.expect("select");
        defer selected.deinit();
        try std.testing.expectEqual(@as(usize, 3), selected.value.object.get("files").?.array.items.len);
        const asked = try helper.expect("files");
        asked.deinit();
    }
    // A reply to a request from before the tick keeps the local ticks...
    try std.testing.expect(browse.toggleItem(&app, row(&app, "a.bin")));
    {
        const selected = try helper.expect("select");
        selected.deinit();
        const asked = try helper.expect("files");
        asked.deinit();
    }
    const detail_old =
        \\{"detail":{"id":"abc","files":[{"index":0,"path":"bundle/a.bin","size":10,"done":0,"wanted":true},
        \\{"index":1,"path":"bundle/sub/b.bin","size":20,"done":5,"wanted":true},
        \\{"index":2,"path":"bundle/sub/c.bin","size":30,"done":30,"wanted":true}]}}
    ;
    helper.send(&app, detail_old);
    try std.testing.expect(!app.torrent_browse.?.wanted.isSet(0));
    // ...and the reply after it carries the helper's.
    const detail_new =
        \\{"detail":{"id":"abc","files":[{"index":0,"path":"bundle/a.bin","size":10,"done":0,"wanted":false},
        \\{"index":1,"path":"bundle/sub/b.bin","size":20,"done":20,"wanted":true},
        \\{"index":2,"path":"bundle/sub/c.bin","size":30,"done":30,"wanted":true}]}}
    ;
    helper.send(&app, detail_new);
    const b = app.torrent_browse.?;
    try std.testing.expect(!b.wanted.isSet(0) and b.wanted.isSet(1) and b.wanted.isSet(2));
    // The folder has arrived: a real one now.
    const sub = app.items.items[row(&app, "sub")];
    try std.testing.expect(!sub.transfer_ghost and !sub.missing);
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, browse.statusText(&app, &buf).?, "2 of 3 files ticked") != null);
}

test "a magnet fetches its file list first" {
    var app = try app_tests.testApp();
    defer app.deinit();
    var helper = try FakeHelper.init(&app);
    defer helper.deinit();
    const magnet =
        \\{"transfers":[{"id":"abc","name":"Fetching file list…","source":"magnet:?xt=urn:btih:abc","download_directory":"/tmp/dl",
        \\"destination":"/tmp/dl","storage":"/tmp/dl/.rediwm-partials/abc","pending":true,"metadata":false,"paused":false,
        \\"finished":false,"published":false,"progress":0,"download_rate":0,"upload_rate":0,"total":0,"done":0,
        \\"ratio":1,"limit":1048576,"error":"","files":[]}]}
    ;
    _ = c.send(helper.fds[1], magnet.ptr, magnet.len, 0);
    app.torrents.drain();
    try app.history.navigateTorrent("/tmp/dl/abc");
    app.loading = false;
    browse.enter(&app);
    try std.testing.expectEqualStrings("Fetching file list…", browse.emptyText(&app).?);
    try std.testing.expectError(error.NoRequest, helper.request());
    // The metadata arrives: its files are asked for, and listed.
    helper.send(&app,
        \\{"transfers":[{"id":"abc","name":"bundle","source":"magnet:?xt=urn:btih:abc","download_directory":"/tmp/dl",
        \\"destination":"/tmp/dl","storage":"/tmp/dl/.rediwm-partials/abc","pending":true,"metadata":true,"paused":true,
        \\"finished":false,"published":false,"progress":0,"download_rate":0,"upload_rate":0,"total":0,"done":0,
        \\"ratio":1,"limit":1048576,"error":"","files":[]}]}
    );
    const asked = try helper.expect("files");
    asked.deinit();
    helper.send(&app,
        \\{"detail":{"id":"abc","files":[{"index":0,"path":"disk.iso","size":10,"done":0,"wanted":false}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expectEqualStrings("bundle", browse.crumbLabel(&app, "abc"));
}

test "New Torrent adds a pasted magnet to the folder shown" {
    var app = try app_tests.testApp();
    defer app.deinit();
    var helper = try FakeHelper.init(&app);
    defer helper.deinit();
    @import("app_torrents.zig").newTorrent(&app);
    try std.testing.expectEqual(@import("app_model.zig").DialogKind.torrent_source, app.dialog.?.kind);
    if (std.c.getenv("REDIWM_FILES_SHOTS")) |dir| {
        app.w = 760;
        app.h = 420;
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, app.w, app.h).?;
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf).?;
        defer c.cairo_destroy(cr);
        app.render(cr);
        var path: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&path, "{s}/new-torrent.png", .{std.mem.span(dir)}, 0)) |name| {
            _ = c.cairo_surface_write_to_png(surf, name.ptr);
        } else |_| {}
    }
    // Anything else is refused, and the dialog stays.
    try app.dialog.?.edit.text.appendSlice(app.allocator, "https://example.org/x");
    app.confirmTorrent();
    try std.testing.expect(app.dialog != null);
    try std.testing.expectError(error.NoRequest, helper.request());
    app.dialog.?.edit.text.clearRetainingCapacity();
    try app.dialog.?.edit.text.appendSlice(app.allocator, " magnet:?xt=urn:btih:abc\n");
    app.confirmTorrent();
    try std.testing.expect(app.dialog == null);
    const added = try helper.expect("add");
    defer added.deinit();
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:abc", added.value.object.get("source").?.string);
    try std.testing.expectEqualStrings("/tmp", added.value.object.get("destination").?.string);
}
