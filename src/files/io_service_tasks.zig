//! Service tasks: the blocking filesystem work the coordinator must not do
//! itself (docs/plans/files-io-threading-and-ownership.md §8), run on small
//! pools of its own, one per lane (`laneOf`, docs/plans/files-io-worker-pools.md
//! §4.1): prepares and requests on the task lane, an extraction's staging work
//! on the staging lane, so neither waits behind the other on a hung mount.
//!
//! * `prepare_transfer` inspects a submit's destination and sources.
//! * `request` runs a window's metadata or small-mutation request
//!   (`io_requests.zig`) and returns its reply.
//! * `delete_tree` destroys a resource the coordinator's executors own, such
//!   as archive staging, once its ledger entry has moved to a worker.
//! * `scan_staging` lists the top level of an extraction's staging folder,
//!   which the coordinator then publishes (stage S4).
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
const io_requests = @import("io_requests.zig");
const io_discovery = @import("io_discovery.zig");
const io_manager = @import("io_manager.zig");

pub const JobId = io_service.JobId;

/// Two workers: one hung mount stalling a task leaves the other free.
pub const worker_count = 2;
/// Staging sits in the extraction's destination (`.rediwm-extract-*`, so
/// publishing is a rename), on a user mount: two for the same reason.
pub const staging_worker_count = 2;
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
    request: struct {
        window_id: io_service.WindowId,
        tag: u64,
        /// The command's payload, moved out of it. Always `.request`.
        payload: *io_service.OwnedPayload,
    },
    scan_staging: struct {
        token: io_manager.WorkToken,
        /// Owned copy of the staging path.
        path: [:0]u8,
    },
};

/// The top-level entries of a staging folder, in directory order.
pub const Scan = struct {
    allocator: Allocator,
    records: std.ArrayList(io_discovery.Record) = .empty,

    pub fn deinit(self: *Scan) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }
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
    replied: struct {
        window_id: io_service.WindowId,
        /// Null when the reply could not be allocated.
        reply: ?*io_requests.Reply,
    },
    scanned: struct {
        token: io_manager.WorkToken,
        scan: anyerror!Scan,
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
            // A delivered reply belongs to the Service; `discard` frees one
            // that never was.
            .replied => {},
            .scanned => |*scanned| if (scanned.scan) |*scan| scan.deinit() else |_| {},
        }
    }
};

pub const Pool = io_workers.WorkerPool(Task, Result);

pub const Lane = enum { tasks, staging };

pub fn laneOf(task: Task) Lane {
    return switch (task) {
        .prepare_transfer, .request => .tasks,
        .delete_tree, .scan_staging => .staging,
    };
}

/// What `discard` needs at shutdown: results of tasks nobody collected.
pub const Context = struct {
    allocator: Allocator,
    io: std.Io,
    /// Called for a `deleted` result that is discarded, so its ledger entry
    /// does not outlive the resource.
    on_discard_delete: ?*const fn (?*anyopaque, io_resource_ledger.Handle) void = null,
    owner: ?*anyopaque = null,
};

pub fn create(context: *Context, lane: Lane) !*Pool {
    const workers: usize = switch (lane) {
        .tasks => worker_count,
        .staging => staging_worker_count,
    };
    return Pool.init(context.allocator, workers, capacity, context, execute, discard);
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
        .request => |request| blk: {
            defer request.payload.deinit();
            break :blk .{ .replied = .{
                .window_id = request.window_id,
                .reply = io_requests.execute(context.allocator, context.io, request.tag, &request.payload.data.request.request),
            } };
        },
        .delete_tree => |delete| .{ .deleted = .{
            .handle = delete.handle,
            .path = delete.path,
            .failed = if (ops.deleteRecursive(context.allocator, delete.path)) |_| null else |err| err,
        } },
        .scan_staging => |scan| blk: {
            defer context.allocator.free(scan.path);
            break :blk .{ .scanned = .{ .token = scan.token, .scan = scanStaging(context.allocator, scan.path) } };
        },
    };
}

fn scanStaging(allocator: Allocator, path: [:0]const u8) !Scan {
    var cursor = try io_discovery.Cursor.open(path);
    defer cursor.deinit();
    var scan: Scan = .{ .allocator = allocator };
    errdefer scan.deinit();
    while (true) {
        var batch = try cursor.nextBatch(allocator, 256);
        defer batch.deinit();
        try scan.records.ensureUnusedCapacity(allocator, batch.records.items.len);
        // The records move into the scan; the batch keeps nothing.
        for (batch.records.items) |record| scan.records.appendAssumeCapacity(record);
        batch.records.clearRetainingCapacity();
        if (batch.complete) return scan;
    }
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
    if (result == .replied) if (result.replied.reply) |reply| reply.destroy();
    result.deinit(context.allocator);
}
