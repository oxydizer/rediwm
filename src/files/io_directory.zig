//! Exclusive destination-directory creation for the Files I/O executor.
//!
//! The input payload contains two NUL-terminated paths: source and
//! destination. A collision is reported as a waiting result so the Manager
//! can later hand it to the shared conflict coordinator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");

const collision_tag: u8 = 1;
const created_tag: u8 = 2;
const merged_tag: u8 = 3;
const created_result_name_offset: usize = 25;

fn allocZ(allocator: Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

fn syncDescriptor(fd: c_int) bool {
    while (true) {
        if (c.fsync(fd) == 0) return true;
        if (std.c._errno().* != c.EINTR) return false;
    }
}

const Paths = struct {
    source: [*:0]const u8,
    destination: []const u8,
    merge_existing_directory: bool,
};

/// Build immutable operation input.
pub fn makeInput(
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
    merge_existing_directory: bool,
) !executor.OwnedPayload {
    if (source_path.len == 0 or destination_path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, source_path, 0) != null or
        std.mem.indexOfScalar(u8, destination_path, 0) != null)
    {
        return error.InvalidPath;
    }
    if (destination_path[0] != '/') return error.InvalidPath;

    const bytes = try allocator.alloc(
        u8,
        source_path.len + 1 + destination_path.len + 2,
    );
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..source_path.len], source_path);
    bytes[source_path.len] = 0;
    const destination_start = source_path.len + 1;
    @memcpy(bytes[destination_start..][0..destination_path.len], destination_path);
    bytes[bytes.len - 2] = 0;
    bytes[bytes.len - 1] = @intFromBool(merge_existing_directory);
    return .{ .allocator = allocator, .bytes = bytes };
}

fn parsePaths(input: *const executor.OwnedPayload) !Paths {
    const bytes = input.slice();
    const separator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidInput;
    if (separator == 0 or bytes.len < separator + 4 or
        bytes[bytes.len - 2] != 0 or bytes[bytes.len - 1] > 1)
    {
        return error.InvalidInput;
    }
    const destination = bytes[separator + 1 .. bytes.len - 2];
    if (destination.len == 0 or destination[0] != '/' or
        std.mem.indexOfScalar(u8, destination, 0) != null)
    {
        return error.InvalidInput;
    }
    return .{
        .source = @ptrCast(bytes.ptr),
        .destination = destination,
        .merge_existing_directory = bytes[bytes.len - 1] == 1,
    };
}

fn splitDestination(
    allocator: Allocator,
    destination: []const u8,
) !struct { parent: [:0]u8, name: [:0]u8 } {
    const separator = std.mem.lastIndexOfScalar(u8, destination, '/') orelse
        return error.InvalidDestination;
    const name = destination[separator + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.InvalidDestination;
    }
    const parent = if (separator == 0) "/" else destination[0..separator];
    const parent_z = try allocZ(allocator, parent);
    errdefer allocator.free(parent_z);
    const name_z = try allocZ(allocator, name);
    return .{
        .parent = parent_z,
        .name = name_z,
    };
}

fn makeCollisionResult(allocator: Allocator) ?executor.OwnedPayload {
    const bytes = allocator.dupe(u8, &.{collision_tag}) catch return null;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn makePermissionResult(
    allocator: Allocator,
    parent_fd: c_int,
    name: [:0]const u8,
    device_id: u64,
    inode_id: u64,
    mode: u32,
    origin_tag: u8,
) ?executor.OwnedPayload {
    const bytes = allocator.alloc(
        u8,
        created_result_name_offset + name.len + 1,
    ) catch return null;
    bytes[0] = origin_tag;
    const raw_fd: u32 = @bitCast(parent_fd);
    for (0..4) |index| {
        bytes[1 + index] = @truncate(raw_fd >> @as(u5, @intCast(index * 8)));
    }
    for (0..8) |index| {
        bytes[5 + index] = @truncate(
            device_id >> @as(u6, @intCast(index * 8)),
        );
        bytes[13 + index] = @truncate(
            inode_id >> @as(u6, @intCast(index * 8)),
        );
    }
    for (0..4) |index| {
        bytes[21 + index] = @truncate(
            mode >> @as(u5, @intCast(index * 8)),
        );
    }
    @memcpy(
        bytes[created_result_name_offset .. created_result_name_offset + name.len],
        name,
    );
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn removeCreatedDirectory(result: *const executor.OwnedPayload) void {
    const bytes = result.slice();
    if (bytes.len < created_result_name_offset + 2 or
        (bytes[0] != created_tag and bytes[0] != merged_tag) or
        bytes[bytes.len - 1] != 0)
        return;

    var raw_fd: u32 = 0;
    for (0..4) |index| {
        raw_fd |= @as(u32, bytes[1 + index]) << @as(u5, @intCast(index * 8));
    }
    const parent_fd: c_int = @bitCast(raw_fd);
    if (parent_fd < 0) return;

    if (bytes[0] == created_tag) {
        const name: [*:0]const u8 =
            @ptrCast(bytes[created_result_name_offset..].ptr);
        _ = c.unlinkat(parent_fd, name, c.AT_REMOVEDIR);
    }
    _ = c.close(parent_fd);
}

pub const PermissionResult = struct {
    device_id: u64,
    inode_id: u64,
    mode: u32,
    origin: enum { created, merged },
};

pub fn permissionResult(result: *const executor.OwnedPayload) ?PermissionResult {
    const bytes = result.slice();
    if (bytes.len < created_result_name_offset + 2 or
        (bytes[0] != created_tag and bytes[0] != merged_tag) or
        bytes[bytes.len - 1] != 0)
        return null;

    var device_id: u64 = 0;
    var inode_id: u64 = 0;
    for (0..8) |index| {
        device_id |= @as(u64, bytes[5 + index]) << @as(u6, @intCast(index * 8));
        inode_id |= @as(u64, bytes[13 + index]) << @as(u6, @intCast(index * 8));
    }

    var mode: u32 = 0;
    for (0..4) |index| {
        mode |= @as(u32, bytes[21 + index]) << @as(u5, @intCast(index * 8));
    }

    return .{
        .device_id = device_id,
        .inode_id = inode_id,
        .mode = mode,
        .origin = if (bytes[0] == created_tag) .created else .merged,
    };
}

/// Execute one exclusive directory-creation operation.
///
/// Existing destinations produce `.waiting` unless the Manager has
/// authorized an explicit directory merge.
pub fn execute(
    allocator: Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var item = item_arg;
    const operation_paths = parsePaths(&item.input) catch {
        return completion(item, .failed, null);
    };

    const split = splitDestination(allocator, operation_paths.destination) catch {
        return completion(item, .failed, null);
    };
    defer allocator.free(split.parent);
    defer allocator.free(split.name);

    // Validate the source as a real directory without following a symlink.
    const source_fd = c.open(
        operation_paths.source,
        c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW,
    );
    if (source_fd < 0) return completion(item, .failed, null);
    var source_stat: c.struct_stat = undefined;
    if (c.fstat(source_fd, &source_stat) != 0 or
        (source_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
    {
        _ = c.close(source_fd);
        return completion(item, .failed, null);
    }
    const source_mode: u32 = @intCast(source_stat.st_mode & 0o777);
    _ = c.close(source_fd);

    // Anchor creation and stale-result cleanup to the opened parent.
    const parent_fd = c.open(
        split.parent,
        c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW,
    );
    if (parent_fd < 0) return completion(item, .failed, null);

    if (c.mkdirat(parent_fd, split.name, 0o755) != 0) {
        const failure_errno = std.c._errno().*;
        if (failure_errno == c.EEXIST) {
            if (operation_paths.merge_existing_directory) {
                // Merge is an explicit Manager authorization. Accept only a
                // real directory entry; O_NOFOLLOW rejects symlinks and
                // O_DIRECTORY rejects every other entry type.
                const existing_fd = c.openat(
                    parent_fd,
                    split.name,
                    c.O_PATH | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW,
                );
                if (existing_fd < 0) {
                    _ = c.close(parent_fd);
                    return completion(item, .failed, null);
                }
                var existing_stat: c.struct_stat = undefined;
                if (c.fstat(existing_fd, &existing_stat) != 0 or
                    (existing_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
                {
                    _ = c.close(existing_fd);
                    _ = c.close(parent_fd);
                    return completion(item, .failed, null);
                }
                const merged_mode = source_mode &
                    @as(u32, @intCast(existing_stat.st_mode & 0o777));
                _ = c.close(existing_fd);
                const result = makePermissionResult(
                    allocator,
                    parent_fd,
                    split.name,
                    @intCast(existing_stat.st_dev),
                    @intCast(existing_stat.st_ino),
                    merged_mode,
                    merged_tag,
                ) orelse {
                    _ = c.close(parent_fd);
                    return completion(item, .failed, null);
                };
                return completion(item, .completed, result);
            }
            _ = c.close(parent_fd);
            const result = makeCollisionResult(allocator) orelse
                return completion(item, .failed, null);
            return completion(item, .waiting, result);
        }
        _ = c.close(parent_fd);
        return completion(item, .failed, null);
    }

    var created_stat: c.struct_stat = undefined;
    if (c.fstatat(parent_fd, split.name, &created_stat, c.AT_SYMLINK_NOFOLLOW) != 0) {
        _ = c.unlinkat(parent_fd, split.name, c.AT_REMOVEDIR);
        _ = c.close(parent_fd);
        return completion(item, .failed, null);
    }

    const result = makePermissionResult(
        allocator,
        parent_fd,
        split.name,
        @intCast(created_stat.st_dev),
        @intCast(created_stat.st_ino),
        source_mode,
        created_tag,
    ) orelse {
        _ = c.unlinkat(parent_fd, split.name, c.AT_REMOVEDIR);
        _ = c.close(parent_fd);
        return completion(item, .failed, null);
    };
    if (!syncDescriptor(parent_fd)) {
        removeCreatedDirectory(&result);
        var owned_result = result;
        owned_result.deinit();
        return completion(item, .failed, null);
    }
    return completion(item, .completed, result);
}

fn completion(
    item_arg: executor.WorkItem,
    outcome: executor.WorkResult,
    result: ?executor.OwnedPayload,
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
        .result = result,
    };
}

/// Executor discard callback. A stale successful completion removes only
/// the directory this operation created, and only if it is still empty.
pub fn discard(
    _: ?*anyopaque,
    _: executor.OperationKind,
    input: executor.OwnedPayload,
    continuation: ?executor.OwnedPayload,
    result: ?executor.OwnedPayload,
) void {
    var owned_result = result;
    if (owned_result) |*payload| {
        removeCreatedDirectory(payload);
        payload.deinit();
    }
    var owned_continuation = continuation;
    if (owned_continuation) |*payload| payload.deinit();
    var owned_input = input;
    owned_input.deinit();
}

/// Accepted results retain their directory; release the parent descriptor.
pub fn complete(
    _: ?*anyopaque,
    _: executor.WorkToken,
    _: executor.WorkResult,
    result: ?executor.OwnedPayload,
) void {
    var owned_result = result;
    if (owned_result) |*payload| {
        const bytes = payload.slice();
        if (bytes.len >= created_result_name_offset + 2 and
            (bytes[0] == created_tag or bytes[0] == merged_tag))
        {
            var raw_fd: u32 = 0;
            for (0..4) |index| {
                raw_fd |= @as(u32, bytes[1 + index]) << @as(u5, @intCast(index * 8));
            }
            const parent_fd: c_int = @bitCast(raw_fd);
            if (parent_fd >= 0) _ = c.close(parent_fd);
        }
        payload.deinit();
    }
}
