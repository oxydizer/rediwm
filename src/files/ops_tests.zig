//! File operation tests: copying, moving, conflicts, cancellation, the clipboard, deletion and view preferences.

const std = @import("std");
const ops_mod = @import("ops.zig");
const clipboard_mod = @import("clipboard.zig");
const c = @import("c.zig").api;
const files_tests = @import("../files_tests.zig");
const makeTestDir = files_tests.makeTestDir;

pub fn writeTestFile(path: []const u8, content: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0);
    const fd = c.open(path_z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return error.WriteFileFailed;
    defer _ = c.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = c.write(fd, content[written..].ptr, content.len - written);
        if (n <= 0) return error.WriteFileFailed;
        written += @intCast(n);
    }
}

pub fn readTestFile(path: []const u8, buf: []u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0);
    const fd = c.open(path_z, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFileFailed;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFileFailed;
    return buf[0..@intCast(n)];
}

pub fn testFileExists(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0) catch return false;
    var st: c.struct_stat = undefined;
    return c.stat(path_z, &st) == 0;
}

test "copyRecursive and copySymlink" {
    const allocator = std.testing.allocator;
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try makeTestDir(&tmp_path_buf);
    defer ops_mod.deleteRecursive(allocator, tmp_path) catch {};

    // Setup source directory hierarchy:
    // src_dir/
    //   file1.txt (content: "hello")
    //   sub/
    //     file2.txt (content: "world")
    //     symlink -> ../file1.txt
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src_dir", .{tmp_path});
    defer allocator.free(src_dir);
    try ops_mod.createFolder(allocator, tmp_path, "src_dir");

    const file1_path = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{src_dir});
    defer allocator.free(file1_path);
    try ops_mod.createFile(allocator, src_dir, "file1.txt");
    try writeTestFile(file1_path, "hello");

    const sub_dir = try std.fmt.allocPrint(allocator, "{s}/sub", .{src_dir});
    defer allocator.free(sub_dir);
    try ops_mod.createFolder(allocator, src_dir, "sub");

    const file2_path = try std.fmt.allocPrint(allocator, "{s}/file2.txt", .{sub_dir});
    defer allocator.free(file2_path);
    try ops_mod.createFile(allocator, sub_dir, "file2.txt");
    try writeTestFile(file2_path, "world");

    // Create symlink inside sub
    const link_src = try std.fmt.allocPrint(allocator, "{s}/link_to_file1", .{sub_dir});
    defer allocator.free(link_src);
    const link_src_z = try allocator.dupeSentinel(u8, link_src, 0);
    defer allocator.free(link_src_z);
    _ = c.symlink("../file1.txt", link_src_z);

    // Copy src_dir -> dst_dir
    const dst_dir = try std.fmt.allocPrint(allocator, "{s}/dst_dir", .{tmp_path});
    defer allocator.free(dst_dir);

    try ops_mod.copyRecursive(allocator, src_dir, dst_dir, null);

    // Verify dst_dir contents
    const dst_file1 = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{dst_dir});
    defer allocator.free(dst_file1);
    var b1: [16]u8 = undefined;
    const content1 = try readTestFile(dst_file1, &b1);
    try std.testing.expectEqualStrings("hello", content1);

    const dst_file2 = try std.fmt.allocPrint(allocator, "{s}/sub/file2.txt", .{dst_dir});
    defer allocator.free(dst_file2);
    var b2: [16]u8 = undefined;
    const content2 = try readTestFile(dst_file2, &b2);
    try std.testing.expectEqualStrings("world", content2);

    // Verify symlink target was preserved
    const dst_link = try std.fmt.allocPrint(allocator, "{s}/sub/link_to_file1", .{dst_dir});
    defer allocator.free(dst_link);
    const dst_link_z = try allocator.dupeSentinel(u8, dst_link, 0);
    defer allocator.free(dst_link_z);
    var target_buf: [256]u8 = undefined;
    const link_len = c.readlink(dst_link_z, &target_buf, target_buf.len);
    try std.testing.expect(link_len > 0);
    try std.testing.expectEqualStrings("../file1.txt", target_buf[0..@intCast(link_len)]);
}

test "crossDeviceMove preserves source on simulated failure" {
    const allocator = std.testing.allocator;
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try makeTestDir(&tmp_path_buf);
    defer ops_mod.deleteRecursive(allocator, tmp_path) catch {};

    // Cannot move into descendant
    try std.testing.expectError(error.CannotMoveIntoDescendant, ops_mod.crossDeviceMove(allocator, "/a/b", "/a/b/c", null));

    // Create source file
    const src_file = try std.fmt.allocPrint(allocator, "{s}/important.txt", .{tmp_path});
    defer allocator.free(src_file);
    try ops_mod.createFile(allocator, tmp_path, "important.txt");
    try writeTestFile(src_file, "critical user data");

    // Normal move simulation: move to new path
    const dst_file = try std.fmt.allocPrint(allocator, "{s}/destination.txt", .{tmp_path});
    defer allocator.free(dst_file);
    try ops_mod.crossDeviceMove(allocator, src_file, dst_file, null);

    // Source must be deleted, destination must exist with data
    try std.testing.expect(!testFileExists(src_file));
    var buf: [64]u8 = undefined;
    const n = try readTestFile(dst_file, &buf);
    try std.testing.expectEqualStrings("critical user data", n);

    // Now test failure preservation:
    // If copying is cancelled or fails: source must be preserved!
    var cancel_flag = std.atomic.Value(bool).init(true); // cancelled immediately
    const cancel_dst = try std.fmt.allocPrint(allocator, "{s}/cancelled_dst.txt", .{tmp_path});
    defer allocator.free(cancel_dst);

    try std.testing.expectError(error.Cancelled, ops_mod.crossDeviceMove(allocator, dst_file, cancel_dst, &cancel_flag));

    // Destination was not created or cleaned up, and SOURCE IS STILL INTACT!
    try std.testing.expect(testFileExists(dst_file));
}

test "clipboard encoding and decoding" {
    const allocator = std.testing.allocator;

    const paths = [_][]const u8{
        "/home/user/document.pdf",
        "/home/user/my photos/summer vacation.jpg",
        "/home/user/hash#tag & percent%20.txt",
    };

    // Test uri-list encoding and decoding
    const encoded_uris = try clipboard_mod.encodeUriList(allocator, &paths);
    defer allocator.free(encoded_uris);

    const decoded_uris = try clipboard_mod.decodeUris(allocator, encoded_uris);
    defer decoded_uris.deinit(allocator);

    try std.testing.expectEqual(clipboard_mod.ClipboardMode.copy, decoded_uris.mode);
    try std.testing.expectEqual(@as(usize, 3), decoded_uris.paths.len);
    try std.testing.expectEqualStrings(paths[0], decoded_uris.paths[0]);
    try std.testing.expectEqualStrings(paths[1], decoded_uris.paths[1]);
    try std.testing.expectEqualStrings(paths[2], decoded_uris.paths[2]);

    // Test GNOME cut format
    const gnome_cut = try clipboard_mod.encodeGnomeCopiedFiles(allocator, .cut, &paths);
    defer allocator.free(gnome_cut);

    const decoded_cut = try clipboard_mod.decodeUris(allocator, gnome_cut);
    defer decoded_cut.deinit(allocator);

    try std.testing.expectEqual(clipboard_mod.ClipboardMode.cut, decoded_cut.mode);
    try std.testing.expectEqual(@as(usize, 3), decoded_cut.paths.len);
    try std.testing.expectEqualStrings(paths[0], decoded_cut.paths[0]);
}

test "JobRunner copy with conflict resolution (Skip and Rename)" {
    const allocator = std.testing.allocator;
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try makeTestDir(&tmp_path_buf);
    defer ops_mod.deleteRecursive(allocator, tmp_path) catch {};

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_path});
    defer allocator.free(src_dir);
    try ops_mod.createFolder(allocator, tmp_path, "src");

    const dst_dir = try std.fmt.allocPrint(allocator, "{s}/dst", .{tmp_path});
    defer allocator.free(dst_dir);
    try ops_mod.createFolder(allocator, tmp_path, "dst");

    // Source files
    const f1_path = try std.fmt.allocPrint(allocator, "{s}/item1.txt", .{src_dir});
    defer allocator.free(f1_path);
    try ops_mod.createFile(allocator, src_dir, "item1.txt");

    const f2_path = try std.fmt.allocPrint(allocator, "{s}/item2.txt", .{src_dir});
    defer allocator.free(f2_path);
    try ops_mod.createFile(allocator, src_dir, "item2.txt");

    // In destination, create conflict item1.txt
    const dst_item1 = try std.fmt.allocPrint(allocator, "{s}/item1.txt", .{dst_dir});
    defer allocator.free(dst_item1);
    try ops_mod.createFile(allocator, dst_dir, "item1.txt");
    try writeTestFile(dst_item1, "original in dst");

    const sources = [_][]const u8{ f1_path, f2_path };

    // Test 1: Conflict action = .skip
    var runner = try ops_mod.JobRunner.init(allocator);
    defer runner.deinit();

    try runner.start(.copy, &sources, dst_dir, .skip);

    // Wait for completion
    while (true) {
        const prog = runner.pollProgress();
        if (prog.state == .finished) {
            try std.testing.expectEqual(@as(usize, 2), prog.total_items);
            try std.testing.expectEqual(@as(usize, 1), prog.success_count); // item2 succeeded
            try std.testing.expectEqual(@as(usize, 1), prog.skipped_count); // item1 was skipped
            try std.testing.expectEqual(@as(usize, 0), prog.failed_count);
            break;
        }
        _ = c.usleep(10 * 1000);
    }

    // Original destination file still contains "original in dst"
    var orig_buf: [32]u8 = undefined;
    const read_content = try readTestFile(dst_item1, &orig_buf);
    try std.testing.expectEqualStrings("original in dst", read_content);

    // Test 2: Conflict action = .rename
    try runner.start(.copy, sources[0..1], dst_dir, .rename);

    while (true) {
        const prog = runner.pollProgress();
        if (prog.state == .finished) {
            try std.testing.expectEqual(@as(usize, 1), prog.success_count);
            try std.testing.expectEqual(@as(usize, 0), prog.skipped_count);
            break;
        }
        _ = c.usleep(10 * 1000);
    }

    // Must have created "item1 (1).txt" in destination
    const renamed_dst = try std.fmt.allocPrint(allocator, "{s}/item1 (1).txt", .{dst_dir});
    defer allocator.free(renamed_dst);
    try std.testing.expect(testFileExists(renamed_dst));
}

test "JobRunner reports byte totals for recursive copies and moves" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const source_dir = try std.fmt.allocPrint(a, "{s}/source", .{tmp});
    defer a.free(source_dir);
    try ops_mod.createFolder(a, tmp, "source");
    const nested = try std.fmt.allocPrint(a, "{s}/nested", .{source_dir});
    defer a.free(nested);
    try ops_mod.createFolder(a, source_dir, "nested");

    const first = try std.fmt.allocPrint(a, "{s}/first.txt", .{source_dir});
    defer a.free(first);
    const second = try std.fmt.allocPrint(a, "{s}/second.txt", .{nested});
    defer a.free(second);
    try writeTestFile(first, "hello");
    try writeTestFile(second, "world!");

    const destination = try std.fmt.allocPrint(a, "{s}/destination", .{tmp});
    defer a.free(destination);
    try ops_mod.createFolder(a, tmp, "destination");

    const runner = try ops_mod.JobRunner.init(a);
    defer runner.deinit();

    try runner.start(.copy, &.{source_dir}, destination, .ask);
    runner.thread.?.join();
    runner.thread = null;

    var progress = runner.pollProgress();
    try std.testing.expect(progress.total_bytes_known);
    try std.testing.expect(!progress.measuring);
    try std.testing.expectEqual(@as(u64, 11), progress.total_bytes);
    try std.testing.expectEqual(@as(u64, 11), progress.transferred_bytes);
    try std.testing.expectEqual(@as(usize, 1), progress.success_count);

    const move_source = try std.fmt.allocPrint(a, "{s}/move-me.txt", .{tmp});
    defer a.free(move_source);
    try writeTestFile(move_source, "move bytes");
    try runner.start(.move, &.{move_source}, destination, .ask);
    runner.thread.?.join();
    runner.thread = null;

    progress = runner.pollProgress();
    try std.testing.expect(progress.total_bytes_known);
    try std.testing.expectEqual(@as(u64, 10), progress.total_bytes);
    try std.testing.expectEqual(@as(u64, 10), progress.transferred_bytes);
    try std.testing.expectEqual(@as(usize, 1), progress.success_count);
    try std.testing.expect(!testFileExists(move_source));
}

test "deletion dialog owns targets and shares responsive hit geometry" {
    const deletion = @import("../delete_dialog.zig");
    var state: deletion.State = .{};
    defer state.deinit();
    var path = [_]u8{ '/', 'a' };
    try state.add(&path, "a", false, 12, null);
    path[1] = 'b';
    try state.add(&path, "b", false, 10, null);
    try std.testing.expectEqualStrings("/a", state.paths.items[0]);
    try std.testing.expectEqualStrings("/b", state.paths.items[1]);
    try std.testing.expect(!state.permanent);
    try std.testing.expectEqual(deletion.Action.cancel, state.key(c.XKB_KEY_Escape));
    try std.testing.expectEqual(deletion.Action.none, state.key(c.XKB_KEY_Tab));
    try std.testing.expectEqual(deletion.Action.toggle, state.key(c.XKB_KEY_space));
    try std.testing.expectEqual(deletion.Action.none, state.key(c.XKB_KEY_Tab));
    try std.testing.expectEqual(deletion.Action.confirm, state.key(c.XKB_KEY_Return));
    for ([_][2]i32{ .{ 960, 540 }, .{ 480, 300 }, .{ 360, 280 }, .{ 1280, 656 } }) |size| {
        const g = deletion.Geometry.init(size[0], size[1]);
        try std.testing.expectEqual(deletion.Action.toggle, g.hit(g.x + 100, g.y + g.height - @as(f64, if (g.width < 440) 82 else 30)));
        try std.testing.expectEqual(deletion.Action.cancel, g.hit(g.x + g.width - 228, g.y + g.height - 30));
        try std.testing.expectEqual(deletion.Action.confirm, g.hit(g.x + g.width - 98, g.y + g.height - 30));
        try std.testing.expectEqual(deletion.Action.cancel, g.hit(g.x + g.width - 25, g.y + g.header / 2));
        try std.testing.expectEqual(@as(f32, 34), g.cancel.h);
        try std.testing.expectEqual(@as(f32, 34), g.confirm.h);
        try std.testing.expectEqual(deletion.Action.none, g.hit(0, 0));
    }
}

test "cancelled conflict and partial moves retain individual outcomes" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    try ops_mod.createFolder(a, tmp, "dest");
    const dest = try std.fmt.allocPrint(a, "{s}/dest", .{tmp});
    defer a.free(dest);
    try ops_mod.createFile(a, tmp, "first");
    try ops_mod.createFile(a, tmp, "conflict");
    try ops_mod.createFile(a, dest, "conflict");
    const first = try std.fmt.allocPrint(a, "{s}/first", .{tmp});
    defer a.free(first);
    const conflict = try std.fmt.allocPrint(a, "{s}/conflict", .{tmp});
    defer a.free(conflict);
    const runner = try ops_mod.JobRunner.init(a);
    defer runner.deinit();
    try runner.start(.move, &.{ first, conflict }, dest, .ask);
    var waiting = false;
    for (0..200) |_| {
        if (runner.pollProgress().state == .waiting_conflict) {
            waiting = true;
            break;
        }
        _ = c.usleep(10000);
    }
    try std.testing.expect(waiting);
    try std.testing.expectError(error.Busy, runner.start(.copy, &.{conflict}, dest, .skip));
    runner.resolveConflict(.cancel);
    runner.thread.?.join();
    runner.thread = null;
    const progress = runner.pollProgress();
    try std.testing.expect(progress.cancelled and progress.is_error);
    try std.testing.expectEqual(@as(usize, 1), progress.success_count);
    try std.testing.expectEqual(@as(usize, 1), progress.processed_items);
    try std.testing.expect(runner.movedSuccessfully(first));
    try std.testing.expect(!runner.movedSuccessfully(conflict));
    try std.testing.expect(testFileExists(conflict));
    try runner.start(.move, &.{conflict}, dest, .skip);
    runner.thread.?.join();
    runner.thread = null;
    try std.testing.expectEqual(@as(usize, 1), runner.pollProgress().skipped_count);
    try std.testing.expect(!runner.movedSuccessfully(conflict));
}

test "clipboard pipes are nonblocking and reject oversized input" {
    const transfer = @import("transfer.zig");
    const a = std.heap.c_allocator;
    var fds: [2]c_int = undefined;
    try std.testing.expect(c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) == 0);
    var receive = transfer.Receive{ .fd = fds[0], .text = true, .revision = 1, .directory = try a.dupe(u8, "/"), .started = 0 };
    defer receive.deinit();
    try std.testing.expect(!try receive.read()); // queued request has not sent yet
    const payload = try a.alloc(u8, 100000);
    defer a.free(payload);
    @memset(payload, 'a');
    var send = try transfer.Send.init(fds[1], payload, 0);
    var finished = false;
    for (0..100) |_| {
        finished = try send.write();
        _ = try receive.read();
        if (finished) break;
    }
    try std.testing.expect(finished);
    send.deinit();
    try std.testing.expect(try receive.read());
    try std.testing.expectEqualSlices(u8, payload, receive.bytes.items);
    const fd = c.memfd_create("oversize-clipboard", c.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    try std.testing.expect(c.ftruncate(fd, transfer.limit + 1) == 0);
    var oversized = transfer.Receive{ .fd = fd, .text = false, .revision = 0, .directory = try a.dupe(u8, "/"), .started = 0 };
    defer oversized.deinit();
    for (0..16) |_| try std.testing.expect(!try oversized.read());
    try std.testing.expectError(error.TooLarge, oversized.read());
}

test "view preferences survive restart and reject malformed state" {
    const Preferences = @import("preferences.zig").Preferences;
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/state/files", .{tmp});
    defer a.free(path);
    const pref: Preferences = .{ .list = true, .sort = 7, .unpinned_places = 0b0101010, .terminal_height = 286 };
    try pref.save(a, std.testing.io, path);
    try std.testing.expectEqual(pref, Preferences.load(a, std.testing.io, path));
    try writeTestFile(path, &.{ '1', 1, 7, '\n' });
    try std.testing.expectEqual(Preferences{ .list = true, .sort = 7 }, Preferences.load(a, std.testing.io, path));
    try writeTestFile(path, &.{ '3', 1, 2, 3, 0, '\n' });
    try std.testing.expectEqual(Preferences{ .list = true, .sort = 2, .unpinned_places = 3, .git_view = false }, Preferences.load(a, std.testing.io, path));
    try writeTestFile(path, &.{ '4', 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xff, '\n' });
    try std.testing.expectEqual(Preferences{}, Preferences.load(a, std.testing.io, path));
    try writeTestFile(path, &.{ '2', 1, 7, 0x80, '\n' });
    try std.testing.expectEqual(Preferences{}, Preferences.load(a, std.testing.io, path));
    try writeTestFile(path, "invalid");
    try std.testing.expectEqual(Preferences{}, Preferences.load(a, std.testing.io, path));
}

test "cancelling an active copy removes partial output and preserves source" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    try ops_mod.createFolder(a, tmp, "dest");
    const dest = try std.fmt.allocPrint(a, "{s}/dest", .{tmp});
    defer a.free(dest);
    const src = try std.fmt.allocPrintSentinel(a, "{s}/large", .{tmp}, 0);
    defer a.free(src);
    const dst = try std.fmt.allocPrintSentinel(a, "{s}/large", .{dest}, 0);
    defer a.free(dst);
    const fd = c.open(src, c.O_CREAT | c.O_WRONLY | c.O_CLOEXEC, @as(c_uint, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    // Sparse source; cancellation follows the first actual destination write.
    try std.testing.expect(c.ftruncate(fd, 512 * 1024 * 1024) == 0);
    const runner = try ops_mod.JobRunner.init(a);
    defer runner.deinit();
    try runner.start(.copy, &.{src}, dest, .ask);
    var started = false;
    for (0..1000) |_| {
        const progress = runner.pollProgress();
        if (progress.transferred_bytes > 0) {
            try std.testing.expect(progress.total_bytes_known);
            try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), progress.total_bytes);
            started = true;
            break;
        }
        _ = c.usleep(1000);
    }
    try std.testing.expect(started);
    runner.cancel();
    runner.thread.?.join();
    runner.thread = null;
    const progress = runner.pollProgress();
    try std.testing.expect(progress.cancelled);
    try std.testing.expectEqual(@as(usize, 0), progress.success_count);
    try std.testing.expect(testFileExists(src));
    try std.testing.expect(!testFileExists(dst));
}

test "paused copy stops at a safe point and resumes" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    try ops_mod.createFolder(a, tmp, "dest");
    const dest = try std.fmt.allocPrint(a, "{s}/dest", .{tmp});
    defer a.free(dest);
    const src = try std.fmt.allocPrintSentinel(a, "{s}/large", .{tmp}, 0);
    defer a.free(src);
    const fd = c.open(src, c.O_CREAT | c.O_WRONLY | c.O_CLOEXEC, @as(c_uint, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    try std.testing.expect(c.ftruncate(fd, 512 * 1024 * 1024) == 0);

    const runner = try ops_mod.JobRunner.init(a);
    defer runner.deinit();
    try runner.start(.copy, &.{src}, dest, .ask);

    var started = false;
    for (0..1000) |_| {
        if (runner.pollProgress().transferred_bytes > 0) {
            started = true;
            break;
        }
        _ = c.usleep(1000);
    }
    try std.testing.expect(started);

    runner.pause();
    var paused = false;
    for (0..1000) |_| {
        if (runner.pollProgress().state == .paused) {
            paused = true;
            break;
        }
        _ = c.usleep(1000);
    }
    try std.testing.expect(paused);
    const paused_bytes = runner.pollProgress().transferred_bytes;
    _ = c.usleep(20 * 1000);
    try std.testing.expectEqual(paused_bytes, runner.pollProgress().transferred_bytes);

    runner.resumeJob();
    var resumed = false;
    for (0..1000) |_| {
        if (runner.pollProgress().state == .running) {
            resumed = true;
            break;
        }
        _ = c.usleep(1000);
    }
    try std.testing.expect(resumed);
    runner.cancel();
    runner.thread.?.join();
    runner.thread = null;
    try std.testing.expect(runner.pollProgress().cancelled);
    try std.testing.expect(testFileExists(src));
}

test "failed copy and cross-device fallback never remove an existing destination" {
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    const src = try std.fmt.allocPrint(a, "{s}/source", .{tmp});
    defer a.free(src);
    const dst = try std.fmt.allocPrint(a, "{s}/destination", .{tmp});
    defer a.free(dst);
    try writeTestFile(src, "source");
    try writeTestFile(dst, "existing data");
    try std.testing.expectError(error.OpenDestFailed, ops_mod.crossDeviceMove(a, src, dst, null));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("existing data", try readTestFile(dst, &buf));
    try std.testing.expect(testFileExists(src));
}
