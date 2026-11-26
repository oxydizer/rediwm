//! Removes a successfully transferred source entry for the Files I/O executor.
//!
//! The input payload contains an entry-kind tag, source identity and metadata
//! snapshot, followed by one NUL-terminated absolute source path. Directories
//! are removed non-recursively; regular files and symlinks are detached only
//! when their identity and content-relevant metadata still match the snapshot.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");
const io_tree = @import("io_tree.zig");

fn allocZ(allocator: Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

/// Build immutable operation input from an absolute source path.
pub fn makeInput(
    allocator: Allocator,
    source_path: []const u8,
    kind: io_tree.EntryKind,
    metadata: io_tree.Metadata,
) !executor.OwnedPayload {
    if (source_path.len == 0 or source_path[0] != '/')
        return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, source_path, 0) != null)
        return error.InvalidPath;

    const device_id = metadata.device_id orelse return error.MissingSourceIdentity;
    const inode_id = metadata.inode_id orelse return error.MissingSourceIdentity;
    const kind_tag: u8 = switch (kind) {
        .directory => 1,
        .regular_file => 2,
        .symlink => 3,
        .other => return error.UnsupportedEntryKind,
    };
    const bytes = try allocator.alloc(u8, source_path.len + 58);
    bytes[0] = kind_tag;
    std.mem.writeInt(u64, bytes[1..9], device_id, .little);
    std.mem.writeInt(u64, bytes[9..17], inode_id, .little);
    std.mem.writeInt(u64, bytes[17..25], metadata.size, .little);
    std.mem.writeInt(u64, bytes[25..33], @bitCast(metadata.mtime_sec), .little);
    std.mem.writeInt(u64, bytes[33..41], @bitCast(metadata.mtime_nsec), .little);
    std.mem.writeInt(u64, bytes[41..49], @bitCast(metadata.ctime_sec), .little);
    std.mem.writeInt(u64, bytes[49..57], @bitCast(metadata.ctime_nsec), .little);
    @memcpy(bytes[57 .. source_path.len + 57], source_path);
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

const ParsedInput = struct {
    path: []const u8,
    kind: io_tree.EntryKind,
    device_id: u64,
    inode_id: u64,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
    ctime_sec: i64,
    ctime_nsec: i64,
};

fn parseInput(input: *const executor.OwnedPayload) !ParsedInput {
    const bytes = input.slice();
    if (bytes.len < 59 or bytes[bytes.len - 1] != 0)
        return error.InvalidInput;
    const kind: io_tree.EntryKind = switch (bytes[0]) {
        1 => .directory,
        2 => .regular_file,
        3 => .symlink,
        else => return error.InvalidInput,
    };
    const path = bytes[57 .. bytes.len - 1];
    if (path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidInput;
    return .{
        .path = path,
        .kind = kind,
        .device_id = std.mem.readInt(u64, bytes[1..9], .little),
        .inode_id = std.mem.readInt(u64, bytes[9..17], .little),
        .size = std.mem.readInt(u64, bytes[17..25], .little),
        .mtime_sec = @bitCast(std.mem.readInt(u64, bytes[25..33], .little)),
        .mtime_nsec = @bitCast(std.mem.readInt(u64, bytes[33..41], .little)),
        .ctime_sec = @bitCast(std.mem.readInt(u64, bytes[41..49], .little)),
        .ctime_nsec = @bitCast(std.mem.readInt(u64, bytes[49..57], .little)),
    };
}

/// Remove one source entry without following its final path component.
pub fn execute(
    allocator: Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var item = item_arg;
    const parsed = parseInput(&item.input) catch {
        return completion(item, .failed);
    };
    const source_path = parsed.path;

    const separator = std.mem.lastIndexOfScalar(u8, source_path, '/') orelse
        return completion(item, .failed);
    const name = source_path[separator + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return completion(item, .failed);
    }

    const parent = if (separator == 0) "/" else source_path[0..separator];
    const parent_z = allocZ(allocator, parent) catch {
        return completion(item, .failed);
    };
    defer allocator.free(parent_z);

    const parent_fd = c.open(
        parent_z,
        c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW,
    );
    if (parent_fd < 0) return completion(item, .failed);
    defer _ = c.close(parent_fd);

    // The basename remains NUL-terminated in the owned input payload.
    const name_z: [*:0]const u8 = @ptrCast(name.ptr);
    var source_stat: c.struct_stat = undefined;
    if (c.fstatat(parent_fd, name_z, &source_stat, c.AT_SYMLINK_NOFOLLOW) != 0)
        return completion(item, .failed);

    const actual_kind: io_tree.EntryKind = switch (source_stat.st_mode & c.S_IFMT) {
        c.S_IFDIR => .directory,
        c.S_IFREG => .regular_file,
        c.S_IFLNK => .symlink,
        else => .other,
    };
    if (actual_kind != parsed.kind) return completion(item, .failed);
    if (@as(u64, @intCast(source_stat.st_dev)) != parsed.device_id or
        @as(u64, @intCast(source_stat.st_ino)) != parsed.inode_id)
    {
        return completion(item, .failed);
    }

    // Directory timestamps naturally change as children are detached. For
    // files and symlinks, reject in-place modifications since the source
    // snapshot was taken, even when the inode and size remain unchanged.
    if (parsed.kind != .directory and
        (@as(u64, @intCast(@max(source_stat.st_size, 0))) != parsed.size or
            @as(i64, @intCast(source_stat.st_mtim.tv_sec)) != parsed.mtime_sec or
            @as(i64, @intCast(source_stat.st_mtim.tv_nsec)) != parsed.mtime_nsec or
            @as(i64, @intCast(source_stat.st_ctim.tv_sec)) != parsed.ctime_sec or
            @as(i64, @intCast(source_stat.st_ctim.tv_nsec)) != parsed.ctime_nsec))
    {
        return completion(item, .failed);
    }

    const flags: c_int = if (parsed.kind == .directory) c.AT_REMOVEDIR else 0;
    if (c.unlinkat(parent_fd, name_z, flags) != 0)
        return completion(item, .failed);

    return completion(item, .completed);
}

fn completion(
    item_arg: executor.WorkItem,
    outcome: executor.WorkResult,
) executor.WorkCompletion {
    var item = item_arg;
    if (item.continuation) |*saved| {
        saved.deinit();
        item.continuation = null;
    }
    return .{
        .token = item.token,
        .outcome = outcome,
        .operation_kind = item.operation_kind,
        .input = item.input,
    };
}

pub fn discard(
    _: ?*anyopaque,
    _: executor.OperationKind,
    input: executor.OwnedPayload,
    continuation: ?executor.OwnedPayload,
    result: ?executor.OwnedPayload,
) void {
    var owned_input = input;
    owned_input.deinit();
    var owned_continuation = continuation;
    if (owned_continuation) |*payload| payload.deinit();
    if (result) |payload| {
        var owned_result = payload;
        owned_result.deinit();
    }
}

pub fn complete(
    _: ?*anyopaque,
    _: executor.WorkToken,
    _: executor.WorkResult,
    result: ?executor.OwnedPayload,
) void {
    if (result) |payload| {
        var owned_result = payload;
        owned_result.deinit();
    }
}
