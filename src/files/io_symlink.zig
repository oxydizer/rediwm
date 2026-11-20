//! Literal symlink creation for the Files I/O executor.
//!
//! The input payload contains a NUL-terminated target followed by a
//! NUL-terminated absolute destination path. The target is never resolved.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");

const collision_tag: u8 = 1;
const created_tag: u8 = 2;

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
    target: [*:0]const u8,
    destination: []const u8,
};

/// Build immutable operation input. Targets remain literal byte strings.
pub fn makeInput(
    allocator: Allocator,
    target: []const u8,
    destination_path: []const u8,
) !executor.OwnedPayload {
    if (target.len == 0 or destination_path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, target, 0) != null or
        std.mem.indexOfScalar(u8, destination_path, 0) != null)
    {
        return error.InvalidPath;
    }
    if (destination_path[0] != '/') return error.InvalidPath;

    const bytes = try allocator.alloc(
        u8,
        target.len + 1 + destination_path.len + 1,
    );
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..target.len], target);
    bytes[target.len] = 0;
    const destination_start = target.len + 1;
    @memcpy(bytes[destination_start..][0..destination_path.len], destination_path);
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn parsePaths(input: *const executor.OwnedPayload) !Paths {
    const bytes = input.slice();
    const separator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidInput;
    if (separator == 0 or bytes.len <= separator + 2 or bytes[bytes.len - 1] != 0) {
        return error.InvalidInput;
    }
    const destination = bytes[separator + 1 .. bytes.len - 1];
    if (destination.len == 0 or destination[0] != '/' or
        std.mem.indexOfScalar(u8, destination, 0) != null)
    {
        return error.InvalidInput;
    }
    return .{
        .target = @ptrCast(bytes.ptr),
        .destination = destination,
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
    return .{ .parent = parent_z, .name = name_z };
}

fn makeCollisionResult(allocator: Allocator) ?executor.OwnedPayload {
    const bytes = allocator.dupe(u8, &.{collision_tag}) catch return null;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn makeCreatedResult(
    allocator: Allocator,
    parent_fd: c_int,
    name: [:0]const u8,
) ?executor.OwnedPayload {
    const bytes = allocator.alloc(u8, 5 + name.len + 1) catch return null;
    bytes[0] = created_tag;
    const raw_fd: u32 = @bitCast(parent_fd);
    for (0..4) |index| {
        bytes[1 + index] = @truncate(raw_fd >> @as(u5, @intCast(index * 8)));
    }
    @memcpy(bytes[5 .. 5 + name.len], name);
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn closeCreatedParent(result: *const executor.OwnedPayload, remove_link: bool) void {
    const bytes = result.slice();
    if (bytes.len < 7 or bytes[0] != created_tag or bytes[bytes.len - 1] != 0) return;

    var raw_fd: u32 = 0;
    for (0..4) |index| {
        raw_fd |= @as(u32, bytes[1 + index]) << @as(u5, @intCast(index * 8));
    }
    const parent_fd: c_int = @bitCast(raw_fd);
    if (parent_fd < 0) return;

    if (remove_link) {
        const name: [*:0]const u8 = @ptrCast(bytes[5..].ptr);
        _ = c.unlinkat(parent_fd, name, 0);
    }
    _ = c.close(parent_fd);
}

/// Create one literal symlink without resolving or following its target.
/// An existing destination produces `.waiting` for Manager conflict handling.
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

    const parent_fd = c.open(
        split.parent,
        c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW,
    );
    if (parent_fd < 0) return completion(item, .failed, null);

    if (c.symlinkat(operation_paths.target, parent_fd, split.name) != 0) {
        const failure_errno = std.c._errno().*;
        _ = c.close(parent_fd);
        if (failure_errno == c.EEXIST) {
            const result = makeCollisionResult(allocator) orelse
                return completion(item, .failed, null);
            return completion(item, .waiting, result);
        }
        return completion(item, .failed, null);
    }

    const result = makeCreatedResult(allocator, parent_fd, split.name) orelse {
        _ = c.unlinkat(parent_fd, split.name, 0);
        _ = c.close(parent_fd);
        return completion(item, .failed, null);
    };
    if (!syncDescriptor(parent_fd)) {
        closeCreatedParent(&result, true);
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

/// Dispose of stale operation results, removing only the link this operation created.
pub fn discard(
    _: ?*anyopaque,
    _: executor.OperationKind,
    input: executor.OwnedPayload,
    continuation: ?executor.OwnedPayload,
    result: ?executor.OwnedPayload,
) void {
    var owned_result = result;
    if (owned_result) |*payload| {
        closeCreatedParent(payload, true);
        payload.deinit();
    }
    var owned_continuation = continuation;
    if (owned_continuation) |*payload| payload.deinit();
    var owned_input = input;
    owned_input.deinit();
}

/// Accepted results keep the symlink and release the parent descriptor.
pub fn complete(
    _: ?*anyopaque,
    _: executor.WorkToken,
    _: executor.WorkResult,
    result: ?executor.OwnedPayload,
) void {
    var owned_result = result;
    if (owned_result) |*payload| {
        closeCreatedParent(payload, false);
        payload.deinit();
    }
}
