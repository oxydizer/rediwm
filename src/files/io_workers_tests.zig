const std = @import("std");
const workers = @import("io_workers.zig");

const TestPool = workers.WorkerPool(u32, u32);

fn doubleTask(_: ?*anyopaque, task: u32) u32 {
    return task * 2;
}

fn discardResult(_: u32) void {}

fn collect(pool: *TestPool, output: []u32) !void {
    var count: usize = 0;
    var attempts: usize = 0;
    while (count < output.len and attempts < 1_000_000) : (attempts += 1) {
        if (pool.tryPopResult()) |result| {
            output[count] = result;
            count += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }
    if (count != output.len) return error.TimedOutWaitingForWorkers;
}

test "worker pool validates configuration" {
    try std.testing.expectError(
        error.InvalidWorkerCount,
        TestPool.init(std.testing.allocator, 0, 4, null, doubleTask, discardResult),
    );
    try std.testing.expectError(
        error.InvalidCapacity,
        TestPool.init(std.testing.allocator, 1, 0, null, doubleTask, discardResult),
    );
}

test "single worker preserves FIFO dequeue and result order" {
    var pool = try TestPool.init(
        std.testing.allocator,
        1,
        4,
        null,
        doubleTask,
        discardResult,
    );
    defer pool.deinit();

    try std.testing.expect(pool.trySubmit(10));
    try std.testing.expect(pool.trySubmit(20));
    try std.testing.expect(pool.trySubmit(30));

    var results: [3]u32 = undefined;
    try collect(pool, &results);
    try std.testing.expectEqualSlices(u32, &.{ 20, 40, 60 }, &results);
    try std.testing.expect(pool.tryPopResult() == null);
}

test "outstanding capacity applies until the result is collected" {
    var pool = try TestPool.init(
        std.testing.allocator,
        1,
        2,
        null,
        doubleTask,
        discardResult,
    );
    defer pool.deinit();

    try std.testing.expect(pool.trySubmit(1));
    try std.testing.expect(pool.trySubmit(2));
    try std.testing.expect(!pool.trySubmit(3));

    var results: [2]u32 = undefined;
    try collect(pool, &results);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, &results);
    try std.testing.expect(pool.trySubmit(3));

    var final_result: [1]u32 = undefined;
    try collect(pool, &final_result);
    try std.testing.expectEqual(@as(u32, 6), final_result[0]);
}

test "deinit joins workers with accepted tasks still outstanding" {
    var pool = try TestPool.init(
        std.testing.allocator,
        2,
        4,
        null,
        doubleTask,
        discardResult,
    );
    try std.testing.expect(pool.trySubmit(1));
    try std.testing.expect(pool.trySubmit(2));
    pool.deinit();
}
