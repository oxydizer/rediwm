const std = @import("std");
const c = @import("c.zig").api;
const io_manager = @import("io_manager.zig");
const io_tree = @import("io_tree.zig");
const operation_executor = @import("io_operation_executor.zig");

fn allocZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

fn makeTempDir(buffer: []u8) ![]const u8 {
    const template = "/tmp/rediwm_io_runtime_XXXXXX\x00";
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

fn makeDirectory(path: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    if (c.mkdir(zpath, 0o755) != 0) return error.MkdirFailed;
}

fn makeSymlink(target: []const u8, path: []const u8) !void {
    const allocator = std.testing.allocator;
    const ztarget = try allocZ(allocator, target);
    defer allocator.free(ztarget);
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    if (c.symlink(ztarget, zpath) != 0) return error.SymlinkFailed;
}

fn readLink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    var buffer: [4096]u8 = undefined;
    const count = c.readlink(zpath, &buffer, buffer.len);
    if (count < 0) return error.ReadlinkFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    const fd = c.open(
        zpath,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    const count = c.write(fd, contents.ptr, contents.len);
    if (count != contents.len) return error.WriteFailed;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    const fd = c.open(zpath, c.O_RDONLY | c.O_CLOEXEC, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var buffer: [4096]u8 = undefined;
    const count = c.read(fd, &buffer, buffer.len);
    if (count < 0) return error.ReadFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn cleanup(path: []const u8, directory: bool) void {
    const zpath = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(zpath);
    if (directory) {
        _ = c.rmdir(zpath);
    } else {
        _ = c.unlink(zpath);
    }
}

fn waitForOne(runtime: *operation_executor.Runtime) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = runtime.wakeFd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const rc = std.posix.system.poll(&descriptors, 1, 5_000);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TimedOutWaitingForExecutor;
                _ = runtime.drainWake();
                return;
            },
            .INTR => continue,
            else => return error.ExecutorPollFailed,
        }
    }
}

test "Manager operations execute directory creation before dependent symlink and file work" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    defer cleanup(source, true);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    defer cleanup(destination_base, true);
    try makeDirectory(source);
    try makeDirectory(destination_base);

    const source_link = try join(allocator, source, "relative-link");
    defer allocator.free(source_link);
    defer cleanup(source_link, false);
    try makeSymlink("../missing/target", source_link);

    const source_file = try join(allocator, source, "payload.txt");
    defer allocator.free(source_file);
    defer cleanup(source_file, false);
    try writeFile(source_file, "executor integration");

    const destination_root = try join(allocator, destination_base, "source");
    defer allocator.free(destination_root);
    defer cleanup(destination_root, true);
    const destination_link = try join(allocator, destination_root, "relative-link");
    defer allocator.free(destination_link);
    defer cleanup(destination_link, false);
    const destination_file = try join(allocator, destination_root, "payload.txt");
    defer allocator.free(destination_file);
    defer cleanup(destination_file, false);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root_id = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .mode = 0o755 },
        null,
    );
    const link_id = try manager.addTreeEntry(
        job,
        root_id,
        "relative-link",
        .symlink,
        .{},
        "../missing/target",
    );
    const file_id = try manager.addTreeEntry(
        job,
        root_id,
        "payload.txt",
        .regular_file,
        .{},
        null,
    );
    try manager.startDiscovery(job, source);
    try manager.setDestinationDirectory(job, destination_base);

    const directory_operation = try manager.addEntryOperation(job, root_id, .create_directory);
    const symlink_operation = try manager.addEntryOperation(job, link_id, .copy_symlink);
    const file_operation = try manager.addEntryOperation(job, file_id, .copy_file);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, directory_operation).?,
    );

    // The parent directory completion unlocks its children. Symlink work
    // has higher scheduler priority than regular-file copying.
    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, symlink_operation).?,
    );

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, file_operation).?,
    );

    const stored_target = try readLink(allocator, destination_link);
    defer allocator.free(stored_target);
    try std.testing.expectEqualStrings("../missing/target", stored_target);

    const copied_contents = try readFile(allocator, destination_file);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings("executor integration", copied_contents);
}

test "Manager Runtime copies a standalone regular-file root" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source = try join(allocator, temp, "payload.bin");
    defer allocator.free(source);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try join(allocator, destination_dir, "payload.bin");
    defer allocator.free(destination);
    defer {
        cleanup(destination, false);
        cleanup(source, false);
        cleanup(destination_dir, true);
        cleanup(temp, true);
    }

    try makeDirectory(destination_dir);
    try writeFile(source, "standalone Manager copy");

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{},
        null,
    );
    try manager.setSourceRootPath(job, source);
    try manager.setDestinationDirectory(job, destination_dir);
    _ = try manager.addEntryOperation(job, root, .copy_file);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    while (!manager.jobState(job).?.isTerminal()) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    const copied_contents = try readFile(allocator, destination);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings("standalone Manager copy", copied_contents);
}
