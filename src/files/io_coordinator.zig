//! Dedicated process thread for Files Runtime ownership and I/O scheduling.
//!
//! The coordinator is the only consumer of the process Service command queue.
//! It owns all access to Runtime after startup; windows retain only Service
//! handles and immutable updates.
const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const io_transfer_plan = @import("io_transfer_plan.zig");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const io_runtime = @import("io_runtime.zig");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const io_tree = @import("io_tree.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const ops_mod = @import("ops.zig");

const JobId = io_service.JobId;

/// The last record written for a job, and when progress and the speed
/// history were last written.
const Published = struct {
    record: io_service.JobRecord,
    last_progress_ms: i64 = 0,
    last_sample_ms: i64 = 0,
};

/// Progress-only changes are written at most this often per job; state,
/// cancellation and conflict changes are written at once (threading §6).
const progress_interval_ms = 50;
const rate_sample_interval_ms = 1000;

/// Ids for submits that failed before a Manager job existed. The high bit
/// keeps them apart from Manager job ids, which count up from 1.
const failed_submit_id_base: JobId = 1 << 63;

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

fn wallClockMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

/// Manager and record states share names and order.
fn recordState(state: io_manager.JobState) io_service.JobState {
    comptime {
        const a = @typeInfo(io_manager.JobState).@"enum";
        const b = @typeInfo(io_service.JobState).@"enum";
        std.debug.assert(a.field_names.len == b.field_names.len);
        for (a.field_names, b.field_names, a.field_values, b.field_values) |x, y, xv, yv|
            std.debug.assert(std.mem.eql(u8, x, y) and xv == yv);
    }
    return @enumFromInt(@intFromEnum(state));
}

pub const RejectionCode = enum(u8) {
    unsupported_command = 1,
    unknown_job = 2,
    invalid_job_state = 3,
    job_not_terminal = 4,
    missing_payload = 5,
    invalid_destination = 6,
    invalid_source = 7,
    unsupported_source = 8,
    destination_inside_source = 9,
    overlapping_move_roots = 10,
    mounted_directory_move = 11,
    nothing_to_transfer = 12,
    other = 255,
};

pub const Coordinator = struct {
    allocator: Allocator,
    service: *io_service.Service,
    runtime: *io_runtime.Runtime,
    thread: ?std.Thread = null,
    published: std.AutoHashMapUnmanaged(JobId, Published) = .empty,
    next_failed_submit_id: JobId = failed_submit_id_base,

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
        self.published.deinit(self.allocator);
        self.* = undefined;
    }

    fn threadMain(self: *Coordinator) void {
        io_thread_guard.markCurrent(.coordinator);
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
            const deadline = self.publishRecords(monotonicMs());
            self.retireReadyJobs();

            if (self.service.isStopping()) break;
            self.waitForWork(deadline);
        }
    }

    /// Waits for a command, a completion, or `deadline` (monotonic ms) when
    /// throttled progress or a speed sample is still due.
    fn waitForWork(self: *Coordinator, deadline: ?i64) void {
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

        const timeout: i32 = if (deadline) |at|
            @intCast(std.math.clamp(at - monotonicMs(), 0, std.math.maxInt(i32)))
        else
            -1;
        while (true) {
            const rc = std.posix.system.poll(&fds, fds.len, timeout);
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
        if (routed.command.kind == .submit_job) return self.handleSubmit(routed);
        // There is no reply channel: a command that cannot apply changes
        // nothing; the job table shows what did happen (threading §5).
        self.applyCommand(routed) catch |err| {
            std.log.info("Files I/O command {s} for job {d} not applied: {s}", .{
                @tagName(routed.command.kind), routed.command.job_id, @errorName(err),
            });
        };
    }

    /// Every admitted submit ends up as a record: the job's, or a `failed`
    /// one carrying the rejection code, so the window always learns the
    /// outcome through its submit_tag.
    fn handleSubmit(self: *Coordinator, routed: io_service.RoutedCommand) void {
        var record: io_service.JobRecord = .{
            .origin_window_id = routed.window_id,
            .submit_tag = routed.command.submit_tag,
            .started_at_ms = wallClockMs(),
        };
        if (routed.command.payload) |payload| switch (payload.data) {
            .transfer => |*request| {
                record.kind = if (request.mode == .move) .move else .copy;
                record.source_count = @intCast(@min(request.sources.len, std.math.maxInt(u32)));
                if (request.sources.len > 0) record.setLabel(std.fs.path.basename(request.sources[0].path));
            },
            else => {},
        };

        if (self.submitTransfer(routed)) |job_id| {
            record.id = job_id;
            record.state = .queued;
            if (self.runtime.manager.jobSummary(job_id)) |summary| applySummary(&record, summary);
            self.service.createJobRecord(record, true) catch |err| {
                std.log.err("Files job record for job {d} failed: {s}", .{ job_id, @errorName(err) });
                return;
            };
            self.published.put(self.allocator, job_id, .{ .record = record }) catch |err| {
                std.log.err("Files job record cache failed: {s}", .{@errorName(err)});
            };
        } else |err| {
            record.id = self.next_failed_submit_id;
            self.next_failed_submit_id += 1;
            record.state = .failed;
            record.error_code = @backingInt(rejectionCode(err));
            record.finished_at_ms = record.started_at_ms;
            self.service.createJobRecord(record, true) catch |create_err| {
                std.log.err("Files failed-submit record failed: {s}", .{@errorName(create_err)});
                return;
            };
            self.service.retireJobRecord(record.id) catch {};
        }
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
            .submit_job => unreachable, // handleSubmit
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
        const io_guard_2 = io_thread_guard.exempt(.c2_resource_cleanup);
        defer io_guard_2.end();
        const handle = io_resource_ledger.Handle{ .id = resource_id };
        const ledger = &self.runtime.resource_ledger;
        const resource_job_id = ledger.jobIdOf(handle) orelse
            return error.UnknownResource;
        if (resource_job_id != job_id) return error.ResourceJobMismatch;

        const owner = ledger.ownerOf(handle) orelse return error.UnknownResource;
        const kind = ledger.kindOf(handle) orelse return error.UnknownResource;

        // The origin check goes in S2, when a holder check replaces it.
        if (self.runtime.manager.jobOriginWindow(job_id) != window_id)
            return error.ResourceWindowMismatch;

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

        // The origin check goes in S2: any window may resolve any conflict.
        if (manager.jobOriginWindow(conflict.job_id) != window_id)
            return error.ConflictWindowMismatch;

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

    /// Plans a transfer of any mix of files, symlinks and directories and
    /// queues it as one Manager job. Filesystem inspection is confined to
    /// `prepareTransfer`, which stage S2 moves onto a discovery worker;
    /// `applyTransferPlan` touches only the Manager.
    fn submitTransfer(
        self: *Coordinator,
        routed: io_service.RoutedCommand,
    ) !JobId {
        const payload = routed.command.payload orelse
            return error.MissingTransferPayload;
        const request = switch (payload.data) {
            .transfer => |*transfer| transfer,
            .discovery, .conflict_resolution => return error.UnexpectedTransferPayload,
        };
        var plan = plan: {
            const io_guard = io_thread_guard.exempt(.c1_submit_validation);
            defer io_guard.end();
            break :plan try io_transfer_plan.prepare(self.allocator, request);
        };
        defer plan.deinit();
        return self.applyTransferPlan(routed.window_id, request.mode, &plan);
    }

    fn applyTransferPlan(
        self: *Coordinator,
        window_id: io_service.WindowId,
        mode: io_service.TransferMode,
        plan: *const io_transfer_plan.TransferPlan,
    ) !JobId {
        const manager = &self.runtime.manager;
        const job_id = try manager.createJob(window_id);
        errdefer std.debug.assert(manager.discardPlanningJob(job_id));

        var discovery_roots: std.ArrayList(io_manager.DiscoveryRoot) = .empty;
        defer discovery_roots.deinit(self.allocator);
        var directory_root_ids: std.ArrayList(io_tree.EntryId) = .empty;
        defer directory_root_ids.deinit(self.allocator);

        for (plan.sources.items) |source| {
            const root_id = try manager.addTreeRoot(
                job_id,
                source.destination_name,
                source.kind,
                source.metadata,
                source.symlink_target,
            );
            switch (source.kind) {
                .directory => {
                    try discovery_roots.append(self.allocator, .{
                        .root_id = root_id,
                        .path = source.path,
                    });
                    try directory_root_ids.append(self.allocator, root_id);
                },
                .regular_file, .symlink => {
                    try manager.setRootSourcePath(job_id, root_id, source.path);
                    const copy_kind: io_manager.OperationKind =
                        if (source.kind == .regular_file) .copy_file else .copy_symlink;
                    if (mode == .move and source.same_device) {
                        _ = try manager.addEntryOperation(job_id, root_id, .move_entry);
                    } else {
                        _ = try manager.addEntryOperation(job_id, root_id, copy_kind);
                        if (mode == .move)
                            _ = try manager.addEntryOperation(job_id, root_id, .detach_source);
                    }
                },
                .other => unreachable,
            }
        }

        try manager.setDestinationDirectory(job_id, plan.destination_path);
        if (mode == .move)
            try manager.setDestinationDeviceId(job_id, plan.destination_device_id);

        if (directory_root_ids.items.len == 0) {
            try manager.queueJob(job_id);
            return job_id;
        }

        if (mode == .move) {
            for (directory_root_ids.items) |root_id| {
                _ = try manager.addEntryOperation(job_id, root_id, .create_directory);
                _ = try manager.addEntryOperation(job_id, root_id, .detach_source);
            }
            try manager.enableDiscoveredEntryMoves(job_id);
        } else {
            try manager.enableDiscoveredEntryOperations(job_id);
            for (directory_root_ids.items) |root_id| {
                _ = try manager.addEntryOperation(job_id, root_id, .create_directory);
            }
        }
        // Atomically commits the job and all discovery roots.
        try manager.queueJobWithDiscoveryRoots(job_id, discovery_roots.items);
        return job_id;
    }

    /// Writes each job's record from its O(1) Manager summary. State,
    /// cancellation and conflict changes are written at once; progress at
    /// most every `progress_interval_ms`; a speed sample every second.
    /// Returns the next time throttled work is due, if any.
    fn publishRecords(self: *Coordinator, now: i64) ?i64 {
        const manager = &self.runtime.manager;
        const head = manager.nextConflict();
        var deadline: ?i64 = null;

        for (0..manager.jobCount()) |index| {
            const summary = manager.jobSummaryAt(index);
            const entry = self.published.getPtr(summary.id) orelse continue;
            var next = entry.record;
            applySummary(&next, summary);
            next.pending_conflict = if (head) |conflict|
                (if (conflict.job_id == summary.id) conflict.id else 0)
            else
                0;
            if (next.state.isTerminal() and next.finished_at_ms == 0) next.finished_at_ms = wallClockMs();

            const previous = entry.record;
            const structural = next.state != previous.state or
                next.cancel_requested != previous.cancel_requested or
                next.pending_conflict != previous.pending_conflict;
            const progressed = next.completed_bytes != previous.completed_bytes or
                next.total_bytes != previous.total_bytes or
                next.completed_items != previous.completed_items or
                next.total_items != previous.total_items or
                next.rate_bytes_per_second != previous.rate_bytes_per_second;

            if (structural or (progressed and now - entry.last_progress_ms >= progress_interval_ms)) {
                self.service.updateJobRecord(next) catch |err| {
                    std.log.err("Files job record update for job {d} failed: {s}", .{ summary.id, @errorName(err) });
                    continue;
                };
                entry.record = next;
                entry.last_progress_ms = now;
            } else if (progressed) {
                deadline = earliest(deadline, entry.last_progress_ms + progress_interval_ms);
            }

            if (!next.state.isTerminal()) {
                if (now - entry.last_sample_ms >= rate_sample_interval_ms) {
                    self.service.appendRateSample(summary.id, summary.rate_bytes_per_second);
                    entry.last_sample_ms = now;
                }
                deadline = earliest(deadline, entry.last_sample_ms + rate_sample_interval_ms);
            }
        }
        return deadline;
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
            if (self.published.fetchRemove(job_id)) |_| {
                self.service.retireJobRecord(job_id) catch |err| {
                    std.log.err("Files job record retirement for job {d} failed: {s}", .{ job_id, @errorName(err) });
                };
            }
        }
    }
};

fn earliest(current: ?i64, candidate: i64) i64 {
    return if (current) |value| @min(value, candidate) else candidate;
}

fn applySummary(record: *io_service.JobRecord, summary: io_manager.JobSummary) void {
    record.state = recordState(summary.state);
    record.cancel_requested = summary.cancel_requested;
    record.completed_bytes = summary.completed_bytes;
    record.total_bytes = summary.total_bytes;
    record.rate_bytes_per_second = summary.rate_bytes_per_second;
    record.completed_items = summary.completed_items;
    record.total_items = summary.total_items;
}

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
    else if (err == error.InvalidTransferDestination)
        .invalid_destination
    else if (err == error.InvalidTransferSource or err == error.EmptyTransfer)
        .invalid_source
    else if (err == error.UnsupportedTransferSource)
        .unsupported_source
    else if (err == error.TransferDestinationInsideSource)
        .destination_inside_source
    else if (err == error.OverlappingMoveRoots)
        .overlapping_move_roots
    else if (err == error.MountedDirectoryMoveUnsupported)
        .mounted_directory_move
    else if (err == error.TransferSourceEqualsDestination)
        .nothing_to_transfer
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
    defer owner_window.close();
    var other_window = try service.registerWindow();
    defer other_window.close();

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
