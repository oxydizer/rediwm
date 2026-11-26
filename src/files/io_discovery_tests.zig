const std = @import("std");
const c = @import("c.zig").api;
const discovery = @import("io_discovery.zig");

fn makeTempDir(buffer: []u8) ![:0]const u8 {
    const template = "/tmp/rediwm_io_discovery_XXXXXX\x00";
    @memcpy(buffer[0..template.len], template);
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(result);
}

fn join(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![:0]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
    defer allocator.free(raw);
    return try allocator.dupeSentinel(u8, raw, 0);
}

fn createFile(path: [:0]const u8) !void {
    const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.FileCreateFailed;
    _ = c.close(fd);
}

fn cleanup(allocator: std.mem.Allocator, root: [:0]const u8) void {
    const names = [_][]const u8{ "file", "folder-link", "link" };
    for (names) |name| {
        const path = join(allocator, root, name) catch continue;
        defer allocator.free(path);
        _ = c.unlink(path);
    }
    const folder = join(allocator, root, "nested") catch return;
    defer allocator.free(folder);
    _ = c.rmdir(folder);
    _ = c.rmdir(root);
}

test "directory cursor yields bounded batches and resumes at the next entry" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root = try makeTempDir(&temp_buffer);
    defer cleanup(allocator, root);

    const file = try join(allocator, root, "file");
    defer allocator.free(file);
    const nested = try join(allocator, root, "nested");
    defer allocator.free(nested);
    try createFile(file);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested, 0o700));

    var cursor = try discovery.Cursor.open(root);
    defer cursor.deinit();

    var first = try cursor.nextBatch(allocator, 1);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.records.items.len);
    try std.testing.expect(!first.complete);

    var second = try cursor.nextBatch(allocator, 1);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.records.items.len);
    try std.testing.expect(!second.complete);
    try std.testing.expect(!std.mem.eql(u8, first.records.items[0].name, second.records.items[0].name));

    var end = try cursor.nextBatch(allocator, 4);
    defer end.deinit();
    try std.testing.expect(end.complete);
    try std.testing.expectEqual(@as(usize, 0), end.records.items.len);
}

test "discovery records literal symlink targets without following directory links" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root = try makeTempDir(&temp_buffer);
    defer cleanup(allocator, root);

    const nested = try join(allocator, root, "nested");
    defer allocator.free(nested);
    const link = try join(allocator, root, "link");
    defer allocator.free(link);
    const folder_link = try join(allocator, root, "folder-link");
    defer allocator.free(folder_link);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("../literal-target", link));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("nested", folder_link));

    var cursor = try discovery.Cursor.open(root);
    defer cursor.deinit();
    var batch = try cursor.nextBatch(allocator, 8);
    defer batch.deinit();
    try std.testing.expect(batch.complete);
    try std.testing.expectEqual(@as(usize, 3), batch.records.items.len);

    var saw_literal_link = false;
    var saw_folder_link = false;
    for (batch.records.items) |record| {
        if (std.mem.eql(u8, record.name, "link")) {
            saw_literal_link = true;
            try std.testing.expectEqual(.symlink, record.kind);
            try std.testing.expectEqualStrings("../literal-target", record.symlink_target.?);
            try std.testing.expect(!record.entry_error);
        } else if (std.mem.eql(u8, record.name, "folder-link")) {
            saw_folder_link = true;
            try std.testing.expectEqual(.symlink, record.kind);
            try std.testing.expectEqualStrings("nested", record.symlink_target.?);
        }
    }
    try std.testing.expect(saw_literal_link);
    try std.testing.expect(saw_folder_link);
}

test "discovery records the filesystem device for each entry" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root = try makeTempDir(&temp_buffer);
    defer cleanup(allocator, root);

    const file = try join(allocator, root, "file");
    defer allocator.free(file);
    try createFile(file);

    var root_stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.stat(root, &root_stat));

    var cursor = try discovery.Cursor.open(root);
    defer cursor.deinit();
    var batch = try cursor.nextBatch(allocator, 4);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 1), batch.records.items.len);
    try std.testing.expectEqual(
        @as(?u64, @intCast(root_stat.st_dev)),
        batch.records.items[0].metadata.device_id,
    );
}

test "child cursor refuses a symlink in place of a directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root = try makeTempDir(&temp_buffer);
    defer cleanup(allocator, root);

    const nested = try join(allocator, root, "nested");
    defer allocator.free(nested);
    const link = try join(allocator, root, "link");
    defer allocator.free(link);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("nested", link));

    var parent = try discovery.Cursor.open(root);
    defer parent.deinit();
    try std.testing.expectError(error.DirectoryOpenFailed, discovery.Cursor.openAt(parent.fd, "link"));
    var child = try discovery.Cursor.openAt(parent.fd, "nested");
    defer child.deinit();
    var batch = try child.nextBatch(allocator, 1);
    defer batch.deinit();
    try std.testing.expect(batch.complete);
    try std.testing.expectEqual(@as(usize, 0), batch.records.items.len);
}

test "persistent anchor opens root and nested cursors independently" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root = try makeTempDir(&temp_buffer);
    defer cleanup(allocator, root);

    const nested = try join(allocator, root, "nested");
    defer allocator.free(nested);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested, 0o700));

    var index = @import("io_tree.zig").TreeIndex.init(allocator);
    defer index.deinit();
    const root_id = try index.addRoot("source", .directory, .{}, null);
    const nested_id = try index.addEntry(root_id, "nested", .directory, .{}, null);

    var anchor = try discovery.Anchor.open(root);
    defer anchor.deinit();

    {
        var root_cursor = try anchor.openCursorForEntry(allocator, &index, root_id);
        defer root_cursor.deinit();
        var batch = try root_cursor.nextBatch(allocator, 1);
        defer batch.deinit();
        try std.testing.expectEqual(@as(usize, 1), batch.records.items.len);
        try std.testing.expectEqualStrings("nested", batch.records.items[0].name);
    }

    // The root cursor is closed; the Anchor still opens a separate child
    // cursor using the stored EntryId ancestry.
    var nested_cursor = try anchor.openCursorForEntry(allocator, &index, nested_id);
    defer nested_cursor.deinit();
    var nested_batch = try nested_cursor.nextBatch(allocator, 1);
    defer nested_batch.deinit();
    try std.testing.expect(nested_batch.complete);
    try std.testing.expectEqual(@as(usize, 0), nested_batch.records.items.len);
}

test "anchor refuses a discovered directory replaced by a symlink" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root = try makeTempDir(&temp_buffer);
    defer cleanup(allocator, root);

    const swapped = try join(allocator, root, "swapped");
    defer allocator.free(swapped);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(swapped, 0o700));

    var index = @import("io_tree.zig").TreeIndex.init(allocator);
    defer index.deinit();
    const root_id = try index.addRoot("source", .directory, .{}, null);
    const swapped_id = try index.addEntry(root_id, "swapped", .directory, .{}, null);

    var anchor = try discovery.Anchor.open(root);
    defer anchor.deinit();

    try std.testing.expectEqual(@as(c_int, 0), c.rmdir(swapped));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(".", swapped));
    defer _ = c.unlink(swapped);

    try std.testing.expectError(
        error.DirectoryOpenFailed,
        anchor.openCursorForEntry(allocator, &index, swapped_id),
    );
}
