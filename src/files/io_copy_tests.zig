const std = @import("std");
const c = @import("c.zig").api;
const copy = @import("io_copy.zig");
const executor = @import("io_executor.zig");

fn makeTempDir(buffer: []u8) ![]const u8 {
    const template = "/tmp/rediwm_io_copy_XXXXXX\x00";
    @memcpy(buffer[0..template.len], template);
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn cleanupTemp(
    allocator: std.mem.Allocator,
    directory: []const u8,
    names: []const []const u8,
) void {
    for (names) |name| {
        const path = join(allocator, directory, name) catch continue;
        defer allocator.free(path);
        const zpath = allocator.dupeSentinel(u8, path, 0) catch continue;
        defer allocator.free(zpath);
        _ = c.unlink(zpath);
    }
    const zdir = allocator.dupeSentinel(u8, directory, 0) catch return;
    defer allocator.free(zdir);
    _ = c.rmdir(zdir);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    const fd = c.open(
        zpath,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}

fn readFile(path: []const u8, buffer: []u8) !usize {
    const allocator = std.testing.allocator;
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    const fd = c.open(
        zpath,
        c.O_RDONLY | c.O_CLOEXEC,
        @as(c_uint, 0),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    const count = c.read(fd, buffer.ptr, buffer.len);
    if (count < 0) return error.ReadFailed;
    return @intCast(count);
}

fn runCopy(
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
) !void {
    return runCopyWithMetrics(allocator, source, destination, null, false);
}

fn executeToTerminal(
    allocator: std.mem.Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var item = item_arg;
    while (true) {
        const done = copy.execute(allocator, item);
        if (done.outcome != .yielded) return done;
        item = .{
            .token = .{
                .job_id = done.token.job_id,
                .operation_id = done.token.operation_id,
                .generation = done.token.generation + 1,
            },
            .operation_kind = done.operation_kind,
            .input = done.input,
            .continuation = done.continuation,
        };
    }
}

fn runCopyWithMetrics(
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
    metrics_out: ?*executor.CopyMetrics,
    profile_enabled: bool,
) !void {
    var item = executor.WorkItem{
        .token = .{ .job_id = 1, .operation_id = 1, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeInput(allocator, source, destination, .{
            .job_id = 1,
            .operation_id = 1,
            .generation = 1,
        }),
        .profile_enabled = profile_enabled,
    };

    while (true) {
        const done = copy.execute(allocator, item);
        if (metrics_out) |total| {
            if (done.copy_metrics) |delta| total.add(delta);
        }
        if (done.outcome == .completed) {
            copy.complete(null, done.token, done.outcome, done.result);
            var owned_input = done.input;
            owned_input.deinit();
            return;
        }
        if (done.outcome != .yielded) {
            copy.discard(
                null,
                done.operation_kind,
                done.input,
                done.continuation,
                done.result,
            );
            return error.CopyFailed;
        }
        item = .{
            .token = .{
                .job_id = 1,
                .operation_id = 1,
                .generation = done.token.generation + 1,
            },
            .operation_kind = done.operation_kind,
            .input = done.input,
            .continuation = done.continuation,
            .profile_enabled = profile_enabled,
        };
    }
}

test "adaptive buffered copy size follows file size and stays bounded" {
    try std.testing.expectEqual(@as(usize, 0), copy.bufferedBufferSize(0));
    try std.testing.expectEqual(@as(usize, 1), copy.bufferedBufferSize(1));
    try std.testing.expectEqual(@as(usize, 16 * 1024), copy.bufferedBufferSize(16 * 1024));
    try std.testing.expectEqual(@as(usize, 16 * 1024), copy.bufferedBufferSize(64 * 1024));
    try std.testing.expectEqual(@as(usize, 64 * 1024), copy.bufferedBufferSize(64 * 1024 + 1));
    try std.testing.expectEqual(@as(usize, 64 * 1024), copy.bufferedBufferSize(1024 * 1024));
    try std.testing.expectEqual(@as(usize, 256 * 1024), copy.bufferedBufferSize(1024 * 1024 + 1));
    try std.testing.expectEqual(@as(usize, 256 * 1024), copy.bufferedBufferSize(64 * 1024 * 1024));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), copy.bufferedBufferSize(64 * 1024 * 1024 + 1));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), copy.bufferedBufferSize(128 * 1024 * 1024));
}

test "regular-file copy handles empty and small files" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "small copy payload");
    try runCopy(allocator, source, destination);

    var buffer: [128]u8 = undefined;
    const count = try readFile(destination, &buffer);
    try std.testing.expectEqualStrings("small copy payload", buffer[0..count]);
}

test "regular-file copy yields across multiple bounded units" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    const contents = try allocator.alloc(u8, copy.chunk_size * 3 + 17);
    defer allocator.free(contents);
    for (contents, 0..) |*byte, index| byte.* = @truncate(index *% 37);
    try writeFile(source, contents);
    try runCopy(allocator, source, destination);

    const copied = try allocator.alloc(u8, contents.len);
    defer allocator.free(copied);
    const count = try readFile(destination, copied);
    try std.testing.expectEqual(contents.len, count);
    try std.testing.expectEqualSlices(u8, contents, copied[0..count]);
}

test "regular-file copy reports exact byte progress with each yielded unit" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    const contents = try allocator.alloc(u8, copy.chunk_size * 2 + 17);
    defer allocator.free(contents);
    @memset(contents, 0x5a);
    try writeFile(source, contents);

    const item = executor.WorkItem{
        .token = .{ .job_id = 1, .operation_id = 1, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeInput(allocator, source, destination, .{
            .job_id = 1,
            .operation_id = 1,
            .generation = 1,
        }),
    };
    const result = copy.execute(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.yielded, result.outcome);
    const progress = result.progress orelse return error.MissingCopyProgress;
    try std.testing.expectEqual(@as(u64, copy.chunk_size), progress.bytes);
    try std.testing.expectEqual(@as(u64, contents.len), progress.total_bytes);
    try std.testing.expectEqual(executor.CopyPhase.transferring, progress.phase);
    var destination_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.OpenFailed,
        readFile(destination, &destination_buffer),
    );
    copy.discard(
        null,
        result.operation_kind,
        result.input,
        result.continuation,
        result.result,
    );
}

test "regular-file copy yields a flushing phase before completion" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "flush before reporting completion");
    const item = executor.WorkItem{
        .token = .{ .job_id = 9, .operation_id = 5, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeInput(allocator, source, destination, .{
            .job_id = 9,
            .operation_id = 5,
            .generation = 1,
        }),
    };
    const flushing = copy.execute(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.yielded, flushing.outcome);
    const progress = flushing.progress orelse return error.MissingCopyProgress;
    try std.testing.expectEqual(executor.CopyPhase.flushing, progress.phase);
    try std.testing.expectEqual(progress.total_bytes, progress.bytes);

    const completed = copy.execute(allocator, .{
        .token = .{
            .job_id = flushing.token.job_id,
            .operation_id = flushing.token.operation_id,
            .generation = flushing.token.generation + 1,
        },
        .operation_kind = flushing.operation_kind,
        .input = flushing.input,
        .continuation = flushing.continuation,
    });
    try std.testing.expectEqual(executor.WorkResult.completed, completed.outcome);
    copy.complete(null, completed.token, completed.outcome, completed.result);
    var owned_input = completed.input;
    owned_input.deinit();
}

test "existing destination is never overwritten" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "source");
    try writeFile(destination, "keep me");

    try std.testing.expectError(
        error.CopyFailed,
        runCopy(allocator, source, destination),
    );

    var buffer: [32]u8 = undefined;
    const count = try readFile(destination, &buffer);
    try std.testing.expectEqualStrings("keep me", buffer[0..count]);
}

test "symlink source is rejected" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"target", "link", "destination"});

    const target = try join(allocator, temp, "target");
    defer allocator.free(target);
    const source = try join(allocator, temp, "link");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(target, "target");
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);
    const target_z = try allocator.dupeSentinel(u8, target, 0);
    defer allocator.free(target_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(target_z, source_z));

    try std.testing.expectError(
        error.CopyFailed,
        runCopy(allocator, source, destination),
    );
}

test "stale yielded copy closes descriptors and removes partial destination" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    const contents = try allocator.alloc(u8, copy.chunk_size * 2);
    defer allocator.free(contents);
    @memset(contents, 0x5a);
    try writeFile(source, contents);

    const item = executor.WorkItem{
        .token = .{ .job_id = 7, .operation_id = 3, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeInput(allocator, source, destination, .{
            .job_id = 7,
            .operation_id = 3,
            .generation = 1,
        }),
    };
    const done = copy.execute(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.yielded, done.outcome);
    try std.testing.expect(done.continuation != null);

    copy.discard(null, done.operation_kind, done.input, done.continuation, done.result);

    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.OpenFailed, readFile(destination, &buffer));
}

test "stale completed copy removes destination before acceptance" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "completed but stale");
    const item = executor.WorkItem{
        .token = .{ .job_id = 8, .operation_id = 4, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeInput(allocator, source, destination, .{
            .job_id = 8,
            .operation_id = 4,
            .generation = 1,
        }),
    };
    const done = executeToTerminal(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.completed, done.outcome);
    try std.testing.expect(done.result != null);

    copy.discard(null, done.operation_kind, done.input, done.continuation, done.result);

    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.OpenFailed, readFile(destination, &buffer));
}

test "stale completed copy does not remove a replacement destination" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "operation-owned file");
    const item = executor.WorkItem{
        .token = .{ .job_id = 10, .operation_id = 6, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeInput(allocator, source, destination, .{
            .job_id = 10,
            .operation_id = 6,
            .generation = 1,
        }),
    };
    const done = executeToTerminal(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.completed, done.outcome);

    const destination_z = try allocator.dupeSentinel(u8, destination, 0);
    defer allocator.free(destination_z);
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(destination_z));
    try writeFile(destination, "replacement must survive");

    copy.discard(null, done.operation_kind, done.input, done.continuation, done.result);

    var buffer: [64]u8 = undefined;
    const count = try readFile(destination, &buffer);
    try std.testing.expectEqualStrings("replacement must survive", buffer[0..count]);
}

test "replacement copy atomically replaces an existing regular file" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(
        allocator,
        temp,
        &.{"source", "destination", ".rediwm-21-7-1.tmp"},
    );
    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "new replacement contents");
    try writeFile(destination, "original contents");
    const item = executor.WorkItem{
        .token = .{ .job_id = 21, .operation_id = 7, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeReplacementInput(
            allocator,
            source,
            destination,
            .{ .job_id = 21, .operation_id = 7, .generation = 1 },
        ),
    };
    const done = executeToTerminal(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.completed, done.outcome);
    try std.testing.expect(done.result != null);
    copy.complete(null, done.token, done.outcome, done.result);

    var buffer: [64]u8 = undefined;
    const count = try readFile(destination, &buffer);
    try std.testing.expectEqualStrings("new replacement contents", buffer[0..count]);
    const staging = try join(allocator, temp, ".rediwm-21-7-1.tmp");
    defer allocator.free(staging);
    try std.testing.expectError(error.OpenFailed, readFile(staging, &buffer));
    var owned_input = done.input;
    owned_input.deinit();
}

test "replacement copy atomically replaces an empty directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(
        allocator,
        temp,
        &.{"source", "destination", ".rediwm-23-9-1.tmp"},
    );
    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "replacement file");
    const destination_z = try allocator.dupeSentinel(u8, destination, 0);
    defer allocator.free(destination_z);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(destination_z, 0o700));

    const item = executor.WorkItem{
        .token = .{ .job_id = 23, .operation_id = 9, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeReplacementInput(
            allocator,
            source,
            destination,
            .{ .job_id = 23, .operation_id = 9, .generation = 1 },
        ),
    };
    const done = executeToTerminal(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.completed, done.outcome);
    try std.testing.expect(done.result != null);
    copy.complete(null, done.token, done.outcome, done.result);

    var buffer: [64]u8 = undefined;
    const count = try readFile(destination, &buffer);
    try std.testing.expectEqualStrings("replacement file", buffer[0..count]);
    var owned_input = done.input;
    owned_input.deinit();
}

test "replacement copy rejects a non-empty destination directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(
        allocator,
        temp,
        &.{"source", "destination", ".rediwm-24-10-1.tmp"},
    );
    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    const child = try join(allocator, destination, "keep");
    defer allocator.free(child);

    try writeFile(source, "replacement file");
    const destination_z = try allocator.dupeSentinel(u8, destination, 0);
    defer allocator.free(destination_z);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(destination_z, 0o700));
    try writeFile(child, "must survive");
    defer {
        const child_z = allocator.dupeSentinel(u8, child, 0) catch unreachable;
        defer allocator.free(child_z);
        _ = c.unlink(child_z);
        _ = c.rmdir(destination_z);
    }

    const item = executor.WorkItem{
        .token = .{ .job_id = 24, .operation_id = 10, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeReplacementInput(
            allocator,
            source,
            destination,
            .{ .job_id = 24, .operation_id = 10, .generation = 1 },
        ),
    };
    const done = executeToTerminal(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.failed, done.outcome);
    var buffer: [64]u8 = undefined;
    const count = try readFile(child, &buffer);
    try std.testing.expectEqualStrings("must survive", buffer[0..count]);
    var owned_input = done.input;
    owned_input.deinit();
}

test "discarded replacement restores the original destination" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(
        allocator,
        temp,
        &.{"source", "destination", ".rediwm-22-8-1.tmp"},
    );
    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    try writeFile(source, "new replacement contents");
    try writeFile(destination, "original contents");
    const item = executor.WorkItem{
        .token = .{ .job_id = 22, .operation_id = 8, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeReplacementInput(
            allocator,
            source,
            destination,
            .{ .job_id = 22, .operation_id = 8, .generation = 1 },
        ),
    };
    const done = executeToTerminal(allocator, item);
    try std.testing.expectEqual(executor.WorkResult.completed, done.outcome);
    copy.discard(null, done.operation_kind, done.input, done.continuation, done.result);

    var buffer: [64]u8 = undefined;
    const count = try readFile(destination, &buffer);
    try std.testing.expectEqualStrings("original contents", buffer[0..count]);
    const staging = try join(allocator, temp, ".rediwm-22-8-1.tmp");
    defer allocator.free(staging);
    try std.testing.expectError(error.OpenFailed, readFile(staging, &buffer));
}

test "copy metrics account for strategy bytes and optional timing" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupTemp(allocator, temp, &.{"source", "destination"});

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);

    const contents = try allocator.alloc(u8, 256 * 1024 + 37);
    defer allocator.free(contents);
    for (contents, 0..) |*byte, index| byte.* = @truncate(index *% 19);
    try writeFile(source, contents);

    var metrics: executor.CopyMetrics = .{};
    try runCopyWithMetrics(allocator, source, destination, &metrics, true);

    try std.testing.expectEqual(@as(u64, 1), metrics.reflink_attempts);
    try std.testing.expectEqual(
        metrics.reflink_attempts,
        metrics.reflink_successes + metrics.reflink_fallbacks,
    );
    try std.testing.expectEqual(
        @as(u64, contents.len),
        metrics.reflink_bytes +
            metrics.copy_file_range_bytes +
            metrics.buffered_read_bytes,
    );
    try std.testing.expectEqual(metrics.buffered_read_bytes, metrics.buffered_write_bytes);
    try std.testing.expect(metrics.elapsed_ns > 0);
}
