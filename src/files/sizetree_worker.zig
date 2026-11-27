//! Folder-size workers and their single-directory reads.
const std = @import("std");
const dirwalk = @import("platform").dirwalk;
const c = @import("c.zig").api;
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Key = tree.Key;
const Allocator = std.mem.Allocator;

pub fn workerLoop(self: *Service) void {
    var path_buf: [4096]u8 = undefined;
    const dir_buf = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(dirwalk.buffer_align), 65536) catch return;
    defer std.heap.page_allocator.free(dir_buf);
    var found: std.ArrayList(Service.Child) = .empty;
    defer found.deinit(self.allocator);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(self.allocator);

    self.lock();
    while (true) {
        const job = self.take(&path_buf) orelse break;
        self.working += 1;
        var retry = false;
        switch (job.work) {
            .resolve => |resolution| {
                self.unlock();
                retry = self.resolvePath(resolution);
                resolution.deinit(self.allocator);
                self.lock();
            },
            .scan => |s| {
                // The path is in this worker's `path_buf`: read it unlocked.
                self.unlock();
                found.clearRetainingCapacity();
                names.clearRetainingCapacity();
                const result = readDirectory(self.allocator, job.path.?, s.key, dir_buf, &found, &names);
                self.lock();
                if (self.liveId(s.ref)) |id| {
                    if (result) |read| {
                        if (!read.opened) {
                            if (read.missing) self.lostScan(id, job.path.?) else self.failScan(id);
                        } else {
                            self.finishScan(id, read.own, found.items, read.unreadable) catch {
                                self.retryScan(id);
                                retry = true;
                            };
                        }
                    } else |_| {
                        self.retryScan(id);
                        retry = true;
                    }
                }
            },
        }
        self.working -= 1;
        if (self.working == 0) self.bump();
        if (retry) {
            // Keep the work queued, but avoid spinning under sustained OOM.
            self.unlock();
            const delay: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 10_000_000 };
            _ = c.nanosleep(&delay, null);
            self.lock();
        }
    }
    self.unlock();
}

const ReadResult = struct { own: i64 = 0, unreadable: bool = false, opened: bool = true, missing: bool = false };

/// Reads one directory: the apparent size of everything in it that is not a
/// directory, and the directories on the same filesystem (mount points are
/// not followed, nor are links).
fn readDirectory(
    a: Allocator,
    path: [:0]const u8,
    expected: Key,
    buf: []align(dirwalk.buffer_align) u8,
    found: *std.ArrayList(Service.Child),
    names: *std.ArrayList(u8),
) !ReadResult {
    var result: ReadResult = .{};
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) {
        const err = std.c._errno().*;
        return .{ .unreadable = true, .opened = false, .missing = err == c.ENOENT or err == c.ENOTDIR or err == c.ELOOP };
    }
    defer _ = c.close(fd);
    const identity = dirwalk.statFd(fd) orelse return .{ .unreadable = true, .opened = false };
    if (identity.kind != .directory or identity.dev != expected.dev or identity.ino != expected.ino)
        return .{ .opened = false, .missing = true };
    var reader = dirwalk.Reader.init(fd, buf) catch return .{ .unreadable = true, .opened = false };
    defer reader.deinit();
    while (true) {
        const name_ptr = (reader.next() catch {
            result.unreadable = true;
            break;
        }) orelse break;
        const entry = dirwalk.statAt(fd, name_ptr) orelse {
            result.unreadable = true;
            continue;
        };
        if (entry.kind == .directory) {
            if (entry.mount_root or entry.dev != expected.dev) continue;
            const name = std.mem.span(name_ptr);
            // Store lengths until the buffer has finished growing.
            try names.appendSlice(a, name);
            try found.append(a, .{ .key = .{ .dev = entry.dev, .ino = entry.ino }, .name = names.items[names.items.len - name.len ..] });
        } else if (entry.kind == .regular) {
            result.own += @intCast(entry.size);
        }
    }
    // Earlier slices may point at the old allocation. Rebuild them from
    // their lengths after the final append.
    var offset: usize = 0;
    for (found.items) |*child| {
        const end = offset + child.name.len;
        child.name = names.items[offset..end];
        offset = end;
    }
    return result;
}

test "sizetree rejects a directory path replaced with another inode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const original_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/root",
        .{base},
        0,
    );
    defer std.testing.allocator.free(original_path);
    const old_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/root_old",
        .{base},
        0,
    );
    defer std.testing.allocator.free(old_path);
    const setup = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "mkdir {s} && printf old > {s}/file",
        .{ original_path, original_path },
        0,
    );
    defer std.testing.allocator.free(setup);
    try std.testing.expectEqual(@as(c_int, 0), c.system(setup));

    const fd = c.open(original_path, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.TestSetupFailed;
    const original = dirwalk.statFd(fd) orelse {
        _ = c.close(fd);
        return error.TestSetupFailed;
    };
    _ = c.close(fd);

    try std.testing.expectEqual(@as(c_int, 0), c.rename(original_path, old_path));
    const replacement = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "mkdir {s} && printf replacement > {s}/file",
        .{ original_path, original_path },
        0,
    );
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqual(@as(c_int, 0), c.system(replacement));

    var found: std.ArrayList(Service.Child) = .empty;
    defer found.deinit(std.testing.allocator);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(std.testing.allocator);
    const buf = try std.heap.page_allocator.alignedAlloc(
        u8,
        .fromByteUnits(dirwalk.buffer_align),
        65536,
    );
    defer std.heap.page_allocator.free(buf);

    const result = try readDirectory(
        std.testing.allocator,
        original_path,
        .{ .dev = original.dev, .ino = original.ino },
        buf,
        &found,
        &names,
    );
    try std.testing.expect(!result.opened);
    try std.testing.expect(result.missing);
    try std.testing.expectEqual(@as(usize, 0), found.items.len);
}

test "sizetree discards a directory read when child collection runs out of memory" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const path = try a.dupeSentinel(u8, base, 0);
    defer a.free(path);
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.TestSetupFailed;
    defer _ = c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(fd, "child", 0o700));
    const identity = dirwalk.statFd(fd) orelse return error.TestSetupFailed;
    const expected: Key = .{ .dev = identity.dev, .ino = identity.ino };
    var buf: [4096]u8 align(dirwalk.buffer_align) = undefined;

    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var found: std.ArrayList(Service.Child) = .empty;
        defer found.deinit(allocator);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(allocator);
        const read = readDirectory(allocator, path, expected, &buf, &found, &names);
        if (fail_index < 2) {
            try std.testing.expectError(error.OutOfMemory, read);
        } else {
            const result = try read;
            try std.testing.expect(result.opened and !result.unreadable);
            try std.testing.expectEqual(@as(usize, 1), found.items.len);
            try std.testing.expectEqualStrings("child", found.items[0].name);
        }
    }
}
