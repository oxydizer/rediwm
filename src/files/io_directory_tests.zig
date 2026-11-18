const std = @import("std");
const c = @import("c.zig").api;
const directory = @import("io_directory.zig");
const executor = @import("io_executor.zig");

fn allocZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

fn makeTempDir(buffer: []u8) ![]const u8 {
    const template = "/tmp/rediwm_io_directory_XXXXXX\x00";
    @memcpy(buffer[0..template.len], template);
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

fn join(
    allocator: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn cleanupDirectory(path: []const u8) void {
    const zpath = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(zpath);
    _ = c.rmdir(zpath);
}

fn cleanupFile(path: []const u8) void {
    const zpath = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(zpath);
    _ = c.unlink(zpath);
}

fn runDirectory(
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
) !executor.WorkCompletion {
    return directory.execute(allocator, .{
        .token = .{ .job_id = 1, .operation_id = 1, .generation = 1 },
        .operation_kind = .create_directory,
        .input = try directory.makeInput(allocator, source, destination),
    });
}

test "directory creation creates a new destination directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    defer cleanupDirectory(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    defer cleanupDirectory(destination);
    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(source_z, 0o700));

    var completion = try runDirectory(allocator, source, destination);
    defer {
        directory.complete(null, completion.token, completion.outcome, completion.result);
        completion.input.deinit();
    }
    try std.testing.expectEqual(executor.WorkResult.completed, completion.outcome);

    const destination_z = try allocZ(allocator, destination);
    defer allocator.free(destination_z);
    const fd = c.open(destination_z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
    try std.testing.expect(fd >= 0);
    _ = c.close(fd);
}

test "directory collision waits and preserves the existing destination" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    defer cleanupDirectory(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    defer cleanupDirectory(destination);
    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    const destination_z = try allocZ(allocator, destination);
    defer allocator.free(destination_z);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(source_z, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(destination_z, 0o700));

    var completion = try runDirectory(allocator, source, destination);
    defer {
        directory.complete(null, completion.token, completion.outcome, completion.result);
        completion.input.deinit();
    }
    try std.testing.expectEqual(executor.WorkResult.waiting, completion.outcome);
    try std.testing.expect(completion.result != null);

    const fd = c.open(destination_z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
    try std.testing.expect(fd >= 0);
    _ = c.close(fd);
}

test "directory creation rejects a symlink source" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const target = try join(allocator, temp, "target");
    defer allocator.free(target);
    defer cleanupDirectory(target);
    const source = try join(allocator, temp, "source-link");
    defer allocator.free(source);
    defer cleanupFile(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    const target_z = try allocZ(allocator, target);
    defer allocator.free(target_z);
    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(target_z, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(target_z, source_z));

    const completion = try runDirectory(allocator, source, destination);
    defer {
        directory.discard(null, completion.operation_kind, completion.input, completion.continuation, completion.result);
    }
    try std.testing.expectEqual(executor.WorkResult.failed, completion.outcome);
}

test "stale successful directory completion removes only its empty directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    defer cleanupDirectory(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    const destination_z = try allocZ(allocator, destination);
    defer allocator.free(destination_z);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(source_z, 0o700));

    const completion = try runDirectory(allocator, source, destination);
    try std.testing.expectEqual(executor.WorkResult.completed, completion.outcome);
    directory.discard(
        null,
        completion.operation_kind,
        completion.input,
        completion.continuation,
        completion.result,
    );

    const fd = c.open(destination_z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    try std.testing.expect(fd < 0);
}
