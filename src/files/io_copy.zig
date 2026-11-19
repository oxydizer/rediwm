//! Bounded regular-file copy operation for the Files I/O executor.
//!
//! The input payload contains two NUL-terminated paths.
//! Continuation state uses an explicit, fixed-width little-endian encoding.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");

pub const chunk_size: usize = 64 * 1024;
const small_buffer_size: usize = 16 * 1024;
const large_buffer_size: usize = 256 * 1024;
const max_buffer_size: usize = 1024 * 1024;
const clone_ioctl: c_ulong = 0x40049409;

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

fn recordFallbackReason(metrics: *executor.CopyMetrics, value: c_int) void {
    if (value == c.EXDEV) {
        metrics.fallback_exdev +|= 1;
    } else if (value == c.EPERM) {
        metrics.fallback_permission +|= 1;
    } else {
        metrics.fallback_unsupported +|= 1;
    }
}

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

pub fn bufferedBufferSize(file_size: u64) usize {
    if (file_size == 0) return 0;
    const target: usize = if (file_size <= 64 * 1024)
        small_buffer_size
    else if (file_size <= 1024 * 1024)
        chunk_size
    else if (file_size <= 64 * 1024 * 1024)
        large_buffer_size
    else
        max_buffer_size;
    return @intCast(@min(file_size, target));
}

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

fn writeContinuationHeader(bytes: []u8, state: Continuation) void {
    writeUnsigned(u32, bytes[0..4], @bitCast(state.source_fd));
    writeUnsigned(u32, bytes[4..8], @bitCast(state.destination_fd));
    writeUnsigned(u64, bytes[8..16], state.offset);
    writeUnsigned(u64, bytes[16..24], state.size);
    bytes[24] = switch (state.strategy) {
        .copy_file_range => 0,
        .buffered => 1,
    };
    bytes[25] = @intFromBool(state.destination_created);
}

fn encodeContinuation(
    allocator: Allocator,
    state: Continuation,
    buffer_size: usize,
) !executor.OwnedPayload {
    const bytes = try allocator.alloc(u8, continuation_size + buffer_size);
    writeContinuationHeader(bytes, state);
    return .{ .allocator = allocator, .bytes = bytes };
}

fn decodeContinuation(payload: *const executor.OwnedPayload) !Continuation {
    const bytes = payload.slice();
    if (bytes.len < continuation_size) return error.InvalidContinuation;
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
    const expected_buffer_size: usize = if (strategy == .buffered)
        bufferedBufferSize(size)
    else
        0;
    if (bytes.len != continuation_size + expected_buffer_size) {
        return error.InvalidContinuation;
    }
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

fn completionWithResultAndProgress(
    item: executor.WorkItem,
    result_payload: executor.OwnedPayload,
    bytes: u64,
    total_bytes: u64,
) executor.WorkCompletion {
    var result = completion(item, .completed, null, result_payload);
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

fn failedWithScratch(
    item: executor.WorkItem,
    state: ?Continuation,
    destination: [*:0]const u8,
    scratch: *?executor.OwnedPayload,
) executor.WorkCompletion {
    if (scratch.*) |*payload| payload.deinit();
    scratch.* = null;
    return failed(item, state, destination);
}

/// Execute exactly one bounded transfer unit.
///
/// A successful reflink completes in one unit. Otherwise each invocation
/// copies one bounded transfer unit before yielding.
pub fn execute(
    allocator: Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var metrics: executor.CopyMetrics = .{};
    const started = if (item_arg.profile_enabled) monotonicNowNs() else 0;
    var done = executeUnit(allocator, item_arg, &metrics);
    if (item_arg.profile_enabled)
        metrics.elapsed_ns = monotonicNowNs() - started;
    done.copy_metrics = metrics;
    return done;
}

fn executeUnit(
    allocator: Allocator,
    item_arg: executor.WorkItem,
    metrics: *executor.CopyMetrics,
) executor.WorkCompletion {
    var item = item_arg;
    const operation_paths = paths(&item.input) catch {
        return completion(item, .failed, null, null);
    };

    var scratch_payload: ?executor.OwnedPayload = null;
    var state: Continuation = undefined;
    var has_state = false;

    if (item.continuation) |*saved| {
        state = decodeContinuation(saved) catch {
            saved.deinit();
            item.continuation = null;
            return completion(item, .failed, null, null);
        };
        // Buffered continuations carry their reusable scratch allocation.
        // Transfer it with the descriptor state across worker dispatches.
        if (state.strategy == .buffered) {
            scratch_payload = saved.take();
        } else {
            saved.deinit();
        }
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
        metrics.reflink_attempts +|= 1;
        const reflink_started = if (item.profile_enabled) monotonicNowNs() else 0;
        const reflink_result = c.ioctl(destination_fd, clone_ioctl, source_fd);
        if (item.profile_enabled)
            metrics.reflink_ns +|= monotonicNowNs() - reflink_started;
        if (reflink_result == 0) {
            metrics.reflink_successes +|= 1;
            metrics.reflink_bytes +|= state.size;
            closeDescriptors(&state);
            const marker = allocator.dupe(u8, &.{1}) catch {
                unlinkDestination(operation_paths.destination);
                return completion(item, .failed, null, null);
            };
            return completionWithResultAndProgress(
                item,
                .{ .allocator = allocator, .bytes = marker },
                state.size,
                state.size,
            );
        }

        const clone_errno = std.c._errno().*;
        if (clone_errno == c.EXDEV or
            clone_errno == c.EINVAL or
            clone_errno == c.ENOSYS or
            clone_errno == c.ENOTTY or
            clone_errno == c.EOPNOTSUPP)
        {
            metrics.reflink_fallbacks +|= 1;
            recordFallbackReason(metrics, clone_errno);
        }
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
            return completionWithResultAndProgress(
                item,
                .{ .allocator = allocator, .bytes = marker },
                state.size,
                state.size,
            );
        }
    }

    if (!has_state) return completion(item, .failed, null, null);

    const remaining = state.size - state.offset;
    if (remaining == 0) {
        closeDescriptors(&state);
        if (scratch_payload) |*payload| payload.deinit();
        scratch_payload = null;
        const marker = allocator.dupe(u8, &.{1}) catch {
            unlinkDestination(operation_paths.destination);
            return completion(item, .failed, null, null);
        };
        return completionWithResultAndProgress(
            item,
            .{ .allocator = allocator, .bytes = marker },
            state.size,
            state.size,
        );
    }

    const request_len: usize = @intCast(@min(remaining, chunk_size));
    if (state.strategy == .copy_file_range) {
        metrics.copy_file_range_calls +|= 1;
        const range_started = if (item.profile_enabled) monotonicNowNs() else 0;
        const copied = c.copy_file_range(
            state.source_fd,
            null,
            state.destination_fd,
            null,
            request_len,
            0,
        );
        if (item.profile_enabled)
            metrics.copy_file_range_ns +|= monotonicNowNs() - range_started;
        if (copied > 0) {
            metrics.copy_file_range_bytes +|= @intCast(copied);
            state.offset += @intCast(copied);
        } else if (copied == 0) {
            return failedWithScratch(item, state, operation_paths.destination, &scratch_payload);
        } else {
            const copy_errno = std.c._errno().*;
            if (copy_errno == c.EINTR) {
                // Yield without changing offsets; retry in the next unit.
            } else if (isFallbackErrno(copy_errno)) {
                metrics.copy_file_range_fallbacks +|= 1;
                recordFallbackReason(metrics, copy_errno);
                state.strategy = .buffered;
            } else {
                return failedWithScratch(item, state, operation_paths.destination, &scratch_payload);
            }
        }
    }

    if (state.strategy == .buffered) {
        const buffered_started = if (item.profile_enabled) monotonicNowNs() else 0;
        defer if (item.profile_enabled) {
            metrics.buffered_ns +|= monotonicNowNs() - buffered_started;
        };

        if (scratch_payload == null) {
            scratch_payload = encodeContinuation(
                allocator,
                state,
                bufferedBufferSize(state.size),
            ) catch {
                return failedWithScratch(item, state, operation_paths.destination, &scratch_payload);
            };
        }
        const buffer = scratch_payload.?.bytes.?[continuation_size..];
        const wanted: usize = @intCast(@min(
            state.size - state.offset,
            @as(u64, buffer.len),
        ));
        metrics.buffered_read_calls +|= 1;
        const count = c.read(state.source_fd, buffer.ptr, wanted);
        if (count == 0) {
            return failedWithScratch(item, state, operation_paths.destination, &scratch_payload);
        }
        if (count < 0) {
            if (std.c._errno().* == c.EINTR) {
                writeContinuationHeader(scratch_payload.?.bytes.?[0..continuation_size], state);
                const saved = scratch_payload.?.take();
                scratch_payload = null;
                return completionWithProgress(
                    item,
                    .yielded,
                    saved,
                    state.offset,
                    state.size,
                );
            }
            return failedWithScratch(item, state, operation_paths.destination, &scratch_payload);
        }

        const bytes_read: usize = @intCast(count);
        metrics.buffered_read_bytes +|= @intCast(bytes_read);
        var written: usize = 0;
        while (written < bytes_read) {
            metrics.buffered_write_calls +|= 1;
            const result = c.write(
                state.destination_fd,
                buffer[written..].ptr,
                bytes_read - written,
            );
            if (result < 0 and std.c._errno().* == c.EINTR) continue;
            if (result <= 0) {
                return failedWithScratch(item, state, operation_paths.destination, &scratch_payload);
            }
            metrics.buffered_write_bytes +|= @intCast(result);
            written += @intCast(result);
        }
        state.offset += bytes_read;
    }

    if (state.offset == state.size) {
        closeDescriptors(&state);
        if (scratch_payload) |*payload| payload.deinit();
        scratch_payload = null;
        const marker = allocator.dupe(u8, &.{1}) catch {
            unlinkDestination(operation_paths.destination);
            return completion(item, .failed, null, null);
        };
        return completionWithResultAndProgress(
            item,
            .{ .allocator = allocator, .bytes = marker },
            state.size,
            state.size,
        );
    }

    const saved = if (scratch_payload) |*payload| blk: {
        writeContinuationHeader(payload.bytes.?[0..continuation_size], state);
        break :blk payload.take();
    } else encodeContinuation(allocator, state, 0) catch {
        return failedWithScratch(item, state, operation_paths.destination, &scratch_payload);
    };
    scratch_payload = null;
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
