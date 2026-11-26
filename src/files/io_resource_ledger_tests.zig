//! Window ownership and borrows (architecture §6).
const std = @import("std");
const ledger_mod = @import("io_resource_ledger.zig");
const Ledger = ledger_mod.Ledger;

test "a resource handed to a window leaves its job's count and only its holder can return it" {
    var ledger = Ledger.init(std.testing.allocator);
    defer ledger.deinit();
    const handle = try ledger.register(5, .archive_staging, .operation_executor);
    try std.testing.expectEqual(@as(usize, 1), ledger.jobResourceCount(5));

    try ledger.handToWindow(handle, .operation_executor, 42);
    try std.testing.expectEqual(ledger_mod.Owner.window, ledger.ownerOf(handle).?);
    try std.testing.expectEqual(@as(?u64, 42), ledger.holderOf(handle));
    // It no longer blocks the job, which may retire and go away.
    try std.testing.expect(ledger.isJobEmpty(5));
    try ledger.releaseJob(5);

    var held: [4]ledger_mod.Handle = undefined;
    try std.testing.expectEqual(@as(usize, 1), ledger.windowResources(42, &held));
    try std.testing.expectEqual(@as(usize, 0), ledger.windowResources(43, &held));

    // Plain transfer cannot reach or leave window ownership.
    try std.testing.expectError(error.WindowOwnerNeedsHandOff, ledger.transfer(handle, .window, .operation_executor));
    try std.testing.expectError(error.ResourceHolderMismatch, ledger.takeFromWindow(handle, 43, .operation_executor));

    // Disposal: back to an executor, then a worker, then released.
    try ledger.takeFromWindow(handle, 42, .operation_executor);
    try ledger.transfer(handle, .operation_executor, .operation_worker);
    try ledger.release(handle, .operation_worker);
    try std.testing.expect(ledger.isEmpty());
}

test "borrows block release and retirement, are bounded per window and drop with the window" {
    var ledger = Ledger.init(std.testing.allocator);
    defer ledger.deinit();
    const staging = try ledger.register(9, .archive_staging, .operation_executor);

    try ledger.borrow(staging, 7);
    try std.testing.expectError(error.AlreadyBorrowed, ledger.borrow(staging, 7));
    try ledger.borrow(staging, 8);
    try std.testing.expectEqual(@as(usize, 2), ledger.jobBorrowCount(9));
    try std.testing.expectError(error.ResourceBorrowed, ledger.release(staging, .operation_executor));
    try std.testing.expectError(error.ResourceBorrowed, ledger.handToWindow(staging, .operation_executor, 7));

    try ledger.releaseBorrow(staging, 8);
    try std.testing.expectError(error.NotBorrowed, ledger.releaseBorrow(staging, 8));
    try std.testing.expectEqual(@as(usize, 1), ledger.dropBorrowsOf(7));
    try std.testing.expectEqual(@as(usize, 0), ledger.jobBorrowCount(9));
    try ledger.release(staging, .operation_executor);

    // Per-window bound.
    var handles: [ledger_mod.max_borrows_per_window + 1]ledger_mod.Handle = undefined;
    for (&handles) |*h| h.* = try ledger.register(10, .discovery_anchor, .discovery_executor);
    for (handles[0..ledger_mod.max_borrows_per_window]) |h| try ledger.borrow(h, 3);
    try std.testing.expectError(error.TooManyBorrows, ledger.borrow(handles[ledger_mod.max_borrows_per_window], 3));
    _ = ledger.dropBorrowsOf(3);
    for (handles) |h| try ledger.release(h, .discovery_executor);
}

test "a borrow holds its job back from retirement until it is dropped" {
    const io_runtime = @import("io_runtime.zig");
    var runtime = io_runtime.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const job = try runtime.manager.createJob(null);
    try runtime.manager.queueJob(job); // empty job: terminal at once
    const handle = try runtime.resource_ledger.register(job, .archive_staging, .operation_executor);
    try runtime.resource_ledger.handToWindow(handle, .operation_executor, 1);
    try runtime.resource_ledger.borrow(handle, 2);

    try runtime.requestJobRetirement(job);
    // The window-owned resource does not hold the job; the borrow does.
    try std.testing.expect(!runtime.isJobRetirementReady(job));
    try runtime.resource_ledger.releaseBorrow(handle, 2);
    try std.testing.expect(runtime.isJobRetirementReady(job));
    try std.testing.expect(runtime.retireJobIfReady(job));

    // The window's resource outlives the job and is disposed later.
    try runtime.resource_ledger.takeFromWindow(handle, 1, .operation_worker);
    try runtime.resource_ledger.release(handle, .operation_worker);
}
