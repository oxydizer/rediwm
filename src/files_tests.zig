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

pub fn makeTestDir(buf: []u8) ![]const u8 {
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

const ops_tests = @import("files/ops_tests.zig");
pub const writeTestFile = ops_tests.writeTestFile;
pub const readTestFile = ops_tests.readTestFile;
test {
    _ = ops_tests;
}

test {
    _ = @import("files/dirsize_tests.zig");
}

test {
    _ = @import("mime_db.zig");
    _ = @import("files/chooser.zig");
    _ = @import("config").portals;
    _ = @import("files/thumb_decode.zig");
    _ = @import("files/thumbs.zig");
    _ = @import("files/volumes.zig");
    _ = @import("files/pins.zig");
    _ = @import("files/trash_tests.zig");
    _ = @import("files/terminal/tests.zig");
}

test {
    _ = @import("session/file_chooser_protocol.zig");
}

test {
    _ = @import("files/archive_tests.zig");
}
