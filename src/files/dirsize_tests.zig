//! Folder size tests: the dirsize walker and the App's folder size column.

const std = @import("std");
const builtin = @import("builtin");
const history_mod = @import("history.zig");
const worker_mod = @import("worker.zig");
const app_mod = @import("app.zig");
const ops_mod = @import("ops.zig");
const dirsize_mod = @import("dirsize.zig");
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

test "dirsize: nested folders give the right total" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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

test "dirsize: a hardlink pair is counted once" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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

    const job = try pool.startJob(tmp);
    defer job.unref();

    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    try std.testing.expectEqual(@as(i64, 21), job.bytes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), job.files.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), job.dirs.load(.acquire));
}

test "dirsize: a symlink loop is not followed" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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
    try std.testing.expectEqual(@as(usize, 3), job.files.load(.acquire));
    try std.testing.expectEqual(@as(i64, 10), job.bytes.load(.acquire));
    try std.testing.expect(!job.partial.load(.acquire));
}

test "dirsize: an unreadable folder gives a partial result" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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
        .folder_sizes = std.StringHashMap(app_mod.SizeState).init(a),
    };
    defer app.deinit();
    defer app.snapshot = null;

    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);

    var buf: [64]u8 = undefined;
    var disp = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expectEqualStrings("—", disp.text);
    try std.testing.expect(!disp.is_running);
    try std.testing.expect(!app.hasRunningFolderSize());

    // Start calculation
    app.startFolderSize(0);
    try std.testing.expect(app.hasRunningFolderSize());

    disp = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expect(disp.is_running);

    // Wait for pool job to complete
    const job = app.folder_sizes.get(folder).?.running;
    while (!job.isDone()) {
        _ = c.usleep(1000);
    }

    app.syncFolderSizes();
    try std.testing.expect(!app.hasRunningFolderSize());

    disp = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expect(!disp.is_running);
    try std.testing.expectEqualStrings("22 B", disp.text);

    // Clearing folder sizes resets it
    app.clearFolderSizes();
    disp = app.itemSizeDisplay(app.items.items[0], &buf);
    try std.testing.expectEqualStrings("—", disp.text);
}

test "App size sort: calculated folders sort by apparent size, uncalculated last" {
    const a = std.testing.allocator;
    var source = [_]worker_mod.Item{
        .{ .name = "uncalc", .path = "/uncalc", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 1, .icon_name = "" },
        .{ .name = "small", .path = "/small", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 2, .icon_name = "" },
        .{ .name = "big", .path = "/big", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 3, .icon_name = "" },
        .{ .name = "file.txt", .path = "/file.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 5000, .mtime = 4, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = "/", .items = &source };

    var app = app_mod.App{
        .allocator = a,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = try history_mod.History.init(a, "/"),
        .home_dir = "/",
        .items_arena = std.heap.ArenaAllocator.init(a),
        .snapshot = &snap,
        .folder_sizes = std.StringHashMap(app_mod.SizeState).init(a),
    };
    defer app.deinit();
    defer app.snapshot = null;

    // Populate fake done sizes
    const key_big = try a.dupe(u8, "/big");
    try app.folder_sizes.put(key_big, .{ .done = .{ .bytes = 10000, .partial = false } });
    const key_small = try a.dupe(u8, "/small");
    try app.folder_sizes.put(key_small, .{ .done = .{ .bytes = 500, .partial = false } });

    app.sort_mode = .size;
    app.rebuildView();

    // Folders come first. Among folders: big (10000) > small (500) > uncalc (-1). Then files.
    try std.testing.expectEqualStrings("big", app.items.items[0].name);
    try std.testing.expectEqualStrings("small", app.items.items[1].name);
    try std.testing.expectEqualStrings("uncalc", app.items.items[2].name);
    try std.testing.expectEqualStrings("file.txt", app.items.items[3].name);
}

test "App clicking dash starts calculation without changing selection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest; // the walk is Linux-only for now
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
        .folder_sizes = std.StringHashMap(app_mod.SizeState).init(a),
    };
    defer app.deinit();
    defer app.snapshot = null;

    app.list_view = true;
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

    // Clicking again cancels
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.hasRunningFolderSize());
}
