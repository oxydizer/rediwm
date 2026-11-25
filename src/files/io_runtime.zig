//! Owns the Files I/O services shared by application instances.
//!
//! The runtime must remain at a stable address after either executor is
//! initialized: the operation executor retains a pointer to the Manager.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_manager = @import("io_manager.zig");
const io_discovery_executor = @import("io_discovery_executor.zig");
const io_operation_executor = @import("io_operation_executor.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");

pub const Runtime = struct {
    allocator: Allocator,
    manager: io_manager.Manager,
    discovery_executor: ?io_discovery_executor.Executor = null,
    operation_executor: ?io_operation_executor.Runtime = null,
    resource_ledger: io_resource_ledger.Ledger,
    retirement_requests: std.AutoHashMapUnmanaged(io_manager.JobId, void) = .empty,

    pub fn init(allocator: Allocator) Runtime {
        return .{
            .allocator = allocator,
            .manager = io_manager.Manager.init(allocator),
            .resource_ledger = io_resource_ledger.Ledger.init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Stop long-running archive work before joining either worker pool.
        if (self.operation_executor) |*executor| executor.deinit();
        if (self.discovery_executor) |*executor| executor.deinit();
        std.debug.assert(self.resource_ledger.isEmpty());
        self.retirement_requests.deinit(self.allocator);
        self.resource_ledger.deinit();
        self.manager.deinit();
        self.* = undefined;
    }

    /// Records App acknowledgement that a terminal Job has been detached.
    /// Repeated requests are harmless; reclamation is coordinated separately.
    pub fn requestJobRetirement(self: *Runtime, job_id: io_manager.JobId) !void {
        const state = self.manager.jobState(job_id) orelse return error.UnknownJob;
        if (!state.isTerminal()) return error.JobNotTerminal;

        if (!self.retirement_requests.contains(job_id)) {
            try self.retirement_requests.ensureUnusedCapacity(self.allocator, 1);
            self.retirement_requests.putAssumeCapacity(job_id, {});
        }
    }

    /// A requested Job is ready only after both executors and all
    /// Runtime-owned archive resources have released their references.
    /// Manager-side queues are safe to ignore because the Job is terminal.
    pub fn isJobRetirementReady(
        self: *const Runtime,
        job_id: io_manager.JobId,
    ) bool {
        if (!self.retirement_requests.contains(job_id)) return false;
        const state = self.manager.jobState(job_id) orelse return false;
        if (!state.isTerminal()) return false;
        if (!self.resource_ledger.isJobEmpty(job_id)) return false;
        // A window still reading one of its resources holds the job.
        if (self.resource_ledger.jobBorrowCount(job_id) != 0) return false;

        if (self.operation_executor) |*executor| {
            if (!executor.isJobQuiescent(job_id)) return false;
        }
        if (self.discovery_executor) |*executor| {
            if (!executor.isJobQuiescent(job_id)) return false;
        }
        return true;
    }

    /// Reclaims a detached terminal Job once both executors and all
    /// Runtime-owned resources have released their references.
    pub fn retireJobIfReady(self: *Runtime, job_id: io_manager.JobId) bool {
        if (!self.isJobRetirementReady(job_id)) return false;
        if (!self.manager.retireTerminalJob(job_id)) return false;
        self.resource_ledger.releaseJob(job_id) catch unreachable;
        std.debug.assert(self.retirement_requests.remove(job_id));
        return true;
    }

    /// Cancels a Job across the Manager and both executor-owned resource sets.
    pub fn cancelJob(self: *Runtime, job_id: io_manager.JobId) !void {
        if (self.operation_executor) |*executor| {
            try executor.cancelJob(job_id);
        } else {
            try self.manager.cancelJob(job_id);
        }

        if (self.discovery_executor) |*executor| {
            executor.cancelJob(&self.manager, job_id);
        }
    }

    pub fn ensureDiscoveryExecutor(
        self: *Runtime,
    ) !*io_discovery_executor.Executor {
        if (self.discovery_executor == null) {
            self.discovery_executor = try io_discovery_executor.Executor.initWithLedger(
                self.allocator,
                &self.resource_ledger,
                2,
                4,
                64,
            );
        }
        return &self.discovery_executor.?;
    }

    pub fn ensureOperationExecutor(
        self: *Runtime,
    ) !*io_operation_executor.Runtime {
        if (self.operation_executor == null) {
            self.operation_executor = try io_operation_executor.Runtime.initWithLedger(
                self.allocator,
                &self.manager,
                &self.resource_ledger,
                2,
                4,
            );
        }
        return &self.operation_executor.?;
    }

    pub fn discoveryWakeFd(self: *Runtime) i32 {
        const executor = if (self.discovery_executor) |*value| value else return -1;
        return @intCast(executor.wakeFd());
    }

    pub fn operationWakeFd(self: *Runtime) i32 {
        const executor = if (self.operation_executor) |*value| value else return -1;
        return @intCast(executor.wakeFd());
    }
};

test "I/O runtime owns and tears down both executors" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    _ = try runtime.ensureDiscoveryExecutor();
    _ = try runtime.ensureOperationExecutor();

    try std.testing.expect(runtime.discovery_executor != null);
    try std.testing.expect(runtime.operation_executor != null);
}

test "I/O runtime retirement requests require terminal jobs and both executors to quiesce" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const job_id = try runtime.manager.createJob(null);
    try std.testing.expectError(
        error.JobNotTerminal,
        runtime.requestJobRetirement(job_id),
    );
    try std.testing.expect(!runtime.isJobRetirementReady(job_id));
    try std.testing.expectError(
        error.UnknownJob,
        runtime.requestJobRetirement(job_id + 100),
    );

    try runtime.manager.queueJob(job_id);
    _ = try runtime.ensureDiscoveryExecutor();
    _ = try runtime.ensureOperationExecutor();

    try runtime.requestJobRetirement(job_id);
    try runtime.requestJobRetirement(job_id);
    try std.testing.expect(runtime.isJobRetirementReady(job_id));
    try std.testing.expect(!runtime.isJobRetirementReady(job_id + 100));
    try std.testing.expect(runtime.retireJobIfReady(job_id));
    try std.testing.expectEqual(@as(?io_manager.JobState, null), runtime.manager.jobState(job_id));
    try std.testing.expect(!runtime.isJobRetirementReady(job_id));
    try std.testing.expect(!runtime.retireJobIfReady(job_id));
}
