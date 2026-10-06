const std = @import("std");
const history_mod = @import("files/history.zig");
const worker_mod = @import("files/worker.zig");
const app_mod = @import("files/app.zig");
const ops_mod = @import("files/ops.zig");
const clipboard_mod = @import("files/clipboard.zig");
const dirsize_mod = @import("files/dirsize.zig");
const c = @import("files/c.zig").api;
const linux = std.os.linux;

test "History navigation stack" {
    const allocator = std.testing.allocator;
    var h = try history_mod.History.init(allocator, "/home/user");
    defer h.deinit();

    try std.testing.expectEqualStrings("/home/user", h.current);
    try std.testing.expect(!h.canBack());
    try std.testing.expect(!h.canForward());
    try std.testing.expect(h.canUp());

    // Navigate to Documents
    try h.navigate("/home/user/Documents");
    try std.testing.expectEqualStrings("/home/user/Documents", h.current);
    try std.testing.expect(h.canBack());
    try std.testing.expect(!h.canForward());

    // Navigate to Projects
    try h.navigate("/home/user/Documents/Projects");
    try std.testing.expectEqualStrings("/home/user/Documents/Projects", h.current);

    // Back -> Documents
    const b1 = try h.back();
    try std.testing.expect(b1 != null);
    try std.testing.expectEqualStrings("/home/user/Documents", b1.?);
    try std.testing.expect(h.canForward());

    // Back -> /home/user
    const b2 = try h.back();
    try std.testing.expect(b2 != null);
    try std.testing.expectEqualStrings("/home/user", b2.?);
    try std.testing.expect(!h.canBack());

    // Forward -> Documents
    const f1 = try h.forward();
    try std.testing.expect(f1 != null);
    try std.testing.expectEqualStrings("/home/user/Documents", f1.?);
    try std.testing.expect(h.canBack());

    // Up from Documents -> /home/user
    const up1 = try h.up();
    try std.testing.expect(up1 != null);
    try std.testing.expectEqualStrings("/home/user", up1.?);

    // Home -> /home/user
    const h1 = try h.home("/home/user");
    try std.testing.expect(h1 == null); // Already at home

    // Archive locations survive history and leave the archive at its root.
    const zip = "/home/user/sample.zip";
    try h.navigateLocation(zip, zip.len);
    try h.navigate("/home/user/sample.zip/nested");
    try std.testing.expectEqual(zip.len, h.archive_len);
    _ = try h.up();
    try std.testing.expectEqualStrings(zip, h.current);
    _ = try h.up();
    try std.testing.expectEqualStrings("/home/user", h.current);
    try std.testing.expectEqual(@as(usize, 0), h.archive_len);
    _ = try h.back();
    try std.testing.expectEqual(zip.len, h.archive_len);
    _ = try h.forward();
    try std.testing.expectEqual(@as(usize, 0), h.archive_len);

    // Navigate to /, test canUp is false
    try h.navigate("/");
    try std.testing.expectEqualStrings("/", h.current);
    try std.testing.expect(!h.canUp());
    const u_root = try h.up();
    try std.testing.expect(u_root == null);
}

test "isStaleSnapshot rejects results from a superseded navigation request" {
    // A snapshot tagged with an older request id than the app's current
    // active_request_id belongs to a directory/hidden-files state the user
    // has already navigated away from; sync() must drop it instead of
    // flashing stale (or error) content over the real destination.
    try std.testing.expect(app_mod.App.isStaleSnapshot(1, 2));
    try std.testing.expect(app_mod.App.isStaleSnapshot(41, 42));

    // The snapshot matching the current request, or one requested even
    // later (shouldn't happen, but must not be treated as stale either),
    // is accepted.
    try std.testing.expect(!app_mod.App.isStaleSnapshot(2, 2));
    try std.testing.expect(!app_mod.App.isStaleSnapshot(3, 2));
}

test "formatSize human readable strings" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("—", app_mod.formatSize(-1, &buf));
    try std.testing.expectEqualStrings("0 B", app_mod.formatSize(0, &buf));
    try std.testing.expectEqualStrings("500 B", app_mod.formatSize(500, &buf));
    try std.testing.expectEqualStrings("1.0 KB", app_mod.formatSize(1024, &buf));
    try std.testing.expectEqualStrings("1.5 KB", app_mod.formatSize(1536, &buf));
    try std.testing.expectEqualStrings("1.0 MB", app_mod.formatSize(1024 * 1024, &buf));
    try std.testing.expectEqualStrings("2.5 MB", app_mod.formatSize(2621440, &buf));
    try std.testing.expectEqualStrings("1.0 GB", app_mod.formatSize(1024 * 1024 * 1024, &buf));
    try std.testing.expectEqualStrings("1.5 TB", app_mod.formatSize(1024 * 1024 * 1024 * 1024 + 512 * 1024 * 1024 * 1024, &buf));
}

test "mimeIcon mapping" {
    try std.testing.expectEqualStrings("folder", worker_mod.mimeIcon("Documents", true, false, false));
    try std.testing.expectEqualStrings("dialog-warning", worker_mod.mimeIcon("broken_link", false, true, true));
    try std.testing.expectEqualStrings("image-x-generic", worker_mod.mimeIcon("photo.PNG", false, false, false));
    try std.testing.expectEqualStrings("image-x-generic", worker_mod.mimeIcon("art.svg", false, false, false));
    try std.testing.expectEqualStrings("application-pdf", worker_mod.mimeIcon("doc.pdf", false, false, false));
    try std.testing.expectEqualStrings("audio-x-generic", worker_mod.mimeIcon("song.mp3", false, false, false));
    try std.testing.expectEqualStrings("video-x-generic", worker_mod.mimeIcon("movie.mp4", false, false, false));
    try std.testing.expectEqualStrings("package-x-generic", worker_mod.mimeIcon("archive.tar.gz", false, false, false));
    try std.testing.expectEqualStrings("text-x-script", worker_mod.mimeIcon("build.zig", false, false, false));
    try std.testing.expectEqualStrings("application-x-executable", worker_mod.mimeIcon("app.desktop", false, false, false));
    try std.testing.expectEqualStrings("text-x-generic", worker_mod.mimeIcon("notes.txt", false, false, false));
}

test "Item sorting: folders first and case-insensitive alphabetical" {
    var items = [_]worker_mod.Item{
        .{ .name = "zebra.txt", .path = "/zebra.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 0, .icon_name = "" },
        .{ .name = "Alpha", .path = "/Alpha", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "" },
        .{ .name = "apple.txt", .path = "/apple.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 0, .icon_name = "" },
        .{ .name = "beta", .path = "/beta", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "" },
        .{ .name = "Banana.txt", .path = "/Banana.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 0, .icon_name = "" },
    };

    std.mem.sort(worker_mod.Item, &items, {}, struct {
        fn less(_: void, a: worker_mod.Item, b: worker_mod.Item) bool {
            if (a.is_dir != b.is_dir) {
                return a.is_dir;
            }
            if (!std.ascii.eqlIgnoreCase(a.name, b.name)) {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);

    // Folders first: Alpha, beta
    try std.testing.expectEqualStrings("Alpha", items[0].name);
    try std.testing.expectEqualStrings("beta", items[1].name);

    // Files: apple.txt, Banana.txt, zebra.txt
    try std.testing.expectEqualStrings("apple.txt", items[2].name);
    try std.testing.expectEqualStrings("Banana.txt", items[3].name);
    try std.testing.expectEqualStrings("zebra.txt", items[4].name);
}

test "validateFilename edge cases" {
    try std.testing.expectError(error.EmptyName, ops_mod.validateFilename(""));
    try std.testing.expectError(error.InvalidCharacter, ops_mod.validateFilename("foo/bar"));
    try std.testing.expectError(error.ReservedName, ops_mod.validateFilename("."));
    try std.testing.expectError(error.ReservedName, ops_mod.validateFilename(".."));

    try ops_mod.validateFilename("hello.txt");
    try ops_mod.validateFilename("New Folder (1)");
    try ops_mod.validateFilename(".gitignore");
}

fn makeTestDir(buf: []u8) ![]const u8 {
    const tmpl = "/tmp/rediwm_test_XXXXXX\x00";
    @memcpy(buf[0..tmpl.len], tmpl);
    const res = c.mkdtemp(@ptrCast(buf.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(res)));
}

test "createFolder, createFile and renameItem on temporary directory" {
    const allocator = std.testing.allocator;
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try makeTestDir(&tmp_path_buf);
    defer ops_mod.deleteRecursive(allocator, tmp_path) catch {};

    // Create folder
    try ops_mod.createFolder(allocator, tmp_path, "test_dir");
    try std.testing.expectError(error.PathAlreadyExists, ops_mod.createFolder(allocator, tmp_path, "test_dir"));

    // Create file
    try ops_mod.createFile(allocator, tmp_path, "test_file.txt");
    try std.testing.expectError(error.PathAlreadyExists, ops_mod.createFile(allocator, tmp_path, "test_file.txt"));

    // Rename file
    const old_path = try std.fmt.allocPrint(allocator, "{s}/test_file.txt", .{tmp_path});
    defer allocator.free(old_path);
    try ops_mod.renameItem(allocator, old_path, "renamed.txt");

    // Renaming to existing folder fails
    const new_path = try std.fmt.allocPrint(allocator, "{s}/renamed.txt", .{tmp_path});
    defer allocator.free(new_path);
    try std.testing.expectError(error.PathAlreadyExists, ops_mod.renameItem(allocator, new_path, "test_dir"));

    // Renaming to same name is no-op
    try ops_mod.renameItem(allocator, new_path, "renamed.txt");
}

test "generateUniqueName conflict resolution" {
    const allocator = std.testing.allocator;
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try makeTestDir(&tmp_path_buf);
    defer ops_mod.deleteRecursive(allocator, tmp_path) catch {};

    // When doesn't exist, returns original name
    const n1 = try ops_mod.generateUniqueName(allocator, tmp_path, "note.txt");
    defer allocator.free(n1);
    try std.testing.expectEqualStrings("note.txt", n1);

    // Create note.txt
    try ops_mod.createFile(allocator, tmp_path, "note.txt");

    // Next unique name should be "note (1).txt"
    const n2 = try ops_mod.generateUniqueName(allocator, tmp_path, "note.txt");
    defer allocator.free(n2);
    try std.testing.expectEqualStrings("note (1).txt", n2);

    // Create note (1).txt
    try ops_mod.createFile(allocator, tmp_path, "note (1).txt");

    // Next unique name should be "note (2).txt"
    const n3 = try ops_mod.generateUniqueName(allocator, tmp_path, "note.txt");
    defer allocator.free(n3);
    try std.testing.expectEqualStrings("note (2).txt", n3);

    // Test file without extension
    try ops_mod.createFolder(allocator, tmp_path, "MyFolder");
    const d1 = try ops_mod.generateUniqueName(allocator, tmp_path, "MyFolder");
    defer allocator.free(d1);
    try std.testing.expectEqualStrings("MyFolder (1)", d1);
}

test "isDescendantOrSame cycle detection" {
    try std.testing.expect(ops_mod.isDescendantOrSame("/a/b", "/a/b"));
    try std.testing.expect(ops_mod.isDescendantOrSame("/a/b", "/a/b/c"));
    try std.testing.expect(ops_mod.isDescendantOrSame("/a/b", "/a/b/c/d"));

    try std.testing.expect(!ops_mod.isDescendantOrSame("/a/b", "/a/b2"));
    try std.testing.expect(!ops_mod.isDescendantOrSame("/a/b", "/a/c"));
    try std.testing.expect(!ops_mod.isDescendantOrSame("/a/b", "/a"));
}

fn writeTestFile(path: []const u8, content: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
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

fn readTestFile(path: []const u8, buf: []u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd = c.open(path_z, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFileFailed;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFileFailed;
    return buf[0..@intCast(n)];
}

fn testFileExists(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
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
    const link_src_z = try allocator.dupeZ(u8, link_src);
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
    const dst_link_z = try allocator.dupeZ(u8, dst_link);
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

test "deletion dialog owns targets and shares responsive hit geometry" {
    const deletion = @import("delete_dialog.zig");
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
    const transfer = @import("files/transfer.zig");
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
    const Preferences = @import("files/preferences.zig").Preferences;
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/state/files", .{tmp});
    defer a.free(path);
    const pref: Preferences = .{ .list = true, .sort = 7, .unpinned_places = 0b0101010 };
    try pref.save(a, std.testing.io, path);
    try std.testing.expectEqual(pref, Preferences.load(a, std.testing.io, path));
    try writeTestFile(path, &.{ '1', 1, 7, '\n' });
    try std.testing.expectEqual(Preferences{ .list = true, .sort = 7 }, Preferences.load(a, std.testing.io, path));
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
        var st: c.struct_stat = undefined;
        if (c.stat(dst, &st) == 0 and st.st_size > 0) {
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

fn countOpenFds() !usize {
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
    const a = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const tmp = try makeTestDir(&tmp_buf);
    defer ops_mod.deleteRecursive(a, tmp) catch {};

    const f1 = try std.fmt.allocPrint(a, "{s}/file1.txt", .{tmp});
    defer a.free(f1);
    try writeTestFile(f1, "hardlink payload");

    const f1_z = try a.dupeZ(u8, f1);
    defer a.free(f1_z);
    const f2 = try std.fmt.allocPrint(a, "{s}/file2_hardlink.txt", .{tmp});
    defer a.free(f2);
    const f2_z = try a.dupeZ(u8, f2);
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

test {
    _ = @import("files/chooser.zig");
    _ = @import("config").portals;
    _ = @import("files/thumb_decode.zig");
    _ = @import("files/thumbs.zig");
    _ = @import("files/volumes.zig");
    _ = @import("files/pins.zig");
}

test {
    _ = @import("session/file_chooser_protocol.zig");
}

test "Git porcelain preserves paths, rename pairs, conflicts and directory boundaries" {
    const git = @import("files/git.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var repo = try git.parse(
        arena.allocator(),
        "# branch.oid abcdef0123456789\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +3 -2\x00" ++
            "1 .M N... 100644 100644 100644 abc abc src/a file\n.txt\x00" ++
            "1 D. N... 100644 000000 000000 abc abc gone.txt\x00" ++
            "2 R. N... 100644 100644 100644 abc abc R100 renamed.txt\x00old name.txt\x00" ++
            "u UU N... 100644 100644 100644 100644 abc abc abc src/conflict.txt\x00" ++
            "? new directory/\x00? src2/other.txt\x00",
    );
    repo.root = "/repo";
    repo.directory = "/repo";
    try git.applyNumstat(&repo, arena.allocator(), "28\t3\tsrc/a file\n.txt\x00" ++
        "0\t7\tgone.txt\x00" ++
        "2\t1\t\x00old name.txt\x00renamed.txt\x00" ++
        "-\t-\tsrc/conflict.txt\x00" ++
        "9\t4\tsrc2/other.txt\x00");
    try repo.index(arena.allocator());
    try std.testing.expectEqualStrings("main", repo.branch);
    try std.testing.expect(repo.upstream);
    try std.testing.expectEqual(@as(u64, 3), repo.ahead);
    try std.testing.expectEqual(@as(u64, 2), repo.behind);
    try std.testing.expectEqual(@as(usize, 6), repo.changes.len);
    try std.testing.expectEqual(git.Status.deleted, repo.status("gone.txt"));
    try std.testing.expectEqual(git.Status.renamed, repo.status("renamed.txt"));
    try std.testing.expectEqual(git.Status.clean, repo.status("old name.txt"));
    try std.testing.expectEqual(git.Status.conflict, repo.status("src"));
    try std.testing.expectEqual(git.Status.untracked, repo.status("new directory"));
    try std.testing.expectEqualDeep(git.LineCounts{ .added = 28, .removed = 3 }, repo.lines("src").?);
    try std.testing.expectEqualDeep(git.LineCounts{ .added = 2, .removed = 1 }, repo.lines("renamed.txt").?);
    try std.testing.expectEqual(@as(u64, 7), repo.lines("gone.txt").?.removed);
    repo.directory = "/repo/src";
    try repo.index(arena.allocator());
    try std.testing.expectEqual(git.Status.modified, repo.status("a file\n.txt"));
    try std.testing.expectEqual(git.Status.clean, repo.status("other.txt"));
    try std.testing.expectEqual(git.Status.conflict, repo.status("conflict.txt"));
    try std.testing.expectEqualDeep(git.LineCounts{ .added = 28, .removed = 3 }, repo.lines("a file\n.txt").?);
    try std.testing.expect(repo.lines("conflict.txt") == null);
    try std.testing.expect(repo.lines("other.txt") == null);
}

fn writeArchiveFixture(path: []const u8, names: []const [:0]const u8) !void {
    const api = @cImport({
        @cInclude("archive.h");
        @cInclude("archive_entry.h");
    });
    const writer = api.archive_write_new() orelse return error.OutOfMemory;
    defer _ = api.archive_write_free(writer);
    if (std.mem.endsWith(u8, path, ".zip")) {
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_set_format_zip(writer));
    } else {
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_set_format_pax_restricted(writer));
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_add_filter_gzip(writer));
    }
    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_open_filename(writer, zpath));
    for (names) |name| {
        const entry = api.archive_entry_new() orelse return error.OutOfMemory;
        defer api.archive_entry_free(entry);
        api.archive_entry_set_pathname(entry, name);
        const directory = std.mem.endsWith(u8, name, "/");
        api.archive_entry_set_filetype(entry, if (directory) c.S_IFDIR else c.S_IFREG);
        api.archive_entry_set_perm(entry, 0o644);
        api.archive_entry_set_size(entry, if (directory) 0 else 7);
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_header(writer, entry));
        if (!directory) try std.testing.expectEqual(@as(isize, 7), api.archive_write_data(writer, "payload", 7));
    }
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_close(writer));
}

test "archive index, staged extraction and member reads preserve destination boundaries" {
    for ([_][]const u8{ ".zip", ".tar.gz" }) |extension| {
        const archive = @import("files/archive.zig");
        const mem = std.testing.allocator;
        var buf: [256]u8 = undefined;
        const root = try makeTestDir(&buf);
        defer ops_mod.deleteRecursive(mem, root) catch {};
        const source = try std.fmt.allocPrint(mem, "{s}/sample{s}", .{ root, extension });
        defer mem.free(source);
        try writeArchiveFixture(source, &.{ "/", "nested/item.txt", "other.txt" });
        var cancel: archive.Cancel = .init(false);
        var index = try archive.Index.read(mem, source, &cancel);
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 3), index.entries.len);
        try std.testing.expectEqualStrings("nested", index.entries[0].path);
        try std.testing.expect(index.entries[0].directory);
        const stage = try archive.temporary(mem, root);
        defer mem.free(stage);
        try archive.extract(mem, source, stage, "nested/item.txt", &cancel);
        const member = try std.fmt.allocPrint(mem, "{s}/nested/item.txt", .{stage});
        defer mem.free(member);
        var content: [32]u8 = undefined;
        try std.testing.expectEqualStrings("payload", try readTestFile(member, &content));
        try std.testing.expectError(error.WriteFailed, archive.extract(mem, source, stage, "nested/item.txt", &cancel));
        const full_stage = try archive.temporary(mem, root);
        defer mem.free(full_stage);
        try archive.extract(mem, source, full_stage, null, &cancel);
        const other = try std.fmt.allocPrint(mem, "{s}/other.txt", .{full_stage});
        defer mem.free(other);
        try std.testing.expectEqualStrings("payload", try readTestFile(other, &content));
        cancel.store(true, .release);
        try std.testing.expectError(error.Cancelled, archive.extract(mem, source, stage, null, &cancel));
        cancel.store(false, .release);

        // An unsafe member prevents publication of even earlier valid members.
        try writeArchiveFixture(source, &.{ "safe.txt", "../escaped.txt" });
        var runner = try ops_mod.JobRunner.init(mem);
        defer runner.deinit();
        try runner.startArchive(source, root, null);
        runner.thread.?.join();
        runner.thread = null;
        try std.testing.expectEqual(@as(usize, 1), runner.pollProgress().failed_count);
        const safe = try std.fmt.allocPrintSentinel(mem, "{s}/safe.txt", .{root}, 0);
        defer mem.free(safe);
        try std.testing.expect(c.access(safe, c.F_OK) != 0);
        for ([_][]const u8{ "/absolute", "//", "dir/../../escape", "a\\b" }) |name| {
            try std.testing.expectError(error.UnsafeArchivePath, archive.normalize(mem, name));
        }

        // Extraction shares the transfer conflict policy, preserving existing data.
        try writeArchiveFixture(source, &.{"same.txt"});
        const same = try std.fmt.allocPrint(mem, "{s}/same.txt", .{root});
        defer mem.free(same);
        try writeTestFile(same, "original");
        try runner.start(.extract, &.{source}, root, .skip);
        runner.thread.?.join();
        runner.thread = null;
        try std.testing.expectEqual(@as(usize, 1), runner.pollProgress().skipped_count);
        try std.testing.expectEqualStrings("original", try readTestFile(same, &content));
        try runner.start(.extract, &.{source}, root, .rename);
        runner.thread.?.join();
        runner.thread = null;
        const renamed = try std.fmt.allocPrint(mem, "{s}/same (1).txt", .{root});
        defer mem.free(renamed);
        try std.testing.expectEqualStrings("payload", try readTestFile(renamed, &content));
    }
}
