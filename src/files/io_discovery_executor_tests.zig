const std = @import("std");
const c = @import("c.zig").api;
const io_manager = @import("io_manager.zig");
const io_discovery_executor = @import("io_discovery_executor.zig");

fn makeTempDir(buffer: []u8) ![:0]const u8 {
    const template = "/tmp/rediwm_io_discovery_executor_XXXXXX\x00";
    @memcpy(buffer[0..template.len], template);
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(result);
}

fn join(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![:0]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
    defer allocator.free(raw);
    return try allocator.dupeSentinel(u8, raw, 0);
}

fn createFile(path: [:0]const u8) !void {
    const fd = c.open(
        path,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.FileCreateFailed;
    _ = c.close(fd);
}

fn waitForWake(executor: *io_discovery_executor.Executor) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = executor.wakeFd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const rc = std.posix.system.poll(&descriptors, 1, 5_000);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TimedOutWaitingForDiscovery;
                _ = executor.drainWake();
                return;
            },
            .INTR => continue,
            else => return error.DiscoveryPollFailed,
        }
    }
}

test "discovery executor transfers resumable cursors and completes breadth first" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root_path = try makeTempDir(&temp_buffer);
    defer {
        const nested_path = join(allocator, root_path, "nested") catch unreachable;
        defer allocator.free(nested_path);
        const nested_file = join(allocator, nested_path, "inside.txt") catch unreachable;
        defer allocator.free(nested_file);
        _ = c.unlink(nested_file);
        _ = c.rmdir(nested_path);
        const root_file = join(allocator, root_path, "root.txt") catch unreachable;
        defer allocator.free(root_file);
        _ = c.unlink(root_file);
        _ = c.rmdir(root_path);
    }

    const nested_path = try join(allocator, root_path, "nested");
    defer allocator.free(nested_path);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested_path, 0o700));
    const root_file = try join(allocator, root_path, "root.txt");
    defer allocator.free(root_file);
    try createFile(root_file);
    const nested_file = try join(allocator, nested_path, "inside.txt");
    defer allocator.free(nested_file);
    try createFile(nested_file);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, root_path);

    var executor = try io_discovery_executor.Executor.init(
        allocator,
        1,
        1,
        1,
    );
    defer executor.deinit();

    var iterations: usize = 0;
    while (manager.discoveryComplete(job) != true) : (iterations += 1) {
        if (iterations == 100) return error.DiscoveryDidNotComplete;
        _ = try executor.dispatchReady(&manager);
        try waitForWake(&executor);
        _ = try executor.drainCompletions(&manager);
    }

    const tree = manager.treeIndex(job).?;
    try std.testing.expectEqual(@as(usize, 4), tree.count());

    const root_id = tree.root().?;
    var saw_nested = false;
    var saw_root_file = false;
    for (tree.getConst(root_id).?.children.items) |child_id| {
        const child = tree.getConst(child_id).?;
        if (std.mem.eql(u8, child.name, "nested")) {
            saw_nested = true;
            try std.testing.expectEqual(.complete, child.discovery);
            try std.testing.expectEqual(@as(usize, 1), child.children.items.len);
            try std.testing.expectEqualStrings(
                "inside.txt",
                tree.getConst(child.children.items[0]).?.name,
            );
        } else if (std.mem.eql(u8, child.name, "root.txt")) {
            saw_root_file = true;
        }
    }
    try std.testing.expect(saw_nested);
    try std.testing.expect(saw_root_file);
}

test "discovery executor rejects an invalid batch size" {
    try std.testing.expectError(
        error.InvalidBatchSize,
        io_discovery_executor.Executor.init(std.testing.allocator, 1, 1, 0),
    );
}
