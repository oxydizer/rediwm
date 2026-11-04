const std = @import("std");
const c = @import("c.zig").api;
const totals = @import("trash_totals.zig");
const collect = totals.collect;

test "Trash totals include nested payloads without following symlinks" {
    var template = "/tmp/rediwm-trash-totals-XXXXXX".* ++ [_]u8{0};
    const root = c.mkdtemp(&template) orelse return error.TempFailed;
    defer _ = c.rmdir(root);
    const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    const stop: std.atomic.Value(bool) = .init(false);
    const empty = collect(std.mem.span(root), &stop);
    try std.testing.expectEqual(@as(u64, 0), empty.items);
    try std.testing.expectEqual(@as(i64, 0), empty.bytes);
    try std.testing.expect(!empty.partial);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(fd, "folder", 0o700));
    defer _ = c.unlinkat(fd, "folder", c.AT_REMOVEDIR);
    const file = c.openat(fd, "folder/data", c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try std.testing.expect(file >= 0);
    defer _ = c.unlinkat(fd, "folder/data", 0);
    try std.testing.expectEqual(@as(isize, 7), c.write(file, "payload", 7));
    _ = c.close(file);
    // A loop would recurse forever if links were followed.
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat(".", fd, "loop"));
    defer _ = c.unlinkat(fd, "loop", 0);
    const summary = collect(std.mem.span(root), &stop);
    try std.testing.expectEqual(@as(u64, 2), summary.items);
    try std.testing.expectEqual(@as(i64, 8), summary.bytes);
    try std.testing.expect(!summary.partial);
    const cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expect(collect(std.mem.span(root), &cancelled).partial);
}

test "a counting task hands over its totals and wakes the host once" {
    var template = "/tmp/rediwm-trash-task-XXXXXX".* ++ [_]u8{0};
    const root = c.mkdtemp(&template) orelse return error.TempFailed;
    defer _ = c.rmdir(root);
    const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    const file = c.openat(fd, "gone.txt", c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try std.testing.expect(file >= 0);
    defer _ = c.unlinkat(fd, "gone.txt", 0);
    try std.testing.expectEqual(@as(isize, 5), c.write(file, "hello", 5));
    _ = c.close(file);

    const wake = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    try std.testing.expect(wake >= 0);
    defer _ = c.close(wake);
    const task = try totals.Task.start(std.mem.span(root), wake);
    defer task.destroy();
    var poll_fd = c.struct_pollfd{ .fd = wake, .events = c.POLLIN, .revents = 0 };
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&poll_fd, 1, 5000));
    const summary = task.poll().?;
    try std.testing.expectEqual(@as(u64, 1), summary.items);
    try std.testing.expectEqual(@as(i64, 5), summary.bytes);
    try std.testing.expect(!summary.partial);
}

test "destroying a task right away is safe" {
    const task = try totals.Task.start("/nonexistent-rediwm-trash", -1);
    task.destroy();
}
