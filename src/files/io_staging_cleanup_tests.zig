//! Archive staging cleanup split for workers: the coordinator takes the
//! staging (ledger moves to a worker), a worker deletes it, and the
//! coordinator finishes the release.
const std = @import("std");
const c = @import("c.zig").api;
const io_manager = @import("io_manager.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const io_operation_executor = @import("io_operation_executor.zig");
const ops = @import("ops.zig");

test "staging taken for cleanup is worker-held until the release finishes" {
    const allocator = std.testing.allocator;
    var temp_buffer: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&temp_buffer, "/tmp/rediwm_staging_cleanup_XXXXXX\x00", .{});
    const temp_ptr = c.mkdtemp(@ptrCast(&temp_buffer)) orelse return error.MkdtempFailed;
    const temp_path = std.mem.span(@as([*:0]const u8, @ptrCast(temp_ptr)));

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job_id = try manager.createJob(null);
    try manager.queueJob(job_id);
    try std.testing.expect(manager.jobState(job_id).?.isTerminal());

    var ledger = io_resource_ledger.Ledger.init(allocator);
    defer ledger.deinit();
    var runtime = try io_operation_executor.Runtime.initWithLedger(allocator, &manager, &ledger, 1, 1);
    defer runtime.deinit();

    const handle = try ledger.register(job_id, .archive_staging, .operation_executor);
    try runtime.context.archive_staging.put(allocator, .{ .job_id = job_id, .operation_id = 1 }, .{
        .allocator = allocator,
        .token = undefined,
        .path = try allocator.dupe(u8, temp_path),
        .ledger_handle = handle,
    });

    // Taking it deletes nothing; the ledger now says a worker holds it, so
    // the job cannot retire while the directory exists.
    const path = try runtime.takeStagingForCleanup(handle);
    defer allocator.free(path);
    try std.testing.expectEqual(io_resource_ledger.Owner.operation_worker, ledger.ownerOf(handle).?);
    try std.testing.expect(!ledger.isJobEmpty(job_id));
    try std.testing.expectError(error.ResourceOwnerMismatch, runtime.takeStagingForCleanup(handle));

    // The worker's part, then the coordinator's.
    try ops.deleteRecursive(allocator, path);
    runtime.finishStagingCleanup(handle);
    try std.testing.expect(ledger.ownerOf(handle) == null);
    try std.testing.expect(ledger.isJobEmpty(job_id));
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, -1), c.lstat(temp_ptr, &stat));
}
