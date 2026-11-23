const std = @import("std");
const c = @import("c.zig").api;
const finalize = @import("io_finalize.zig");
const io_executor = @import("io_executor.zig");

fn allocZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

fn join(
    allocator: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn makeTempDir(buffer: []u8) ![]const u8 {
    const template = "/tmp/rediwm_io_finalize_XXXXXX\x00";
    @memcpy(buffer[0..template.len], template);
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

fn makeDirectory(path: []const u8, mode: c_uint) !void {
    const path_z = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_z);
    if (c.mkdir(path_z, mode) != 0) return error.MkdirFailed;
}

fn chmodPath(path: []const u8, mode: c_uint) !void {
    const path_z = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_z);
    if (c.chmod(path_z, mode) != 0) return error.ChmodFailed;
}

fn removeDirectory(path: []const u8) void {
    const path_z = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(path_z);
    _ = c.rmdir(path_z);
}

fn removeSymlink(path: []const u8) void {
    const path_z = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(path_z);
    _ = c.unlink(path_z);
}

fn identity(path: []const u8) !struct { device_id: u64, inode_id: u64 } {
    const path_z = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_z);
    var stat: c.struct_stat = undefined;
    if (c.lstat(path_z, &stat) != 0) return error.StatFailed;
    return .{
        .device_id = @intCast(stat.st_dev),
        .inode_id = @intCast(stat.st_ino),
    };
}

fn modeOf(path: []const u8) !u32 {
    const path_z = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_z);
    var stat: c.struct_stat = undefined;
    if (c.lstat(path_z, &stat) != 0) return error.StatFailed;
    return @intCast(stat.st_mode & 0o777);
}

fn openDirectory(path: []const u8) !c_int {
    const path_z = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_z);
    const fd = c.open(path_z, c.O_PATH | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn modeOfFd(fd: c_int) !u32 {
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.StatFailed;
    return @intCast(stat.st_mode & 0o777);
}

fn run(records: []const finalize.Record) !finalize.Stats {
    var input = try finalize.makeInput(std.testing.allocator, records);
    defer input.deinit();
    return finalize.execute(std.testing.allocator, &input);
}

test "finalization restores nested directories deepest-first" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer removeDirectory(temp);

    const parent = try join(allocator, temp, "parent");
    defer allocator.free(parent);
    const child = try join(allocator, parent, "child");
    defer allocator.free(child);
    defer {
        chmodPath(parent, 0o700) catch {};
        removeDirectory(child);
        removeDirectory(parent);
    }

    try makeDirectory(parent, 0o755);
    try makeDirectory(child, 0o755);
    const parent_id = try identity(parent);
    const child_id = try identity(child);
    const child_fd = try openDirectory(child);
    defer _ = c.close(child_fd);

    const stats = try run(&.{
        .{
            .path = parent,
            .device_id = parent_id.device_id,
            .inode_id = parent_id.inode_id,
            .mode = 0,
        },
        .{
            .path = child,
            .device_id = child_id.device_id,
            .inode_id = child_id.inode_id,
            .mode = 0o700,
        },
    });

    try std.testing.expectEqual(@as(usize, 2), stats.restored);
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
    try std.testing.expectEqual(@as(u32, 0), try modeOf(parent));
    try std.testing.expectEqual(@as(u32, 0o700), try modeOfFd(child_fd));
}

test "finalization can chmod a directory without read permission" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer removeDirectory(temp);

    const target = try join(allocator, temp, "target");
    defer allocator.free(target);
    defer {
        chmodPath(target, 0o700) catch {};
        removeDirectory(target);
    }

    try makeDirectory(target, 0o300);
    const target_id = try identity(target);
    const stats = try run(&.{
        .{
            .path = target,
            .device_id = target_id.device_id,
            .inode_id = target_id.inode_id,
            .mode = 0,
        },
    });

    try std.testing.expectEqual(@as(usize, 1), stats.restored);
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
    try std.testing.expectEqual(@as(u32, 0), try modeOf(target));
}

test "finalization rejects symlink traversal and continues with other records" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer removeDirectory(temp);

    const target = try join(allocator, temp, "target");
    defer allocator.free(target);
    const alias = try join(allocator, temp, "alias");
    defer allocator.free(alias);
    const valid = try join(allocator, temp, "valid");
    defer allocator.free(valid);
    defer {
        removeSymlink(alias);
        removeDirectory(valid);
        removeDirectory(target);
    }

    try makeDirectory(target, 0o755);
    const original_mode = try modeOf(target);
    try makeDirectory(valid, 0o755);
    const alias_z = try allocZ(allocator, alias);
    defer allocator.free(alias_z);
    const target_z = try allocZ(allocator, target);
    defer allocator.free(target_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(target_z, alias_z));

    const target_id = try identity(target);
    const valid_id = try identity(valid);
    const stats = try run(&.{
        .{
            .path = alias,
            .device_id = target_id.device_id,
            .inode_id = target_id.inode_id,
            .mode = 0,
        },
        .{
            .path = valid,
            .device_id = valid_id.device_id,
            .inode_id = valid_id.inode_id,
            .mode = 0o700,
        },
    });

    try std.testing.expectEqual(@as(usize, 1), stats.restored);
    try std.testing.expectEqual(@as(usize, 1), stats.failed);
    try std.testing.expectEqual(original_mode, try modeOf(target));
    try std.testing.expectEqual(@as(u32, 0o700), try modeOf(valid));
}

test "finalization refuses to chmod a replacement directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer removeDirectory(temp);

    const target = try join(allocator, temp, "target");
    defer allocator.free(target);
    const old = try join(allocator, temp, "old");
    defer allocator.free(old);
    defer {
        chmodPath(target, 0o700) catch {};
        removeDirectory(target);
        removeDirectory(old);
    }

    try makeDirectory(target, 0o755);
    const original_id = try identity(target);
    const target_z = try allocZ(allocator, target);
    defer allocator.free(target_z);
    const old_z = try allocZ(allocator, old);
    defer allocator.free(old_z);
    try std.testing.expectEqual(@as(c_int, 0), c.rename(target_z, old_z));
    try makeDirectory(target, 0o755);
    const replacement_mode = try modeOf(target);

    const stats = try run(&.{
        .{
            .path = target,
            .device_id = original_id.device_id,
            .inode_id = original_id.inode_id,
            .mode = 0,
        },
    });

    try std.testing.expectEqual(@as(usize, 0), stats.restored);
    try std.testing.expectEqual(@as(usize, 1), stats.failed);
    try std.testing.expectEqual(replacement_mode, try modeOf(target));
}
