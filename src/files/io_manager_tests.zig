const std = @import("std");
const io_manager = @import("io_manager.zig");

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
