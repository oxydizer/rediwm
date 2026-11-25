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

test "a folder's progress sums its subtree as files report" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(7);
    const folder = try manager.addTreeRoot(job, "folder", .directory, .{}, null);
    const inner = try manager.addTreeEntry(job, folder, "inner", .directory, .{}, null);
    const a = try manager.addTreeEntry(job, folder, "a.bin", .regular_file, .{ .size = 100 }, null);
    const b = try manager.addTreeEntry(job, inner, "b.bin", .regular_file, .{ .size = 300 }, null);
    _ = try manager.addEntryOperation(job, folder, .create_directory);
    _ = try manager.addEntryOperation(job, inner, .create_directory);
    _ = try manager.addEntryOperation(job, a, .copy_file);
    _ = try manager.addEntryOperation(job, b, .copy_file);
    try manager.queueJob(job);

    try std.testing.expectEqual(io_manager.EntryBytes{ .completed_bytes = 0, .total_bytes = 400 }, manager.entryBytes(job, folder).?);
    try std.testing.expectEqual(io_manager.EntryBytes{ .completed_bytes = 0, .total_bytes = 300 }, manager.entryBytes(job, inner).?);
    try std.testing.expectEqual(io_manager.EntryBytes{ .completed_bytes = 0, .total_bytes = 100 }, manager.entryBytes(job, a).?);

    // The folders are created first.
    for (0..2) |_| try std.testing.expect(manager.completeWork(manager.dispatchNext().?, .completed));

    // Progress of the inner file moves both folders, and nothing else.
    var first = manager.dispatchNext().?;
    var second = manager.dispatchNext().?;
    if (manager.operationDetails(first).?.entry_id != b) std.mem.swap(io_manager.WorkToken, &first, &second);
    try std.testing.expect(manager.completeWork(first, .yielded));
    try std.testing.expect(manager.recordOperationProgress(first, 120, 300, .transferring));
    try std.testing.expectEqual(io_manager.EntryBytes{ .completed_bytes = 120, .total_bytes = 400 }, manager.entryBytes(job, folder).?);
    try std.testing.expectEqual(io_manager.EntryBytes{ .completed_bytes = 120, .total_bytes = 300 }, manager.entryBytes(job, inner).?);

    // Nothing has fully arrived yet.
    try std.testing.expectEqual(@as(u64, 0), manager.entryBytes(job, folder).?.arrived);
    try std.testing.expect(manager.completeWork(second, .completed));
    try std.testing.expectEqual(io_manager.EntryBytes{ .completed_bytes = 220, .total_bytes = 400, .arrived = 1 }, manager.entryBytes(job, folder).?);
    // a.bin arrived in the folder, not in inner: inner is still a ghost.
    try std.testing.expectEqual(@as(u64, 0), manager.entryBytes(job, inner).?.arrived);
    try std.testing.expectEqual(manager.jobSummary(job).?.completed_bytes, manager.entryBytes(job, folder).?.completed_bytes);
}

test "hovered files form a soft queue that goes first and holds other copies back" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(1);
    var files: [4]u64 = undefined;
    const names = [_][]const u8{ "a", "b", "c", "d" };
    for (names, 0..) |name, i| {
        files[i] = try manager.addTreeRoot(job, name, .regular_file, .{ .size = 10 }, null);
        _ = try manager.addEntryOperation(job, files[i], .copy_file);
    }
    try manager.queueJob(job);

    // The user hovers d, then c.
    try std.testing.expect(manager.prioritizeEntryOperation(job, files[3]));
    try std.testing.expect(manager.prioritizeEntryOperation(job, files[2]));

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(files[3], manager.operationDetails(first).?.entry_id);
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(files[2], manager.operationDetails(second).?.entry_id);
    // Both preferred copies run: the rest waits.
    try std.testing.expect(manager.dispatchNext() == null);

    // A preferred copy that yields goes again before anything else.
    try std.testing.expect(manager.completeWork(first, .yielded));
    const again = manager.dispatchNext().?;
    try std.testing.expectEqual(files[3], manager.operationDetails(again).?.entry_id);

    try std.testing.expect(manager.completeWork(again, .completed));
    try std.testing.expect(manager.completeWork(second, .completed));
    // The queue is done: normal order resumes.
    const next = manager.dispatchNext().?;
    try std.testing.expect(manager.operationDetails(next).?.entry_id == files[0] or manager.operationDetails(next).?.entry_id == files[1]);
}
