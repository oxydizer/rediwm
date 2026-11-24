//! Tracks resource ownership obligations associated with Files I/O Jobs.
//!
//! The ledger records ownership metadata only. Resource-specific executors
//! and App code remain responsible for destroying the resources they own.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_manager = @import("io_manager.zig");

pub const ResourceKind = enum {
    operation_payload,
    discovery_anchor,
    discovery_cursor,
    archive_cancellation,
    archive_staging,
    archive_publication_cursor,
};

/// The module currently responsible for releasing a resource.
///
/// This describes cleanup ownership, not every module that may temporarily
/// borrow or access the resource. In particular, archive cancellation state
/// remains executor-owned while a worker accesses its cancellation flag.
pub const Owner = enum {
    operation_executor,
    operation_worker,
    discovery_executor,
    discovery_worker,
    app,
};

/// Stable identity for one registered ownership obligation.
pub const Handle = struct {
    id: u64,
};

const Record = struct {
    handle: Handle,
    job_id: io_manager.JobId,
    kind: ResourceKind,
    owner: Owner,
};

pub const Ledger = struct {
    allocator: Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,
    index_by_id: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    resource_count_by_job: std.AutoHashMapUnmanaged(io_manager.JobId, usize) = .empty,
    next_resource_id: u64 = 1,

    pub fn init(allocator: Allocator) Ledger {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Ledger) void {
        self.records.deinit(self.allocator);
        self.index_by_id.deinit(self.allocator);
        self.resource_count_by_job.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers an ownership obligation before the resource is handed to
    /// another owner. Allocation failure leaves the ledger unchanged.
    pub fn register(
        self: *Ledger,
        job_id: io_manager.JobId,
        kind: ResourceKind,
        owner: Owner,
    ) !Handle {
        if (self.next_resource_id == std.math.maxInt(u64))
            return error.ResourceIdExhausted;

        try self.records.ensureUnusedCapacity(self.allocator, 1);
        try self.index_by_id.ensureUnusedCapacity(self.allocator, 1);
        if (!self.resource_count_by_job.contains(job_id)) {
            try self.resource_count_by_job.ensureUnusedCapacity(self.allocator, 1);
        }

        const handle = Handle{ .id = self.next_resource_id };
        self.next_resource_id += 1;

        const index = self.records.items.len;
        self.records.appendAssumeCapacity(.{
            .handle = handle,
            .job_id = job_id,
            .kind = kind,
            .owner = owner,
        });
        self.index_by_id.putAssumeCapacity(handle.id, index);

        if (self.resource_count_by_job.getPtr(job_id)) |count| {
            count.* += 1;
        } else {
            self.resource_count_by_job.putAssumeCapacity(job_id, 1);
        }

        return handle;
    }

    /// Changes cleanup ownership without allocating or changing the Job's
    /// outstanding resource count.
    pub fn transfer(
        self: *Ledger,
        handle: Handle,
        expected_owner: Owner,
        new_owner: Owner,
    ) !void {
        const index = self.index_by_id.get(handle.id) orelse
            return error.UnknownResource;
        const record = &self.records.items[index];
        if (record.owner != expected_owner) return error.ResourceOwnerMismatch;
        if (expected_owner == new_owner) return error.SameResourceOwner;
        record.owner = new_owner;
    }

    /// Records that the current owner has destroyed or otherwise released
    /// the resource. The resource must no longer be accessible.
    pub fn release(
        self: *Ledger,
        handle: Handle,
        expected_owner: Owner,
    ) !void {
        try self.removeOwnedResource(handle, expected_owner);
    }

    /// Removes a resource from Job ownership after an explicit handoff to an
    /// independent lifetime, such as a clipboard, drag or Open With lease.
    ///
    /// The receiving owner becomes responsible for eventual destruction.
    pub fn transferOut(
        self: *Ledger,
        handle: Handle,
        expected_owner: Owner,
    ) !void {
        try self.removeOwnedResource(handle, expected_owner);
    }

    fn removeOwnedResource(
        self: *Ledger,
        handle: Handle,
        expected_owner: Owner,
    ) !void {
        const index = self.index_by_id.get(handle.id) orelse
            return error.UnknownResource;
        const record = self.records.items[index];
        if (record.owner != expected_owner) return error.ResourceOwnerMismatch;

        const last_index = self.records.items.len - 1;
        if (index != last_index) {
            const moved = self.records.items[last_index];
            self.records.items[index] = moved;
            self.index_by_id.putAssumeCapacity(moved.handle.id, index);
        }
        self.records.items.len = last_index;
        std.debug.assert(self.index_by_id.remove(handle.id));

        const count = self.resource_count_by_job.getPtr(record.job_id) orelse
            unreachable;
        std.debug.assert(count.* > 0);
        count.* -= 1;
    }

    pub fn ownerOf(self: *const Ledger, handle: Handle) ?Owner {
        const index = self.index_by_id.get(handle.id) orelse return null;
        return self.records.items[index].owner;
    }

    pub fn kindOf(self: *const Ledger, handle: Handle) ?ResourceKind {
        const index = self.index_by_id.get(handle.id) orelse return null;
        return self.records.items[index].kind;
    }

    pub fn jobIdOf(self: *const Ledger, handle: Handle) ?io_manager.JobId {
        const index = self.index_by_id.get(handle.id) orelse return null;
        return self.records.items[index].job_id;
    }

    pub fn jobResourceCount(
        self: *const Ledger,
        job_id: io_manager.JobId,
    ) usize {
        return self.resource_count_by_job.get(job_id) orelse 0;
    }

    pub fn isJobEmpty(
        self: *const Ledger,
        job_id: io_manager.JobId,
    ) bool {
        return self.jobResourceCount(job_id) == 0;
    }

    pub fn isEmpty(self: *const Ledger) bool {
        return self.records.items.len == 0;
    }

    /// Drops empty per-Job bookkeeping. A Job with outstanding resources
    /// cannot be removed from the ledger.
    pub fn releaseJob(self: *Ledger, job_id: io_manager.JobId) !void {
        if (!self.isJobEmpty(job_id)) return error.JobHasResources;
        _ = self.resource_count_by_job.remove(job_id);
    }
};

test "ledger registers resources and tracks per-job counts" {
    var ledger = Ledger.init(std.testing.allocator);
    defer ledger.deinit();

    const first = try ledger.register(10, .operation_payload, .operation_executor);
    const second = try ledger.register(10, .discovery_anchor, .discovery_executor);
    const other_job = try ledger.register(20, .archive_staging, .operation_executor);

    try std.testing.expectEqual(@as(usize, 2), ledger.jobResourceCount(10));
    try std.testing.expectEqual(@as(usize, 1), ledger.jobResourceCount(20));
    try std.testing.expectEqual(@as(usize, 0), ledger.jobResourceCount(30));
    try std.testing.expect(!ledger.isJobEmpty(10));
    try std.testing.expectEqual(Owner.operation_executor, ledger.ownerOf(first).?);
    try std.testing.expectEqual(ResourceKind.discovery_anchor, ledger.kindOf(second).?);

    try ledger.release(first, .operation_executor);
    try ledger.release(second, .discovery_executor);
    try ledger.release(other_job, .operation_executor);

    try std.testing.expect(ledger.isJobEmpty(10));
    try std.testing.expect(ledger.isJobEmpty(20));
}

test "ledger transfers ownership without changing job resource count" {
    var ledger = Ledger.init(std.testing.allocator);
    defer ledger.deinit();

    const handle = try ledger.register(7, .operation_payload, .operation_executor);
    try ledger.transfer(handle, .operation_executor, .operation_worker);

    try std.testing.expectEqual(Owner.operation_worker, ledger.ownerOf(handle).?);
    try std.testing.expectEqual(@as(usize, 1), ledger.jobResourceCount(7));

    try ledger.transfer(handle, .operation_worker, .operation_executor);
    try std.testing.expectEqual(Owner.operation_executor, ledger.ownerOf(handle).?);
    try ledger.release(handle, .operation_executor);
    try std.testing.expect(ledger.isJobEmpty(7));
}

test "ledger rejects unknown handles and incorrect ownership transitions" {
    var ledger = Ledger.init(std.testing.allocator);
    defer ledger.deinit();

    const handle = try ledger.register(4, .discovery_cursor, .discovery_executor);
    const unknown = Handle{ .id = handle.id + 1000 };

    try std.testing.expectError(
        error.UnknownResource,
        ledger.transfer(unknown, .discovery_executor, .discovery_worker),
    );
    try std.testing.expectError(
        error.ResourceOwnerMismatch,
        ledger.transfer(handle, .operation_executor, .operation_worker),
    );
    try std.testing.expectError(
        error.SameResourceOwner,
        ledger.transfer(handle, .discovery_executor, .discovery_executor),
    );
    try std.testing.expectError(
        error.ResourceOwnerMismatch,
        ledger.release(handle, .discovery_worker),
    );

    try std.testing.expectEqual(Owner.discovery_executor, ledger.ownerOf(handle).?);
    try ledger.release(handle, .discovery_executor);
    try std.testing.expectError(
        error.UnknownResource,
        ledger.release(handle, .discovery_executor),
    );
}

test "transferred-out leases no longer prevent job retirement" {
    var ledger = Ledger.init(std.testing.allocator);
    defer ledger.deinit();

    const staging = try ledger.register(12, .archive_staging, .app);
    const publication = try ledger.register(12, .archive_publication_cursor, .app);

    try std.testing.expectError(error.JobHasResources, ledger.releaseJob(12));
    try ledger.transferOut(staging, .app);

    try std.testing.expectEqual(@as(usize, 1), ledger.jobResourceCount(12));
    try std.testing.expect(!ledger.isJobEmpty(12));

    try ledger.release(publication, .app);
    try std.testing.expect(ledger.isJobEmpty(12));
    try ledger.releaseJob(12);
    try std.testing.expectEqual(@as(usize, 0), ledger.jobResourceCount(12));
}

test "ledger supports multiple resource families and independent jobs" {
    var ledger = Ledger.init(std.testing.allocator);
    defer ledger.deinit();

    const operation = try ledger.register(1, .operation_payload, .operation_worker);
    const anchor = try ledger.register(1, .discovery_anchor, .discovery_executor);
    const cursor = try ledger.register(1, .discovery_cursor, .discovery_worker);
    const cancellation = try ledger.register(1, .archive_cancellation, .operation_executor);
    const staging = try ledger.register(1, .archive_staging, .operation_executor);
    const unrelated = try ledger.register(2, .operation_payload, .operation_worker);

    try std.testing.expectEqual(@as(usize, 5), ledger.jobResourceCount(1));
    try std.testing.expectEqual(@as(usize, 1), ledger.jobResourceCount(2));

    try ledger.release(operation, .operation_worker);
    try ledger.release(anchor, .discovery_executor);
    try ledger.release(cursor, .discovery_worker);
    try ledger.release(cancellation, .operation_executor);
    try ledger.release(staging, .operation_executor);
    try ledger.release(unrelated, .operation_worker);

    try ledger.releaseJob(1);
    try ledger.releaseJob(2);
    try std.testing.expect(ledger.isJobEmpty(1));
    try std.testing.expect(ledger.isJobEmpty(2));
}
