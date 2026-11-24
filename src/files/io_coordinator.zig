//! Dedicated process thread for Files Runtime ownership and I/O scheduling.
//!
//! The coordinator is the only consumer of the process Service command queue.
//! It owns all access to Runtime after startup; windows retain only Service
//! handles and immutable updates.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const io_runtime = @import("io_runtime.zig");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const io_tree = @import("io_tree.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const ops_mod = @import("ops.zig");

const JobId = io_service.JobId;

const PublishedJobState = struct {
    state: ?io_manager.JobState = null,
    has_progress: bool = false,
    completed_bytes: u64 = 0,
    total_bytes: u64 = 0,
    rate_bytes_per_second: u64 = 0,
};

const RejectionCode = enum(u8) {
    unsupported_command = 1,
    unknown_job = 2,
    invalid_job_state = 3,
    job_not_terminal = 4,
    missing_payload = 5,
    other = 255,
};

pub const Coordinator = struct {
    allocator: Allocator,
    service: *io_service.Service,
    runtime: *io_runtime.Runtime,
    thread: ?std.Thread = null,
    published_jobs: std.AutoHashMapUnmanaged(JobId, PublishedJobState) = .empty,
    last_published_conflict_id: ?io_manager.ConflictId = null,

    /// Initialize at a stable address. The Runtime is allocated separately
    /// because its executors retain pointers into it and into its Manager.
    pub fn init(
        self: *Coordinator,
        allocator: Allocator,
        service: *io_service.Service,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .service = service,
            .runtime = undefined,
        };

        const runtime = try allocator.create(io_runtime.Runtime);
        errdefer allocator.destroy(runtime);
        runtime.* = io_runtime.Runtime.init(allocator);
        errdefer runtime.deinit();

        // Keep the existing bounded worker-pool sizes. Creating both pools
        // before the thread starts gives its poll set stable wake descriptors.
        _ = try runtime.ensureDiscoveryExecutor();
        _ = try runtime.ensureOperationExecutor();

        self.runtime = runtime;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Stops admission, wakes the coordinator and joins its thread. Runtime
    /// teardown happens on the coordinator thread after its loop has ended.
    pub fn deinit(self: *Coordinator) void {
        self.service.beginShutdown();
        if (self.thread) |thread| thread.join();
        self.published_jobs.deinit(self.allocator);
        self.* = undefined;
    }

    fn threadMain(self: *Coordinator) void {
        defer {
            self.runtime.deinit();
            self.allocator.destroy(self.runtime);
        }

        while (true) {
            _ = self.service.drainCommandWake();
            while (self.service.tryReceiveCommand()) |routed| {
                self.handleCommand(routed);
            }

            self.pumpExecutors();
            self.publishJobUpdates() catch |err| {
                std.log.err("Files job update publication failed: {s}", .{@errorName(err)});
            };
            self.publishConflictUpdate() catch |err| {
                std.log.err("Files conflict update publication failed: {s}", .{@errorName(err)});
            };
            self.retireReadyJobs();

            if (self.service.isStopping()) break;
            self.waitForWork();
        }
    }

    fn waitForWork(self: *Coordinator) void {
        const discovery = if (self.runtime.discovery_executor) |*executor|
            executor
        else
            unreachable;
        const operation = if (self.runtime.operation_executor) |*executor|
            executor
        else
            unreachable;
        var fds = [_]std.posix.pollfd{
            .{
                .fd = self.service.commandWakeFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = discovery.wakeFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = operation.wakeFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        while (true) {
            const rc = std.posix.system.poll(&fds, fds.len, -1);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => std.debug.panic(
                    "Files I/O coordinator poll failed: {s}",
                    .{@tagName(std.posix.errno(rc))},
                ),
            }
        }
    }

    fn pumpExecutors(self: *Coordinator) void {
        if (self.runtime.discovery_executor) |*executor| {
            _ = executor.drainWake();
            _ = executor.drainCompletions(&self.runtime.manager) catch |err| blk: {
                std.log.err("Files discovery completion reconciliation failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
            _ = executor.dispatchReady(&self.runtime.manager) catch |err| blk: {
                std.log.err("Files discovery scheduling failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
        }

        if (self.runtime.operation_executor) |*executor| {
            _ = executor.drainWake();
            _ = executor.drainCompletions() catch |err| blk: {
                std.log.err("Files operation completion reconciliation failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
            _ = executor.dispatchReady() catch |err| blk: {
                std.log.err("Files operation scheduling failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
        }
    }

    fn handleCommand(
        self: *Coordinator,
        routed_value: io_service.RoutedCommand,
    ) void {
        var routed = routed_value;
        defer routed.command.deinitPayload();
        self.applyCommand(routed) catch |err| {
            const code = rejectionCode(err);
            _ = self.service.publishUpdate(routed.window_id, .{
                .job_id = routed.command.job_id,
                .kind = .command_rejected,
                .state_code = @backingInt(code),
            }) catch {};
        };
    }

    fn applyCommand(
        self: *Coordinator,
        routed: io_service.RoutedCommand,
    ) anyerror!void {
        const command = routed.command;
        switch (command.kind) {
            .pause_job => try self.runtime.manager.pauseJob(command.job_id),
            .resume_job => try self.runtime.manager.resumeJob(command.job_id),
            .cancel_job => try self.runtime.cancelJob(command.job_id),
            .retire_job => try self.runtime.requestJobRetirement(command.job_id),
            .submit_job => try self.submitTransfer(routed),
            .start_discovery => try self.startDiscovery(command.job_id, command.payload),
            .prioritize_discovery => try self.prioritizeDiscovery(command.job_id, command.payload),
            .resolve_conflict => try self.resolveConflict(
                routed.window_id,
                command.payload,
            ),
            .release_resource => try self.releaseResource(
                routed.window_id,
                command.job_id,
                command.resource_id,
            ),
        }
    }

    fn releaseResource(
        self: *Coordinator,
        window_id: io_service.WindowId,
        job_id: JobId,
        resource_id: io_service.ResourceId,
    ) !void {
        const handle = io_resource_ledger.Handle{ .id = resource_id };
        const ledger = &self.runtime.resource_ledger;
        const resource_job_id = ledger.jobIdOf(handle) orelse
            return error.UnknownResource;
        if (resource_job_id != job_id) return error.ResourceJobMismatch;

        const owner = ledger.ownerOf(handle) orelse return error.UnknownResource;
        const kind = ledger.kindOf(handle) orelse return error.UnknownResource;

        const snapshots = try self.runtime.manager.snapshotJobs(self.allocator);
        defer {
            for (snapshots) |*snapshot| snapshot.deinit();
            self.allocator.free(snapshots);
        }

        var owns_job = false;
        for (snapshots) |snapshot| {
            if (snapshot.id != job_id) continue;
            owns_job = snapshot.origin_window_id == window_id;
            break;
        }
        if (!owns_job) return error.ResourceWindowMismatch;

        switch (owner) {
            .operation_worker, .discovery_worker => return error.ResourceBusy,
            .app => return error.ResourceNotServiceOwned,
            .operation_executor, .discovery_executor => {},
        }

        const state = self.runtime.manager.jobState(job_id) orelse
            return error.UnknownJob;
        if (!state.isTerminal()) return error.ResourceBusy;

        switch (owner) {
            .discovery_executor => {
                if (kind != .discovery_anchor and kind != .discovery_cursor)
                    return error.ResourceNotReleasable;
                const executor = if (self.runtime.discovery_executor) |*value|
                    value
                else
                    return error.ResourceOwnerUnavailable;
                try executor.releaseResource(handle);
            },
            .operation_executor => {
                if (kind != .archive_staging)
                    return error.ResourceNotReleasable;
                const executor = if (self.runtime.operation_executor) |*value|
                    value
                else
                    return error.ResourceOwnerUnavailable;
                try executor.releaseResource(handle);
            },
            .operation_worker, .discovery_worker, .app => unreachable,
        }
    }

    fn startDiscovery(
        self: *Coordinator,
        job_id: JobId,
        payload: ?*io_service.OwnedPayload,
    ) !void {
        const owned = payload orelse return error.MissingDiscoveryPayload;
        const request = switch (owned.data) {
            .discovery => |*discovery| discovery,
            else => return error.UnexpectedDiscoveryPayload,
        };
        const root_path = request.root_path orelse
            return error.MissingDiscoveryRootPath;
        try self.runtime.manager.startRootDiscovery(
            job_id,
            request.root_entry_id,
            root_path,
        );
    }

    fn prioritizeDiscovery(
        self: *Coordinator,
        job_id: JobId,
        payload: ?*io_service.OwnedPayload,
    ) !void {
        const owned = payload orelse return error.MissingDiscoveryPayload;
        const request = switch (owned.data) {
            .discovery => |*discovery| discovery,
            else => return error.UnexpectedDiscoveryPayload,
        };
        try self.runtime.manager.prioritizeDiscovery(
            job_id,
            request.root_entry_id,
        );
    }

    fn resolveConflict(
        self: *Coordinator,
        window_id: io_service.WindowId,
        payload: ?*io_service.OwnedPayload,
    ) !void {
        const owned = payload orelse return error.MissingConflictResolutionPayload;
        const request = switch (owned.data) {
            .conflict_resolution => |*resolution| resolution,
            else => return error.UnexpectedConflictResolutionPayload,
        };
        const manager = &self.runtime.manager;
        const conflict = manager.nextConflict() orelse
            return error.ConflictNotAtQueueHead;
        if (conflict.id != request.conflict_id)
            return error.ConflictNotAtQueueHead;

        const snapshots = try manager.snapshotJobs(self.allocator);
        defer {
            for (snapshots) |*snapshot| snapshot.deinit();
            self.allocator.free(snapshots);
        }
        var owns_job = false;
        for (snapshots) |snapshot| {
            if (snapshot.id != conflict.job_id) continue;
            owns_job = snapshot.origin_window_id == window_id;
            break;
        }
        if (!owns_job) return error.ConflictWindowMismatch;

        switch (request.action) {
            .retry => try manager.resolveConflict(request.conflict_id),
            .replace => try manager.replaceConflict(request.conflict_id),
            .merge => try manager.mergeConflict(request.conflict_id),
            .rename => try manager.renameConflict(
                request.conflict_id,
                request.destination_path orelse return error.MissingConflictDestinationPath,
            ),
            .skip => try manager.skipConflict(request.conflict_id),
            .cancel => try manager.cancelConflict(request.conflict_id),
        }
    }

    /// Builds and queues a basic file/symlink transfer entirely on the
    /// coordinator thread. No filesystem metadata crosses the UI boundary.
    fn submitTransfer(
        self: *Coordinator,
        routed: io_service.RoutedCommand,
    ) !void {
        const payload = routed.command.payload orelse
            return error.MissingTransferPayload;
        const request = switch (payload.data) {
            .transfer => |*transfer| transfer,
            .discovery, .conflict_resolution => return error.UnexpectedTransferPayload,
        };
        if (request.sources.len == 0) return error.EmptyTransfer;
        if (request.destination_path.len == 0 or
            !std.fs.path.isAbsolute(request.destination_path) or
            std.mem.indexOfScalar(u8, request.destination_path, 0) != null)
        {
            return error.InvalidTransferDestination;
        }

        const destination_z = try self.allocator.dupeSentinel(
            u8,
            request.destination_path,
            0,
        );
        defer self.allocator.free(destination_z);

        var destination_stat: c.struct_stat = undefined;
        if (c.stat(destination_z, &destination_stat) != 0 or
            (destination_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
        {
            return error.InvalidTransferDestination;
        }

        // Directory roots use Manager-owned incremental discovery. Keep
        // mixed selections out of this path because move planning has a
        // distinct operation mode for directory roots.
        var directory_count: usize = 0;
        for (request.sources) |source| {
            if (source.path.len == 0 or
                !std.fs.path.isAbsolute(source.path) or
                std.mem.indexOfScalar(u8, source.path, 0) != null)
            {
                return error.InvalidTransferSource;
            }

            const source_z = try self.allocator.dupeSentinel(u8, source.path, 0);
            defer self.allocator.free(source_z);
            var source_stat: c.struct_stat = undefined;
            if (c.lstat(source_z, &source_stat) != 0)
                return error.InvalidTransferSource;
            if ((source_stat.st_mode & c.S_IFMT) == c.S_IFDIR)
                directory_count += 1;
        }

        if (directory_count != 0) {
            if (directory_count != request.sources.len)
                return error.MixedTransferSourceKinds;
            try self.submitDirectoryTransfer(routed, request, destination_stat);
            return;
        }

        const manager = &self.runtime.manager;
        const job_id = try manager.createJob(routed.window_id);
        errdefer std.debug.assert(manager.discardPlanningJob(job_id));

        for (request.sources) |source| {
            if (source.path.len == 0 or
                !std.fs.path.isAbsolute(source.path) or
                std.mem.indexOfScalar(u8, source.path, 0) != null)
            {
                return error.InvalidTransferSource;
            }

            const name = std.fs.path.basename(source.path);
            if (name.len == 0) return error.InvalidTransferSource;

            const source_z = try self.allocator.dupeSentinel(u8, source.path, 0);
            defer self.allocator.free(source_z);

            var source_stat: c.struct_stat = undefined;
            if (c.lstat(source_z, &source_stat) != 0)
                return error.InvalidTransferSource;

            const kind: io_tree.EntryKind = switch (source_stat.st_mode & c.S_IFMT) {
                c.S_IFREG => .regular_file,
                c.S_IFLNK => .symlink,
                else => return error.UnsupportedTransferSource,
            };

            var symlink_target: ?[]u8 = null;
            defer if (symlink_target) |target| self.allocator.free(target);
            if (kind == .symlink) {
                var target_buffer: [4096]u8 = undefined;
                const target_len = c.readlink(
                    source_z,
                    &target_buffer,
                    target_buffer.len,
                );
                if (target_len < 0 or target_len == target_buffer.len)
                    return error.InvalidTransferSource;
                symlink_target = try self.allocator.dupe(
                    u8,
                    target_buffer[0..@intCast(target_len)],
                );
            }

            const target_path = try std.fs.path.join(
                self.allocator,
                &.{ request.destination_path, name },
            );
            defer self.allocator.free(target_path);
            if (std.mem.eql(u8, source.path, target_path))
                return error.TransferSourceEqualsDestination;

            const metadata: io_tree.Metadata = .{
                .size = @intCast(@max(source_stat.st_size, 0)),
                .mode = @intCast(source_stat.st_mode),
                .device_id = @intCast(source_stat.st_dev),
                .inode_id = @intCast(source_stat.st_ino),
                .mtime_sec = @intCast(source_stat.st_mtim.tv_sec),
                .mtime_nsec = @intCast(source_stat.st_mtim.tv_nsec),
                .ctime_sec = @intCast(source_stat.st_ctim.tv_sec),
                .ctime_nsec = @intCast(source_stat.st_ctim.tv_nsec),
            };

            const root_id = try manager.addTreeRoot(
                job_id,
                name,
                kind,
                metadata,
                symlink_target,
            );
            try manager.setRootSourcePath(job_id, root_id, source.path);

            const operation_kind: io_manager.OperationKind = switch (kind) {
                .regular_file => .copy_file,
                .symlink => .copy_symlink,
                else => unreachable,
            };

            if (request.mode == .move and
                source_stat.st_dev == destination_stat.st_dev)
            {
                _ = try manager.addEntryOperation(job_id, root_id, .move_entry);
            } else {
                _ = try manager.addEntryOperation(job_id, root_id, operation_kind);
                if (request.mode == .move)
                    _ = try manager.addEntryOperation(job_id, root_id, .detach_source);
            }
        }

        try manager.setDestinationDirectory(job_id, request.destination_path);
        if (request.mode == .move)
            try manager.setDestinationDeviceId(job_id, @intCast(destination_stat.st_dev));
        try manager.queueJob(job_id);
    }

    /// Plans selected directory roots and lets Manager incrementally discover
    /// and schedule their descendants. Discovery and operation execution stay
    /// on the existing process-owned Runtime.
    fn submitDirectoryTransfer(
        self: *Coordinator,
        routed: io_service.RoutedCommand,
        request: *const io_service.TransferRequest,
        destination_stat: c.struct_stat,
    ) !void {
        const manager = &self.runtime.manager;
        const job_id = try manager.createJob(routed.window_id);
        errdefer std.debug.assert(manager.discardPlanningJob(job_id));

        var roots: std.ArrayList(io_manager.DiscoveryRoot) = .empty;
        defer roots.deinit(self.allocator);

        for (request.sources, 0..) |source, index| {
            const name = std.fs.path.basename(source.path);
            if (name.len == 0) return error.InvalidTransferSource;

            const source_z = try self.allocator.dupeSentinel(
                u8,
                source.path,
                0,
            );
            defer self.allocator.free(source_z);

            var source_stat: c.struct_stat = undefined;
            if (c.lstat(source_z, &source_stat) != 0 or
                (source_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
            {
                return error.InvalidTransferSource;
            }

            // Do not move a directory that is itself a mount point.
            if (request.mode == .move) {
                const parent_path = std.fs.path.dirname(source.path) orelse "/";
                const parent_z = try self.allocator.dupeSentinel(
                    u8,
                    parent_path,
                    0,
                );
                defer self.allocator.free(parent_z);

                var parent_stat: c.struct_stat = undefined;
                if (c.stat(parent_z, &parent_stat) != 0 or
                    source_stat.st_dev != parent_stat.st_dev)
                {
                    return error.MountedDirectoryMoveUnsupported;
                }

                // Independent discovery roots must not overlap during a
                // move: detaching a parent could invalidate a child root.
                for (request.sources[0..index]) |previous| {
                    if (ops_mod.isDescendantOrSame(source.path, previous.path) or
                        ops_mod.isDescendantOrSame(previous.path, source.path))
                    {
                        return error.OverlappingDirectoryMoveRoots;
                    }
                }
            }

            // Discovery must not traverse into the destination it creates.
            if (ops_mod.isDescendantOrSame(source.path, request.destination_path))
                return error.TransferDestinationInsideSource;

            const metadata: io_tree.Metadata = .{
                .mode = @intCast(source_stat.st_mode),
                .device_id = @intCast(source_stat.st_dev),
                .inode_id = @intCast(source_stat.st_ino),
                .mtime_sec = @intCast(source_stat.st_mtim.tv_sec),
                .mtime_nsec = @intCast(source_stat.st_mtim.tv_nsec),
                .ctime_sec = @intCast(source_stat.st_ctim.tv_sec),
                .ctime_nsec = @intCast(source_stat.st_ctim.tv_nsec),
            };

            const root_id = try manager.addTreeRoot(
                job_id,
                name,
                .directory,
                metadata,
                null,
            );
            try roots.append(self.allocator, .{
                .root_id = root_id,
                .path = source.path,
            });
        }

        try manager.setDestinationDirectory(job_id, request.destination_path);

        if (request.mode == .move) {
            try manager.setDestinationDeviceId(
                job_id,
                @intCast(destination_stat.st_dev),
            );
            for (roots.items) |root| {
                _ = try manager.addEntryOperation(
                    job_id,
                    root.root_id,
                    .create_directory,
                );
                _ = try manager.addEntryOperation(
                    job_id,
                    root.root_id,
                    .detach_source,
                );
            }
            try manager.enableDiscoveredEntryMoves(job_id);
        } else {
            try manager.enableDiscoveredEntryOperations(job_id);
            for (roots.items) |root| {
                _ = try manager.addEntryOperation(
                    job_id,
                    root.root_id,
                    .create_directory,
                );
            }
        }

        // This call atomically commits the job and all discovery roots.
        try manager.queueJobWithDiscoveryRoots(job_id, roots.items);
    }

    /// Publishes immutable job state and aggregate operation progress to the
    /// window that submitted each job. The cache suppresses unchanged updates.
    fn publishJobUpdates(self: *Coordinator) !void {
        const snapshots = try self.runtime.manager.snapshotJobs(self.allocator);
        defer {
            for (snapshots) |*snapshot| snapshot.deinit();
            self.allocator.free(snapshots);
        }

        for (snapshots) |snapshot| {
            const window_id = snapshot.origin_window_id orelse continue;
            var published = self.published_jobs.get(snapshot.id) orelse
                PublishedJobState{};
            var changed = false;

            if (published.state != snapshot.state) {
                _ = self.service.publishUpdate(window_id, .{
                    .job_id = snapshot.id,
                    .kind = .job_state,
                    .state_code = @intCast(@intFromEnum(snapshot.state)),
                }) catch |err| {
                    if (err != error.WindowClosed) {
                        std.log.err(
                            "Files job state update failed for job {d}: {s}",
                            .{ snapshot.id, @errorName(err) },
                        );
                    }
                    continue;
                };
                published.state = snapshot.state;
                changed = true;
            }

            var completed_bytes: u64 = 0;
            var total_bytes: u64 = 0;
            var rate_bytes_per_second: u64 = 0;
            for (snapshot.operations) |operation| {
                completed_bytes +|= operation.progress_bytes;
                total_bytes +|= operation.progress_total_bytes;
                rate_bytes_per_second +|= operation.progress_bytes_per_second;
            }

            if (total_bytes > 0 and
                (!published.has_progress or
                    published.completed_bytes != completed_bytes or
                    published.total_bytes != total_bytes or
                    published.rate_bytes_per_second != rate_bytes_per_second))
            {
                _ = self.service.publishUpdate(window_id, .{
                    .job_id = snapshot.id,
                    .kind = .progress,
                    .completed_bytes = completed_bytes,
                    .total_bytes = total_bytes,
                    .rate_bytes_per_second = rate_bytes_per_second,
                }) catch |err| {
                    if (err != error.WindowClosed) {
                        std.log.err(
                            "Files job progress update failed for job {d}: {s}",
                            .{ snapshot.id, @errorName(err) },
                        );
                    }
                    continue;
                };
                published.has_progress = true;
                published.completed_bytes = completed_bytes;
                published.total_bytes = total_bytes;
                published.rate_bytes_per_second = rate_bytes_per_second;
                changed = true;
            }

            if (changed)
                try self.published_jobs.put(self.allocator, snapshot.id, published);
        }
    }

    /// Publishes only the FIFO conflict head. Its Job snapshot supplies the
    /// originating window; the conflict view itself remains Manager-owned.
    /// A new head receives a new notification, while repeated coordinator
    /// iterations do not duplicate the current notification.
    fn publishConflictUpdate(self: *Coordinator) !void {
        const conflict = self.runtime.manager.nextConflict() orelse {
            self.last_published_conflict_id = null;
            return;
        };
        if (self.last_published_conflict_id == conflict.id) return;

        const snapshots = try self.runtime.manager.snapshotJobs(self.allocator);
        defer {
            for (snapshots) |*snapshot| snapshot.deinit();
            self.allocator.free(snapshots);
        }

        for (snapshots) |snapshot| {
            if (snapshot.id != conflict.job_id) continue;
            const window_id = snapshot.origin_window_id orelse {
                self.last_published_conflict_id = conflict.id;
                return;
            };
            _ = self.service.publishUpdate(window_id, .{
                .job_id = conflict.job_id,
                .kind = .conflict,
                .conflict_id = conflict.id,
            }) catch |err| {
                if (err == error.WindowClosed) {
                    self.last_published_conflict_id = conflict.id;
                    return;
                }
                return err;
            };
            self.last_published_conflict_id = conflict.id;
            return;
        }

        // The conflict's Job may have been retired between observations.
        self.last_published_conflict_id = conflict.id;
    }

    fn retireReadyJobs(self: *Coordinator) void {
        while (true) {
            var candidate: ?JobId = null;
            var iterator = self.runtime.retirement_requests.keyIterator();
            while (iterator.next()) |job_id| {
                if (self.runtime.isJobRetirementReady(job_id.*)) {
                    candidate = job_id.*;
                    break;
                }
            }

            const job_id = candidate orelse return;
            if (!self.runtime.retireJobIfReady(job_id)) return;
            _ = self.published_jobs.remove(job_id);
        }
    }
};

fn rejectionCode(err: anyerror) RejectionCode {
    return if (err == error.UnsupportedCommand)
        .unsupported_command
    else if (err == error.MissingTransferPayload or
        err == error.MissingDiscoveryPayload or
        err == error.MissingConflictResolutionPayload)
        .missing_payload
    else if (err == error.UnknownJob)
        .unknown_job
    else if (err == error.InvalidJobState)
        .invalid_job_state
    else if (err == error.JobNotTerminal)
        .job_not_terminal
    else
        .other;
}

test "coordinator protects worker and App resources during release" {
    const allocator = std.testing.allocator;

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();

    var owner_window = try service.registerWindow();
    defer owner_window.close() catch unreachable;
    var other_window = try service.registerWindow();
    defer other_window.close() catch unreachable;

    const job_id = try runtime.manager.createJob(owner_window.window_id);
    const app_resource = try runtime.resource_ledger.register(
        job_id,
        .archive_publication_cursor,
        .app,
    );
    const worker_resource = try runtime.resource_ledger.register(
        job_id,
        .archive_cancellation,
        .operation_worker,
    );

    var coordinator: Coordinator = .{
        .allocator = allocator,
        .service = &service,
        .runtime = &runtime,
    };

    try std.testing.expectError(
        error.ResourceWindowMismatch,
        coordinator.releaseResource(
            other_window.window_id,
            job_id,
            app_resource.id,
        ),
    );
    try std.testing.expectError(
        error.ResourceNotServiceOwned,
        coordinator.releaseResource(
            owner_window.window_id,
            job_id,
            app_resource.id,
        ),
    );
    try std.testing.expectError(
        error.ResourceBusy,
        coordinator.releaseResource(
            owner_window.window_id,
            job_id,
            worker_resource.id,
        ),
    );
    try std.testing.expectError(
        error.UnknownResource,
        coordinator.releaseResource(
            owner_window.window_id,
            job_id,
            std.math.maxInt(io_service.ResourceId),
        ),
    );
    try std.testing.expectError(
        error.ResourceJobMismatch,
        coordinator.releaseResource(
            owner_window.window_id,
            job_id + 1,
            app_resource.id,
        ),
    );

    try std.testing.expectEqual(
        io_resource_ledger.Owner.app,
        runtime.resource_ledger.ownerOf(app_resource).?,
    );
    try std.testing.expectEqual(
        io_resource_ledger.Owner.operation_worker,
        runtime.resource_ledger.ownerOf(worker_resource).?,
    );

    try runtime.resource_ledger.release(app_resource, .app);
    try runtime.resource_ledger.release(worker_resource, .operation_worker);
}
