//! Dedicated process thread for Files Runtime ownership and I/O scheduling.
//!
//! The coordinator is the only consumer of the process Service command queue.
//! It owns all access to Runtime after startup; windows retain only Service
//! handles and immutable updates.
const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const io_transfer_plan = @import("io_transfer_plan.zig");
const io_service_tasks = @import("io_service_tasks.zig");
const resources = @import("io_coordinator_resources.zig");
const lifecycle = @import("io_coordinator_lifecycle.zig");
const deletions = @import("io_coordinator_deletions.zig");
const job_views = @import("io_coordinator_views.zig");
const coordinator_requests = @import("io_coordinator_requests.zig");
const io_deletion = @import("io_deletion.zig");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const io_runtime = @import("io_runtime.zig");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const io_tree = @import("io_tree.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const ops_mod = @import("ops.zig");

const JobId = io_service.JobId;

pub const WindowHeld = struct {
    /// Owned.
    path: []u8,
};

/// A submit whose plan is being prepared on a worker.
const Preparing = struct {
    mode: io_service.TransferMode,
    cancelled: bool = false,
};

/// The last record written for a job, and when progress and the speed
/// history were last written.
const Published = struct {
    record: io_service.JobRecord,
    last_progress_ms: i64 = 0,
    last_sample_ms: i64 = 0,
    retirement_requested: bool = false,
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

pub fn wallClockMs() i64 {
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

const codes = @import("io_coordinator_codes.zig");
pub const RejectionCode = codes.RejectionCode;
pub const rejectionCode = codes.rejectionCode;

pub const Coordinator = struct {
    allocator: Allocator,
    service: *io_service.Service,
    runtime: *io_runtime.Runtime,
    /// Delete, trash and empty-trash jobs (`io_coordinator_deletions.zig`).
    deletion_pool: *io_deletion.Pool = undefined,
    deletion_context: io_deletion.Context = undefined,
    deletions: std.AutoHashMapUnmanaged(JobId, deletions.Deletion) = .empty,
    next_deletion_id: JobId = deletions.id_base,
    /// Levels of job trees that windows watch, by window and view slot.
    watching: std.AutoHashMapUnmanaged(u64, job_views.Watching) = .empty,
    thread: ?std.Thread = null,
    published: std.AutoHashMapUnmanaged(JobId, Published) = .empty,
    next_failed_submit_id: JobId = failed_submit_id_base,
    /// Blocking filesystem work handed off by this thread (threading §8).
    tasks: *io_service_tasks.Pool = undefined,
    task_context: io_service_tasks.Context = undefined,
    /// Tasks the pool had no room for, submitted in order as room frees.
    task_backlog: std.ArrayList(io_service_tasks.Task) = .empty,
    /// Jobs whose submit is being prepared on a worker.
    preparing: std.AutoHashMapUnmanaged(JobId, Preparing) = .empty,
    /// Set once shutdown has begun: no new submits; accepted ordinary work
    /// finishes (threading §10).
    draining: bool = false,
    /// A second quit: cancel everything, ordinary jobs included.
    abort_requested: std.atomic.Value(bool) = .init(false),
    aborting: bool = false,
    /// What disposing a window-owned resource needs, by ledger handle id.
    window_held: std.AutoHashMapUnmanaged(u64, WindowHeld) = .empty,

    /// Initialize at a stable address. The Runtime is allocated separately
    /// because its executors retain pointers into it and into its Manager.
    pub fn init(
        self: *Coordinator,
        allocator: Allocator,
        io: std.Io,
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

        self.task_context = .{
            .allocator = allocator,
            .io = io,
            .on_discard_delete = discardDeleteResult,
            .owner = self,
        };
        self.tasks = try io_service_tasks.create(&self.task_context);
        errdefer self.tasks.deinit();
        self.deletion_context = .{ .allocator = allocator, .io = io };
        self.deletion_pool = try io_deletion.create(&self.deletion_context);
        errdefer self.deletion_pool.deinit();

        self.runtime = runtime;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Begins the drain and waits for it: no new submits, accepted ordinary
    /// work finishes, archive extractions and jobs no one can answer are
    /// cancelled, then the thread tears the Runtime down and exits. The
    /// caller is the process owner after every window is gone (threading §10).
    pub fn deinit(self: *Coordinator) void {
        self.service.beginShutdown();
        if (self.thread) |thread| thread.join();
        self.published.deinit(self.allocator);
        self.preparing.deinit(self.allocator);
        var remaining = self.deletions.valueIterator();
        while (remaining.next()) |entry| self.allocator.destroy(entry.control);
        self.deletions.deinit(self.allocator);
        job_views.deinitWatching(self);
        var held = self.window_held.valueIterator();
        while (held.next()) |entry| self.allocator.free(entry.path);
        self.window_held.deinit(self.allocator);
        self.task_backlog.deinit(self.allocator);
        self.* = undefined;
    }

    fn threadMain(self: *Coordinator) void {
        io_thread_guard.markCurrent(.coordinator);
        defer {
            // Tasks first: finishing or discarding them may release ledger
            // entries the Runtime still owns.
            self.tasks.deinit();
            self.discardTaskBacklog();
            self.deletion_pool.deinit();
            self.runtime.deinit();
            self.allocator.destroy(self.runtime);
        }

        while (true) {
            _ = self.service.drainCommandWake();
            while (self.service.tryReceiveCommand()) |routed| {
                self.handleCommand(routed);
            }

            self.sweepClosedWindows();
            self.pumpTasks();
            self.pumpDeletions();
            self.pumpExecutors();

            // Decisions the coordinator makes on its own come before
            // publication, so their results reach the table in this pass.
            if (self.service.isStopping()) {
                if (!self.draining) self.beginDraining();
                if (self.abort_requested.load(.acquire) and !self.aborting) self.abortAll();
            }
            if (!self.service.anyWindowOpen() or self.draining) self.cancelUnanswerableConflicts();

            const now = monotonicMs();
            var deadline = self.publishRecords(now);
            if (self.publishDeletions(now)) |at| deadline = earliest(deadline, at);
            if (self.publishViews(now)) |at| deadline = earliest(deadline, at);
            self.retireReadyJobs();
            if (self.draining and self.isIdle()) break;
            // While draining, re-check progress at least every 50 ms: the
            // phase is short, and some transitions raise no wake of their own.
            self.waitForWork(if (self.draining) earliest(deadline, monotonicMs() + 50) else deadline);
        }
    }

    pub const requestAbort = lifecycle.requestAbort;
    const beginDraining = lifecycle.beginDraining;
    const abortAll = lifecycle.abortAll;
    const cancelUnanswerableConflicts = lifecycle.cancelUnanswerableConflicts;
    const isIdle = lifecycle.isIdle;
    const submitDeletion = deletions.submitDeletion;
    const cancelDeletion = deletions.cancelDeletion;
    pub const cancelAllDeletions = deletions.cancelAllDeletions;
    const pumpDeletions = deletions.pumpDeletions;
    const publishDeletions = deletions.publishDeletions;
    const watchView = job_views.watchView;
    const unwatchView = job_views.unwatchView;
    const publishViews = job_views.publishViews;
    const handleRequest = coordinator_requests.handleRequest;

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
            .{
                .fd = self.tasks.wakeFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.deletion_pool.wakeFd(),
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
        if (routed.command.kind == .submit_job) return self.handleSubmit(&routed);
        if (routed.command.kind == .request) return self.handleRequest(&routed);
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
    ///
    /// Accept is bounded and does no I/O: the job is created in `planning`,
    /// its record appears at once, and the request moves into a prepare
    /// task. `applyPrepared` finishes the submit when the plan returns.
    fn handleSubmit(self: *Coordinator, routed: *io_service.RoutedCommand) void {
        var record: io_service.JobRecord = .{
            .origin_window_id = routed.window_id,
            .submit_tag = routed.command.submit_tag,
            .started_at_ms = wallClockMs(),
        };
        const payload = routed.command.payload orelse
            return self.failSubmit(&record, error.MissingTransferPayload);
        if (payload.data == .deletion) return self.submitDeletion(routed, record);
        const request = switch (payload.data) {
            .transfer => |*request| request,
            else => return self.failSubmit(&record, error.UnexpectedTransferPayload),
        };
        record.kind = if (request.mode == .move) .move else .copy;
        record.source_count = @intCast(@min(request.sources.len, std.math.maxInt(u32)));
        if (request.sources.len > 0) record.setLabel(std.fs.path.basename(request.sources[0].path));

        const manager = &self.runtime.manager;
        const job_id = manager.createJob(routed.window_id) catch |err|
            return self.failSubmit(&record, err);
        record.id = job_id;
        record.state = .planning;
        self.preparing.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            std.debug.assert(manager.discardPlanningJob(job_id));
            return self.failSubmit(&record, err);
        };
        self.published.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            std.debug.assert(manager.discardPlanningJob(job_id));
            return self.failSubmit(&record, err);
        };
        self.service.createJobRecord(record, true) catch |err| {
            std.log.err("Files job record for job {d} failed: {s}", .{ job_id, @errorName(err) });
            std.debug.assert(manager.discardPlanningJob(job_id));
            return;
        };
        self.published.putAssumeCapacity(job_id, .{ .record = record });
        self.preparing.putAssumeCapacity(job_id, .{ .mode = request.mode });

        // The task owns the payload from here on.
        routed.command.payload = null;
        self.submitTask(.{ .prepare_transfer = .{ .job_id = job_id, .payload = payload } });
    }

    /// A submit that failed before any Manager job existed.
    pub fn failSubmit(self: *Coordinator, record: *io_service.JobRecord, err: anyerror) void {
        record.id = self.next_failed_submit_id;
        self.next_failed_submit_id += 1;
        record.state = .failed;
        record.error_code = @backingInt(rejectionCode(err));
        record.finished_at_ms = record.started_at_ms;
        self.service.createJobRecord(record.*, true) catch |create_err| {
            std.log.err("Files failed-submit record failed: {s}", .{@errorName(create_err)});
            return;
        };
        self.service.retireJobRecord(record.id) catch {};
    }

    /// Ends a job that never left `planning`: discards it and retires its
    /// record as cancelled or failed.
    fn endPlanningJob(self: *Coordinator, job_id: JobId, state: io_service.JobState, err: ?anyerror) void {
        _ = self.runtime.manager.discardPlanningJob(job_id);
        const entry = self.published.fetchRemove(job_id) orelse return;
        var record = entry.value.record;
        record.state = state;
        record.error_code = if (err) |e| @backingInt(rejectionCode(e)) else 0;
        record.finished_at_ms = wallClockMs();
        self.service.updateJobRecord(record) catch {};
        self.service.retireJobRecord(job_id) catch {};
    }

    pub fn submitTask(self: *Coordinator, task: io_service_tasks.Task) void {
        if (self.task_backlog.items.len == 0 and self.tasks.trySubmit(task)) return;
        self.task_backlog.append(self.allocator, task) catch {
            // Out of memory with a full pool: give the work up visibly.
            std.log.err("Files service task dropped: out of memory", .{});
            switch (task) {
                .prepare_transfer => |prepare| {
                    prepare.payload.deinit();
                    _ = self.preparing.remove(prepare.job_id);
                    self.endPlanningJob(prepare.job_id, .failed, error.OutOfMemory);
                },
                .delete_tree => |delete| {
                    self.allocator.free(delete.path);
                    self.finishCleanup(delete.handle);
                },
                .request => |request| {
                    request.payload.deinit();
                    self.service.cancelReplyReservation(request.window_id);
                },
            }
        };
    }

    pub fn pumpTasks(self: *Coordinator) void {
        _ = self.tasks.drainWake();
        while (self.tasks.tryPopResult()) |result_value| {
            var result = result_value;
            defer result.deinit(self.allocator);
            switch (result) {
                .prepared => |*prepared| self.applyPrepared(prepared.job_id, &prepared.plan),
                .deleted => |deleted| {
                    if (deleted.failed) |err| std.log.err(
                        "Files could not delete {s}: {s}",
                        .{ deleted.path, @errorName(err) },
                    );
                    self.finishCleanup(deleted.handle);
                },
                .replied => |replied| if (replied.reply) |reply|
                    self.service.deliverReply(replied.window_id, reply)
                else
                    self.service.cancelReplyReservation(replied.window_id),
            }
        }
        while (self.task_backlog.items.len > 0) {
            if (!self.tasks.trySubmit(self.task_backlog.items[0])) break;
            _ = self.task_backlog.orderedRemove(0);
        }
    }

    /// Applies a prepared plan to its planning job, unless the job was
    /// cancelled meanwhile or the plan failed.
    fn applyPrepared(self: *Coordinator, job_id: JobId, plan_result: *anyerror!io_transfer_plan.TransferPlan) void {
        const entry = self.preparing.fetchRemove(job_id) orelse return;
        if (entry.value.cancelled) return self.endPlanningJob(job_id, .cancelled, null);
        const plan = if (plan_result.*) |*plan| plan else |err|
            return self.endPlanningJob(job_id, .failed, err);
        self.applyTransferPlan(job_id, entry.value.mode, plan) catch |err|
            return self.endPlanningJob(job_id, .failed, err);
    }

    /// A worker finished destroying a resource it held: release its entry.
    /// A failed delete is released too; it is under a known staging root
    /// that a later start sweeps (roadmap phase 5).
    fn finishCleanup(self: *Coordinator, handle: io_resource_ledger.Handle) void {
        self.runtime.resource_ledger.release(handle, .operation_worker) catch |err| {
            std.log.err("Files cleanup release of resource {d} failed: {s}", .{ handle.id, @errorName(err) });
        };
    }

    fn discardDeleteResult(raw: ?*anyopaque, handle: io_resource_ledger.Handle) void {
        const self: *Coordinator = @ptrCast(@alignCast(raw.?));
        self.finishCleanup(handle);
    }

    fn discardTaskBacklog(self: *Coordinator) void {
        for (self.task_backlog.items) |task| switch (task) {
            .prepare_transfer => |prepare| prepare.payload.deinit(),
            .delete_tree => |delete| {
                self.allocator.free(delete.path);
                self.finishCleanup(delete.handle);
            },
            .request => |request| request.payload.deinit(),
        };
        self.task_backlog.clearRetainingCapacity();
    }

    fn applyCommand(
        self: *Coordinator,
        routed: io_service.RoutedCommand,
    ) anyerror!void {
        const command = routed.command;
        switch (command.kind) {
            .pause_job => try self.runtime.manager.pauseJob(command.job_id),
            .resume_job => try self.runtime.manager.resumeJob(command.job_id),
            .cancel_job => if (self.cancelDeletion(command.job_id)) {} else if (self.preparing.getPtr(command.job_id)) |preparing| {
                // Still being prepared: the plan is discarded on return.
                preparing.cancelled = true;
                if (self.published.getPtr(command.job_id)) |entry| {
                    entry.record.cancel_requested = true;
                    self.service.updateJobRecord(entry.record) catch {};
                }
            } else try self.runtime.cancelJob(command.job_id),
            .submit_job => unreachable, // handleSubmit
            .request => unreachable, // handleRequest
            .watch_view => try self.watchView(routed.window_id, command.payload),
            .unwatch_view => self.unwatchView(routed.window_id, command.submit_tag),
            // A hovered ghost: copy it next. A hovered ghost folder: sooner.
            .prioritize_entry => if (!self.runtime.manager.prioritizeEntryOperation(command.job_id, command.resource_id))
                return error.NotPrioritized,
            .promote_subtree => try self.runtime.manager.promoteDiscoverySubtree(command.job_id, command.resource_id),
            .start_discovery => try self.startDiscovery(command.job_id, command.payload),
            .prioritize_discovery => try self.prioritizeDiscovery(command.job_id, command.payload),
            .resolve_conflict => try self.resolveConflict(
                routed.window_id,
                command.payload,
            ),
            .release_borrow => try self.runtime.resource_ledger.releaseBorrow(
                .{ .id = command.resource_id },
                routed.window_id,
            ),
            .dispose_resource => try self.disposeWindowResource(
                .{ .id = command.resource_id },
                routed.window_id,
            ),
        }
    }

    pub const handResourceToWindow = resources.handResourceToWindow;
    pub const disposeWindowResource = resources.disposeWindowResource;
    pub const sweepClosedWindows = resources.sweepClosedWindows;

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

        // Any window may resolve any conflict (architecture §4).
        _ = window_id;

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

    /// Turns a prepared plan into the roots and operations of a planning
    /// job and queues it. Touches only the Manager. On error the job stays in
    /// `planning` for the caller to discard.
    fn applyTransferPlan(
        self: *Coordinator,
        job_id: JobId,
        mode: io_service.TransferMode,
        plan: *const io_transfer_plan.TransferPlan,
    ) !void {
        const manager = &self.runtime.manager;

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
            return;
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
            next.borrow_count = @intCast(@min(self.runtime.resource_ledger.jobBorrowCount(summary.id), 255));
            next.pending_conflict = if (head) |conflict|
                (if (conflict.job_id == summary.id) conflict.id else 0)
            else
                0;
            if (next.state.isTerminal() and next.finished_at_ms == 0) next.finished_at_ms = wallClockMs();
            // Retirement is automatic (architecture §6). It happens once the
            // executors are quiescent for the job and the ledger holds
            // nothing it owns; no consumer is waited for.
            if (next.state.isTerminal() and !entry.retirement_requested) {
                self.runtime.requestJobRetirement(summary.id) catch |err| {
                    std.log.err("Files job {d} retirement request failed: {s}", .{ summary.id, @errorName(err) });
                };
                entry.retirement_requested = true;
            }

            const previous = entry.record;
            const structural = next.state != previous.state or
                next.cancel_requested != previous.cancel_requested or
                next.borrow_count != previous.borrow_count or
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

            // Only moving jobs are sampled: a paused job or one waiting on a
            // conflict must not wake the coordinator every second.
            if (next.state == .running or next.state == .finalizing) {
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
    // A cancel request never goes back; it may also come from the
    // coordinator for a job still being prepared.
    record.cancel_requested = record.cancel_requested or summary.cancel_requested;
    record.completed_bytes = summary.completed_bytes;
    record.total_bytes = summary.total_bytes;
    record.rate_bytes_per_second = summary.rate_bytes_per_second;
    record.completed_items = summary.completed_items;
    record.total_items = summary.total_items;
}
