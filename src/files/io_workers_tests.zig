const std = @import("std");
const workers = @import("io_workers.zig");

const TestPool = workers.WorkerPool(u32, u32);

const TestContext = struct {
    executed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    discarded: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn doubleTask(raw_context: ?*anyopaque, task: u32) u32 {
    const context: *TestContext = @ptrCast(@alignCast(raw_context.?));
    _ = context.executed.fetchAdd(1, .monotonic);
    return task * 2;
}

fn discardResult(raw_context: ?*anyopaque, _: u32) void {
    const context: *TestContext = @ptrCast(@alignCast(raw_context.?));
    _ = context.discarded.fetchAdd(1, .monotonic);
}

fn initPool(context: *TestContext, worker_count: usize, capacity: usize) !*TestPool {
    return TestPool.init(
        std.testing.allocator,
        worker_count,
        capacity,
        @ptrCast(context),
        doubleTask,
        discardResult,
    );
}

fn waitForResults(pool: *TestPool, expected: usize) !void {
    var notified: u64 = 0;
    while (notified < expected) {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = pool.wakeFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const rc = std.posix.system.poll(&descriptors, 1, 5_000);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TimedOutWaitingForWorkers;
                notified +|= pool.drainWake();
            },
            .INTR => continue,
            else => return error.WorkerPollFailed,
        }
    }
}

fn collect(pool: *TestPool, output: []u32) !void {
    try waitForResults(pool, output.len);
    for (output) |*slot| {
        slot.* = pool.tryPopResult() orelse return error.NotifiedResultMissing;
    }
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
    var context = TestContext{};
    var pool = try initPool(&context, 1, 4);
    defer pool.deinit();

    try std.testing.expect(pool.trySubmit(10));
    try std.testing.expect(pool.trySubmit(20));
    try std.testing.expect(pool.trySubmit(30));

    var results: [3]u32 = undefined;
    try collect(pool, &results);
    try std.testing.expectEqualSlices(u32, &.{ 20, 40, 60 }, &results);
    try std.testing.expect(pool.tryPopResult() == null);
    try std.testing.expectEqual(@as(usize, 3), context.executed.load(.monotonic));
}

test "completed uncollected results retain outstanding capacity" {
    var context = TestContext{};
    var pool = try initPool(&context, 1, 2);
    defer pool.deinit();

    try std.testing.expect(pool.trySubmit(1));
    try std.testing.expect(pool.trySubmit(2));

    try waitForResults(pool, 2);
    try std.testing.expectEqual(@as(usize, 2), context.executed.load(.monotonic));
    try std.testing.expect(!pool.trySubmit(3));

    try std.testing.expectEqual(@as(u32, 2), pool.tryPopResult().?);
    try std.testing.expect(pool.trySubmit(3));

    // The second result was already queued before the new submission.
    try waitForResults(pool, 1);
    var results: [2]u32 = undefined;
    for (&results) |*slot| {
        slot.* = pool.tryPopResult() orelse return error.NotifiedResultMissing;
    }
    try std.testing.expectEqualSlices(u32, &.{ 4, 6 }, &results);
}

test "deinit finishes queued accepted work and discards every uncollected result" {
    var context = TestContext{};
    var pool = try initPool(&context, 1, 4);
    try std.testing.expect(pool.trySubmit(1));
    try std.testing.expect(pool.trySubmit(2));
    try std.testing.expect(pool.trySubmit(3));
    try std.testing.expect(pool.trySubmit(4));

    pool.deinit();

    try std.testing.expectEqual(@as(usize, 4), context.executed.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 4), context.discarded.load(.monotonic));
}
