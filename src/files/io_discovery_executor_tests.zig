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

test "discovery executor resumes deprioritized cursors without rescanning" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root_path = try makeTempDir(&temp_buffer);

    const first_path = try join(allocator, root_path, "first");
    defer allocator.free(first_path);
    const second_path = try join(allocator, root_path, "second");
    defer allocator.free(second_path);
    const first_file = try join(allocator, first_path, "first.txt");
    defer allocator.free(first_file);
    const second_file = try join(allocator, second_path, "second.txt");
    defer allocator.free(second_file);
    defer {
        _ = c.unlink(first_file);
        _ = c.unlink(second_file);
        _ = c.rmdir(first_path);
        _ = c.rmdir(second_path);
        _ = c.rmdir(root_path);
    }

    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(first_path, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(second_path, 0o700));
    try createFile(first_file);
    try createFile(second_file);

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

    _ = try executor.dispatchReady(&manager);
    try waitForWake(&executor);
    _ = try executor.drainCompletions(&manager);

    const tree = manager.treeIndex(job).?;
    const root_id = tree.root().?;
    try std.testing.expectEqual(@as(usize, 1), tree.getConst(root_id).?.children.items.len);
    const first_discovered = tree.getConst(root_id).?.children.items[0];
    try manager.prioritizeDiscovery(job, first_discovered);

    var iterations: usize = 0;
    while (manager.discoveryComplete(job) != true) : (iterations += 1) {
        if (iterations == 100) return error.DiscoveryDidNotComplete;
        _ = try executor.dispatchReady(&manager);
        try waitForWake(&executor);
        _ = try executor.drainCompletions(&manager);
    }

    try std.testing.expectEqual(@as(usize, 5), tree.count());
    try std.testing.expectEqual(@as(usize, 2), tree.getConst(root_id).?.children.items.len);
    for (tree.getConst(root_id).?.children.items) |directory_id| {
        const directory = tree.getConst(directory_id).?;
        try std.testing.expectEqual(.complete, directory.discovery);
        try std.testing.expectEqual(@as(usize, 1), directory.children.items.len);
    }
}

test "discovery executor uses independent anchors for multiple roots in one Job" {
    const allocator = std.testing.allocator;
    var first_buffer: [256]u8 = undefined;
    var second_buffer: [256]u8 = undefined;
    const first_path = try makeTempDir(&first_buffer);
    const second_path = try makeTempDir(&second_buffer);

    const first_file = try join(allocator, first_path, "first.txt");
    defer allocator.free(first_file);
    const second_file = try join(allocator, second_path, "second.txt");
    defer allocator.free(second_file);
    defer {
        _ = c.unlink(first_file);
        _ = c.unlink(second_file);
        _ = c.rmdir(first_path);
        _ = c.rmdir(second_path);
    }

    try createFile(first_file);
    try createFile(second_file);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(
        job,
        "first",
        .directory,
        .{},
        null,
    );
    const second_root = try manager.addTreeRoot(
        job,
        "second",
        .directory,
        .{},
        null,
    );
    try manager.startRootDiscovery(job, first_root, first_path);
    try manager.startRootDiscovery(job, second_root, second_path);

    var executor = try io_discovery_executor.Executor.init(
        allocator,
        1,
        1,
        1,
    );
    defer executor.deinit();

    var iterations: usize = 0;
    while (manager.discoveryComplete(job) != true) : (iterations += 1) {
        if (iterations == 20) return error.DiscoveryDidNotComplete;
        _ = try executor.dispatchReady(&manager);
        try waitForWake(&executor);
        _ = try executor.drainCompletions(&manager);
    }

    const tree = manager.treeIndex(job).?;
    try std.testing.expectEqual(@as(usize, 4), tree.count());
    try std.testing.expectEqual(@as(usize, 1), tree.getConst(first_root).?.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), tree.getConst(second_root).?.children.items.len);

    const first_child = tree.getConst(first_root).?.children.items[0];
    const second_child = tree.getConst(second_root).?.children.items[0];
    try std.testing.expectEqualStrings(
        "first.txt",
        tree.getConst(first_child).?.name,
    );
    try std.testing.expectEqualStrings(
        "second.txt",
        tree.getConst(second_child).?.name,
    );

    const first_source = try manager.sourcePath(allocator, job, first_child);
    defer allocator.free(first_source);
    const second_source = try manager.sourcePath(allocator, job, second_child);
    defer allocator.free(second_source);
    try std.testing.expectEqualStrings(first_file, first_source);
    try std.testing.expectEqualStrings(second_file, second_source);
}

test "discovery executor interleaves multiple roots under bounded execution" {
    const allocator = std.testing.allocator;
    var first_buffer: [256]u8 = undefined;
    var second_buffer: [256]u8 = undefined;
    const first_path = try makeTempDir(&first_buffer);
    const second_path = try makeTempDir(&second_buffer);

    const first_a = try join(allocator, first_path, "a1");
    defer allocator.free(first_a);
    const first_b = try join(allocator, first_path, "a2");
    defer allocator.free(first_b);
    const second_a = try join(allocator, second_path, "b1");
    defer allocator.free(second_a);
    const second_b = try join(allocator, second_path, "b2");
    defer allocator.free(second_b);

    const first_a_file = try join(allocator, first_a, "a.txt");
    defer allocator.free(first_a_file);
    const first_b_file = try join(allocator, first_b, "b.txt");
    defer allocator.free(first_b_file);
    const second_a_file = try join(allocator, second_a, "c.txt");
    defer allocator.free(second_a_file);
    const second_b_file = try join(allocator, second_b, "d.txt");
    defer allocator.free(second_b_file);

    defer {
        _ = c.unlink(first_a_file);
        _ = c.unlink(first_b_file);
        _ = c.unlink(second_a_file);
        _ = c.unlink(second_b_file);
        _ = c.rmdir(first_a);
        _ = c.rmdir(first_b);
        _ = c.rmdir(second_a);
        _ = c.rmdir(second_b);
        _ = c.rmdir(first_path);
        _ = c.rmdir(second_path);
    }

    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(first_a, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(first_b, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(second_a, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(second_b, 0o700));
    try createFile(first_a_file);
    try createFile(first_b_file);
    try createFile(second_a_file);
    try createFile(second_b_file);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(
        job,
        "first",
        .directory,
        .{},
        null,
    );
    const second_root = try manager.addTreeRoot(
        job,
        "second",
        .directory,
        .{},
        null,
    );
    try manager.startRootDiscovery(job, first_root, first_path);
    try manager.startRootDiscovery(job, second_root, second_path);

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
    try std.testing.expectEqual(@as(usize, 10), tree.count());
    try std.testing.expectEqual(.complete, tree.getConst(first_root).?.discovery);
    try std.testing.expectEqual(.complete, tree.getConst(second_root).?.discovery);
    try std.testing.expectEqual(@as(usize, 2), tree.getConst(first_root).?.children.items.len);
    try std.testing.expectEqual(@as(usize, 2), tree.getConst(second_root).?.children.items.len);

    var saw_a1 = false;
    var saw_a2 = false;
    var saw_b1 = false;
    var saw_b2 = false;

    for (tree.getConst(first_root).?.children.items) |directory_id| {
        const directory = tree.getConst(directory_id).?;
        try std.testing.expectEqual(.complete, directory.discovery);
        try std.testing.expectEqual(@as(usize, 1), directory.children.items.len);
        const child_id = directory.children.items[0];
        const source = try manager.sourcePath(allocator, job, child_id);
        defer allocator.free(source);

        if (std.mem.eql(u8, directory.name, "a1")) {
            saw_a1 = true;
            try std.testing.expectEqualStrings(first_a_file, source);
        } else if (std.mem.eql(u8, directory.name, "a2")) {
            saw_a2 = true;
            try std.testing.expectEqualStrings(first_b_file, source);
        } else {
            return error.UnexpectedDiscoveredDirectory;
        }
    }

    for (tree.getConst(second_root).?.children.items) |directory_id| {
        const directory = tree.getConst(directory_id).?;
        try std.testing.expectEqual(.complete, directory.discovery);
        try std.testing.expectEqual(@as(usize, 1), directory.children.items.len);
        const child_id = directory.children.items[0];
        const source = try manager.sourcePath(allocator, job, child_id);
        defer allocator.free(source);

        if (std.mem.eql(u8, directory.name, "b1")) {
            saw_b1 = true;
            try std.testing.expectEqualStrings(second_a_file, source);
        } else if (std.mem.eql(u8, directory.name, "b2")) {
            saw_b2 = true;
            try std.testing.expectEqualStrings(second_b_file, source);
        } else {
            return error.UnexpectedDiscoveredDirectory;
        }
    }

    try std.testing.expect(saw_a1);
    try std.testing.expect(saw_a2);
    try std.testing.expect(saw_b1);
    try std.testing.expect(saw_b2);
}

test "discovery executor isolates a failed root from another root in the same Job" {
    const allocator = std.testing.allocator;
    var missing_buffer: [256]u8 = undefined;
    var valid_buffer: [256]u8 = undefined;
    const missing_path = try makeTempDir(&missing_buffer);
    const valid_path = try makeTempDir(&valid_buffer);

    // Keep the pathname but remove the directory so Anchor.open fails
    // deterministically, independent of the test process's privileges.
    try std.testing.expectEqual(@as(c_int, 0), c.rmdir(missing_path));

    const valid_file = try join(allocator, valid_path, "valid.txt");
    defer allocator.free(valid_file);
    defer {
        _ = c.unlink(valid_file);
        _ = c.rmdir(valid_path);
    }
    try createFile(valid_file);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const failed_root = try manager.addTreeRoot(
        job,
        "missing",
        .directory,
        .{},
        null,
    );
    const valid_root = try manager.addTreeRoot(
        job,
        "valid",
        .directory,
        .{},
        null,
    );
    try manager.startRootDiscovery(job, failed_root, missing_path);
    try manager.startRootDiscovery(job, valid_root, valid_path);

    var executor = try io_discovery_executor.Executor.init(
        allocator,
        1,
        1,
        1,
    );
    defer executor.deinit();

    var iterations: usize = 0;
    while (manager.discoveryComplete(job) != true) : (iterations += 1) {
        if (iterations == 20) return error.DiscoveryDidNotComplete;
        _ = try executor.dispatchReady(&manager);
        try waitForWake(&executor);
        _ = try executor.drainCompletions(&manager);
    }

    const tree = manager.treeIndex(job).?;
    try std.testing.expectEqual(.failed, tree.getConst(failed_root).?.discovery);
    try std.testing.expectEqual(.complete, tree.getConst(valid_root).?.discovery);
    try std.testing.expectEqual(@as(usize, 0), tree.getConst(failed_root).?.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), tree.getConst(valid_root).?.children.items.len);

    const valid_child = tree.getConst(valid_root).?.children.items[0];
    try std.testing.expectEqualStrings("valid.txt", tree.getConst(valid_child).?.name);
    const resolved_path = try manager.sourcePath(allocator, job, valid_child);
    defer allocator.free(resolved_path);
    try std.testing.expectEqualStrings(valid_file, resolved_path);
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);
}

test "cancelled discovery releases retained cursors and root anchors" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root_path = try makeTempDir(&temp_buffer);

    const first_file = try join(allocator, root_path, "first.txt");
    defer allocator.free(first_file);
    const second_file = try join(allocator, root_path, "second.txt");
    defer allocator.free(second_file);
    defer {
        _ = c.unlink(first_file);
        _ = c.unlink(second_file);
        _ = c.rmdir(root_path);
    }
    try createFile(first_file);
    try createFile(second_file);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, root_path);
    try manager.queueJob(job);

    var executor = try io_discovery_executor.Executor.init(
        allocator,
        1,
        1,
        1,
    );
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    try std.testing.expect(!executor.isJobQuiescent(job));
    try waitForWake(&executor);
    try std.testing.expect(!executor.isJobQuiescent(job));
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));
    try std.testing.expectEqual(@as(usize, 1), executor.anchors.count());
    try std.testing.expectEqual(@as(usize, 1), executor.cursors.get(job).?.count());
    try std.testing.expect(!executor.isJobQuiescent(job));

    try manager.cancelJob(job);
    executor.cancelJob(&manager, job);

    try std.testing.expect(executor.isJobQuiescent(job));
    try std.testing.expectEqual(@as(usize, 0), executor.anchors.count());
    try std.testing.expect(executor.cursors.get(job) == null);
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);
}

test "stale discovery completion releases its cursor and root anchor after cancellation" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const root_path = try makeTempDir(&temp_buffer);

    const first_file = try join(allocator, root_path, "first.txt");
    defer allocator.free(first_file);
    const second_file = try join(allocator, root_path, "second.txt");
    defer allocator.free(second_file);
    defer {
        _ = c.unlink(first_file);
        _ = c.unlink(second_file);
        _ = c.rmdir(root_path);
    }
    try createFile(first_file);
    try createFile(second_file);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, root_path);
    try manager.queueJob(job);

    var executor = try io_discovery_executor.Executor.init(
        allocator,
        1,
        1,
        1,
    );
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    try waitForWake(&executor);
    try std.testing.expectEqual(@as(usize, 1), executor.anchors.count());

    // Leave the completion in the pool so the executor must reject its stale
    // token and release the returned cursor while reconciling it.
    try manager.cancelJob(job);
    try std.testing.expect(!executor.isJobQuiescent(job));
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));

    try std.testing.expect(executor.isJobQuiescent(job));
    try std.testing.expectEqual(@as(usize, 0), executor.anchors.count());
    try std.testing.expect(executor.cursors.get(job) == null);
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);
}
