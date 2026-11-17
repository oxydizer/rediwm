const std = @import("std");
const io_manager = @import("io_manager.zig");
const io_executor = @import("io_executor.zig");

const TestContext = struct {
    prepared: usize = 0,
    completed: usize = 0,
    last_token: ?io_manager.WorkToken = null,
    input_mismatches: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    continuation_mismatches: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn prepareWork(
    raw_context: ?*anyopaque,
    token: io_manager.WorkToken,
) anyerror!io_executor.PreparedWork {
    const context: *TestContext = @ptrCast(@alignCast(raw_context.?));
    context.prepared += 1;
    context.last_token = token;
    return .{
        .operation_kind = .copy_file,
        .input = try io_executor.OwnedPayload.copy(std.heap.page_allocator, "input"),
    };
}

fn executeWork(
    raw_context: ?*anyopaque,
    item: io_executor.WorkItem,
) io_executor.WorkCompletion {
    const context: *TestContext = @ptrCast(@alignCast(raw_context.?));
    const stage = if (item.continuation) |continuation|
        continuation.slice()
    else
        "";

    if (!std.mem.eql(u8, item.input.slice(), "input")) {
        _ = context.input_mismatches.fetchAdd(1, .monotonic);
    }

    const expected_continuation: []const u8 = switch (context.completed) {
        0 => "",
        1 => "yielded",
        else => "waiting",
    };
    if (!std.mem.eql(u8, stage, expected_continuation)) {
        _ = context.continuation_mismatches.fetchAdd(1, .monotonic);
    }

    const outcome: io_manager.WorkResult = if (stage.len == 0)
        .yielded
    else if (std.mem.eql(u8, stage, "yielded"))
        .waiting
    else
        .completed;

    const next_continuation: ?io_executor.OwnedPayload = switch (outcome) {
        .yielded => io_executor.OwnedPayload.copy(std.heap.page_allocator, "yielded") catch unreachable,
        .waiting => io_executor.OwnedPayload.copy(std.heap.page_allocator, "waiting") catch unreachable,
        else => null,
    };

    return .{
        .token = item.token,
        .outcome = outcome,
        .operation_kind = item.operation_kind,
        .input = item.input,
        .continuation = next_continuation,
        .result = null,
    };
}

fn completeWork(
    raw_context: ?*anyopaque,
    _: io_manager.WorkToken,
    _: io_manager.WorkResult,
    result: ?io_executor.OwnedPayload,
) void {
    const context: *TestContext = @ptrCast(@alignCast(raw_context.?));
    context.completed += 1;
    if (result) |owned_result| {
        var value = owned_result;
        value.deinit();
    }
}

fn initExecutor(context: *TestContext, capacity: usize) !io_executor.Executor {
    return io_executor.Executor.init(
        std.testing.allocator,
        .{ .worker_count = 1, .capacity = capacity },
        @ptrCast(context),
        .{
            .prepare = prepareWork,
            .execute = executeWork,
            .complete = completeWork,
        },
    );
}

fn waitForOne(executor: *io_executor.Executor) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = executor.wakeFd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    while (true) {
        const rc = std.posix.system.poll(&descriptors, 1, 5_000);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TimedOutWaitingForExecutor;
                _ = executor.drainWake();
                return;
            },
            .INTR => continue,
            else => return error.ExecutorPollFailed,
        }
    }
}

test "executor preserves input and continuation across yield and waiting" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const operation = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);

    var context = TestContext{};
    var executor = try initExecutor(&context, 1);
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    try waitForOne(&executor);
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));
    try std.testing.expectEqual(io_manager.OperationState.pending, manager.operationState(job, operation).?);

    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    try waitForOne(&executor);
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));
    try std.testing.expectEqual(io_manager.OperationState.waiting, manager.operationState(job, operation).?);

    try manager.resolveWaiting(job, operation);
    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    try waitForOne(&executor);
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));

    try std.testing.expectEqual(io_manager.OperationState.completed, manager.operationState(job, operation).?);
    try std.testing.expectEqual(@as(usize, 1), context.prepared);
    try std.testing.expectEqual(@as(usize, 3), context.completed);
    try std.testing.expectEqual(@as(usize, 0), context.input_mismatches.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), context.continuation_mismatches.load(.monotonic));
}

test "executor retains prepared work when the pool applies backpressure" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(null);
    _ = try manager.addOperation(first_job, .copy_file);
    try manager.queueJob(first_job);

    const second_job = try manager.createJob(null);
    _ = try manager.addOperation(second_job, .copy_file);
    try manager.queueJob(second_job);

    var context = TestContext{};
    var executor = try initExecutor(&context, 1);
    defer executor.deinit();

    // First task occupies the only outstanding slot. The second item is
    // prepared once and retained when submission is refused.
    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    try std.testing.expectEqual(@as(usize, 2), context.prepared);

    try waitForOne(&executor);
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));

    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    try waitForOne(&executor);
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));

    try std.testing.expectEqual(@as(usize, 2), context.prepared);
    try std.testing.expectEqual(@as(usize, 2), context.completed);
}

test "executor disposes stale completions without calling complete callback" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const operation = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);

    var context = TestContext{};
    var executor = try initExecutor(&context, 1);
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 1), try executor.dispatchReady(&manager));
    const token = context.last_token.?;
    try std.testing.expect(manager.completeWork(token, .cancelled));

    try waitForOne(&executor);
    try std.testing.expectEqual(@as(usize, 1), try executor.drainCompletions(&manager));

    try std.testing.expectEqual(io_manager.OperationState.cancelled, manager.operationState(job, operation).?);
    try std.testing.expectEqual(@as(usize, 0), context.completed);
}
