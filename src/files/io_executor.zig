//! Main-thread execution bridge between the Files scheduler and worker pool.
//!
//! This module defines the ownership contract shared by the main thread and
//! workers. It deliberately contains no filesystem or UI operations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_manager = @import("io_manager.zig");

pub const JobId = io_manager.JobId;
pub const OperationId = io_manager.OperationId;
pub const OperationKind = io_manager.OperationKind;
pub const WorkToken = io_manager.WorkToken;
pub const WorkResult = io_manager.WorkResult;
pub const CopyMetrics = io_manager.CopyMetrics;

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
};

const WorkerPool = @import("io_workers.zig").WorkerPool;
const Pool = WorkerPool(WorkItem, WorkCompletion);

pub const Executor = struct {
    allocator: Allocator,
    pool: *Pool,
    callback_context: *CallbackContext,
    continuations: std.AutoHashMapUnmanaged(OperationKey, OperationPayloads) = .empty,
    pending: std.AutoHashMapUnmanaged(OperationKey, WorkItem) = .empty,
    profile_enabled: bool = false,

    pub fn init(
        allocator: Allocator,
        config: Config,
        context: ?*anyopaque,
        callbacks: Callbacks,
    ) !Executor {
        const callback_context = try allocator.create(CallbackContext);
        errdefer allocator.destroy(callback_context);

        callback_context.* = .{
            .user_context = context,
            .callbacks = callbacks,
        };

        const pool = try Pool.init(
            allocator,
            config.worker_count,
            config.capacity,
            callback_context,
            executeWork,
            discardCompletion,
        );

        return .{
            .allocator = allocator,
            .pool = pool,
            .callback_context = callback_context,
        };
    }

    pub fn deinit(self: *Executor) void {
        // Keep callback context alive until workers have joined and
        // uncollected completions have been discarded.
        self.pool.deinit();

        var pending_iter = self.pending.valueIterator();
        while (pending_iter.next()) |item| {
            discardWorkItem(self.callback_context, item.*);
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
        }
        self.continuations.deinit(self.allocator);

        self.allocator.destroy(self.callback_context);
        self.* = undefined;
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
                discardWorkItem(self.callback_context, removed.value);
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
            }
        }
    }

    /// Route all currently available worker completions through Manager.
    /// This must run on the main thread.
    pub fn drainCompletions(self: *Executor, manager: *io_manager.Manager) !usize {
        var drained: usize = 0;

        while (self.pool.tryPopResult()) |completion_value| {
            var completion = completion_value;
            drained += 1;

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
                    discardCompletion(self.callback_context, completion);
                    return err;
                };
            }

            if (!manager.completeWork(completion.token, completion.outcome)) {
                // Stale or duplicate result: operation-specific cleanup
                // owns every payload, including external resources.
                discardCompletion(self.callback_context, completion);
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
            if (retain_payloads) {
                if (completion.progress) |progress| {
                    _ = manager.recordOperationProgress(
                        completion.token,
                        progress.bytes,
                        progress.total_bytes,
                    );
                }
            }

            const result = takeOptional(&completion.result);

            if (retain_payloads) {
                const key = OperationKey.fromToken(completion.token);
                self.continuations.putAssumeCapacity(key, .{
                    .operation_kind = completion.operation_kind,
                    .input = completion.input.take(),
                    .continuation = takeOptional(&completion.continuation),
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
        }

        return drained;
    }

    /// Dispatch ready operations until the scheduler is empty or the
    /// bounded worker pool applies backpressure.
    pub fn dispatchReady(self: *Executor, manager: *io_manager.Manager) !usize {
        var submitted: usize = 0;

        while (manager.dispatchNext()) |token| {
            const key = OperationKey.fromToken(token);

            if (self.pending.getPtr(key)) |pending_item| {
                // Retry a retained item with the new dispatch generation.
                pending_item.token = token;
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
                        .token = token,
                        .operation_kind = payloads.operation_kind,
                        .input = payloads.input,
                        .continuation = payloads.continuation,
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

                    self.pending.putAssumeCapacity(key, .{
                        .token = token,
                        .operation_kind = prepared.operation_kind,
                        .input = prepared.input,
                        .continuation = null,
                    });
                }
            }

            const pending_item = self.pending.getPtr(key).?;
            pending_item.profile_enabled = self.profile_enabled;
            if (self.pool.trySubmit(pending_item.*)) {
                // Ownership transfers to the pool. Do not deinit the
                // removed map value.
                _ = self.pending.fetchRemove(key).?;
                submitted += 1;
                continue;
            }

            // Keep ownership in pending until a later dispatch can submit.
            if (!manager.completeWork(token, .yielded)) {
                if (self.pending.fetchRemove(key)) |entry| {
                    discardWorkItem(self.callback_context, entry.value);
                }
            }
            break;
        }

        return submitted;
    }
};

fn executeWork(context: ?*anyopaque, item: WorkItem) WorkCompletion {
    const callback_context: *CallbackContext = @ptrCast(@alignCast(context.?));
    return callback_context.callbacks.execute(
        callback_context.user_context,
        item,
    );
}

fn discardCompletion(raw_context: ?*anyopaque, completion: WorkCompletion) void {
    const callback_context: *CallbackContext = @ptrCast(@alignCast(raw_context.?));
    discardPayloads(
        callback_context,
        completion.operation_kind,
        completion.input,
        completion.continuation,
        completion.result,
    );
}

fn discardWorkItem(callback_context: *CallbackContext, item: WorkItem) void {
    discardPayloads(
        callback_context,
        item.operation_kind,
        item.input,
        item.continuation,
        null,
    );
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
};

const OperationPayloads = struct {
    operation_kind: OperationKind,
    input: OwnedPayload,
    continuation: ?OwnedPayload,

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
