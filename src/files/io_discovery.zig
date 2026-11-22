//! Resumable, bounded directory discovery for Files I/O jobs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const tree = @import("io_tree.zig");

pub const Record = struct {
    name: []u8,
    kind: tree.EntryKind,
    metadata: tree.Metadata = .{},
    symlink_target: ?[]u8 = null,
    entry_error: bool = false,

    fn deinit(self: *Record, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.symlink_target) |target| allocator.free(target);
    }
};

pub const Batch = struct {
    allocator: Allocator,
    records: std.ArrayList(Record) = .empty,
    complete: bool = false,

    pub fn deinit(self: *Batch) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Persistent FD-relative anchor for one discovered source tree.
///
/// The Anchor outlives individual directory cursors. It lets discovery open
/// later BFS entries without retaining a descriptor for every queued folder
/// or reconstructing an absolute path.
pub const Anchor = struct {
    fd: c_int,

    /// Opens the root without following a symlink in its final component.
    pub fn open(path: [:0]const u8) !Anchor {
        const fd = c.open(
            path,
            c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC,
        );
        if (fd < 0) return error.DirectoryOpenFailed;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Anchor) void {
        _ = c.close(self.fd);
        self.* = undefined;
    }

    /// Opens a fresh cursor for an entry by resolving its TreeIndex ancestry
    /// from the persistent root FD. Every component is opened with O_NOFOLLOW.
    pub fn openCursorForEntry(
        self: *const Anchor,
        allocator: Allocator,
        index: *const tree.TreeIndex,
        entry_id: tree.EntryId,
    ) !Cursor {
        var components: std.ArrayList([]const u8) = .empty;
        defer components.deinit(allocator);

        var current_id = entry_id;
        while (true) {
            const entry = index.getConst(current_id) orelse
                return error.UnknownEntry;
            if (entry.kind != .directory) return error.EntryNotDirectory;

            if (entry.parent_id) |parent_id| {
                try components.append(allocator, entry.name);
                current_id = parent_id;
            } else {
                if (!index.isRoot(current_id))
                    return error.EntryOutsideRoot;
                break;
            }
        }

        const flags = c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC;
        var current_fd = c.openat(self.fd, ".", flags);
        if (current_fd < 0) return error.DirectoryOpenFailed;

        var owns_fd = true;
        errdefer if (owns_fd) {
            _ = c.close(current_fd);
        };

        var remaining = components.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const name = try allocator.dupeSentinel(
                u8,
                components.items[remaining],
                0,
            );
            defer allocator.free(name);

            const next_fd = c.openat(current_fd, name, flags);
            if (next_fd < 0) return error.DirectoryOpenFailed;

            _ = c.close(current_fd);
            current_fd = next_fd;
        }

        const cursor = try Cursor.fromOwnedFd(current_fd);
        owns_fd = false;
        return cursor;
    }
};

pub const Cursor = struct {
    dir: *c.DIR,
    fd: c_int,
    complete: bool = false,

    /// Opens the root without following a symlink in its final component.
    pub fn open(path: [:0]const u8) !Cursor {
        const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.DirectoryOpenFailed;
        return fromOwnedFd(fd);
    }

    /// Opens a discovered child relative to its already-open parent.
    pub fn openAt(parent_fd: c_int, name: [:0]const u8) !Cursor {
        const fd = c.openat(
            parent_fd,
            name,
            c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC,
        );
        if (fd < 0) return error.DirectoryOpenFailed;
        return fromOwnedFd(fd);
    }

    fn fromOwnedFd(fd: c_int) !Cursor {
        const dir = c.fdopendir(fd) orelse {
            _ = c.close(fd);
            return error.DirectoryOpenFailed;
        };
        return .{ .dir = dir, .fd = fd };
    }

    pub fn deinit(self: *Cursor) void {
        _ = c.closedir(self.dir);
        self.* = undefined;
    }

    /// Reads no more than max_entries non-dot entries. The next call resumes
    /// from the same directory stream position.
    pub fn nextBatch(self: *Cursor, allocator: Allocator, max_entries: usize) !Batch {
        if (max_entries == 0) return error.InvalidBatchSize;
        var batch: Batch = .{ .allocator = allocator, .complete = self.complete };
        errdefer batch.deinit();
        if (self.complete) return batch;

        while (batch.records.items.len < max_entries) {
            std.c._errno().* = 0;
            const entry = c.readdir(self.dir) orelse {
                if (std.c._errno().* != 0) return error.DirectoryReadFailed;
                self.complete = true;
                batch.complete = true;
                break;
            };
            const name_z: [*:0]const u8 = @ptrCast(&entry.*.d_name);
            const name = std.mem.span(name_z);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            try batch.records.ensureUnusedCapacity(allocator, 1);
            batch.records.appendAssumeCapacity(try inspectEntry(allocator, self.fd, name_z));
        }
        return batch;
    }
};

fn inspectEntry(allocator: Allocator, dir_fd: c_int, name_z: [*:0]const u8) !Record {
    var record: Record = .{
        .name = try allocator.dupe(u8, std.mem.span(name_z)),
        .kind = .other,
    };
    errdefer record.deinit(allocator);

    var stat: c.struct_stat = undefined;
    if (c.fstatat(dir_fd, name_z, &stat, c.AT_SYMLINK_NOFOLLOW) != 0) {
        record.entry_error = true;
        return record;
    }

    record.metadata = .{
        .size = @intCast(@max(stat.st_size, 0)),
        .mode = @intCast(stat.st_mode),
        .device_id = @intCast(stat.st_dev),
        .inode_id = @intCast(stat.st_ino),
        .mtime_sec = @intCast(stat.st_mtim.tv_sec),
        .mtime_nsec = @intCast(stat.st_mtim.tv_nsec),
        .ctime_sec = @intCast(stat.st_ctim.tv_sec),
        .ctime_nsec = @intCast(stat.st_ctim.tv_nsec),
    };
    const file_type = stat.st_mode & c.S_IFMT;
    if (file_type == c.S_IFDIR) {
        record.kind = .directory;
    } else if (file_type == c.S_IFREG) {
        record.kind = .regular_file;
    } else if (file_type == c.S_IFLNK) {
        record.kind = .symlink;
        // Linux symlink targets are at most 4095 bytes. A full buffer means
        // the result may be truncated, so do not store it as a valid target.
        var target: [4096]u8 = undefined;
        const count = c.readlinkat(dir_fd, name_z, &target, target.len);
        if (count < 0) {
            record.entry_error = true;
        } else {
            const target_len: usize = @intCast(count);
            if (target_len == target.len) {
                record.entry_error = true;
            } else {
                record.symlink_target = try allocator.dupe(u8, target[0..target_len]);
            }
        }
    }
    return record;
}
