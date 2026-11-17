//! Runtime integration for the Manager-owned Files discovery service.
const App = @import("app.zig").App;
const io_manager = @import("io_manager.zig");
const io_discovery_executor = @import("io_discovery_executor.zig");

/// Starts discovery for a Job whose root entry has already been added.
/// The executor is created only when discovery is first requested.
pub fn startDiscovery(
    self: *App,
    job_id: io_manager.JobId,
    root_path: []const u8,
) !void {
    const manager = if (self.io_manager) |*value| value else
        return error.DiscoveryManagerUnavailable;

    if (self.discovery_executor == null) {
        self.discovery_executor = try io_discovery_executor.Executor.init(
            self.allocator,
            2,
            4,
            64,
        );
    }

    try manager.startDiscovery(job_id, root_path);
}

/// Reconciles completed batches and submits more bounded discovery work.
/// Called on the Files main thread; workers never access App or Manager.
pub fn stepDiscovery(self: *App) void {
    const executor = if (self.discovery_executor) |*value| value else return;
    const manager = if (self.io_manager) |*value| value else return;

    _ = executor.drainWake();
    _ = executor.drainCompletions(manager) catch {
        self.setStatusNotice("Directory discovery failed", true);
        return;
    };
    _ = executor.dispatchReady(manager) catch {
        self.setStatusNotice("Could not schedule directory discovery", true);
    };
}

/// Poll descriptor for worker completions, or -1 before discovery is used.
pub fn discoveryWakeFd(self: *App) i32 {
    const executor = if (self.discovery_executor) |*value| value else return -1;
    return @intCast(executor.wakeFd());
}
