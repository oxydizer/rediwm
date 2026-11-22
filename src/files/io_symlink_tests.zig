const std = @import("std");
const c = @import("c.zig").api;
const symlink = @import("io_symlink.zig");
const executor = @import("io_executor.zig");

fn allocZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

fn makeTempDir(buffer: []u8) ![]const u8 {
    const template = "/tmp/rediwm_io_symlink_XXXXXX\x00";
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

fn cleanupLink(path: []const u8) void {
    const zpath = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(zpath);
    _ = c.unlink(zpath);
}

fn readLink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    var buffer: [4096]u8 = undefined;
    const count = c.readlink(zpath, &buffer, buffer.len);
    if (count < 0) return error.ReadlinkFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn runSymlink(
    allocator: std.mem.Allocator,
    target: []const u8,
    destination: []const u8,
) !executor.WorkCompletion {
    return symlink.execute(allocator, .{
        .token = .{ .job_id = 1, .operation_id = 1, .generation = 1 },
        .operation_kind = .copy_symlink,
        .input = try symlink.makeInput(allocator, target, destination),
    });
}

test "symlink creation preserves relative, absolute, and dangling targets literally" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const relative_path = try join(allocator, temp, "relative-link");
    defer allocator.free(relative_path);
    defer cleanupLink(relative_path);
    const absolute_path = try join(allocator, temp, "absolute-link");
    defer allocator.free(absolute_path);
    defer cleanupLink(absolute_path);

    const relative_target = "../missing/relative-target";
    var relative_completion = try runSymlink(allocator, relative_target, relative_path);
    defer {
        symlink.complete(null, relative_completion.token, relative_completion.outcome, relative_completion.result);
        relative_completion.input.deinit();
    }
    try std.testing.expectEqual(executor.WorkResult.completed, relative_completion.outcome);
    const stored_relative = try readLink(allocator, relative_path);
    defer allocator.free(stored_relative);
    try std.testing.expectEqualStrings(relative_target, stored_relative);

    const absolute_target = "/path/that/does/not/exist";
    var absolute_completion = try runSymlink(allocator, absolute_target, absolute_path);
    defer {
        symlink.complete(null, absolute_completion.token, absolute_completion.outcome, absolute_completion.result);
        absolute_completion.input.deinit();
    }
    try std.testing.expectEqual(executor.WorkResult.completed, absolute_completion.outcome);
    const stored_absolute = try readLink(allocator, absolute_path);
    defer allocator.free(stored_absolute);
    try std.testing.expectEqualStrings(absolute_target, stored_absolute);
}

test "symlink collision waits without replacing the existing link" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const destination = try join(allocator, temp, "existing-link");
    defer allocator.free(destination);
    defer cleanupLink(destination);
    const destination_z = try allocZ(allocator, destination);
    defer allocator.free(destination_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("original-target", destination_z));

    var completion = try runSymlink(allocator, "replacement-target", destination);
    defer {
        symlink.complete(null, completion.token, completion.outcome, completion.result);
        completion.input.deinit();
    }
    try std.testing.expectEqual(executor.WorkResult.waiting, completion.outcome);
    try std.testing.expect(completion.result != null);
    const stored = try readLink(allocator, destination);
    defer allocator.free(stored);
    try std.testing.expectEqualStrings("original-target", stored);
}

test "stale successful symlink completion removes the created link" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const destination = try join(allocator, temp, "stale-link");
    defer allocator.free(destination);
    const destination_z = try allocZ(allocator, destination);
    defer allocator.free(destination_z);

    const completion = try runSymlink(allocator, "dangling-target", destination);
    try std.testing.expectEqual(executor.WorkResult.completed, completion.outcome);
    symlink.discard(
        null,
        completion.operation_kind,
        completion.input,
        completion.continuation,
        completion.result,
    );
    try std.testing.expect(c.access(destination_z, c.F_OK) != 0);
}

test "stale symlink completion preserves a same-path replacement" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanupDirectory(temp);

    const destination = try join(allocator, temp, "stale-link");
    defer allocator.free(destination);
    const destination_z = try allocZ(allocator, destination);
    defer allocator.free(destination_z);

    const original = try join(allocator, temp, "original-link");
    defer allocator.free(original);
    const original_z = try allocZ(allocator, original);
    defer allocator.free(original_z);
    defer cleanupLink(original);
    defer cleanupLink(destination);

    const completion = try runSymlink(allocator, "original-target", destination);
    try std.testing.expectEqual(executor.WorkResult.completed, completion.outcome);

    try std.testing.expectEqual(@as(c_int, 0), c.rename(destination_z, original_z));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("replacement-target", destination_z));

    symlink.discard(
        null,
        completion.operation_kind,
        completion.input,
        completion.continuation,
        completion.result,
    );

    const replacement_target = try readLink(allocator, destination);
    defer allocator.free(replacement_target);
    try std.testing.expectEqualStrings("replacement-target", replacement_target);

    const original_target = try readLink(allocator, original);
    defer allocator.free(original_target);
    try std.testing.expectEqualStrings("original-target", original_target);
}

test "symlink input rejects empty, NUL-containing, and relative destinations" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, symlink.makeInput(allocator, "", "/tmp/link"));
    try std.testing.expectError(error.InvalidPath, symlink.makeInput(allocator, "bad\x00target", "/tmp/link"));
    try std.testing.expectError(error.InvalidPath, symlink.makeInput(allocator, "target", "relative/link"));
}
