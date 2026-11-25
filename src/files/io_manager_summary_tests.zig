//! Job summaries: the O(1) per-job view the coordinator publishes.
const std = @import("std");
const io_manager = @import("io_manager.zig");

test "a job summary totals planned bytes and items and follows completion" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(7);
    const small = try manager.addTreeRoot(job, "small.bin", .regular_file, .{ .size = 100 }, null);
    const large = try manager.addTreeRoot(job, "large.bin", .regular_file, .{ .size = 900 }, null);
    _ = try manager.addEntryOperation(job, small, .copy_file);
    _ = try manager.addEntryOperation(job, large, .copy_file);
    try manager.queueJob(job);

    // Known before anything runs: planned sizes, not only dispatched ones.
    var summary = manager.jobSummary(job).?;
    try std.testing.expectEqual(@as(u64, 1000), summary.total_bytes);
    try std.testing.expectEqual(@as(u64, 0), summary.completed_bytes);
    try std.testing.expectEqual(@as(u64, 2), summary.total_items);
    try std.testing.expectEqual(@as(u64, 0), summary.completed_items);
    try std.testing.expectEqual(@as(?io_manager.WindowId, 7), summary.origin_window_id);

    // Partial progress of one file.
    const first = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(first, .yielded));
    try std.testing.expect(manager.recordOperationProgress(first, 40, 100, .transferring));
    summary = manager.jobSummary(job).?;
    try std.testing.expectEqual(@as(u64, 40), summary.completed_bytes);

    // Completing a file counts its whole size once, and the item.
    const resumed = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(resumed, .completed));
    summary = manager.jobSummary(job).?;
    try std.testing.expectEqual(@as(u64, 1), summary.completed_items);

    const second = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(second, .completed));
    summary = manager.jobSummary(job).?;
    try std.testing.expectEqual(@as(u64, 1000), summary.completed_bytes);
    try std.testing.expectEqual(@as(u64, 2), summary.completed_items);
    try std.testing.expectEqual(io_manager.JobState.completed, summary.state);
}
