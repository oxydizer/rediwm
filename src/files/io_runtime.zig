//! Owns the Files I/O services shared by application instances.
//!
//! The runtime must remain at a stable address after either executor is
//! initialized: the operation executor retains a pointer to the Manager.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_manager = @import("io_manager.zig");
const io_discovery_executor = @import("io_discovery_executor.zig");
const io_operation_executor = @import("io_operation_executor.zig");

pub const Runtime = struct {
    allocator: Allocator,
    manager: io_manager.Manager,
    discovery_executor: ?io_discovery_executor.Executor = null,
    operation_executor: ?io_operation_executor.Runtime = null,

    pub fn init(allocator: Allocator) Runtime {
        return .{
            .allocator = allocator,
            .manager = io_manager.Manager.init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Stop long-running archive work before joining either worker pool.
        if (self.operation_executor) |*executor| executor.deinit();
        if (self.discovery_executor) |*executor| executor.deinit();
        self.manager.deinit();
        self.* = undefined;
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
            self.discovery_executor = try io_discovery_executor.Executor.init(
                self.allocator,
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
            self.operation_executor = try io_operation_executor.Runtime.init(
                self.allocator,
                &self.manager,
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
