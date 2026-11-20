//! Removes an emptied source directory for the Files I/O executor.
//!
//! The input payload contains one NUL-terminated absolute source path.
//! Removal is non-recursive: unlinkat with AT_REMOVEDIR succeeds only
//! when the directory is empty.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");

fn allocZ(allocator: Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

/// Build immutable operation input from an absolute source path.
pub fn makeInput(
    allocator: Allocator,
    source_path: []const u8,
) !executor.OwnedPayload {
    if (source_path.len == 0 or source_path[0] != '/')
        return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, source_path, 0) != null)
        return error.InvalidPath;

    const bytes = try allocator.alloc(u8, source_path.len + 1);
    @memcpy(bytes[0..source_path.len], source_path);
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn parsePath(input: *const executor.OwnedPayload) ![]const u8 {
    const bytes = input.slice();
    if (bytes.len < 2 or bytes[bytes.len - 1] != 0)
        return error.InvalidInput;
    const path = bytes[0 .. bytes.len - 1];
    if (path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidInput;
    return path;
}

/// Remove one source directory without following its final path component.
pub fn execute(
    allocator: Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var item = item_arg;
    const source_path = parsePath(&item.input) catch {
        return completion(item, .failed);
    };

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
    if (c.unlinkat(parent_fd, name_z, c.AT_REMOVEDIR) != 0)
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
