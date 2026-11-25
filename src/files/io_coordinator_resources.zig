//! Resource ownership on the coordinator: window-owned resources and borrows
//! (docs/plans/files-io-service-architecture.md §6). Methods of `Coordinator`,
//! aliased there.
const std = @import("std");
const c = @import("c.zig").api;
const io_service = @import("io_service.zig");
const io_runtime = @import("io_runtime.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const io_service_tasks = @import("io_service_tasks.zig");
const Coordinator = @import("io_coordinator.zig").Coordinator;

/// Hands a resource to a window: it becomes window-owned and stops
/// counting toward its job (architecture §6). `path` is what disposal
/// needs later, kept here so the window never has to delete anything
/// itself. Used by the archive hand-offs of S4.
pub fn handResourceToWindow(
    self: *Coordinator,
    handle: io_resource_ledger.Handle,
    expected_owner: io_resource_ledger.Owner,
    window_id: io_service.WindowId,
    path: []u8,
) !void {
    try self.window_held.ensureUnusedCapacity(self.allocator, 1);
    try self.runtime.resource_ledger.handToWindow(handle, expected_owner, window_id);
    self.window_held.putAssumeCapacity(handle.id, .{ .path = path });
}

/// Disposes a window-owned resource at its holder's request or when the
/// holder closes: ownership goes back to an executor and a worker
/// destroys it. Only the holder can ask (no origin check).
pub fn disposeWindowResource(
    self: *Coordinator,
    handle: io_resource_ledger.Handle,
    window_id: io_service.WindowId,
) !void {
    const ledger = &self.runtime.resource_ledger;
    if (ledger.holderOf(handle) != window_id) return error.ResourceHolderMismatch;
    const kind = ledger.kindOf(handle) orelse return error.UnknownResource;
    switch (kind) {
        .archive_staging => {
            const held = self.window_held.fetchRemove(handle.id) orelse
                return error.ResourceNotDisposable;
            try ledger.takeFromWindow(handle, window_id, .operation_worker);
            self.submitTask(.{ .delete_tree = .{ .handle = handle, .path = held.value.path } });
        },
        else => return error.ResourceNotDisposable,
    }
}

/// A window closed: drop its borrows and dispose everything it owns.
/// Never touches executor-owned or worker-held resources, or any job.
fn sweepClosedWindow(self: *Coordinator, window_id: io_service.WindowId) void {
    @import("io_coordinator_views.zig").dropWindowViews(self, window_id);
    self.dropWindowHandoffs(window_id);
    const ledger = &self.runtime.resource_ledger;
    _ = ledger.dropBorrowsOf(window_id);
    var held: [16]io_resource_ledger.Handle = undefined;
    while (true) {
        const count = ledger.windowResources(window_id, &held);
        if (count == 0) return;
        for (held[0..count]) |handle| {
            disposeWindowResource(self, handle, window_id) catch |err| {
                std.log.err("Files could not dispose resource {d} of closed window {d}: {s}", .{
                    handle.id, window_id, @errorName(err),
                });
                // Leave it with the window: it is still accounted for.
                return;
            };
        }
    }
}

pub fn sweepClosedWindows(self: *Coordinator) void {
    var overflowed = false;
    while (self.service.takeClosedWindow(&overflowed)) |window_id| sweepClosedWindow(self, window_id);
    if (!overflowed) return;
    // Some closures were not recorded: check every holder and borrower.
    const ledger = &self.runtime.resource_ledger;
    var i: usize = 0;
    while (i < ledger.borrows.items.len) {
        const window_id = ledger.borrows.items[i].window_id;
        if (!self.service.isWindowOpen(window_id)) {
            sweepClosedWindow(self, window_id);
            i = 0;
        } else i += 1;
    }
    for (ledger.records.items) |record| {
        if (record.owner == .window and !self.service.isWindowOpen(record.holder_window)) {
            sweepClosedWindow(self, record.holder_window);
            return sweepClosedWindows(self);
        }
    }
}

test "only the holder disposes a window-owned resource, and closing a window disposes what it owns" {
    const allocator = std.testing.allocator;

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();

    var holder = try service.registerWindow();
    var other = try service.registerWindow();
    defer other.close();

    var context: io_service_tasks.Context = .{ .allocator = allocator, .io = std.testing.io };
    var coordinator: Coordinator = .{
        .allocator = allocator,
        .service = &service,
        .runtime = &runtime,
        .tasks = try io_service_tasks.create(&context),
    };
    defer {
        coordinator.tasks.deinit();
        coordinator.published.deinit(allocator);
        coordinator.task_backlog.deinit(allocator);
        coordinator.window_held.deinit(allocator);
    }

    // A job's staging handed to a window: the window owns it and the job
    // no longer counts it.
    var template = "/tmp/rediwm_window_held_XXXXXX".*;
    const dir = c.mkdtemp(&template) orelse return error.MkdtempFailed;
    const path = try allocator.dupe(u8, std.mem.span(dir));
    const job_id = try runtime.manager.createJob(holder.window_id);
    const handle = try runtime.resource_ledger.register(job_id, .archive_staging, .operation_executor);
    const worker_resource = try runtime.resource_ledger.register(job_id, .archive_cancellation, .operation_worker);
    try coordinator.handResourceToWindow(handle, .operation_executor, holder.window_id, path);
    try std.testing.expectEqual(@as(usize, 1), runtime.resource_ledger.jobResourceCount(job_id));

    // Another window cannot dispose it, nor anything executor- or worker-owned.
    try std.testing.expectError(error.ResourceHolderMismatch, coordinator.disposeWindowResource(handle, other.window_id));
    try std.testing.expectError(error.ResourceHolderMismatch, coordinator.disposeWindowResource(worker_resource, holder.window_id));

    // Closing the holder disposes it through a worker task; the worker-held
    // resource of the same job is untouched.
    holder.close();
    _ = service.tryReceiveCommand(); // recycles the slot
    coordinator.sweepClosedWindows();
    for (0..1000) |_| {
        coordinator.pumpTasks();
        if (runtime.resource_ledger.ownerOf(handle) == null) break;
        _ = std.posix.system.poll(&.{}, 0, 1);
    } else return error.Timeout;
    var stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(dir, &stat) != 0);
    try std.testing.expectEqual(io_resource_ledger.Owner.operation_worker, runtime.resource_ledger.ownerOf(worker_resource).?);
    try runtime.resource_ledger.release(worker_resource, .operation_worker);
}
