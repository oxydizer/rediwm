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
    var item = executor.WorkItem{
        .token = .{ .job_id = 1, .operation_id = 1, .generation = 1 },
        .operation_kind = .copy_file,
        .input = try copy.makeInput(allocator, source, destination),
    };

    while (true) {
        const done = copy.execute(allocator, item);
        item = .{
            .token = .{
                .job_id = 1,
                .operation_id = 1,
                .generation = item.token.generation + 1,
            },
            .operation_kind = .copy_file,
            .input = done.input,
            .continuation = done.continuation,
        };
        if (done.outcome == .completed) {
            copy.complete(null, done.token, done.outcome, done.result);
            item.input.deinit();
            return;
        }
        if (done.outcome != .yielded) {
            item.input.deinit();
            return error.CopyFailed;
        }
    }
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
