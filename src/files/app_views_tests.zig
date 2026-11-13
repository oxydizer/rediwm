//! Files Git and Transfers view tests.

const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const worker_mod = @import("worker.zig");
const ViewItem = @import("app_model.zig").ViewItem;
const app_tests = @import("app_tests.zig");
const testApp = app_tests.testApp;
const testItems = app_tests.testItems;

test "Git layout has two columns, scrollable sidebar and display-only deleted rows" {
    var app = try testApp();
    defer app.deinit();
    var snap: worker_mod.Snapshot = .{ .arena = undefined, .request_id = 1, .dir = "/repo", .items = &.{}, .repository = .{ .root = "/repo", .directory = "/repo", .branch = "main" } };
    app.snapshot = &snap;
    defer app.snapshot = null;
    app.list_view = true;
    try std.testing.expectEqual(@as(usize, 2), app.columnLabels().len);
    try std.testing.expectEqualStrings("Git", app.columnLabels()[1]);
    try std.testing.expectEqual(@as(f64, 164), app.listColumn(1).w);
    try std.testing.expectEqual(@as(f64, 0), app.listColumn(2).w);
    const boundary = app.listColumn(0);
    const boundary_x = boundary.x + boundary.w;
    const boundary_y = boundary.y + 10;
    try std.testing.expectEqual(@as(?usize, 0), app.columnBoundary(boundary_x, boundary_y));
    const sort = app.sort_mode;
    app.handleMotion(boundary_x, boundary_y);
    app.handleButton(0x110, true);
    app.handleMotion(boundary_x - 40, boundary_y + 100);
    try std.testing.expectApproxEqAbs(@as(f64, 164), app.listColumn(1).w, 0.001);
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(boundary_x - 40, boundary_y + 100)));
    app.handleMotion(boundary_x + 1000, boundary_y);
    try std.testing.expectApproxEqAbs(@as(f64, 164), app.listColumn(1).w, 0.001);
    app.handleButton(0x110, false);
    try std.testing.expect(app.column_resize == null);
    try std.testing.expectEqual(sort, app.sort_mode);
    app.resize(360, 300);
    const widths = app.listWidths();
    try std.testing.expect(widths[0] >= 96 and widths[1] >= 64);
    try std.testing.expect(widths[0] + widths[1] > @as(f64, @floatFromInt(app.cellWidth() - 20)));
    try std.testing.expect(app.horizontalScrollbar() != null);
    app.resize(960, 540);
    app.sortByColumn(1);
    try std.testing.expectEqual(sort, app.sort_mode);
    // Turning Git View off presents the repository as an ordinary folder.
    const gone: worker_mod.Item = .{ .name = "gone.txt", .path = "/repo/gone.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "", .git_status = .deleted, .missing = true };
    try std.testing.expect(app.matches(gone));
    app.git_view = false;
    try std.testing.expect(app.repository() == null and app.inRepository());
    try std.testing.expectEqual(@as(usize, 5), app.columnLabels().len);
    try std.testing.expectEqual(@as(i32, 0), app.gitSidebarHeight());
    try std.testing.expect(!app.matches(gone));
    app.git_view = true;
    // Changed files list flat; search matches the path shown, and full paths can be turned off.
    const nested: worker_mod.Item = .{ .name = "omega.txt", .label = "zdir/inner/omega.txt", .path = "/repo/zdir/inner/omega.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 6, .mtime = 1, .icon_name = "", .git_status = .untracked };
    try app.search.text.appendSlice(app.allocator, "zdir");
    try std.testing.expect(app.matches(nested));
    app.full_paths = false;
    try std.testing.expect(!app.matches(nested));
    app.full_paths = true;
    app.changed_only = false;
    try std.testing.expect(!app.matches(nested));
    app.changed_only = true;
    app.search.text.clearRetainingCapacity();
    // Git's body follows its shared accordion header geometry.
    app.sidebar_section = .git;
    const git_geometry = app.sidebarLayout().cards[@intFromEnum(@import("app_model.zig").SidebarSection.git)];
    try std.testing.expect(git_geometry.visible and git_geometry.expanded);
    try std.testing.expectEqual(
        @as(f64, @floatFromInt(git_geometry.y + git_geometry.header_height)),
        app.gitCard().y,
    );
    const expanded_extent = app.sidebarExtent();
    app.git_expanded = false;
    // Collapsing hides the current-branch row and the "New branch" row (28px each) and the 4px padding.
    try std.testing.expectEqual(expanded_extent - 60, app.sidebarExtent());
    try testItems(&app, 1);
    app.items.items[0].missing = true;
    app.items.items[0].selected = true;
    app.focused_index = 0;
    app.copySelected();
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    app.openRenameDialog();
    try std.testing.expect(app.dialog == null);
    app.openTrashConfirmDialog();
    try std.testing.expect(app.dialog == null);
    app.previewSelected();
    try std.testing.expect(app.editor_path == null);
}

test "Transfers uses list geometry and isolates file actions while preserving the folder view" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    // These records are only counted. File actions must never read them
    // while the transfer pane is active.
    var files: [32]ViewItem = undefined;
    var transfers: [32]@import("torrents.zig").Transfer = undefined;
    app.items = .fromOwnedSlice(&files);
    app.torrents.snapshot = .{ .arena = undefined, .value = .{ .transfers = &transfers } };
    app.list_view = false;
    app.transfer_view = .{ .active = true, .folder_scroll = 77, .folder_search_visible = true };
    try std.testing.expectEqual(@as(i32, 1), app.columns());
    try std.testing.expectEqual(@as(i32, 38), app.rowHeight());
    try std.testing.expectEqualStrings("Status", app.columnLabels()[1]);
    try std.testing.expect(app.scrollbarGeometry() != null);
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(260, 180));
    try std.testing.expectEqual(@as(?[]const u8, null), app.dropDirectoryAt(260, 180));
    app.handleKey(c.XKB_KEY_Delete, "");
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_v, "v");
    try std.testing.expect(!app.paste_requested);
    try std.testing.expect(app.dialog == null);
    app.ctrl = false;
    app.transferPaneKey(c.XKB_KEY_End);
    try std.testing.expectEqual(@as(?usize, 31), app.transfer_view.row);
    try std.testing.expect(app.scroll_y > 0);
    app.back();
    try std.testing.expect(!app.transfer_view.active);
    try std.testing.expect(!app.list_view);
    try std.testing.expect(app.search_visible);
    try std.testing.expectEqual(@as(i32, 77), app.scroll_y);
}

pub fn inlineTransferFixture() @import("torrents.zig").Transfer {
    return .{
        .id = "abc",
        .name = "bundle",
        .source = "/Downloads/bundle.torrent",
        .download_directory = "/Downloads",
        .destination = "/Downloads",
        .storage = "/Downloads/.rediwm-partials/abc",
        .pending = false,
        .metadata = true,
        .paused = false,
        .finished = false,
        .published = false,
        .progress = 420000,
        .download_rate = 100,
        .upload_rate = 50,
        .total = 1000,
        .done = 420,
        .ratio = 1,
        .limit = 1024,
        .@"error" = "",
        .files = &.{},
        .peers = 4,
        .known_peers = 8,
        .seeds = 2,
    };
}

test "folder transfer rows match full paths, avoid duplicates and exclude staging from file operations" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var app = App{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = allocator, .current = "/Downloads" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    defer app.items.deinit(allocator);
    var transfers = [_]@import("torrents.zig").Transfer{inlineTransferFixture()};
    app.torrents.snapshot = .{ .arena = undefined, .value = .{ .transfers = &transfers } };
    const old = std.StringHashMap(ViewItem).init(allocator);
    app.appendTorrentRows(arena.allocator(), &old);
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expect(app.items.items[0].transfer_stub and app.items.items[0].missing);
    try std.testing.expectEqualStrings("abc", app.torrentForItem(0).?.id);
    app.list_view = true;
    try std.testing.expect(app.inlineTorrentWidth(0) > 0);
    try std.testing.expect(app.sizeButtonRect(0) == null);
    app.items.items[0].selected = true;
    app.copySelected();
    app.openRenameDialog();
    app.openTrashConfirmDialog();
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    try std.testing.expect(app.dialog == null);
    app.activateItem(0);
    try std.testing.expectEqual(@import("app_model.zig").DialogKind.transfers, app.dialog.?.kind);
    app.closeDialog();

    app.items.items[0].transfer_stub = false;
    app.items.items[0].missing = false;
    app.items.items[0].path = "/Downloads/bundle.torrent";
    app.appendTorrentRows(arena.allocator(), &old);
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    app.items.items[0].path = "/Elsewhere/bundle.torrent";
    try std.testing.expect(app.torrentForItem(0) == null);
    transfers[0].published = true;
    transfers[0].destination = "/Downloads/bundle.download";
    app.items.items[0].path = "/Downloads/bundle.download/file.bin";
    try std.testing.expect(app.torrentForItem(0) != null);
    app.items.items[0].path = "/Downloads/bundle.download-other/file.bin";
    try std.testing.expect(app.torrentForItem(0) == null);
}

test "torrent ETA uses remaining selected bytes and is unknown while paused or stalled" {
    const eta = @import("torrents.zig").etaSeconds;
    var transfer = inlineTransferFixture();
    try std.testing.expectEqual(@as(?i64, 6), eta(transfer));
    transfer.download_rate = 0;
    try std.testing.expect(eta(transfer) == null);
    transfer.download_rate = 100;
    transfer.paused = true;
    try std.testing.expect(eta(transfer) == null);
    transfer.finished = true;
    try std.testing.expectEqual(@as(?i64, 0), eta(transfer));
    transfer.pending = true;
    try std.testing.expect(eta(transfer) == null);
}
