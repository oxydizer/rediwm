const std = @import("std");
const io_manager = @import("io_manager.zig");
const io_discovery = @import("io_discovery.zig");
const io_tree = @import("io_tree.zig");

fn makeDiscoveryBatch(
    allocator: std.mem.Allocator,
    records: []const struct {
        name: []const u8,
        kind: io_tree.EntryKind,
    },
    complete: bool,
) !io_discovery.Batch {
    var batch: io_discovery.Batch = .{
        .allocator = allocator,
        .complete = complete,
    };
    errdefer batch.deinit();

    for (records) |record| {
        const name = try allocator.dupe(u8, record.name);
        errdefer allocator.free(name);
        try batch.records.append(allocator, .{
            .name = name,
            .kind = record.kind,
        });
    }

    return batch;
}

test "scheduler rotates fairly across Jobs and preserves per-Job FIFO" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_a = try manager.createJob(1);
    const a1 = try manager.addOperation(job_a, .copy_file);
    const a2 = try manager.addOperation(job_a, .publish);
    const job_b = try manager.createJob(2);
    const b1 = try manager.addOperation(job_b, .copy_file);
    try manager.queueJob(job_a);
    try manager.queueJob(job_b);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, first.job_id);
    try std.testing.expectEqual(a1, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .yielded));

    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(job_b, second.job_id);
    try std.testing.expectEqual(b1, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));

    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(a1, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    const fourth = manager.dispatchNext().?;
    try std.testing.expectEqual(a2, fourth.operation_id);
    try std.testing.expect(manager.completeWork(fourth, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_a).?);
}

test "dependencies block descendants but not independent operations" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const parent = try manager.addOperation(job, .create_directory);
    const independent = try manager.addOperation(job, .copy_file);
    const child = try manager.addOperation(job, .copy_file);
    try manager.addDependency(job, child, parent);
    try manager.queueJob(job);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(parent, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .completed));
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(independent, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(child, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "stale and duplicate worker results are rejected" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const operation = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);
    const old_token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(old_token, .yielded));
    const new_token = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, new_token.operation_id);
    try std.testing.expect(new_token.generation > old_token.generation);
    try std.testing.expect(!manager.completeWork(old_token, .completed));
    try std.testing.expect(manager.completeWork(new_token, .completed));
    try std.testing.expect(!manager.completeWork(new_token, .completed));
}

test "waiting Operations release the worker and can be resolved" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const waiting_op = try manager.addOperation(job, .copy_file);
    const independent = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);
    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(waiting_op, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .waiting));
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(independent, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));
    try std.testing.expectEqual(io_manager.JobState.waiting, manager.jobState(job).?);

    try manager.resolveWaiting(job, waiting_op);
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(waiting_op, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "failed dependencies skip descendants" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const parent = try manager.addOperation(job, .copy_file);
    const child = try manager.addOperation(job, .publish);
    try manager.addDependency(job, child, parent);
    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(token, .failed));
    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, child).?);
    try std.testing.expectEqual(io_manager.JobState.failed, manager.jobState(job).?);
}

test "dependency cycles are rejected before queueing" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const first = try manager.addOperation(job, .copy_file);
    const second = try manager.addOperation(job, .publish);
    try manager.addDependency(job, first, second);
    try manager.addDependency(job, second, first);
    try std.testing.expectError(error.DependencyCycle, manager.queueJob(job));
    try std.testing.expectEqual(io_manager.JobState.planning, manager.jobState(job).?);
}

test "pause prevents dispatch and resume restores eligible work" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);
    try manager.pauseJob(job);
    try std.testing.expect(manager.dispatchNext() == null);
    try manager.resumeJob(job);
    try std.testing.expect(manager.dispatchNext() != null);
}

test "snapshots own dependency data and planning closes at queue time" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(42);
    const first = try manager.addOperation(job, .create_directory);
    const second = try manager.addOperation(job, .copy_file);
    try manager.addDependency(job, second, first);
    try manager.queueJob(job);

    var snapshot = try manager.snapshotJob(std.testing.allocator, job);
    defer snapshot.deinit();
    try std.testing.expectEqual(job, snapshot.id);
    try std.testing.expectEqual(@as(?io_manager.WindowId, 42), snapshot.origin_window_id);
    try std.testing.expectEqual(@as(usize, 2), snapshot.operations.len);
    try std.testing.expectEqual(first, snapshot.operations[1].dependencies[0]);
    try std.testing.expectError(error.InvalidJobState, manager.addOperation(job, .publish));
}

test "queued Jobs accept operations as discovery progresses" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job).?);
    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    try std.testing.expectEqual(io_manager.OperationState.pending, manager.operationState(job, root_op).?);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .completed));
}

test "entry operations depend on their destination parent directory" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    const child = try manager.addTreeEntry(job, root, "child", .directory, .{}, null);
    const file = try manager.addTreeEntry(job, child, "file", .regular_file, .{}, null);

    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    const child_op = try manager.addEntryOperation(job, child, .create_directory);
    const file_op = try manager.addEntryOperation(job, file, .copy_file);
    try manager.queueJob(job);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .completed));

    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(child_op, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));

    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(file_op, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
}

test "late entries inherit skipped state from failed destination parents" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    const child = try manager.addTreeEntry(job, root, "child", .directory, .{}, null);
    const file = try manager.addTreeEntry(job, child, "file", .regular_file, .{}, null);

    _ = try manager.startDiscovery(job, "/tmp/source");
    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .failed));

    const child_op = try manager.addEntryOperation(job, child, .create_directory);
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, child_op).?,
    );

    const file_op = try manager.addEntryOperation(job, file, .copy_file);
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, file_op).?,
    );
}

test "directory creation outranks symlinks and regular files" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    const file = try manager.addTreeEntry(job, root, "file", .regular_file, .{}, null);
    const link = try manager.addTreeEntry(job, root, "link", .symlink, .{}, "target");
    const directory = try manager.addTreeEntry(job, root, "directory", .directory, .{}, null);

    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    const file_op = try manager.addEntryOperation(job, file, .copy_file);
    const link_op = try manager.addEntryOperation(job, link, .copy_symlink);
    const directory_op = try manager.addEntryOperation(job, directory, .create_directory);
    try manager.queueJob(job);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .completed));
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(directory_op, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(link_op, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    const fourth = manager.dispatchNext().?;
    try std.testing.expectEqual(file_op, fourth.operation_id);
    try std.testing.expect(manager.completeWork(fourth, .completed));
}

test "Job remains active while discovery has pending work and no operations" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job).?);
}

test "Manager owns an independent TreeIndex for each Job" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(null);
    const second_job = try manager.createJob(null);
    const root_id = try manager.addTreeRoot(first_job, "source", .directory, .{}, null);
    const child_id = try manager.addTreeEntry(first_job, root_id, "child", .regular_file, .{ .size = 42 }, null);
    const second_root = try manager.addTreeRoot(second_job, "other", .directory, .{}, null);

    const first_tree = manager.treeIndex(first_job).?;
    const second_tree = manager.treeIndex(second_job).?;
    try std.testing.expectEqual(@as(usize, 2), first_tree.count());
    try std.testing.expectEqual(@as(usize, 1), second_tree.count());
    try std.testing.expectEqual(child_id, first_tree.getConst(child_id).?.id);
    try std.testing.expectEqual(second_root, second_tree.root().?);
    try std.testing.expectEqualStrings("source", first_tree.getConst(root_id).?.name);
    try std.testing.expectEqualStrings("other", second_tree.getConst(second_root).?.name);

    _ = try manager.addTreeEntry(first_job, root_id, "another-child", .regular_file, .{}, null);
    try std.testing.expectEqual(@as(usize, 3), first_tree.count());
    try std.testing.expectEqual(@as(usize, 1), second_tree.count());
}

test "discovery adopts batches and visits directories breadth first" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    try std.testing.expectEqualStrings(
        "/tmp/source",
        manager.discoveryRootPath(job).?,
    );

    const root_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, root_token.entry_id);

    var root_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "a", .kind = .directory },
        .{ .name = "root.txt", .kind = .regular_file },
        .{ .name = "b", .kind = .directory },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(root_token, &root_batch));

    const tree = manager.treeIndex(job).?;
    try std.testing.expectEqual(@as(usize, 4), tree.count());
    const a_id = tree.getConst(root).?.children.items[0];
    const b_id = tree.getConst(root).?.children.items[2];

    const a_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(a_id, a_token.entry_id);
    var a_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "inside-a", .kind = .regular_file },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(a_token, &a_batch));

    const b_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(b_id, b_token.entry_id);
    var b_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(b_token, &b_batch));

    try std.testing.expect(manager.discoveryComplete(job).?);
    try std.testing.expectEqual(@as(usize, 5), tree.count());
}

test "discovery resumes a partial directory after promoted work" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const first_token = manager.dispatchDiscovery().?;
    var first_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "child", .kind = .directory },
    }, false);
    try std.testing.expect(try manager.completeDiscovery(first_token, &first_batch));

    const child_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(
        manager.treeIndex(job).?.getConst(root).?.children.items[0],
        child_token.entry_id,
    );
    var child_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(child_token, &child_batch));

    const resumed_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, resumed_token.entry_id);
    try std.testing.expect(resumed_token.generation > first_token.generation);

    var final_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(resumed_token, &final_batch));
    try std.testing.expect(manager.discoveryComplete(job).?);
}

test "discovery rejects stale completion and failure tokens" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const token = manager.dispatchDiscovery().?;
    try std.testing.expect(manager.failDiscovery(token));
    try std.testing.expect(!manager.failDiscovery(token));

    var stale_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    defer stale_batch.deinit();
    try std.testing.expect(!try manager.completeDiscovery(token, &stale_batch));
    try std.testing.expect(manager.discoveryComplete(job).?);
}

test "discovery scheduler follows the foreground promoted background 2:1:1 rotation" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    var jobs: [8]io_manager.JobId = undefined;
    for (&jobs, 0..) |*job_id, index| {
        job_id.* = try manager.createJob(null);
        _ = try manager.addTreeRoot(job_id.*, "source", .directory, .{}, null);
        try manager.startDiscovery(job_id.*, "/tmp/source");
        if (index < 4) {
            const root = manager.treeIndex(job_id.*).?.root().?;
            try manager.prioritizeDiscovery(job_id.*, root);
        } else if (index < 6) {
            const root = manager.treeIndex(job_id.*).?.root().?;
            try manager.promoteDiscoverySubtree(job_id.*, root);
        }
    }

    const expected = [_]io_manager.JobId{
        jobs[0], jobs[1], jobs[4], jobs[6],
        jobs[2], jobs[3], jobs[5], jobs[7],
    };
    for (expected) |expected_job| {
        const token = manager.dispatchDiscovery() orelse return error.MissingDiscoveryWork;
        try std.testing.expectEqual(expected_job, token.job_id);
        var batch = try makeDiscoveryBatch(allocator, &.{}, true);
        try std.testing.expect(try manager.completeDiscovery(token, &batch));
    }

    for (jobs) |job_id|
        try std.testing.expect(manager.discoveryComplete(job_id).?);
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "discovery scheduler skips empty priority queues without wasting dispatches" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const promoted_job = try manager.createJob(null);
    const promoted_root = try manager.addTreeRoot(
        promoted_job,
        "promoted",
        .directory,
        .{},
        null,
    );
    try manager.startDiscovery(promoted_job, "/tmp/promoted");
    try manager.promoteDiscoverySubtree(promoted_job, promoted_root);

    const background_job = try manager.createJob(null);
    _ = try manager.addTreeRoot(background_job, "background", .directory, .{}, null);
    try manager.startDiscovery(background_job, "/tmp/background");

    const first = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(promoted_job, first.job_id);
    var first_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(first, &first_batch));

    const second = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(background_job, second.job_id);
    var second_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(second, &second_batch));
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "promoting a queued directory changes its priority without duplicating it" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const root_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, root_token.entry_id);
    var root_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "a", .kind = .directory },
        .{ .name = "b", .kind = .directory },
        .{ .name = "c", .kind = .directory },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(root_token, &root_batch));

    const children = manager.treeIndex(job).?.getConst(root).?.children.items;
    const a_id = children[0];
    const b_id = children[1];
    try manager.prioritizeDiscovery(job, b_id);

    const promoted = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(b_id, promoted.entry_id);
    var promoted_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(promoted, &promoted_batch));

    const background = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(a_id, background.entry_id);
    var background_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(background, &background_batch));

    const final_child = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(children[2], final_child.entry_id);
    var final_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(final_child, &final_batch));
    try std.testing.expect(manager.discoveryComplete(job).?);
}

test "promoted subtree descendants inherit promoted priority" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const promoted_job = try manager.createJob(null);
    const root = try manager.addTreeRoot(promoted_job, "source", .directory, .{}, null);
    try manager.startDiscovery(promoted_job, "/tmp/source");
    try manager.promoteDiscoverySubtree(promoted_job, root);

    const background_job = try manager.createJob(null);
    _ = try manager.addTreeRoot(background_job, "other", .directory, .{}, null);
    try manager.startDiscovery(background_job, "/tmp/other");

    const root_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(promoted_job, root_token.job_id);
    var root_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "nested", .kind = .directory },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(root_token, &root_batch));

    const background = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(background_job, background.job_id);
    var background_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(background, &background_batch));

    const nested_id = manager.treeIndex(promoted_job).?.getConst(root).?.children.items[0];
    const nested = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(promoted_job, nested.job_id);
    try std.testing.expectEqual(nested_id, nested.entry_id);
    var nested_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(nested, &nested_batch));
}

test "foreground work can run between batches while a background continuation is retained" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const root_token = manager.dispatchDiscovery().?;
    var first_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "b", .kind = .directory },
    }, false);
    try std.testing.expect(try manager.completeDiscovery(root_token, &first_batch));

    const children = manager.treeIndex(job).?.getConst(root).?.children.items;
    const foreground_id = children[0];
    try manager.prioritizeDiscovery(job, foreground_id);

    const foreground = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(foreground_id, foreground.entry_id);
    var foreground_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(foreground, &foreground_batch));

    const resumed = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, resumed.entry_id);
    try std.testing.expect(resumed.generation > root_token.generation);
    var final_root_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(resumed, &final_root_batch));
}

test "large dependency chain dispatches in insertion order" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const operation_count = 10_000;
    const job = try manager.createJob(null);
    const ids = try std.testing.allocator.alloc(io_manager.OperationId, operation_count);
    defer std.testing.allocator.free(ids);

    for (ids, 0..) |*id, index| {
        id.* = try manager.addOperation(job, .copy_file);
        if (index > 0) {
            try manager.addDependency(job, id.*, ids[index - 1]);
        }
    }

    try manager.queueJob(job);

    for (ids) |expected_id| {
        const token = manager.dispatchNext() orelse return error.MissingWork;
        try std.testing.expectEqual(expected_id, token.operation_id);
        try std.testing.expect(manager.completeWork(token, .completed));
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
}

test "failure propagation handles shared descendants in a diamond graph" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addOperation(job, .copy_file);
    const left = try manager.addOperation(job, .copy_file);
    const right = try manager.addOperation(job, .copy_file);
    const join = try manager.addOperation(job, .publish);

    try manager.addDependency(job, left, root);
    try manager.addDependency(job, right, root);
    try manager.addDependency(job, join, left);
    try manager.addDependency(job, join, right);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .failed));

    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, left).?);
    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, right).?);
    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, join).?);
    try std.testing.expectEqual(io_manager.JobState.failed, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
}
