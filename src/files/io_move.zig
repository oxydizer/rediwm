//! Same-filesystem move operations for regular files and symlinks.
//!
//! The input payload contains a NUL-terminated source path followed by a
//! NUL-terminated destination path. The rename never replaces an existing
//! destination.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");
const platform_fs = @import("platform").fs;

const collision_tag: u8 = 1;
const cross_device_tag: u8 = 3;

fn allocZ(allocator: Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

const Paths = struct {
    source: [*:0]const u8,
    destination: [*:0]const u8,
};

/// Build immutable operation input from absolute paths.
pub fn makeInput(
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) !executor.OwnedPayload {
    if (source_path.len == 0 or destination_path.len == 0)
        return error.InvalidPath;
    if (source_path[0] != '/' or destination_path[0] != '/')
        return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, source_path, 0) != null or
        std.mem.indexOfScalar(u8, destination_path, 0) != null)
    {
        return error.InvalidPath;
    }

    const bytes = try allocator.alloc(
        u8,
        source_path.len + 1 + destination_path.len + 1,
    );
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..source_path.len], source_path);
    bytes[source_path.len] = 0;
    const destination_start = source_path.len + 1;
    @memcpy(bytes[destination_start..][0..destination_path.len], destination_path);
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn parsePaths(input: *const executor.OwnedPayload) !Paths {
    const bytes = input.slice();
    const separator = std.mem.indexOfScalar(u8, bytes, 0) orelse
        return error.InvalidInput;
    if (separator == 0 or bytes.len <= separator + 2 or
        bytes[bytes.len - 1] != 0)
    {
        return error.InvalidInput;
    }

    const destination = bytes[separator + 1 .. bytes.len - 1];
    if (destination.len == 0 or destination[0] != '/' or
        std.mem.indexOfScalar(u8, destination, 0) != null)
    {
        return error.InvalidInput;
    }

    return .{
        .source = @ptrCast(bytes.ptr),
        .destination = @ptrCast(bytes[separator + 1 ..].ptr),
    };
}

fn makeCollisionResult(allocator: Allocator) ?executor.OwnedPayload {
    const bytes = allocator.dupe(u8, &.{collision_tag}) catch return null;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn makeCrossDeviceResult(allocator: Allocator) ?executor.OwnedPayload {
    const bytes = allocator.dupe(u8, &.{cross_device_tag}) catch return null;
    return .{ .allocator = allocator, .bytes = bytes };
}

/// Rename one regular file or symlink without replacing an existing entry.
/// Cross-device moves are handed back to the Manager for copy-and-detach.
pub fn execute(
    allocator: Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var item = item_arg;
    const paths = parsePaths(&item.input) catch {
        return completion(item, .failed, null);
    };

    var source_stat: c.struct_stat = undefined;
    if (c.lstat(paths.source, &source_stat) != 0) {
        return completion(item, .failed, null);
    }

    const source_mode = source_stat.st_mode & c.S_IFMT;
    if (source_mode != c.S_IFREG and source_mode != c.S_IFLNK) {
        return completion(item, .failed, null);
    }

    platform_fs.renameNoReplace(paths.source, paths.destination) catch |err| {
        if (err == error.PathAlreadyExists) {
            const result = makeCollisionResult(allocator) orelse
                return completion(item, .failed, null);
            return completion(item, .waiting, result);
        }
        if (err == error.CrossDevice) {
            const result = makeCrossDeviceResult(allocator) orelse
                return completion(item, .failed, null);
            return completion(item, .waiting, result);
        }
        return completion(item, .failed, null);
    };

    return completion(item, .completed, null);
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
    var owned_result = result;
    if (owned_result) |*payload| payload.deinit();
}

pub fn complete(
    _: ?*anyopaque,
    _: executor.WorkToken,
    _: executor.WorkResult,
    result: ?executor.OwnedPayload,
) void {
    var owned_result = result;
    if (owned_result) |*payload| payload.deinit();
}
