//! Main-thread execution bridge between the Files scheduler and worker pool.
//!
//! This module defines the ownership contract shared by the main thread and
//! workers. It deliberately contains no filesystem or UI operations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_manager = @import("io_manager.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");

pub const JobId = io_manager.JobId;
pub const OperationId = io_manager.OperationId;
pub const OperationKind = io_manager.OperationKind;
pub const WorkToken = io_manager.WorkToken;
pub const WorkResult = io_manager.WorkResult;
pub const CopyMetrics = io_manager.CopyMetrics;
pub const CopyPhase = io_manager.CopyPhase;

pub const OperationKey = struct {
    job_id: JobId,
    operation_id: OperationId,

    pub fn fromToken(token: WorkToken) OperationKey {
        return .{
            .job_id = token.job_id,
            .operation_id = token.operation_id,
        };
    }
};

/// An explicitly owned byte payload.
///
/// A null slice means ownership has been transferred or released. An empty
/// but non-null slice is still owned and must be freed.
pub const OwnedPayload = struct {
    allocator: Allocator,
    bytes: ?[]u8,

    pub fn copy(allocator: Allocator, bytes: []const u8) !OwnedPayload {
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, bytes),
        };
    }

    pub fn slice(self: *const OwnedPayload) []const u8 {
        return self.bytes orelse &.{};
    }

    /// Transfers ownership and leaves this value inert.
    pub fn take(self: *OwnedPayload) OwnedPayload {
        const owned = self.*;
        self.bytes = null;
        return owned;
    }

    pub fn deinit(self: *OwnedPayload) void {
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.bytes = null;
    }
};

pub const PreparedWork = struct {
    operation_kind: OperationKind,
    input: OwnedPayload,
};

/// A bounded unit of work transferred to a worker.
///
/// The worker owns the item and must return its input in WorkCompletion.
pub const WorkItem = struct {
    token: WorkToken,
    operation_kind: OperationKind,
    input: OwnedPayload,
    continuation: ?OwnedPayload = null,
    profile_enabled: bool = false,

    pub fn deinit(self: *WorkItem) void {
        self.input.deinit();
        deinitOptional(&self.continuation);
    }
};

/// A worker result transferred to the pool and then back to the main thread.
///
/// Input is returned on every outcome so yielded and waiting operations can
/// retain it without preparing or rebuilding it on their next dispatch.
pub const WorkCompletion = struct {
    token: WorkToken,
    outcome: WorkResult,
    operation_kind: OperationKind,
    input: OwnedPayload,
    continuation: ?OwnedPayload = null,
    result: ?OwnedPayload = null,
    progress: ?WorkProgress = null,
    copy_metrics: ?CopyMetrics = null,

    pub fn deinit(self: *WorkCompletion) void {
        self.input.deinit();
        deinitOptional(&self.continuation);
        deinitOptional(&self.result);
    }
};

pub const WorkProgress = struct {
    bytes: u64,
    total_bytes: u64,
    phase: CopyPhase,
};

pub const DrainStats = struct {
    drained: usize = 0,
    state_changes: usize = 0,
};

const WorkerPool = @import("io_workers.zig").WorkerPool;

const PoolWorkItem = struct {
    item: WorkItem,
    ledger_handle: io_resource_ledger.Handle,

    pub fn stallKey(self: PoolWorkItem) u64 {
        return self.item.token.job_id;
    }
};

const PoolCompletion = struct {
    completion: WorkCompletion,
    ledger_handle: io_resource_ledger.Handle,
};

const Pool = WorkerPool(PoolWorkItem, PoolCompletion);

const PendingWork = struct {
    item: WorkItem,
    ledger_handle: io_resource_ledger.Handle,
};

pub const Executor = struct {
    allocator: Allocator,
    pool: *Pool,
    callback_context: *CallbackContext,
    ledger: *io_resource_ledger.Ledger,
    owned_ledger: ?*io_resource_ledger.Ledger = null,
    continuations: std.AutoHashMapUnmanaged(OperationKey, OperationPayloads) = .empty,
    pending: std.AutoHashMapUnmanaged(OperationKey, PendingWork) = .empty,
    in_flight_by_job: std.AutoHashMapUnmanaged(JobId, usize) = .empty,
    profile_enabled: bool = false,

    pub fn init(
        allocator: Allocator,
        config: Config,
        context: ?*anyopaque,
        callbacks: Callbacks,
    ) !Executor {
        const ledger = try allocator.create(io_resource_ledger.Ledger);
        ledger.* = io_resource_ledger.Ledger.init(allocator);
        errdefer {
            ledger.deinit();
            allocator.destroy(ledger);
        }

        return initInternal(
            allocator,
            config,
            context,
            callbacks,
            ledger,
            ledger,
        );
    }

    /// Uses a Runtime-owned ledger instead of creating a private one.
    pub fn initWithLedger(
        allocator: Allocator,
        config: Config,
        context: ?*anyopaque,
        callbacks: Callbacks,
        ledger: *io_resource_ledger.Ledger,
    ) !Executor {
        return initInternal(
            allocator,
            config,
            context,
            callbacks,
            ledger,
            null,
        );
    }

    fn initInternal(
        allocator: Allocator,
        config: Config,
        context: ?*anyopaque,
        callbacks: Callbacks,
        ledger: *io_resource_ledger.Ledger,
        owned_ledger: ?*io_resource_ledger.Ledger,
    ) !Executor {
        const callback_context = try allocator.create(CallbackContext);
        errdefer allocator.destroy(callback_context);

        callback_context.* = .{
            .user_context = context,
            .callbacks = callbacks,
            .ledger = ledger,
        };

        const pool = try Pool.initElastic(
            allocator,
            config.worker_count,
            @max(config.worker_count, config.worker_cap),
            config.capacity,
            callback_context,
            executeWork,
            discardPoolCompletion,
        );

        return .{
            .allocator = allocator,
            .pool = pool,
            .callback_context = callback_context,
            .ledger = ledger,
            .owned_ledger = owned_ledger,
        };
    }

    pub fn deinit(self: *Executor) void {
        // Keep callback context alive until workers have joined and
        // uncollected completions have been discarded.
        self.pool.deinit();

        var pending_iter = self.pending.valueIterator();
        while (pending_iter.next()) |item| {
            discardPendingWork(self.callback_context, self.ledger, item.*);
        }
        self.pending.deinit(self.allocator);

        var continuation_iter = self.continuations.valueIterator();
        while (continuation_iter.next()) |payloads| {
            discardPayloads(
                self.callback_context,
                payloads.operation_kind,
                payloads.input,
                payloads.continuation,
                null,
            );
            self.ledger.release(
                payloads.ledger_handle,
                .operation_executor,
            ) catch unreachable;
        }
        self.continuations.deinit(self.allocator);
        self.in_flight_by_job.deinit(self.allocator);

        if (self.owned_ledger) |ledger| {
            std.debug.assert(ledger.isEmpty());
            ledger.deinit();
            self.allocator.destroy(ledger);
        }
        self.allocator.destroy(self.callback_context);
        self.* = undefined;
    }

    /// True only when this executor owns no work or retained payloads for
    /// the Job. Manager-side ready work is deliberately outside this query.
    pub fn isJobQuiescent(self: *const Executor, job_id: JobId) bool {
        if (self.in_flight_by_job.contains(job_id)) return false;

        var pending_iter = self.pending.keyIterator();
        while (pending_iter.next()) |key| {
            if (key.job_id == job_id) return false;
        }

        var continuation_iter = self.continuations.keyIterator();
        while (continuation_iter.next()) |key| {
            if (key.job_id == job_id) return false;
        }

        return true;
    }

    fn reserveInFlightSlot(self: *Executor, job_id: JobId) !void {
        if (!self.in_flight_by_job.contains(job_id)) {
            try self.in_flight_by_job.ensureUnusedCapacity(self.allocator, 1);
        }
    }

    fn addInFlightAssumeCapacity(self: *Executor, job_id: JobId) void {
        if (self.in_flight_by_job.getPtr(job_id)) |count| {
            count.* += 1;
        } else {
            self.in_flight_by_job.putAssumeCapacity(job_id, 1);
        }
    }

    fn finishInFlight(self: *Executor, job_id: JobId) void {
        const count = self.in_flight_by_job.getPtr(job_id) orelse unreachable;
        if (count.* == 1) {
            _ = self.in_flight_by_job.remove(job_id);
        } else {
            count.* -= 1;
        }
    }

    pub fn runningTasks(self: *Executor, out: []@import("io_workers.zig").Running) usize {
        return self.pool.runningTasks(out);
    }

    pub fn queuedCount(self: *Executor) usize {
        return self.pool.queuedCount();
    }

    pub fn grow(self: *Executor, stuck_after_ms: i64) usize {
        return self.pool.grow(stuck_after_ms);
    }

    /// File descriptor to monitor for completed worker results.
    pub fn wakeFd(self: *Executor) std.posix.fd_t {
        return self.pool.wakeFd();
    }

    /// Drain the pool's eventfd notification counter.
    pub fn drainWake(self: *Executor) u64 {
        return self.pool.drainWake();
    }

    /// Releases retained or backpressured payloads belonging to a cancelled
    /// Job. Work already owned by a worker is reconciled when it returns.
    pub fn cancelJob(self: *Executor, job_id: JobId) void {
        while (true) {
            var found: ?OperationKey = null;
            var keys = self.pending.keyIterator();
            while (keys.next()) |key| {
                if (key.job_id == job_id) {
                    found = key.*;
                    break;
                }
            }
            const key = found orelse break;
            if (self.pending.fetchRemove(key)) |removed|
                discardPendingWork(self.callback_context, self.ledger, removed.value);
        }

        while (true) {
            var found: ?OperationKey = null;
            var keys = self.continuations.keyIterator();
            while (keys.next()) |key| {
                if (key.job_id == job_id) {
                    found = key.*;
                    break;
                }
            }
            const key = found orelse break;
            if (self.continuations.fetchRemove(key)) |removed| {
                const payloads = removed.value;
                discardPayloads(
                    self.callback_context,
                    payloads.operation_kind,
                    payloads.input,
                    payloads.continuation,
                    null,
                );
                self.ledger.release(
                    payloads.ledger_handle,
                    .operation_executor,
                ) catch unreachable;
            }
        }
    }

    /// Route all currently available worker completions through Manager.
    /// This must run on the main thread.
    pub fn drainCompletions(self: *Executor, manager: *io_manager.Manager) !usize {
        return (try self.drainCompletionsWithStats(manager)).drained;
    }

    /// Reconciles completions and distinguishes progress yields from
    /// accepted outcomes that change an operation's visible state.
    pub fn drainCompletionsWithStats(
        self: *Executor,
        manager: *io_manager.Manager,
    ) !DrainStats {
        var stats: DrainStats = .{};
        var first_error: ?anyerror = null;

        while (self.pool.tryPopResult()) |pool_completion| {
            var completion = pool_completion.completion;
            self.ledger.transfer(
                pool_completion.ledger_handle,
                .operation_worker,
                .operation_executor,
            ) catch unreachable;
            defer self.finishInFlight(completion.token.job_id);
            stats.drained += 1;

            // Yielded work resumes the same execution and retains its
            // continuation. Waiting work requires an external decision;
            // discard its prepared input so a retry runs prepare() again
            // against the Manager's potentially updated destination.
            // Reserve before changing Manager state. If allocation fails,
            // fail the operation instead of accepting a transition whose
            // continuation we cannot retain.
            if (completion.outcome == .yielded) {
                self.continuations.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                    if (manager.completeWork(completion.token, .failed)) {
                        self.callback_context.callbacks.complete(
                            self.callback_context.user_context,
                            completion.token,
                            completion.operation_kind,
                            .failed,
                            null,
                        );
                    }
                    discardCompletionAndRelease(
                        self.callback_context,
                        self.ledger,
                        completion,
                        pool_completion.ledger_handle,
                        .operation_executor,
                    );
                    if (first_error == null) first_error = err;
                    continue;
                };
            }

            if (!manager.acceptsWorkToken(completion.token)) {
                // Do not expose stale worker metadata to operation-specific
                // acceptance logic. The discard path retains payload ownership.
                discardCompletionAndRelease(
                    self.callback_context,
                    self.ledger,
                    completion,
                    pool_completion.ledger_handle,
                    .operation_executor,
                );
                continue;
            }

            if (self.callback_context.callbacks.accept) |accept| {
                accept(
                    self.callback_context.user_context,
                    completion.token,
                    completion.operation_kind,
                    completion.outcome,
                    if (completion.result) |*result| result else null,
                ) catch |err| {
                    // Acceptance must be atomic: on failure, reconcile the
                    // operation as failed and discard every worker payload.
                    if (manager.completeWork(completion.token, .failed)) {
                        self.callback_context.callbacks.complete(
                            self.callback_context.user_context,
                            completion.token,
                            completion.operation_kind,
                            .failed,
                            null,
                        );
                    }
                    discardCompletionAndRelease(
                        self.callback_context,
                        self.ledger,
                        completion,
                        pool_completion.ledger_handle,
                        .operation_executor,
                    );
                    if (first_error == null) first_error = err;
                    continue;
                };
            }

            if (!manager.completeWork(completion.token, completion.outcome)) {
                // Stale or duplicate result: operation-specific cleanup
                // owns every payload, including external resources.
                discardCompletionAndRelease(
                    self.callback_context,
                    self.ledger,
                    completion,
                    pool_completion.ledger_handle,
                    .operation_executor,
                );
                continue;
            }

            if (completion.copy_metrics) |metrics| {
                _ = manager.recordOperationCopyMetrics(completion.token, metrics);
            }

            const retain_payloads =
                completion.outcome == .yielded and
                manager.operationState(
                    completion.token.job_id,
                    completion.token.operation_id,
                ) == .pending;
            if (!retain_payloads) stats.state_changes += 1;
            if (completion.progress) |progress| {
                _ = manager.recordOperationProgress(
                    completion.token,
                    progress.bytes,
                    progress.total_bytes,
                    progress.phase,
                );
            }

            const result = takeOptional(&completion.result);

            if (retain_payloads) {
                const key = OperationKey.fromToken(completion.token);
                self.continuations.putAssumeCapacity(key, .{
                    .operation_kind = completion.operation_kind,
                    .input = completion.input.take(),
                    .continuation = takeOptional(&completion.continuation),
                    .ledger_handle = pool_completion.ledger_handle,
                });
            } else {
                // Terminal input and continuation are abandoned; the
                // result alone transfers to complete().
                discardPayloads(
                    self.callback_context,
                    completion.operation_kind,
                    completion.input.take(),
                    takeOptional(&completion.continuation),
                    null,
                );
            }

            // The fields transferred above are now empty in completion.
            completion.deinit();
            self.callback_context.callbacks.complete(
                self.callback_context.user_context,
                completion.token,
                completion.operation_kind,
                completion.outcome,
                result,
            );
            if (!retain_payloads) {
                self.ledger.release(
                    pool_completion.ledger_handle,
                    .operation_executor,
                ) catch unreachable;
            }
        }

        if (first_error) |err| return err;
        return stats;
    }

    /// Dispatch ready operations until the scheduler is empty or the
    /// bounded worker pool applies backpressure.
    pub fn dispatchReady(self: *Executor, manager: *io_manager.Manager) !usize {
        var submitted: usize = 0;

        while (manager.dispatchNext()) |token| {
            const key = OperationKey.fromToken(token);

            if (self.pending.getPtr(key)) |pending_work| {
                // Retry a retained item with the new dispatch generation.
                pending_work.item.token = token;
            } else {
                // Reserve before removing continuation ownership or
                // calling prepare, so insertion below cannot allocate.
                self.pending.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                    if (self.continuations.fetchRemove(key)) |entry| {
                        const payloads = entry.value;
                        discardPayloads(
                            self.callback_context,
                            payloads.operation_kind,
                            payloads.input,
                            payloads.continuation,
                            null,
                        );
                        self.ledger.release(
                            payloads.ledger_handle,
                            .operation_executor,
                        ) catch unreachable;
                    }
                    if (manager.completeWork(token, .failed)) {
                        self.callback_context.callbacks.complete(
                            self.callback_context.user_context,
                            token,
                            null,
                            .failed,
                            null,
                        );
                    }
                    return err;
                };

                if (self.continuations.fetchRemove(key)) |entry| {
                    const payloads = entry.value;
                    self.pending.putAssumeCapacity(key, .{
                        .item = .{
                            .token = token,
                            .operation_kind = payloads.operation_kind,
                            .input = payloads.input,
                            .continuation = payloads.continuation,
                        },
                        .ledger_handle = payloads.ledger_handle,
                    });
                } else {
                    const prepared = self.callback_context.callbacks.prepare(
                        self.callback_context.user_context,
                        token,
                    ) catch {
                        if (manager.completeWork(token, .failed)) {
                            self.callback_context.callbacks.complete(
                                self.callback_context.user_context,
                                token,
                                null,
                                .failed,
                                null,
                            );
                        }
                        continue;
                    };

                    const ledger_handle = self.ledger.register(
                        token.job_id,
                        .operation_payload,
                        .operation_executor,
                    ) catch |err| {
                        discardPayloads(
                            self.callback_context,
                            prepared.operation_kind,
                            prepared.input,
                            null,
                            null,
                        );
                        if (manager.completeWork(token, .failed)) {
                            self.callback_context.callbacks.complete(
                                self.callback_context.user_context,
                                token,
                                prepared.operation_kind,
                                .failed,
                                null,
                            );
                        }
                        return err;
                    };

                    self.pending.putAssumeCapacity(key, .{
                        .item = .{
                            .token = token,
                            .operation_kind = prepared.operation_kind,
                            .input = prepared.input,
                            .continuation = null,
                        },
                        .ledger_handle = ledger_handle,
                    });
                }
            }

            const pending_work = self.pending.getPtr(key).?;
            pending_work.item.profile_enabled = self.profile_enabled;
            self.reserveInFlightSlot(token.job_id) catch |err| {
                // Keep the prepared item in pending and return the operation
                // to the scheduler; a later dispatch can retry the reserve.
                if (!manager.completeWork(token, .yielded)) {
                    if (self.pending.fetchRemove(key)) |entry| {
                        discardPendingWork(self.callback_context, self.ledger, entry.value);
                    }
                }
                return err;
            };
            self.ledger.transfer(
                pending_work.ledger_handle,
                .operation_executor,
                .operation_worker,
            ) catch unreachable;
            if (self.pool.trySubmit(.{
                .item = pending_work.item,
                .ledger_handle = pending_work.ledger_handle,
            })) {
                // Ownership transfers to the pool. Do not deinit the
                // removed map value.
                _ = self.pending.fetchRemove(key).?;
                self.addInFlightAssumeCapacity(token.job_id);
                submitted += 1;
                continue;
            }

            self.ledger.transfer(
                pending_work.ledger_handle,
                .operation_worker,
                .operation_executor,
            ) catch unreachable;

            // Keep ownership in pending until a later dispatch can submit.
            if (!manager.completeWork(token, .yielded)) {
                if (self.pending.fetchRemove(key)) |entry| {
                    discardPendingWork(self.callback_context, self.ledger, entry.value);
                }
            }
            break;
        }

        return submitted;
    }
};

fn executeWork(context: ?*anyopaque, pool_item: PoolWorkItem) PoolCompletion {
    const callback_context: *CallbackContext = @ptrCast(@alignCast(context.?));
    return .{
        .completion = callback_context.callbacks.execute(
            callback_context.user_context,
            pool_item.item,
        ),
        .ledger_handle = pool_item.ledger_handle,
    };
}

fn discardPoolCompletion(raw_context: ?*anyopaque, pool_completion: PoolCompletion) void {
    const callback_context: *CallbackContext = @ptrCast(@alignCast(raw_context.?));
    discardPayloads(
        callback_context,
        pool_completion.completion.operation_kind,
        pool_completion.completion.input,
        pool_completion.completion.continuation,
        pool_completion.completion.result,
    );
    callback_context.ledger.release(
        pool_completion.ledger_handle,
        .operation_worker,
    ) catch unreachable;
}

fn discardCompletionAndRelease(
    callback_context: *CallbackContext,
    ledger: *io_resource_ledger.Ledger,
    completion: WorkCompletion,
    ledger_handle: io_resource_ledger.Handle,
    owner: io_resource_ledger.Owner,
) void {
    discardPayloads(
        callback_context,
        completion.operation_kind,
        completion.input,
        completion.continuation,
        completion.result,
    );
    ledger.release(ledger_handle, owner) catch unreachable;
}

fn discardPendingWork(
    callback_context: *CallbackContext,
    ledger: *io_resource_ledger.Ledger,
    pending: PendingWork,
) void {
    discardPayloads(
        callback_context,
        pending.item.operation_kind,
        pending.item.input,
        pending.item.continuation,
        null,
    );
    ledger.release(
        pending.ledger_handle,
        .operation_executor,
    ) catch unreachable;
}

fn discardPayloads(
    callback_context: *CallbackContext,
    operation_kind: OperationKind,
    input: OwnedPayload,
    continuation: ?OwnedPayload,
    result: ?OwnedPayload,
) void {
    callback_context.callbacks.discard(
        callback_context.user_context,
        operation_kind,
        input,
        continuation,
        result,
    );
}

pub const Config = struct {
    worker_count: usize,
    capacity: usize,
    /// Most workers `grow` may run while some are stuck; 0 is `worker_count`.
    worker_cap: usize = 0,
};

pub const Callbacks = struct {
    /// Main-thread callback used only when an operation is first prepared.
    /// The executor retains its input across yielded and waiting work units.
    prepare: *const fn (
        context: ?*anyopaque,
        token: WorkToken,
    ) anyerror!PreparedWork,

    /// Worker-thread callback. It owns item and must return its input in the
    /// completion, including for terminal outcomes.
    execute: *const fn (
        context: ?*anyopaque,
        item: WorkItem,
    ) WorkCompletion,

    /// Main-thread acceptance hook for a current worker result. The result
    /// is borrowed and remains owned by the executor. Implementations must
    /// leave no partial registration behind when returning an error.
    accept: ?*const fn (
        context: ?*anyopaque,
        token: WorkToken,
        operation_kind: ?OperationKind,
        outcome: WorkResult,
        result: ?*const OwnedPayload,
    ) anyerror!void = null,

    /// Main-thread callback for accepted completions. Ownership of result
    /// transfers to this callback.
    complete: *const fn (
        context: ?*anyopaque,
        token: WorkToken,
        operation_kind: ?OperationKind,
        outcome: WorkResult,
        result: ?OwnedPayload,
    ) void,

    /// Main-thread cleanup callback for payloads abandoned by the executor.
    /// It receives ownership of every supplied payload and must release or
    /// otherwise dispose of any operation-specific resources they describe.
    /// Called for stale completions, terminal input/continuation state,
    /// retained work during shutdown, and uncollected pool results.
    discard: *const fn (
        context: ?*anyopaque,
        operation_kind: OperationKind,
        input: OwnedPayload,
        continuation: ?OwnedPayload,
        result: ?OwnedPayload,
    ) void,
};

const CallbackContext = struct {
    user_context: ?*anyopaque,
    callbacks: Callbacks,
    ledger: *io_resource_ledger.Ledger,
};

const OperationPayloads = struct {
    operation_kind: OperationKind,
    input: OwnedPayload,
    continuation: ?OwnedPayload,
    ledger_handle: io_resource_ledger.Handle,
};

fn takeOptional(value: *?OwnedPayload) ?OwnedPayload {
    if (value.*) |*payload| {
        const owned = payload.take();
        value.* = null;
        return owned;
    }
    return null;
}

fn deinitOptional(value: *?OwnedPayload) void {
    if (value.*) |*payload| payload.deinit();
    value.* = null;
}
