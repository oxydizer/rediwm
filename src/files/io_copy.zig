//! Bounded regular-file copy operation for the Files I/O executor.
//!
//! The input payload contains two NUL-terminated paths.
//! Continuation state uses an explicit, fixed-width little-endian encoding.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");

pub const chunk_size: usize = 64 * 1024;
const clone_ioctl: c_ulong = 0x40049409;

const Strategy = enum(u8) {
    copy_file_range,
    buffered,
};

const Continuation = struct {
    source_fd: c_int,
    destination_fd: c_int,
    offset: u64,
    size: u64,
    strategy: Strategy,
    destination_created: bool,
};

const continuation_size = 26;

/// Build the immutable operation input.
pub fn makeInput(
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) !executor.OwnedPayload {
    if (source_path.len == 0 or destination_path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, source_path, 0) != null or
        std.mem.indexOfScalar(u8, destination_path, 0) != null)
    {
        return error.InvalidPath;
    }

    const bytes = try allocator.alloc(u8, source_path.len + 1 + destination_path.len + 1);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..source_path.len], source_path);
    bytes[source_path.len] = 0;
    const destination_start = source_path.len + 1;
    @memcpy(bytes[destination_start ..][0..destination_path.len], destination_path);
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

fn paths(input: *const executor.OwnedPayload) !struct {
    source: [*:0]const u8,
    destination: [*:0]const u8,
} {
    const bytes = input.slice();
    const separator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidInput;
    if (separator == 0 or bytes.len < separator + 3 or bytes[bytes.len - 1] != 0) {
        return error.InvalidInput;
    }
    const destination_bytes = bytes[separator + 1 ..];
    if (std.mem.indexOfScalar(u8, destination_bytes[0 .. destination_bytes.len - 1], 0) != null) {
        return error.InvalidInput;
    }
    return .{
        .source = @ptrCast(bytes.ptr),
        .destination = @ptrCast(bytes[separator + 1 ..].ptr),
    };
}

fn writeUnsigned(comptime T: type, output: []u8, value: T) void {
    for (0..@sizeOf(T)) |index| {
        const shift: std.math.Log2Int(T) = @intCast(index * 8);
        output[index] = @truncate(value >> shift);
    }
}

fn readUnsigned(comptime T: type, input: []const u8) T {
    var value: T = 0;
    for (0..@sizeOf(T)) |index| {
        const shift: std.math.Log2Int(T) = @intCast(index * 8);
        value |= @as(T, input[index]) << shift;
    }
    return value;
}

fn encodeContinuation(allocator: Allocator, state: Continuation) !executor.OwnedPayload {
    const bytes = try allocator.alloc(u8, continuation_size);
    writeUnsigned(u32, bytes[0..4], @bitCast(state.source_fd));
    writeUnsigned(u32, bytes[4..8], @bitCast(state.destination_fd));
    writeUnsigned(u64, bytes[8..16], state.offset);
    writeUnsigned(u64, bytes[16..24], state.size);
    bytes[24] = switch (state.strategy) {
        .copy_file_range => 0,
        .buffered => 1,
    };
    bytes[25] = @intFromBool(state.destination_created);
    return .{ .allocator = allocator, .bytes = bytes };
}

fn decodeContinuation(payload: *const executor.OwnedPayload) !Continuation {
    const bytes = payload.slice();
    if (bytes.len != continuation_size) return error.InvalidContinuation;
    const strategy: Strategy = switch (bytes[24]) {
        0 => .copy_file_range,
        1 => .buffered,
        else => return error.InvalidContinuation,
    };
    if (bytes[25] > 1) return error.InvalidContinuation;
    const source_fd: c_int = @bitCast(readUnsigned(u32, bytes[0..4]));
    const destination_fd: c_int = @bitCast(readUnsigned(u32, bytes[4..8]));
    const offset = readUnsigned(u64, bytes[8..16]);
    const size = readUnsigned(u64, bytes[16..24]);
    if (source_fd < 0 or destination_fd < 0 or offset > size or bytes[25] != 1) {
        return error.InvalidContinuation;
    }
    return .{
        .source_fd = source_fd,
        .destination_fd = destination_fd,
        .offset = offset,
        .size = size,
        .strategy = strategy,
        .destination_created = true,
    };
}

fn closeDescriptors(state: *const Continuation) void {
    _ = c.close(state.source_fd);
    _ = c.close(state.destination_fd);
}

fn unlinkDestination(destination: [*:0]const u8) void {
    _ = c.unlink(destination);
}

fn isFallbackErrno(value: c_int) bool {
    return value == c.EXDEV or
        value == c.EINVAL or
        value == c.ENOSYS or
        value == c.EOPNOTSUPP or
        value == c.EPERM;
}

fn completion(
    item_arg: executor.WorkItem,
    outcome: executor.WorkResult,
    continuation: ?executor.OwnedPayload,
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
        .continuation = continuation,
        .result = result,
    };
}

fn completionWithProgress(
    item: executor.WorkItem,
    outcome: executor.WorkResult,
    continuation: ?executor.OwnedPayload,
    bytes: u64,
    total_bytes: u64,
) executor.WorkCompletion {
    var result = completion(item, outcome, continuation, null);
    result.progress = .{
        .bytes = bytes,
        .total_bytes = total_bytes,
    };
    return result;
}

fn failed(
    item: executor.WorkItem,
    state: ?Continuation,
    destination: [*:0]const u8,
) executor.WorkCompletion {
    if (state) |current| {
        closeDescriptors(&current);
        if (current.destination_created) unlinkDestination(destination);
    }
    return completion(item, .failed, null, null);
}

/// Execute exactly one bounded transfer unit.
///
/// A successful reflink completes in one unit. Otherwise each invocation
/// copies at most chunk_size bytes before yielding.
pub fn execute(
    allocator: Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var item = item_arg;
    const operation_paths = paths(&item.input) catch {
        return completion(item, .failed, null, null);
    };

    var state: Continuation = undefined;
    var has_state = false;

    if (item.continuation) |*saved| {
        state = decodeContinuation(saved) catch {
            saved.deinit();
            item.continuation = null;
            return completion(item, .failed, null, null);
        };
        // The decoded descriptor state now owns the resources. The previous
        // serialized continuation is no longer needed.
        saved.deinit();
        item.continuation = null;
        has_state = true;
    } else {
        const source_fd = c.open(
            operation_paths.source,
            c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK,
        );
        if (source_fd < 0) return completion(item, .failed, null, null);

        var stat: c.struct_stat = undefined;
        if (c.fstat(source_fd, &stat) != 0 or
            (stat.st_mode & c.S_IFMT) != c.S_IFREG or
            stat.st_size < 0)
        {
            _ = c.close(source_fd);
            return completion(item, .failed, null, null);
        }

        const mode: c_uint = @intCast(stat.st_mode & 0o7777);
        const destination_fd = c.open(
            operation_paths.destination,
            c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
            mode,
        );
        if (destination_fd < 0) {
            const failure_errno = std.c._errno().*;
            _ = c.close(source_fd);
            if (failure_errno == c.EEXIST) {
                // Distinct from the successful-copy marker: discard must
                // never unlink a destination that existed before this job.
                const marker = allocator.dupe(u8, &.{2}) catch {
                    return completion(item, .failed, null, null);
                };
                return completion(
                    item,
                    .waiting,
                    null,
                    .{ .allocator = allocator, .bytes = marker },
                );
            }
            return completion(item, .failed, null, null);
        }

        state = .{
            .source_fd = source_fd,
            .destination_fd = destination_fd,
            .offset = 0,
            .size = @intCast(stat.st_size),
            .strategy = .copy_file_range,
            .destination_created = true,
        };
        has_state = true;

        // FICLONE is attempted before either streaming strategy.
        if (c.ioctl(destination_fd, clone_ioctl, source_fd) == 0) {
            closeDescriptors(&state);
            const marker = allocator.dupe(u8, &.{1}) catch {
                unlinkDestination(operation_paths.destination);
                return completion(item, .failed, null, null);
            };
            return completion(
                item,
                .completed,
                null,
                .{ .allocator = allocator, .bytes = marker },
            );
        }

        const clone_errno = std.c._errno().*;
        if (clone_errno != c.EXDEV and
            clone_errno != c.EINVAL and
            clone_errno != c.ENOSYS and
            clone_errno != c.ENOTTY and
            clone_errno != c.EOPNOTSUPP)
        {
            return failed(item, state, operation_paths.destination);
        }

        if (state.size == 0) {
            closeDescriptors(&state);
            const marker = allocator.dupe(u8, &.{1}) catch {
                unlinkDestination(operation_paths.destination);
                return completion(item, .failed, null, null);
            };
            return completion(
                item,
                .completed,
                null,
                .{ .allocator = allocator, .bytes = marker },
            );
        }
    }

    if (!has_state) return completion(item, .failed, null, null);

    const remaining = state.size - state.offset;
    if (remaining == 0) {
        closeDescriptors(&state);
        const marker = allocator.dupe(u8, &.{1}) catch {
            unlinkDestination(operation_paths.destination);
            return completion(item, .failed, null, null);
        };
        return completion(
            item,
            .completed,
            null,
            .{ .allocator = allocator, .bytes = marker },
        );
    }

    const request_len: usize = @intCast(@min(remaining, chunk_size));
    if (state.strategy == .copy_file_range) {
        const copied = c.copy_file_range(
            state.source_fd,
            null,
            state.destination_fd,
            null,
            request_len,
            0,
        );
        if (copied > 0) {
            state.offset += @intCast(copied);
        } else if (copied == 0) {
            return failed(item, state, operation_paths.destination);
        } else {
            const copy_errno = std.c._errno().*;
            if (copy_errno == c.EINTR) {
                // Yield without changing offsets; retry in the next unit.
            } else if (isFallbackErrno(copy_errno)) {
                state.strategy = .buffered;
            } else {
                return failed(item, state, operation_paths.destination);
            }
        }
    }

    if (state.strategy == .buffered) {
        var buffer: [chunk_size]u8 = undefined;
        const wanted: usize = @intCast(@min(
            state.size - state.offset,
            @as(u64, chunk_size),
        ));
        const count = c.read(state.source_fd, &buffer, wanted);
        if (count == 0) return failed(item, state, operation_paths.destination);
        if (count < 0) {
            if (std.c._errno().* == c.EINTR) {
                const saved = encodeContinuation(allocator, state) catch {
                    return failed(item, state, operation_paths.destination);
                };
                return completionWithProgress(
                    item,
                    .yielded,
                    saved,
                    state.offset,
                    state.size,
                );
            }
            return failed(item, state, operation_paths.destination);
        }

        const bytes_read: usize = @intCast(count);
        var written: usize = 0;
        while (written < bytes_read) {
            const result = c.write(
                state.destination_fd,
                buffer[written..].ptr,
                bytes_read - written,
            );
            if (result < 0 and std.c._errno().* == c.EINTR) continue;
            if (result <= 0) {
                return failed(item, state, operation_paths.destination);
            }
            written += @intCast(result);
        }
        state.offset += bytes_read;
    }

    if (state.offset == state.size) {
        closeDescriptors(&state);
        const marker = allocator.dupe(u8, &.{1}) catch {
            unlinkDestination(operation_paths.destination);
            return completion(item, .failed, null, null);
        };
        return completion(
            item,
            .completed,
            null,
            .{ .allocator = allocator, .bytes = marker },
        );
    }

    const saved = encodeContinuation(allocator, state) catch {
        return failed(item, state, operation_paths.destination);
    };
    return completionWithProgress(
        item,
        .yielded,
        saved,
        state.offset,
        state.size,
    );
}

/// Executor discard callback. It owns and releases all supplied payloads.
/// A continuation means the destination is still partial and operation-owned.
/// A result marker means a completed destination was not accepted by Manager.
pub fn discard(
    _: ?*anyopaque,
    _: executor.OperationKind,
    input: executor.OwnedPayload,
    continuation: ?executor.OwnedPayload,
    result: ?executor.OwnedPayload,
) void {
    const operation_paths = paths(&input) catch {
        var owned_input = input;
        owned_input.deinit();
        if (continuation) |payload| {
            var owned = payload;
            owned.deinit();
        }
        if (result) |payload| {
            var owned = payload;
            owned.deinit();
        }
        return;
    };

    if (continuation) |payload| {
        if (decodeContinuation(&payload)) |state| {
            closeDescriptors(&state);
            if (state.destination_created) {
                unlinkDestination(operation_paths.destination);
            }
        } else |_| {}
        var owned = payload;
        owned.deinit();
    }

    if (result) |payload| {
        if (payload.slice().len == 1 and payload.slice()[0] == 1) {
            unlinkDestination(operation_paths.destination);
        }
        var owned = payload;
        owned.deinit();
    }

    var owned_input = input;
    owned_input.deinit();
}

/// Accepted terminal results are preserved; only the marker payload is freed.
pub fn complete(
    _: ?*anyopaque,
    _: executor.WorkToken,
    _: executor.WorkResult,
    result: ?executor.OwnedPayload,
) void {
    if (result) |payload| {
        var owned = payload;
        owned.deinit();
    }
}
