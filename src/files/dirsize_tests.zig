//! Folder size tests: the dirsize walker and the App's folder size column.

const std = @import("std");
const builtin = @import("builtin");
const history_mod = @import("history.zig");
const worker_mod = @import("worker.zig");
const app_mod = @import("app.zig");
const ops_mod = @import("ops.zig");
const dirsize_mod = @import("dirsize.zig");
const sizetree = @import("sizetree.zig");
const FileAction = @import("app_model.zig").FileAction;
const c = @import("c.zig").api;
const linux = std.os.linux;
const files_tests = @import("../files_tests.zig");
const makeTestDir = files_tests.makeTestDir;
const writeTestFile = files_tests.writeTestFile;

pub fn countOpenFds() !usize {
    const fd = c.open("/proc/self/fd", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    var count: usize = 0;
    while (true) {
        const rc = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        var pos: usize = 0;
        while (pos < rc) {
            const d: *const linux.dirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += d.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&d.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                count += 1;
            }
        }
    }
    return if (count > 0) count - 1 else 0;
}

fn everyDisk(_: u32, _: u32) bool {
    return true;
}

/// Like a thumb drive: nothing is measured until clicked.
fn noDisk(_: u32, _: u32) bool {
    return false;
}

fn settle(svc: *sizetree.Service) void {
    var waited: usize = 0;
    while (svc.busy() and waited < 10_000) : (waited += 1) _ = c.usleep(1000);
}

test "dirsize: nested folders give the right total" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const sub1 = try std.fmt.allocPrint(a, "{s}/sub1", .{tmp});
    defer a.free(sub1);
    try ops_mod.createFolder(a, tmp, "sub1");

    const sub2 = try std.fmt.allocPrint(a, "{s}/sub2", .{sub1});
    defer a.free(sub2);
    try ops_mod.createFolder(a, sub1, "sub2");

    const sub3 = try std.fmt.allocPrint(a, "{s}/sub3", .{tmp});
    defer a.free(sub3);
    try ops_mod.createFolder(a, tmp, "sub3");

    const f1 = try std.fmt.allocPrint(a, "{s}/root.txt", .{tmp});
    defer a.free(f1);
    try writeTestFile(f1, "1234567890");

    const f2 = try std.fmt.allocPrint(a, "{s}/a.txt", .{sub1});
    defer a.free(f2);
    try writeTestFile(f2, "hello world!");

    const f3 = try std.fmt.allocPrint(a, "{s}/b.txt", .{sub2});
    defer a.free(f3);
    try writeTestFile(f3, "deep content");

    const f4 = try std.fmt.allocPrint(a, "{s}/c.txt", .{sub3});
    defer a.free(f4);
    try writeTestFile(f4, "folder 3 file");

    const pool = try dirsize_mod.Pool.init(a);
    defer pool.deinit();

    const job = try pool.startJob(tmp);
    defer job.unref();

    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    try std.testing.expectEqual(@as(i64, 47), job.bytes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), job.files.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), job.dirs.load(.acquire));
    try std.testing.expect(!job.partial.load(.acquire));
    try std.testing.expect(!job.cancelled.load(.acquire));
}

test "dirsize: a hardlink is counted at each name, its blocks once" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const f1 = try std.fmt.allocPrint(a, "{s}/file1.txt", .{tmp});
    defer a.free(f1);
    try writeTestFile(f1, "hardlink payload");

    const f1_z = try a.dupeSentinel(u8, f1, 0);
    defer a.free(f1_z);
    const f2 = try std.fmt.allocPrint(a, "{s}/file2_hardlink.txt", .{tmp});
    defer a.free(f2);
    const f2_z = try a.dupeSentinel(u8, f2, 0);
    defer a.free(f2_z);

    try std.testing.expect(c.link(f1_z, f2_z) == 0);

    const f3 = try std.fmt.allocPrint(a, "{s}/file3.txt", .{tmp});
    defer a.free(f3);
    try writeTestFile(f3, "other");

    const pool = try dirsize_mod.Pool.init(a);
    defer pool.deinit();

    const job = try pool.startJobWith(tmp, .{ .allocated = true });
    defer job.unref();

    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    // Size: 16 + 16 + 5, every name counted, like a copy would write.
    try std.testing.expectEqual(@as(i64, 37), job.bytes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), job.files.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), job.dirs.load(.acquire));

    // On disk: the folder plus two inodes, the linked one once.
    var expected: i64 = 0;
    for ([_][]const u8{ tmp, f1, f3 }) |path| {
        const z = try a.dupeSentinel(u8, path, 0);
        defer a.free(z);
        var st: c.struct_stat = undefined;
        try std.testing.expect(c.lstat(z, &st) == 0);
        expected += @as(i64, @intCast(st.st_blocks)) * 512;
    }
    try std.testing.expectEqual(expected, job.allocated.load(.acquire));
    try std.testing.expect(!job.partial.load(.acquire));
}

test "dirsize: on disk is only added up when asked for" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    const f1 = try std.fmt.allocPrint(a, "{s}/file.txt", .{tmp});
    defer a.free(f1);
    try writeTestFile(f1, "payload");

    const pool = try dirsize_mod.Pool.init(a);
    defer pool.deinit();
    const job = try pool.startJob(tmp);
    defer job.unref();
    while (!job.isDone()) _ = c.usleep(1000);
    try std.testing.expectEqual(@as(i64, 7), job.bytes.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), job.allocated.load(.acquire));
}

test "dirsize: symlinks are not followed or counted in Size" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const f1 = try std.fmt.allocPrint(a, "{s}/file.txt", .{tmp});
    defer a.free(f1);
    try writeTestFile(f1, "content");

    const sub = try std.fmt.allocPrint(a, "{s}/sub", .{tmp});
    defer a.free(sub);
    try ops_mod.createFolder(a, tmp, "sub");

    const link1 = try std.fmt.allocPrintSentinel(a, "{s}/sub/loop_to_parent", .{tmp}, 0);
    defer a.free(link1);
    _ = c.symlink("..", link1);

    const link2 = try std.fmt.allocPrintSentinel(a, "{s}/self_loop", .{tmp}, 0);
    defer a.free(link2);
    _ = c.symlink(".", link2);

    const pool = try dirsize_mod.Pool.init(a);
    defer pool.deinit();

    const job = try pool.startJob(tmp);
    defer job.unref();

    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    try std.testing.expectEqual(@as(usize, 1), job.dirs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), job.files.load(.acquire));
    try std.testing.expectEqual(@as(i64, 7), job.bytes.load(.acquire));
    try std.testing.expect(!job.partial.load(.acquire));
}

test "dirsize: an unreadable folder gives a partial result" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const readable = try std.fmt.allocPrint(a, "{s}/readable", .{tmp});
    defer a.free(readable);
    try ops_mod.createFolder(a, tmp, "readable");

    const rf = try std.fmt.allocPrint(a, "{s}/f.txt", .{readable});
    defer a.free(rf);
    try writeTestFile(rf, "readable file data");

    const unreadable = try std.fmt.allocPrintSentinel(a, "{s}/unreadable", .{tmp}, 0);
    defer a.free(unreadable);
    try ops_mod.createFolder(a, tmp, "unreadable");

    const uf = try std.fmt.allocPrint(a, "{s}/secret.txt", .{unreadable});
    defer a.free(uf);
    try writeTestFile(uf, "super secret unreadable content");

    _ = c.chmod(unreadable, 0o000);
    defer _ = c.chmod(unreadable, 0o755);

    const pool = try dirsize_mod.Pool.init(a);
    defer pool.deinit();

    const job = try pool.startJob(tmp);
    defer job.unref();

    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    try std.testing.expect(job.partial.load(.acquire));
    try std.testing.expect(job.bytes.load(.acquire) >= 18);
}

test "dirsize: cancelling mid-walk leaks no fds" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // counts /proc/self/fd, which FreeBSD lacks without fdescfs
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    for (0..30) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "dir_{d}", .{i});
        try ops_mod.createFolder(a, tmp, name);
        const sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ tmp, name });
        defer a.free(sub_path);
        for (0..5) |j| {
            var sub_name_buf: [32]u8 = undefined;
            const sub_name = try std.fmt.bufPrint(&sub_name_buf, "sub_{d}", .{j});
            try ops_mod.createFolder(a, sub_path, sub_name);
        }
    }

    const initial_fds = try countOpenFds();

    const pool = try dirsize_mod.Pool.init(a);
    const job = try pool.startJob(tmp);
    job.cancel();

    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    job.unref();
    pool.deinit();

    const final_fds = try countOpenFds();
    try std.testing.expectEqual(initial_fds, final_fds);
}

test "dirsize: a mount boundary is not crossed" {
    const a = std.testing.allocator;
    const pool = try dirsize_mod.Pool.init(a);
    defer pool.deinit();

    const job = try pool.startJob("/dev");
    defer job.unref();

    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    try std.testing.expect(job.isDone());
}

test "App folder size calculation and display lifecycle" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const folder = try std.fmt.allocPrint(a, "{s}/my_folder", .{tmp});
    defer a.free(folder);
    try ops_mod.createFolder(a, tmp, "my_folder");

    const f1 = try std.fmt.allocPrint(a, "{s}/file1.txt", .{folder});
    defer a.free(f1);
    try writeTestFile(f1, "1234567890"); // 10 bytes

    const f2 = try std.fmt.allocPrint(a, "{s}/file2.txt", .{folder});
    defer a.free(f2);
    try writeTestFile(f2, "hello world!"); // 12 bytes

    var source = [_]worker_mod.Item{
        .{ .name = "my_folder", .path = folder, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 100, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = tmp, .items = &source };

    const svc = try sizetree.Service.create(a, 2, noDisk);
    defer svc.destroy();
    var app = app_mod.App{
        .allocator = a,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = try history_mod.History.init(a, tmp),
        .home_dir = tmp,
        .items_arena = std.heap.ArenaAllocator.init(a),
        .snapshot = &snap,
        .size_service = svc,
    };
    defer app.deinit();
    defer app.snapshot = null;

    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);

    // A disk that is not measured automatically: a dash until clicked.
    var buf: [64]u8 = undefined;
    app.syncVisibleFolderSizes();
    var disp = app.itemSizeDisplay(app.items.items[0], &buf);
    settle(svc);
    disp = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expectEqualStrings("—", disp.text);
    try std.testing.expect(!disp.is_running);
    app.syncFolderSizes();
    try std.testing.expect(!app.hasRunningFolderSize());

    app.startFolderSize(0);
    settle(svc);
    app.syncFolderSizes();
    try std.testing.expect(!app.hasRunningFolderSize());
    disp = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expect(!disp.is_running);
    try std.testing.expectEqualStrings("22 B", disp.text);

    // Leaving the folder keeps what was added up.
    app.clearFolderSizes();
    disp = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expectEqualStrings("22 B", disp.text);
}

test "App folder sizes are measured automatically on a fast local disk" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    const folder = try std.fmt.allocPrint(a, "{s}/auto", .{tmp});
    defer a.free(folder);
    try ops_mod.createFolder(a, tmp, "auto");
    const f1 = try std.fmt.allocPrint(a, "{s}/file.txt", .{folder});
    defer a.free(f1);
    try writeTestFile(f1, "12345");

    var source = [_]worker_mod.Item{
        .{ .name = "auto", .path = folder, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 100, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = tmp, .items = &source };
    const svc = try sizetree.Service.create(a, 2, everyDisk);
    defer svc.destroy();
    var app = app_mod.App{
        .allocator = a,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = try history_mod.History.init(a, tmp),
        .home_dir = tmp,
        .items_arena = std.heap.ArenaAllocator.init(a),
        .snapshot = &snap,
        .size_service = svc,
    };
    defer app.deinit();
    defer app.snapshot = null;
    app.rebuildView();

    // Painting the folder asks for its size.
    var buf: [64]u8 = undefined;
    app.syncVisibleFolderSizes();
    _ = app.itemSizeDisplay(app.items.items[0], &buf);
    settle(svc);
    try std.testing.expectEqualStrings("5 B", app.itemSizeDisplay(app.items.items[0], &buf).text);
    try std.testing.expect(!app.folderSizeClickable(app.items.items[0]));
}

test "App leaving a folder drops its queued sizes until they are painted again" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    const folder = try std.fmt.allocPrint(a, "{s}/queued", .{tmp});
    defer a.free(folder);
    try ops_mod.createFolder(a, tmp, "queued");
    var source = [_]worker_mod.Item{
        .{ .name = "queued", .path = folder, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 100, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = tmp, .items = &source };
    // No workers: requests stay queued.
    const svc = try sizetree.Service.create(a, 0, everyDisk);
    defer svc.destroy();
    var app = app_mod.App{
        .allocator = a,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = try history_mod.History.init(a, tmp),
        .home_dir = tmp,
        .items_arena = std.heap.ArenaAllocator.init(a),
        .snapshot = &snap,
        .size_service = svc,
    };
    defer app.deinit();
    defer app.snapshot = null;
    app.rebuildView();

    var buf: [64]u8 = undefined;
    app.syncVisibleFolderSizes();
    try std.testing.expect(app.itemSizeDisplay(app.items.items[0], &buf).is_running);
    try std.testing.expect(app.hasRunningFolderSize());
    app.cancelRunningFolderSizes();
    try std.testing.expect(!app.hasRunningFolderSize());
    app.syncVisibleFolderSizes();
    _ = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expect(app.hasRunningFolderSize());
}

test "App size sort: measured folders sort by apparent size, unmeasured last" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    var paths: [3][]u8 = undefined;
    for ([_][]const u8{ "uncalc", "small", "big" }, 0..) |name, i| {
        try ops_mod.createFolder(a, tmp, name);
        paths[i] = try std.fmt.allocPrint(a, "{s}/{s}", .{ tmp, name });
    }
    defer for (paths) |p| a.free(p);
    const small_file = try std.fmt.allocPrint(a, "{s}/f", .{paths[1]});
    defer a.free(small_file);
    try writeTestFile(small_file, &@as([500]u8, @splat('x')));
    const big_file = try std.fmt.allocPrint(a, "{s}/f", .{paths[2]});
    defer a.free(big_file);
    try writeTestFile(big_file, &@as([10000]u8, @splat('y')));
    const file_path = try std.fmt.allocPrint(a, "{s}/file.txt", .{tmp});
    defer a.free(file_path);
    try writeTestFile(file_path, "z");

    var source = [_]worker_mod.Item{
        .{ .name = "uncalc", .path = paths[0], .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 1, .icon_name = "" },
        .{ .name = "small", .path = paths[1], .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 2, .icon_name = "" },
        .{ .name = "big", .path = paths[2], .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 3, .icon_name = "" },
        .{ .name = "file.txt", .path = file_path, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 5000, .mtime = 4, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = tmp, .items = &source };

    const svc = try sizetree.Service.create(a, 2, noDisk);
    defer svc.destroy();
    var app = app_mod.App{
        .allocator = a,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = try history_mod.History.init(a, tmp),
        .home_dir = tmp,
        .items_arena = std.heap.ArenaAllocator.init(a),
        .snapshot = &snap,
        .size_service = svc,
    };
    defer app.deinit();
    defer app.snapshot = null;

    var owner = svc.registerOwner();
    defer owner.deinit();
    svc.request(&owner, paths[1], .visible, .{ .force = true });
    svc.request(&owner, paths[2], .visible, .{ .force = true });
    settle(svc);

    app.sort_mode = .size;
    app.rebuildView();

    // Folders come first. Among folders: big (10000) > small (500) > uncalc (-1). Then files.
    try std.testing.expectEqualStrings("big", app.items.items[0].name);
    try std.testing.expectEqualStrings("small", app.items.items[1].name);
    try std.testing.expectEqualStrings("uncalc", app.items.items[2].name);
    try std.testing.expectEqualStrings("file.txt", app.items.items[3].name);
}

/// Clicks a folder's size dash twice: the first starts the calculation,
/// the second stops it; the selection stays on the file throughout.
fn clickDash(list_view: bool) !void {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const folder_path = try std.fmt.allocPrint(a, "{s}/folder", .{tmp});
    defer a.free(folder_path);
    try ops_mod.createFolder(a, tmp, "folder");

    const file_path = try std.fmt.allocPrint(a, "{s}/file.txt", .{tmp});
    defer a.free(file_path);
    try writeTestFile(file_path, "file data");

    var source = [_]worker_mod.Item{
        .{ .name = "folder", .path = folder_path, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 1, .icon_name = "" },
        .{ .name = "file.txt", .path = file_path, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 9, .mtime = 2, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = tmp, .items = &source };

    // A slow disk with no workers: the click's request stays running.
    const svc = try sizetree.Service.create(a, 0, noDisk);
    defer svc.destroy();
    var app = app_mod.App{
        .allocator = a,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = try history_mod.History.init(a, tmp),
        .home_dir = tmp,
        .items_arena = std.heap.ArenaAllocator.init(a),
        .snapshot = &snap,
        .size_service = svc,
    };
    defer app.deinit();
    defer app.snapshot = null;

    app.list_view = list_view;
    app.w = 960;
    app.h = 540;
    app.rebuildView();

    // Select file.txt (item 1)
    app.items.items[1].selected = true;
    app.focused_index = 1;

    // Get sizeButtonRect for folder (item 0)
    const btn_rect = app.sizeButtonRect(0).?;
    app.mouse_x = btn_rect.x + 5;
    app.mouse_y = btn_rect.y + 5;

    // Left click on size button
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);

    // Job was started!
    try std.testing.expect(app.hasRunningFolderSize());

    // Selection did NOT change! Item 1 is still selected, item 0 is NOT selected!
    try std.testing.expect(!app.items.items[0].selected);
    try std.testing.expect(app.items.items[1].selected);
    try std.testing.expectEqual(@as(?usize, 1), app.focused_index);

    // Clicking again stops it.
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    app.syncFolderSizes();
    try std.testing.expect(!app.hasRunningFolderSize());
    try std.testing.expect(app.items.items[1].selected);
}

test "App clicking dash starts calculation without changing selection" {
    try clickDash(true);
}

test "App clicking the grid card's size dash starts calculation without changing selection" {
    try clickDash(false);
}

test "App context menu Calculate size starts the selected folders" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const first = try std.fmt.allocPrint(a, "{s}/first", .{tmp});
    defer a.free(first);
    try ops_mod.createFolder(a, tmp, "first");
    const second = try std.fmt.allocPrint(a, "{s}/second", .{tmp});
    defer a.free(second);
    try ops_mod.createFolder(a, tmp, "second");
    const third = try std.fmt.allocPrint(a, "{s}/third", .{tmp});
    defer a.free(third);
    try ops_mod.createFolder(a, tmp, "third");

    var source = [_]worker_mod.Item{
        .{ .name = "first", .path = first, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 1, .icon_name = "" },
        .{ .name = "second", .path = second, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 2, .icon_name = "" },
        .{ .name = "third", .path = third, .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 3, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = tmp, .items = &source };

    const svc = try sizetree.Service.create(a, 0, noDisk);
    defer svc.destroy();
    var app = app_mod.App{
        .allocator = a,
        .io = std.testing.io,
        .environ = undefined,
        .theme_cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .worker = undefined,
        .history = try history_mod.History.init(a, tmp),
        .home_dir = tmp,
        .items_arena = std.heap.ArenaAllocator.init(a),
        .snapshot = &snap,
        .size_service = svc,
    };
    defer app.deinit();
    defer app.snapshot = null;
    app.rebuildView();

    // Two of the three folders are selected.
    app.items.items[0].selected = true;
    app.items.items[2].selected = true;
    app.menu = .file;
    const row = std.mem.indexOfScalar(FileAction, app.fileActions(), .size).?;
    try std.testing.expectEqualStrings("Calculate size", app.menuLabels()[row]);
    app.runMenu(row);

    try std.testing.expect(app.menu == null);
    try std.testing.expectEqual(sizetree.Status.measuring, svc.lookup(first).status);
    try std.testing.expectEqual(sizetree.Status.unknown, svc.lookup(second).status);
    try std.testing.expectEqual(sizetree.Status.measuring, svc.lookup(third).status);
    try std.testing.expect(app.hasRunningFolderSize());
}

test "Files viewport, navigation and destruction release their own folder-size demand" {
    const a = std.testing.allocator;
    const svc = try sizetree.Service.create(a, 0, everyDisk);
    defer svc.destroy();
    var other = svc.registerOwner();
    defer other.deinit();
    var app = app_mod.App{
        .allocator = a,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = try history_mod.History.init(a, "/root"),
        .home_dir = "/root",
        .items_arena = std.heap.ArenaAllocator.init(a),
        .size_service = svc,
        .list_view = true,
    };
    var open = true;
    defer if (open) app.deinit();
    try app.items.appendSlice(a, &.{
        .{ .name = "one", .path = "/root/one", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "" },
        .{ .name = "two", .path = "/root/two", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "" },
    });
    app.h = app.viewTop() + app.footerHeight() + app.cardHeight();
    app.syncVisibleFolderSizes();
    try std.testing.expectEqual(sizetree.Status.measuring, svc.lookup("/root/one").status);
    try std.testing.expectEqual(sizetree.Status.unknown, svc.lookup("/root/two").status);
    app.startFolderSize(0);
    app.scroll_y = app.rowHeight();
    app.syncVisibleFolderSizes();
    try std.testing.expectEqual(sizetree.Status.measuring, svc.lookup("/root/one").status);
    try std.testing.expectEqual(sizetree.Status.measuring, svc.lookup("/root/two").status);
    app.items.items.len = 1;
    app.view_revision += 1;
    app.syncVisibleFolderSizes();
    try std.testing.expectEqual(sizetree.Status.unknown, svc.lookup("/root/two").status);

    // The navigation hook clears explicit off-screen work as well.
    app.cancelRunningFolderSizes();
    try std.testing.expect(!svc.busy());
    app.scroll_y = 0;
    app.syncVisibleFolderSizes();
    svc.request(&other, "/root/one", .background, .{});
    app.deinit();
    open = false;
    try std.testing.expect(svc.busy());
    try std.testing.expectEqual(@as(usize, 1), svc.paths.get("/root/one").?.owners);
    other.clear();
    try std.testing.expect(!svc.busy());
}
