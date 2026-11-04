//! Trash restore and permanent-delete tests on fixture trash directories.

const std = @import("std");
const trash = @import("trash.zig");
const ops = @import("ops.zig");
const c = @import("c.zig").api;
const files_tests = @import("../files_tests.zig");
const ops_tests = @import("ops_tests.zig");

const allocator = std.testing.allocator;

fn exists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false;
    var st: c.struct_stat = undefined;
    return c.lstat(z, &st) == 0;
}

fn encode(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(arena, ch);
        } else try out.print(arena, "%{X:0>2}", .{ch});
    }
    return out.items;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp_buf: [256]u8 = undefined,
    tmp: []const u8 = "",
    /// `$XDG_DATA_HOME/Trash/files`.
    files: []const u8 = "",
    /// A stand-in for the home directory, where items came from.
    home: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.tmp = try files_tests.makeTestDir(&self.tmp_buf);
        const a = self.arena.allocator();
        for ([_][]const u8{ "Trash", "Trash/files", "Trash/info", "home" }) |dir| {
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.tmp, dir });
            if (c.mkdir(try a.dupeSentinel(u8, full, 0), 0o755) != 0) return error.MkdirFailed;
        }
        self.files = try self.path("Trash/files");
        self.home = try self.path("home");
    }

    fn deinit(self: *Fixture) void {
        ops.deleteRecursive(allocator, self.tmp) catch {};
        self.arena.deinit();
    }

    fn path(self: *Fixture, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp, rel });
    }

    fn home_path(self: *Fixture, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.home, rel });
    }

    /// A trashed file or folder named `name` that came from `origin`.
    fn put(self: *Fixture, name: []const u8, origin: []const u8, is_dir: bool, content: []const u8) !void {
        const a = self.arena.allocator();
        const item = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.files, name });
        if (is_dir) {
            try ops.createFolder(allocator, self.files, name);
            if (content.len > 0) try ops_tests.writeTestFile(try std.fmt.allocPrint(a, "{s}/inner.txt", .{item}), content);
        } else try ops_tests.writeTestFile(item, content);
        try self.info(name, origin);
    }

    fn info(self: *Fixture, name: []const u8, origin: []const u8) !void {
        const a = self.arena.allocator();
        const text = try std.fmt.allocPrint(a, "[Trash Info]\nPath={s}\nDeletionDate=2026-11-03T12:00:00\n", .{try encode(a, origin)});
        try ops_tests.writeTestFile(try self.path(try std.fmt.allocPrint(a, "Trash/info/{s}.trashinfo", .{name})), text);
    }

    fn infoExists(self: *Fixture, name: []const u8) !bool {
        return exists(try self.path(try std.fmt.allocPrint(self.arena.allocator(), "Trash/info/{s}.trashinfo", .{name})));
    }
};

fn expectContent(path: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try ops_tests.readTestFile(path, &buf));
}

test "relation tells the trash root from folders inside it" {
    const files = "/home/u/.local/share/Trash/files";
    try std.testing.expectEqual(trash.Relation.root, trash.relation(files, files));
    try std.testing.expectEqual(trash.Relation.root, trash.relation(files, files ++ "/"));
    try std.testing.expectEqual(trash.Relation.inside, trash.relation(files, files ++ "/dir"));
    try std.testing.expectEqual(trash.Relation.inside, trash.relation(files, files ++ "/dir/sub/"));
    try std.testing.expectEqual(trash.Relation.none, trash.relation(files, files ++ "2"));
    try std.testing.expectEqual(trash.Relation.none, trash.relation(files, "/home/u/.local/share/Trash"));
    try std.testing.expectEqual(trash.Relation.none, trash.relation(files, "/home/u"));
}

test "parseInfo reads the Trash Info group and rejects unusable metadata" {
    const info = try trash.parseInfo(allocator, "[Trash Info]\r\nPath=/home/u/caf%C3%A9%20menu.txt\r\nDeletionDate=2026-11-03T11:36:35\r\n");
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("/home/u/café menu.txt", info.path);
    try std.testing.expectEqualStrings("2026-11-03T11:36:35", info.date.?);

    // Only the [Trash Info] group counts, and a trailing slash is dropped.
    const other = try trash.parseInfo(allocator, "[Other]\nPath=/wrong\n[Trash Info]\nPath=/right/dir/\n");
    defer other.deinit(allocator);
    try std.testing.expectEqualStrings("/right/dir", other.path);
    try std.testing.expectEqual(@as(?[]u8, null), other.date);

    for ([_][]const u8{
        "",
        "Path=/no/group\n",
        "[Trash Info]\nDeletionDate=2026-11-03T11:36:35\n",
        "[Trash Info]\nPath=relative/file\n",
        "[Trash Info]\nPath=/\n",
        "[Trash Info]\nPath=/a/../b\n",
        "[Trash Info]\nPath=/a/./b\n",
        "[Trash Info]\nPath=/a%00b\n",
        "[Trash Info]\nPath=/a%4\n",
        "[Trash Info]\nPath=/a%zz\n",
        "[Other]\nPath=/a\n",
    }) |text| {
        try std.testing.expectError(error.InvalidMetadata, trash.parseInfo(allocator, text));
    }
}

test "restoring puts a file back and removes its metadata" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const origin = try fx.home_path("note.txt");
    try fx.put("note.txt", origin, false, "kept");

    const restored = try trash.restoreEntry(allocator, fx.files, "note.txt");
    defer restored.deinit(allocator);
    try std.testing.expectEqualStrings(origin, restored.path);
    try std.testing.expect(!restored.renamed);
    try expectContent(origin, "kept");
    try std.testing.expect(!exists(try fx.path("Trash/files/note.txt")));
    try std.testing.expect(!try fx.infoExists("note.txt"));
}

test "restoring uses the original name, not the one chosen when trashing" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const origin = try fx.home_path("report.txt");
    try fx.put("report.2.txt", origin, false, "second");

    const restored = try trash.restoreEntry(allocator, fx.files, "report.2.txt");
    defer restored.deinit(allocator);
    try std.testing.expectEqualStrings(origin, restored.path);
    try expectContent(origin, "second");
}

test "restoring never overwrites: a taken name gets a unique one" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const origin = try fx.home_path("a.txt");
    try ops_tests.writeTestFile(origin, "current");
    try fx.put("a.txt", origin, false, "trashed");

    const first = try trash.restoreEntry(allocator, fx.files, "a.txt");
    defer first.deinit(allocator);
    try std.testing.expect(first.renamed);
    try std.testing.expectEqualStrings(try fx.home_path("a (1).txt"), first.path);
    try expectContent(origin, "current");
    try expectContent(first.path, "trashed");
    try std.testing.expect(!try fx.infoExists("a.txt"));

    // A second trashed copy skips the name the first one took.
    try fx.put("a.txt", origin, false, "again");
    const second = try trash.restoreEntry(allocator, fx.files, "a.txt");
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings(try fx.home_path("a (2).txt"), second.path);
    try expectContent(first.path, "trashed");
}

test "a dangling symlink at the destination counts as taken" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const origin = try fx.home_path("link");
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("/nonexistent/target", try std.fmt.bufPrintSentinel(&buf, "{s}", .{origin}, 0)));
    try fx.put("link", origin, false, "data");

    const restored = try trash.restoreEntry(allocator, fx.files, "link");
    defer restored.deinit(allocator);
    try std.testing.expect(restored.renamed);
    try expectContent(restored.path, "data");
    try std.testing.expect(exists(origin));
}

test "restoring recreates missing parent folders" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const origin = try fx.home_path("gone/deeper/file.txt");
    try fx.put("file.txt", origin, false, "deep");

    const restored = try trash.restoreEntry(allocator, fx.files, "file.txt");
    defer restored.deinit(allocator);
    try expectContent(origin, "deep");
}

test "a parent that cannot be created leaves the entry and creates nothing" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    // "blocker" is a file, so "blocker/sub" can never be a folder.
    try ops_tests.writeTestFile(try fx.home_path("blocker"), "x");
    try fx.put("file.txt", try fx.home_path("blocker/sub/file.txt"), false, "stay");

    try std.testing.expectError(error.NoParent, trash.restoreEntry(allocator, fx.files, "file.txt"));
    try std.testing.expect(exists(try fx.path("Trash/files/file.txt")));
    try std.testing.expect(try fx.infoExists("file.txt"));
}

test "an unwritable destination folder fails without touching the entry" {
    if (c.geteuid() == 0) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const locked = try fx.home_path("locked");
    try ops.createFolder(allocator, fx.home, "locked");
    var buf: [4096]u8 = undefined;
    const locked_z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{locked}, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(locked_z, 0o555));
    defer _ = c.chmod(locked_z, 0o755);
    try fx.put("file.txt", try fx.home_path("locked/file.txt"), false, "stay");

    try std.testing.expectError(error.AccessDenied, trash.restoreEntry(allocator, fx.files, "file.txt"));
    try std.testing.expect(exists(try fx.path("Trash/files/file.txt")));
    try std.testing.expect(try fx.infoExists("file.txt"));
}

test "entries without usable metadata are skipped and counted" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.put("good.txt", try fx.home_path("good.txt"), false, "g");
    // No .trashinfo at all, an unusable one, and one pointing into the trash.
    try ops_tests.writeTestFile(try fx.path("Trash/files/bare.txt"), "b");
    try ops_tests.writeTestFile(try fx.path("Trash/files/broken.txt"), "b");
    try ops_tests.writeTestFile(try fx.path("Trash/info/broken.txt.trashinfo"), "[Trash Info]\nPath=relative\n");
    try fx.put("inside.txt", try fx.path("Trash/files/elsewhere.txt"), false, "i");

    try std.testing.expectError(error.NoMetadata, trash.restoreEntry(allocator, fx.files, "bare.txt"));
    try std.testing.expectError(error.InvalidMetadata, trash.restoreEntry(allocator, fx.files, "broken.txt"));
    try std.testing.expectError(error.InvalidMetadata, trash.restoreEntry(allocator, fx.files, "inside.txt"));
    try std.testing.expect(trash.restorable(allocator, fx.files, "good.txt"));
    try std.testing.expect(!trash.restorable(allocator, fx.files, "bare.txt"));
    try std.testing.expect(!trash.restorable(allocator, fx.files, "broken.txt"));
    try std.testing.expect(!trash.restorable(allocator, fx.files, "inside.txt"));
    try std.testing.expect(!trash.restorable(allocator, fx.files, "missing.txt"));

    const summary = trash.restoreMany(allocator, fx.files, &.{ "good.txt", "bare.txt", "broken.txt", "inside.txt", "../escape" });
    try std.testing.expectEqual(@as(usize, 1), summary.restored);
    try std.testing.expectEqual(@as(usize, 0), summary.renamed);
    try std.testing.expectEqual(@as(usize, 3), summary.no_metadata);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    // Skipped entries stay exactly where they were.
    try std.testing.expect(exists(try fx.path("Trash/files/bare.txt")));
    try std.testing.expect(exists(try fx.path("Trash/files/broken.txt")));
    try std.testing.expect(exists(try fx.path("Trash/files/inside.txt")));
}

test "restoring a folder takes its directorysizes line and keeps the others" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const origin = try fx.home_path("Photos Old");
    try fx.put("Photos Old", origin, true, "inner");
    try fx.put("Other Dir", try fx.home_path("Other Dir"), true, "");
    try ops_tests.writeTestFile(try fx.path("Trash/directorysizes"), "10 100 Photos%20Old\n20 200 Other%20Dir\n");

    const restored = try trash.restoreEntry(allocator, fx.files, "Photos Old");
    defer restored.deinit(allocator);
    const inner = try fx.home_path("Photos Old/inner.txt");
    try expectContent(inner, "inner");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("20 200 Other%20Dir\n", try ops_tests.readTestFile(try fx.path("Trash/directorysizes"), &buf));
}

test "deleting removes the item, its metadata and its directorysizes line" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const keep = try fx.home_path("keep.txt");
    try ops_tests.writeTestFile(keep, "outside");
    try fx.put("dir", try fx.home_path("dir"), true, "inner");
    // A symlink inside the folder must not be followed.
    var buf: [4096]u8 = undefined;
    const link = try fx.path("Trash/files/dir/link");
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(try std.fmt.bufPrintSentinel(&buf, "{s}", .{keep}, 0), try fx.arena.allocator().dupeSentinel(u8, link, 0)));
    try fx.put("file.txt", try fx.home_path("file.txt"), false, "f");
    try ops_tests.writeTestFile(try fx.path("Trash/directorysizes"), "5 50 dir\n");

    try trash.deleteEntry(allocator, fx.files, "dir");
    try std.testing.expect(!exists(try fx.path("Trash/files/dir")));
    try std.testing.expect(!try fx.infoExists("dir"));
    try expectContent(keep, "outside");
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try ops_tests.readTestFile(try fx.path("Trash/directorysizes"), &out));
    // Other entries are untouched.
    try std.testing.expect(exists(try fx.path("Trash/files/file.txt")));
    try std.testing.expect(try fx.infoExists("file.txt"));
}

test "deleting handles orphans, bad names and batches" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const outside = try fx.home_path("outside.txt");
    try ops_tests.writeTestFile(outside, "safe");
    try fx.put("a.txt", try fx.home_path("a.txt"), false, "a");
    try fx.put("b.txt", try fx.home_path("b.txt"), false, "b");
    // Metadata whose item is already gone.
    try fx.info("ghost.txt", try fx.home_path("ghost.txt"));

    try std.testing.expectError(error.InvalidName, trash.deleteEntry(allocator, fx.files, "../home/outside.txt"));
    try std.testing.expectError(error.InvalidName, trash.deleteEntry(allocator, fx.files, ""));
    try std.testing.expectError(error.InvalidName, trash.deleteEntry(allocator, fx.files, ".."));
    try expectContent(outside, "safe");

    const removed = trash.deleteMany(allocator, fx.files, &.{ "a.txt", "ghost.txt", "b.txt", "../x" });
    try std.testing.expectEqual(@as(usize, 3), removed.deleted);
    try std.testing.expectEqual(@as(usize, 1), removed.failed);
    for ([_][]const u8{ "a.txt", "b.txt", "ghost.txt" }) |name| {
        try std.testing.expect(!try fx.infoExists(name));
    }
    try expectContent(outside, "safe");
}

test "sweeping removes only metadata with no item" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.put("live.txt", try fx.home_path("live.txt"), false, "l");
    try fx.info("stale.txt", try fx.home_path("stale.txt"));
    try fx.info("stale2", try fx.home_path("stale2"));
    try ops_tests.writeTestFile(try fx.path("Trash/info/readme.md"), "not metadata");

    trash.sweepOrphans(allocator, fx.files);
    try std.testing.expect(try fx.infoExists("live.txt"));
    try std.testing.expect(!try fx.infoExists("stale.txt"));
    try std.testing.expect(!try fx.infoExists("stale2"));
    try std.testing.expect(exists(try fx.path("Trash/info/readme.md")));
}

test "listing returns every top-level entry, hidden ones too" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.put("one", try fx.home_path("one"), false, "1");
    try fx.put(".hidden", try fx.home_path(".hidden"), false, "h");
    try fx.put("folder", try fx.home_path("folder"), true, "x");

    const names = try trash.listEntries(allocator, fx.files);
    defer allocator.free(names);
    defer trash.freeNames(allocator, names);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    for ([_][]const u8{ "one", ".hidden", "folder" }) |want| {
        var found = false;
        for (names) |name| found = found or std.mem.eql(u8, name, want);
        try std.testing.expect(found);
    }
}
