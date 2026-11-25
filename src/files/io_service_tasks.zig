//! Service tasks: the blocking filesystem work the coordinator must not do
//! itself (docs/plans/files-io-threading-and-ownership.md §8), run on a small
//! pool of its own.
//!
//! * `prepare_transfer` inspects a submit's destination and sources.
//! * `delete_tree` destroys a resource the coordinator's executors own, such
//!   as archive staging, once its ledger entry has moved to a worker.
//!
//! Each task carries an immutable, independently owned payload. Workers read
//! no Manager state, keep no pointer into a Manager collection and perform no
//! lifecycle transition; only the coordinator applies a result.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const io_service = @import("io_service.zig");
const io_transfer_plan = @import("io_transfer_plan.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const io_workers = @import("io_workers.zig");
const ops = @import("ops.zig");

pub const JobId = io_service.JobId;

/// Two workers: one hung mount stalling a task leaves the other free.
pub const worker_count = 2;
/// Prepares are bounded by live jobs; cleanups queue behind them.
pub const capacity = io_service.max_live_jobs * 2;

pub const Task = union(enum) {
    prepare_transfer: struct {
        job_id: JobId,
        /// The submit's payload, moved out of the command.
        payload: *io_service.OwnedPayload,
    },
    delete_tree: struct {
        handle: io_resource_ledger.Handle,
        path: []u8,
    },
};

pub const Result = union(enum) {
    prepared: struct {
        job_id: JobId,
        payload: *io_service.OwnedPayload,
        plan: anyerror!io_transfer_plan.TransferPlan,
    },
    deleted: struct {
        handle: io_resource_ledger.Handle,
        path: []u8,
        failed: ?anyerror,
    },

    /// Frees what the result owns. The caller has already applied it, or is
    /// discarding it at shutdown.
    pub fn deinit(self: *Result, allocator: Allocator) void {
        switch (self.*) {
            .prepared => |*prepared| {
                if (prepared.plan) |*plan| plan.deinit() else |_| {}
                prepared.payload.deinit();
            },
            .deleted => |deleted| allocator.free(deleted.path),
        }
    }
};

pub const Pool = io_workers.WorkerPool(Task, Result);

/// What `discard` needs at shutdown: results of tasks nobody collected.
pub const Context = struct {
    allocator: Allocator,
    /// Called for a `deleted` result that is discarded, so its ledger entry
    /// does not outlive the resource.
    on_discard_delete: ?*const fn (?*anyopaque, io_resource_ledger.Handle) void = null,
    owner: ?*anyopaque = null,
};

pub fn create(context: *Context) !*Pool {
    return Pool.init(context.allocator, worker_count, capacity, context, execute, discard);
}

fn execute(raw_context: ?*anyopaque, task: Task) Result {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    if (builtin.is_test and task == .prepare_transfer) test_gate.maybePark();
    return switch (task) {
        .prepare_transfer => |prepare| .{ .prepared = .{
            .job_id = prepare.job_id,
            .payload = prepare.payload,
            .plan = switch (prepare.payload.data) {
                .transfer => |*request| io_transfer_plan.prepare(context.allocator, request),
                else => error.UnexpectedTransferPayload,
            },
        } },
        .delete_tree => |delete| .{ .deleted = .{
            .handle = delete.handle,
            .path = delete.path,
            .failed = if (ops.deleteRecursive(context.allocator, delete.path)) |_| null else |err| err,
        } },
    };
}

/// Test-only stand-in for a hung mount: when armed, the next prepare parks
/// on its worker until the test releases it. Compiled out of non-test builds.
pub const test_gate = if (builtin.is_test) struct {
    pub var armed: std.atomic.Value(bool) = .init(false);
    pub var parked: std.atomic.Value(bool) = .init(false);
    pub var released: std.atomic.Value(bool) = .init(false);

    pub fn arm() void {
        parked.store(false, .release);
        released.store(false, .release);
        armed.store(true, .release);
    }

    pub fn release() void {
        armed.store(false, .release);
        released.store(true, .release);
    }

    fn maybePark() void {
        if (armed.cmpxchgStrong(true, false, .acq_rel, .monotonic) != null) return;
        parked.store(true, .release);
        while (!released.load(.acquire)) _ = std.posix.system.poll(&.{}, 0, 1);
    }
} else struct {};

fn discard(raw_context: ?*anyopaque, result_value: Result) void {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    var result = result_value;
    if (result == .deleted) {
        if (context.on_discard_delete) |callback| callback(context.owner, result.deleted.handle);
    }
    result.deinit(context.allocator);
}
