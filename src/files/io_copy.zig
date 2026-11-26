//! Bounded regular-file copy operation for the Files I/O executor.
//!
//! The input payload contains source and destination paths plus a
//! same-directory staging basename.
//! Continuation state uses an explicit, fixed-width little-endian encoding.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");
const existing_mod = @import("io_copy_existing.zig");

pub const chunk_size: usize = 64 * 1024;
/// A unit copies chunks until this many bytes or `unit_ns`, whichever comes
/// first, then yields for fairness, cancellation and progress. Jobs take
/// turns by unit, so a long unit takes a bigger share of the workers: at
/// 10 ms an extraction beside two copies ran about 20 % slower; at 2 ms it
/// ran as before.
pub const unit_bytes: u64 = 1024 * 1024;
const unit_ns: u64 = 2 * std.time.ns_per_ms;
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
    parent_fd: c_int,
    original_fd: c_int,
    offset: u64,
    size: u64,
    strategy: Strategy,
    destination_created: bool,
    flushing: bool,
    replacement: bool,
};

const continuation_size = 36;
/// The input's last byte: bit 0 replacement, bit 1 deferred sync.
const flag_replacement: u8 = 1;
const flag_deferred_sync: u8 = 2;
const replacement_marker_header_size = 13;

/// The read/write fallback's buffer: one per worker thread, reused by every
/// file it copies. A unit reads and writes within itself, so nothing in it
/// outlives the unit; a file is no longer given a buffer of its own. It
/// grows to the largest size class asked for, at most `max_buffer_size`, and
/// goes with the thread (`releaseThreadBuffer`, from the worker pool).
threadlocal var thread_buffer: []u8 = &.{};

fn threadBuffer(size: usize) ?[]u8 {
    if (thread_buffer.len < size) {
        const grown = std.heap.c_allocator.alloc(u8, size) catch return null;
        releaseThreadBuffer();
        thread_buffer = grown;
    }
    return thread_buffer[0..size];
}

pub fn releaseThreadBuffer() void {
    if (thread_buffer.len > 0) std.heap.c_allocator.free(thread_buffer);
    thread_buffer = &.{};
}

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
    token: executor.WorkToken,
) !executor.OwnedPayload {
    const staging_name = try std.fmt.allocPrint(
        allocator,
        ".rediwm-{d}-{d}-{d}.tmp",
        .{ token.job_id, token.operation_id, token.generation },
    );
    defer allocator.free(staging_name);
    return makeInputWithStagingName(
        allocator,
        source_path,
        destination_path,
        staging_name,
        false,
    );
}

/// As `makeInput`, for a copy job that syncs once at its end
/// (`Manager.setDeferredSync`): the new file is not synced on its own. A
/// replacement always is, so an overwrite never leaves a broken file.
pub fn makeDeferredInput(
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
    token: executor.WorkToken,
) !executor.OwnedPayload {
    const input = try makeInput(allocator, source_path, destination_path, token);
    const bytes = input.bytes.?;
    bytes[bytes.len - 1] |= flag_deferred_sync;
    return input;
}

/// Build replacement input with a unique staging basename in the destination
/// directory. The work generation prevents a stale attempt from sharing it.
pub fn makeReplacementInput(
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
    token: executor.WorkToken,
) !executor.OwnedPayload {
    const staging_name = try std.fmt.allocPrint(
        allocator,
        ".rediwm-{d}-{d}-{d}.tmp",
        .{ token.job_id, token.operation_id, token.generation },
    );
    defer allocator.free(staging_name);
    return makeInputWithStagingName(
        allocator,
        source_path,
        destination_path,
        staging_name,
        true,
    );
}

fn makeInputWithStagingName(
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
    staging_name: ?[]const u8,
    replacement: bool,
) !executor.OwnedPayload {
    if (source_path.len == 0 or destination_path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, source_path, 0) != null or
        std.mem.indexOfScalar(u8, destination_path, 0) != null)
    {
        return error.InvalidPath;
    }
    if (staging_name) |name| {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or
            std.mem.indexOfScalar(u8, name, '/') != null)
        {
            return error.InvalidPath;
        }
    }

    const staging_length = if (staging_name) |name| name.len + 2 else 0;
    const bytes = try allocator.alloc(
        u8,
        source_path.len + 1 + destination_path.len + 1 + staging_length,
    );
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..source_path.len], source_path);
    bytes[source_path.len] = 0;
    const destination_start = source_path.len + 1;
    @memcpy(bytes[destination_start ..][0..destination_path.len], destination_path);
    const staging_start = destination_start + destination_path.len + 1;
    bytes[staging_start - 1] = 0;
    if (staging_name) |name| {
        @memcpy(bytes[staging_start..][0..name.len], name);
        bytes[bytes.len - 2] = 0;
        bytes[bytes.len - 1] = if (replacement) flag_replacement else 0;
    }
    return .{ .allocator = allocator, .bytes = bytes };
}

fn paths(input: *const executor.OwnedPayload) !struct {
    source: [*:0]const u8,
    destination: [*:0]const u8,
    destination_name: [*:0]const u8,
    staging_name: ?[*:0]const u8,
    replacement: bool,
    deferred_sync: bool,
} {
    const bytes = input.slice();
    const separator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidInput;
    if (separator == 0 or bytes.len < separator + 3) {
        return error.InvalidInput;
    }
    const destination_bytes = bytes[separator + 1 ..];
    const destination_end = std.mem.indexOfScalar(u8, destination_bytes, 0) orelse
        return error.InvalidInput;
    if (destination_end == 0) return error.InvalidInput;
    const destination_path = destination_bytes[0..destination_end];
    const staging_bytes = destination_bytes[destination_end + 1 ..];
    if (staging_bytes.len == 0 and bytes[bytes.len - 1] != 0) {
        return error.InvalidInput;
    }
    const staging_name: ?[*:0]const u8 = if (staging_bytes.len == 0)
        null
    else blk: {
        const name_end = std.mem.indexOfScalar(u8, staging_bytes, 0) orelse
            return error.InvalidInput;
        if (name_end == 0 or name_end + 2 != staging_bytes.len or
            staging_bytes[name_end + 1] > (flag_replacement | flag_deferred_sync))
            return error.InvalidInput;
        const name = staging_bytes[0..name_end];
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
            return error.InvalidInput;
        }
        break :blk @ptrCast(name.ptr);
    };
    const flags: u8 = if (staging_bytes.len != 0) staging_bytes[staging_bytes.len - 1] else 0;
    const replacement = flags & flag_replacement != 0;
    const destination_separator = std.mem.lastIndexOfScalar(u8, destination_path, '/');
    const name = if (destination_separator) |index|
        destination_path[index + 1 ..]
    else
        destination_path;
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return error.InvalidInput;
    }
    return .{
        .source = @ptrCast(bytes.ptr),
        .destination = @ptrCast(bytes[separator + 1 ..].ptr),
        .destination_name = @ptrCast(name.ptr),
        .staging_name = staging_name,
        .replacement = replacement,
        .deferred_sync = !replacement and flags & flag_deferred_sync != 0,
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

fn makeReplacementMarker(
    allocator: Allocator,
    state: *const Continuation,
    staging_name: [*:0]const u8,
) ![]u8 {
    var original_stat: c.struct_stat = undefined;
    if (c.fstat(state.original_fd, &original_stat) != 0)
        return error.ReplacementStatFailed;
    const marker_kind: u8 = switch (original_stat.st_mode & c.S_IFMT) {
        c.S_IFREG => 3,
        c.S_IFDIR => 4,
        else => return error.UnsupportedReplacementType,
    };
    const name = std.mem.span(staging_name);
    const marker = try allocator.alloc(
        u8,
        replacement_marker_header_size + name.len + 1,
    );
    marker[0] = marker_kind;
    writeUnsigned(u32, marker[1..5], @bitCast(state.parent_fd));
    writeUnsigned(u32, marker[5..9], @bitCast(state.destination_fd));
    writeUnsigned(u32, marker[9..13], @bitCast(state.original_fd));
    @memcpy(marker[replacement_marker_header_size ..][0..name.len], name);
    marker[replacement_marker_header_size + name.len] = 0;
    return marker;
}

fn writeContinuationHeader(bytes: []u8, state: Continuation) void {
    writeUnsigned(u32, bytes[0..4], @bitCast(state.source_fd));
    writeUnsigned(u32, bytes[4..8], @bitCast(state.destination_fd));
    writeUnsigned(u32, bytes[8..12], @bitCast(state.parent_fd));
    writeUnsigned(u64, bytes[12..20], state.offset);
    writeUnsigned(u64, bytes[20..28], state.size);
    bytes[28] = switch (state.strategy) {
        .copy_file_range => 0,
        .buffered => 1,
    };
    bytes[29] = @intFromBool(state.destination_created);
    bytes[30] = @intFromBool(state.flushing);
    writeUnsigned(u32, bytes[31..35], @bitCast(state.original_fd));
    bytes[35] = @intFromBool(state.replacement);
}

fn encodeContinuation(
    allocator: Allocator,
    state: Continuation,
) !executor.OwnedPayload {
    const bytes = try allocator.alloc(u8, continuation_size);
    writeContinuationHeader(bytes, state);
    return .{ .allocator = allocator, .bytes = bytes };
}

fn decodeContinuation(payload: *const executor.OwnedPayload) !Continuation {
    const bytes = payload.slice();
    if (bytes.len < continuation_size) return error.InvalidContinuation;
    const strategy: Strategy = switch (bytes[28]) {
        0 => .copy_file_range,
        1 => .buffered,
        else => return error.InvalidContinuation,
    };
    if (bytes[29] > 1 or bytes[30] > 1 or bytes[35] > 1) {
        return error.InvalidContinuation;
    }
    const source_fd: c_int = @bitCast(readUnsigned(u32, bytes[0..4]));
    const destination_fd: c_int = @bitCast(readUnsigned(u32, bytes[4..8]));
    const parent_fd: c_int = @bitCast(readUnsigned(u32, bytes[8..12]));
    const original_fd: c_int = @bitCast(readUnsigned(u32, bytes[31..35]));
    const offset = readUnsigned(u64, bytes[12..20]);
    const size = readUnsigned(u64, bytes[20..28]);
    // The header alone: buffers belong to worker threads (`threadBuffer`).
    if (bytes.len != continuation_size) return error.InvalidContinuation;
    const replacement = bytes[35] == 1;
    if (source_fd < 0 or destination_fd < 0 or parent_fd < 0 or
        (replacement and original_fd < 0) or
        (!replacement and original_fd != -1) or
        offset > size or bytes[29] != 1)
    {
        return error.InvalidContinuation;
    }
    return .{
        .source_fd = source_fd,
        .destination_fd = destination_fd,
        .parent_fd = parent_fd,
        .original_fd = original_fd,
        .offset = offset,
        .size = size,
        .strategy = strategy,
        .destination_created = true,
        .flushing = bytes[30] == 1,
        .replacement = replacement,
    };
}

fn closeDescriptors(state: *const Continuation) void {
    _ = c.close(state.source_fd);
    _ = c.close(state.destination_fd);
    if (state.original_fd >= 0) _ = c.close(state.original_fd);
    _ = c.close(state.parent_fd);
}

fn closeSourceDescriptor(state: *const Continuation) void {
    _ = c.close(state.source_fd);
}

fn syncDescriptor(fd: c_int) bool {
    while (true) {
        if (c.fsync(fd) == 0) return true;
        if (std.c._errno().* != c.EINTR) return false;
    }
}

fn descriptorMatchesName(
    fd: c_int,
    parent_fd: c_int,
    name: [*:0]const u8,
) bool {
    var descriptor_stat: c.struct_stat = undefined;
    var name_stat: c.struct_stat = undefined;
    if (c.fstat(fd, &descriptor_stat) != 0 or
        c.fstatat(parent_fd, name, &name_stat, c.AT_SYMLINK_NOFOLLOW) != 0)
    {
        return false;
    }
    return descriptor_stat.st_dev == name_stat.st_dev and
        descriptor_stat.st_ino == name_stat.st_ino;
}

/// Atomically exchange two names in one directory. Replacement deliberately
/// has no weaker fallback on platforms without this primitive.
fn exchangeNames(
    parent_fd: c_int,
    first: [*:0]const u8,
    second: [*:0]const u8,
) bool {
    if (builtin.os.tag != .linux) return false;
    return c.renameat2(parent_fd, first, parent_fd, second, 2) == 0;
}

/// Publish a completed new file without replacing a name that appeared
/// during the copy. There is deliberately no non-atomic fallback.
fn publishNoReplace(
    parent_fd: c_int,
    staging_name: [*:0]const u8,
    destination_name: [*:0]const u8,
) bool {
    if (builtin.os.tag != .linux) return false;
    return c.renameat2(parent_fd, staging_name, parent_fd, destination_name, 1) == 0;
}

fn unlinkOwnedDestination(
    destination_fd: c_int,
    parent_fd: c_int,
    name: [*:0]const u8,
) void {
    var owned_stat: c.struct_stat = undefined;
    var current_stat: c.struct_stat = undefined;
    if (c.fstat(destination_fd, &owned_stat) != 0 or
        c.fstatat(parent_fd, name, &current_stat, c.AT_SYMLINK_NOFOLLOW) != 0)
    {
        return;
    }
    if (owned_stat.st_dev != current_stat.st_dev or
        owned_stat.st_ino != current_stat.st_ino)
    {
        return;
    }
    _ = c.unlinkat(parent_fd, name, 0);
}

fn directoryIsEmpty(fd: c_int) bool {
    const scan_fd = c.dup(fd);
    if (scan_fd < 0) return false;
    const directory = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return false;
    };
    defer _ = c.closedir(directory);

    while (true) {
        std.c._errno().* = 0;
        const entry = c.readdir(directory) orelse
            return std.c._errno().* == 0;
        const name: [*:0]const u8 = @ptrCast(&entry.*.d_name);
        const text = std.mem.span(name);
        if (std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, ".."))
            continue;
        return false;
    }
}

fn unlinkOwnedDirectory(
    directory_fd: c_int,
    parent_fd: c_int,
    name: [*:0]const u8,
) void {
    var owned_stat: c.struct_stat = undefined;
    var current_stat: c.struct_stat = undefined;
    if (c.fstat(directory_fd, &owned_stat) != 0 or
        c.fstatat(parent_fd, name, &current_stat, c.AT_SYMLINK_NOFOLLOW) != 0)
    {
        return;
    }
    if ((owned_stat.st_mode & c.S_IFMT) != c.S_IFDIR or
        owned_stat.st_dev != current_stat.st_dev or
        owned_stat.st_ino != current_stat.st_ino)
    {
        return;
    }
    _ = c.unlinkat(parent_fd, name, c.AT_REMOVEDIR);
}

fn cleanupDestination(state: *const Continuation, name: [*:0]const u8) void {
    if (!state.destination_created) return;
    unlinkOwnedDestination(state.destination_fd, state.parent_fd, name);
    _ = syncDescriptor(state.parent_fd);
}

fn cleanupAndClose(
    state: *const Continuation,
    name: [*:0]const u8,
) void {
    cleanupDestination(state, name);
    closeDescriptors(state);
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
    phase: executor.CopyPhase,
) executor.WorkCompletion {
    var result = completion(item, outcome, continuation, null);
    result.progress = .{
        .bytes = bytes,
        .total_bytes = total_bytes,
        .phase = phase,
    };
    return result;
}

fn completionWithResultAndProgress(
    item: executor.WorkItem,
    result_payload: executor.OwnedPayload,
    bytes: u64,
    total_bytes: u64,
    phase: executor.CopyPhase,
) executor.WorkCompletion {
    var result = completion(item, .completed, null, result_payload);
    result.progress = .{
        .bytes = bytes,
        .total_bytes = total_bytes,
        .phase = phase,
    };
    return result;
}

fn failed(
    item: executor.WorkItem,
    state: ?Continuation,
    destination_name: [*:0]const u8,
) executor.WorkCompletion {
    if (state) |current| {
        cleanupAndClose(&current, destination_name);
    }
    return completion(item, .failed, null, null);
}

fn yieldForFlush(
    allocator: Allocator,
    item: executor.WorkItem,
    state_arg: Continuation,
    destination_name: [*:0]const u8,
) executor.WorkCompletion {
    var state = state_arg;
    state.flushing = true;
    const saved = encodeContinuation(allocator, state) catch {
        return failed(item, state, destination_name);
    };
    return completionWithProgress(
        item,
        .yielded,
        saved,
        state.size,
        state.size,
        .flushing,
    );
}

fn finishFlushing(
    allocator: Allocator,
    item: executor.WorkItem,
    state_arg: Continuation,
    destination_name: [*:0]const u8,
    original_destination_name: [*:0]const u8,
    deferred_sync: bool,
) executor.WorkCompletion {
    var state = state_arg;
    existing_mod.keepTimes(state.source_fd, state.destination_fd);
    // A deferred job syncs its whole destination once, at its end
    // (`io_finalize`): a new file is not synced on its own.
    if (!deferred_sync and (!syncDescriptor(state.destination_fd) or
        !syncDescriptor(state.parent_fd)))
    {
        return failed(item, state, destination_name);
    }


    if (state.replacement) {
        const marker = makeReplacementMarker(
            allocator,
            &state,
            destination_name,
        ) catch {
            cleanupAndClose(&state, destination_name);
            return completion(item, .failed, null, null);
        };
        if (!descriptorMatchesName(
                state.original_fd,
                state.parent_fd,
                original_destination_name,
            ) or
            !descriptorMatchesName(
                state.destination_fd,
                state.parent_fd,
                destination_name,
            ) or
            !exchangeNames(
                state.parent_fd,
                destination_name,
                original_destination_name,
            ))
        {
            allocator.free(marker);
            cleanupAndClose(&state, destination_name);
            return completion(item, .failed, null, null);
        }
        if (!syncDescriptor(state.parent_fd)) {
            const rolled_back =
                descriptorMatchesName(
                    state.destination_fd,
                    state.parent_fd,
                    original_destination_name,
                ) and
                descriptorMatchesName(
                    state.original_fd,
                    state.parent_fd,
                    destination_name,
                ) and
                exchangeNames(
                    state.parent_fd,
                    destination_name,
                    original_destination_name,
                );
            allocator.free(marker);
            if (rolled_back) {
                cleanupAndClose(&state, destination_name);
            } else {
                closeDescriptors(&state);
            }
            return completion(item, .failed, null, null);
        }
        closeSourceDescriptor(&state);
        return completionWithResultAndProgress(
            item,
            .{ .allocator = allocator, .bytes = marker },
            state.size,
            state.size,
            .flushing,
        );
    }

    if (!publishNoReplace(
        state.parent_fd,
        destination_name,
        original_destination_name,
    )) {
        const publish_errno = std.c._errno().*;
        if (publish_errno == c.EEXIST) {
            const marker = allocator.dupe(u8, &.{2}) catch {
                cleanupAndClose(&state, destination_name);
                return completion(item, .failed, null, null);
            };
            cleanupAndClose(&state, destination_name);
            return completion(
                item,
                .waiting,
                null,
                .{ .allocator = allocator, .bytes = marker },
            );
        }
        return failed(item, state, destination_name);
    }

    if (!deferred_sync and !syncDescriptor(state.parent_fd)) {
        cleanupDestination(&state, original_destination_name);
        closeDescriptors(&state);
        return completion(item, .failed, null, null);
    }

    closeSourceDescriptor(&state);
    const marker = allocator.alloc(u8, 9) catch {
        cleanupDestination(&state, original_destination_name);
        _ = c.close(state.destination_fd);
        _ = c.close(state.parent_fd);
        return completion(item, .failed, null, null);
    };
    marker[0] = 1;
    writeUnsigned(u32, marker[1..5], @bitCast(state.parent_fd));
    writeUnsigned(u32, marker[5..9], @bitCast(state.destination_fd));
    return completionWithResultAndProgress(
        item,
        .{ .allocator = allocator, .bytes = marker },
        state.size,
        state.size,
        .flushing,
    );
}

/// Execute exactly one bounded transfer unit.
///
/// A unit copies up to `unit_bytes` or `unit_ns` before yielding. A copied
/// file is flushed in the same unit when its job syncs at its end, otherwise
/// in a unit of its own (`toFlush`).
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
    const owned_destination_name =
        operation_paths.staging_name orelse operation_paths.destination_name;

    var state: Continuation = undefined;
    var has_state = false;

    if (item.continuation) |*saved| {
        state = decodeContinuation(saved) catch {
            saved.deinit();
            item.continuation = null;
            return completion(item, .failed, null, null);
        };
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
        const destination_path = std.mem.span(operation_paths.destination);
        const destination_separator =
            std.mem.lastIndexOfScalar(u8, destination_path, '/');
        const parent_path = if (destination_separator) |index|
            (if (index == 0) "/" else destination_path[0..index])
        else
            ".";
        const parent_z = allocator.dupeSentinel(u8, parent_path, 0) catch {
            _ = c.close(source_fd);
            return completion(item, .failed, null, null);
        };
        defer allocator.free(parent_z);

        const parent_fd = c.open(
            parent_z,
            c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC,
        );
        if (parent_fd < 0) {
            _ = c.close(source_fd);
            return completion(item, .failed, null, null);
        }

        // A name already taken is decided before a byte is written: the
        // same file again is done, anything else is asked about now rather
        // than after a whole copy has been made only to be refused.
        if (!operation_paths.replacement) {
            switch (existing_mod.check(parent_fd, operation_paths.destination_name, stat)) {
                .none => {},
                .same => {
                    _ = c.close(source_fd);
                    _ = c.close(parent_fd);
                    const size: u64 = @intCast(stat.st_size);
                    return completionWithProgress(item, .completed, null, size, size, .flushing);
                },
                .other => {
                    _ = c.close(source_fd);
                    _ = c.close(parent_fd);
                    // The marker that never lets discard unlink the name.
                    const marker = allocator.dupe(u8, &.{2}) catch {
                        return completion(item, .failed, null, null);
                    };
                    return completion(item, .waiting, null, .{ .allocator = allocator, .bytes = marker });
                },
            }
        }

        var original_fd: c_int = -1;
        if (operation_paths.replacement) {
            original_fd = c.openat(
                parent_fd,
                operation_paths.destination_name,
                c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK,
            );
            if (original_fd < 0) {
                _ = c.close(source_fd);
                _ = c.close(parent_fd);
                return completion(item, .failed, null, null);
            }

            var original_stat: c.struct_stat = undefined;
            var current_stat: c.struct_stat = undefined;
            const stat_ok = c.fstat(original_fd, &original_stat) == 0;
            const original_kind = if (stat_ok)
                original_stat.st_mode & c.S_IFMT
            else
                0;
            const valid_original = stat_ok and
                (original_kind == c.S_IFREG or
                    (original_kind == c.S_IFDIR and directoryIsEmpty(original_fd)));
            const same_name = valid_original and
                c.fstatat(
                    parent_fd,
                    operation_paths.destination_name,
                    &current_stat,
                    c.AT_SYMLINK_NOFOLLOW,
                ) == 0 and
                original_stat.st_dev == current_stat.st_dev and
                original_stat.st_ino == current_stat.st_ino;
            if (!same_name) {
                _ = c.close(original_fd);
                _ = c.close(source_fd);
                _ = c.close(parent_fd);
                return completion(item, .failed, null, null);
            }
        }

        const destination_fd = c.openat(
            parent_fd,
            owned_destination_name,
            c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
            mode,
        );
        if (destination_fd < 0) {
            const failure_errno = std.c._errno().*;
            if (original_fd >= 0) _ = c.close(original_fd);
            _ = c.close(source_fd);
            _ = c.close(parent_fd);
            if (failure_errno == c.EEXIST and
                operation_paths.staging_name == null)
            {
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
            .parent_fd = parent_fd,
            .original_fd = original_fd,
            .offset = 0,
            .size = @intCast(stat.st_size),
            .strategy = .copy_file_range,
            .destination_created = true,
            .flushing = false,
            .replacement = original_fd >= 0,
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
            return toFlush(
                allocator,
                item,
                state,
                owned_destination_name,
                operation_paths);
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
            return failed(item, state, owned_destination_name);
        }

        if (state.size == 0) {
            return toFlush(
                allocator,
                item,
                state,
                owned_destination_name,
                operation_paths);
        }
    }

    if (!has_state) return completion(item, .failed, null, null);

    if (state.flushing) {
        return finishFlushing(
            allocator,
            item,
            state,
            owned_destination_name,
            operation_paths.destination_name,
            operation_paths.deferred_sync);
    }

    const unit_started = monotonicNowNs();
    const unit_end = state.offset +| unit_bytes;
    while (state.offset < state.size) {
        switch (copyChunk(&state, metrics, item.profile_enabled)) {
            .copied => {},
            .interrupted => break,
            .failed => return failed(item, state, owned_destination_name),
        }
        if (state.offset >= unit_end or
            monotonicNowNs() - unit_started >= unit_ns) break;
    }

    if (state.offset == state.size) {
        return toFlush(
            allocator,
            item,
            state,
            owned_destination_name,
            operation_paths);
    }

    const saved = encodeContinuation(allocator, state) catch {
        return failed(item, state, owned_destination_name);
    };
    return completionWithProgress(
        item,
        .yielded,
        saved,
        state.offset,
        state.size,
        .transferring,
    );
}

/// Hand a fully copied file to its flush. A job that syncs once at its end
/// publishes the file in this same unit (a rename, no sync); otherwise the
/// flush is a unit of its own, since its syncs can take long.
fn toFlush(
    allocator: Allocator,
    item: executor.WorkItem,
    state: Continuation,
    destination_name: [*:0]const u8,
    operation_paths: anytype,
) executor.WorkCompletion {
    if (operation_paths.deferred_sync and !state.replacement) {
        return finishFlushing(
            allocator,
            item,
            state,
            destination_name,
            operation_paths.destination_name,
            true,
        );
    }
    return yieldForFlush(allocator, item, state, destination_name);
}

const ChunkResult = enum { copied, interrupted, failed };

/// Copy one chunk at the state's offset, switching to the buffered strategy
/// when `copy_file_range` is not supported.
fn copyChunk(
    state: *Continuation,
    metrics: *executor.CopyMetrics,
    profile_enabled: bool,
) ChunkResult {
    const remaining = state.size - state.offset;
    if (state.strategy == .copy_file_range) {
        metrics.copy_file_range_calls +|= 1;
        const range_started = if (profile_enabled) monotonicNowNs() else 0;
        const copied = c.copy_file_range(
            state.source_fd,
            null,
            state.destination_fd,
            null,
            @intCast(@min(remaining, chunk_size)),
            0,
        );
        if (profile_enabled)
            metrics.copy_file_range_ns +|= monotonicNowNs() - range_started;
        if (copied > 0) {
            metrics.copy_file_range_bytes +|= @intCast(copied);
            state.offset += @intCast(copied);
            return .copied;
        }
        if (copied == 0) return .failed;
        const copy_errno = std.c._errno().*;
        // Retried in the next unit, offsets unchanged.
        if (copy_errno == c.EINTR) return .interrupted;
        if (!isFallbackErrno(copy_errno)) return .failed;
        metrics.copy_file_range_fallbacks +|= 1;
        recordFallbackReason(metrics, copy_errno);
        state.strategy = .buffered;
    }

    const buffered_started = if (profile_enabled) monotonicNowNs() else 0;
    defer if (profile_enabled) {
        metrics.buffered_ns +|= monotonicNowNs() - buffered_started;
    };
    const buffer = threadBuffer(bufferedBufferSize(state.size)) orelse return .failed;
    const wanted: usize = @intCast(@min(remaining, @as(u64, buffer.len)));
    metrics.buffered_read_calls +|= 1;
    const count = c.read(state.source_fd, buffer.ptr, wanted);
    if (count == 0) return .failed;
    if (count < 0) {
        return if (std.c._errno().* == c.EINTR) .interrupted else .failed;
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
        if (result <= 0) return .failed;
        metrics.buffered_write_bytes +|= @intCast(result);
        written += @intCast(result);
    }
    state.offset += bytes_read;
    return .copied;
}

const ReplacementMarker = struct {
    parent_fd: c_int,
    destination_fd: c_int,
    original_fd: c_int,
    staging_name: [*:0]const u8,
    original_is_directory: bool,
};

fn decodeReplacementMarker(bytes: []const u8) ?ReplacementMarker {
    if (bytes.len <= replacement_marker_header_size + 1 or
        (bytes[0] != 3 and bytes[0] != 4) or
        bytes[bytes.len - 1] != 0)
    {
        return null;
    }
    const name = bytes[replacement_marker_header_size .. bytes.len - 1];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.indexOfScalar(u8, name, '/') != null)
    {
        return null;
    }
    const parent_fd: c_int = @bitCast(readUnsigned(u32, bytes[1..5]));
    const destination_fd: c_int = @bitCast(readUnsigned(u32, bytes[5..9]));
    const original_fd: c_int = @bitCast(readUnsigned(u32, bytes[9..13]));
    if (parent_fd < 0 or destination_fd < 0 or original_fd < 0) return null;
    return .{
        .parent_fd = parent_fd,
        .destination_fd = destination_fd,
        .original_fd = original_fd,
        .staging_name = @ptrCast(bytes[replacement_marker_header_size..].ptr),
        .original_is_directory = bytes[0] == 4,
    };
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
            if (decodeContinuation(&payload)) |state| {
                closeDescriptors(&state);
            } else |_| {}
            var owned = payload;
            owned.deinit();
        }
        if (result) |payload| {
            const bytes = payload.slice();
            if (bytes.len == 9 and bytes[0] == 1) {
                const parent_fd: c_int = @bitCast(readUnsigned(u32, bytes[1..5]));
                const destination_fd: c_int = @bitCast(readUnsigned(u32, bytes[5..9]));
                _ = c.close(destination_fd);
                _ = c.close(parent_fd);
            } else if (decodeReplacementMarker(bytes)) |marker| {
                _ = c.close(marker.destination_fd);
                _ = c.close(marker.original_fd);
                _ = c.close(marker.parent_fd);
            }
            var owned = payload;
            owned.deinit();
        }
        return;
    };

    if (continuation) |payload| {
        if (decodeContinuation(&payload)) |state| {
            cleanupAndClose(
                &state,
                operation_paths.staging_name orelse operation_paths.destination_name,
            );
        } else |_| {}
        var owned = payload;
        owned.deinit();
    }

    if (result) |payload| {
        const bytes = payload.slice();
        if (bytes.len == 9 and bytes[0] == 1) {
            const parent_fd: c_int = @bitCast(readUnsigned(u32, bytes[1..5]));
            const destination_fd: c_int = @bitCast(readUnsigned(u32, bytes[5..9]));
            unlinkOwnedDestination(
                destination_fd,
                parent_fd,
                operation_paths.destination_name,
            );
            _ = syncDescriptor(parent_fd);
            _ = c.close(destination_fd);
            _ = c.close(parent_fd);
        } else if (decodeReplacementMarker(bytes)) |marker| {
            if (descriptorMatchesName(
                    marker.original_fd,
                    marker.parent_fd,
                    marker.staging_name,
                ) and
                descriptorMatchesName(
                    marker.destination_fd,
                    marker.parent_fd,
                    operation_paths.destination_name,
                ) and
                exchangeNames(
                    marker.parent_fd,
                    marker.staging_name,
                    operation_paths.destination_name,
                ))
            {
                unlinkOwnedDestination(
                    marker.destination_fd,
                    marker.parent_fd,
                    marker.staging_name,
                );
                _ = syncDescriptor(marker.parent_fd);
            }
            _ = c.close(marker.destination_fd);
            _ = c.close(marker.original_fd);
            _ = c.close(marker.parent_fd);
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
        const bytes = payload.slice();
        if (bytes.len == 9 and bytes[0] == 1) {
            const parent_fd: c_int = @bitCast(readUnsigned(u32, bytes[1..5]));
            const destination_fd: c_int = @bitCast(readUnsigned(u32, bytes[5..9]));
            _ = c.close(destination_fd);
            _ = c.close(parent_fd);
        } else if (decodeReplacementMarker(bytes)) |marker| {
            if (marker.original_is_directory) {
                unlinkOwnedDirectory(
                    marker.original_fd,
                    marker.parent_fd,
                    marker.staging_name,
                );
            } else {
                unlinkOwnedDestination(
                    marker.original_fd,
                    marker.parent_fd,
                    marker.staging_name,
                );
            }
            _ = syncDescriptor(marker.parent_fd);
            _ = c.close(marker.destination_fd);
            _ = c.close(marker.original_fd);
            _ = c.close(marker.parent_fd);
        }
        var owned = payload;
        owned.deinit();
    }
}
