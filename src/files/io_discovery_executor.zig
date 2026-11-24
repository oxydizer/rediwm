//! Bounded worker handoff for incremental Files directory discovery.
//!
//! The Manager and TreeIndex remain main-thread-owned. A worker receives
//! exclusive ownership of one directory cursor for one bounded batch, then
//! returns the cursor and batch for main-thread reconciliation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_manager = @import("io_manager.zig");
const io_discovery = @import("io_discovery.zig");
const io_workers = @import("io_workers.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");

const JobId = io_manager.JobId;
const DiscoveryToken = io_manager.DiscoveryToken;
const Ledger = io_resource_ledger.Ledger;
const LedgerHandle = io_resource_ledger.Handle;

const AnchorLease = struct {
    anchor: io_discovery.Anchor,
    ledger_handle: LedgerHandle,
};

const CursorLease = struct {
    cursor: io_discovery.Cursor,
    ledger_handle: LedgerHandle,
};

const RootKey = struct {
    job_id: JobId,
    root_id: u64,
};

const Task = struct {
    token: DiscoveryToken,
    cursor: io_discovery.Cursor,
    ledger_handle: LedgerHandle,
};

const Completion = struct {
    token: DiscoveryToken,
    ledger_handle: LedgerHandle,
    cursor: ?io_discovery.Cursor = null,
    batch: ?io_discovery.Batch = null,
    failed: bool = false,
};

const Context = struct {
    allocator: Allocator,
    batch_size: usize,
    ledger: *Ledger,
};

const Pool = io_workers.WorkerPool(Task, Completion);

pub const Executor = struct {
    allocator: Allocator,
    context: *Context,
    pool: *Pool,
    ledger: *Ledger,
    owned_ledger: ?*Ledger = null,
    anchors: std.AutoHashMapUnmanaged(RootKey, AnchorLease) = .empty,
    cursors: std.AutoHashMapUnmanaged(
        JobId,
        std.AutoHashMapUnmanaged(u64, CursorLease),
    ) = .empty,
    in_flight_by_job: std.AutoHashMapUnmanaged(JobId, usize) = .empty,

    pub fn init(
        allocator: Allocator,
        worker_count: usize,
        capacity: usize,
        batch_size: usize,
    ) !Executor {
        const ledger = try allocator.create(Ledger);
        errdefer allocator.destroy(ledger);
        ledger.* = Ledger.init(allocator);
        errdefer ledger.deinit();

        var executor = try initWithLedger(
            allocator,
            ledger,
            worker_count,
            capacity,
            batch_size,
        );
        executor.owned_ledger = ledger;
        return executor;
    }

    pub fn initWithLedger(
        allocator: Allocator,
        ledger: *Ledger,
        worker_count: usize,
        capacity: usize,
        batch_size: usize,
    ) !Executor {
        if (batch_size == 0) return error.InvalidBatchSize;

        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);
        context.* = .{
            .allocator = allocator,
            .batch_size = batch_size,
            .ledger = ledger,
        };

        const pool = try Pool.init(
            allocator,
            worker_count,
            capacity,
            context,
            executeBatch,
            discardCompletion,
        );

        return .{
            .allocator = allocator,
            .context = context,
            .pool = pool,
            .ledger = ledger,
        };
    }

    pub fn deinit(self: *Executor) void {
        // Accepted tasks finish before the pool returns. Its discard callback
        // releases any results that were not collected by the main thread.
        self.pool.deinit();

        var job_cursor_iter = self.cursors.valueIterator();
        while (job_cursor_iter.next()) |job_cursors| {
            var cursor_iter = job_cursors.valueIterator();
            while (cursor_iter.next()) |lease| {
                var cursor = lease.cursor;
                cursor.deinit();
                self.ledger.release(
                    lease.ledger_handle,
                    .discovery_executor,
                ) catch unreachable;
            }
            job_cursors.deinit(self.allocator);
        }
        self.cursors.deinit(self.allocator);

        var anchor_iter = self.anchors.valueIterator();
        while (anchor_iter.next()) |lease| {
            var anchor = lease.anchor;
            anchor.deinit();
            self.ledger.release(
                lease.ledger_handle,
                .discovery_executor,
            ) catch unreachable;
        }
        self.anchors.deinit(self.allocator);
        self.in_flight_by_job.deinit(self.allocator);

        self.allocator.destroy(self.context);
        if (self.owned_ledger) |ledger| {
            std.debug.assert(ledger.isEmpty());
            ledger.deinit();
            self.allocator.destroy(ledger);
        }
        self.* = undefined;
    }

    /// True only when this executor owns no worker task, retained cursor,
    /// or root anchor for the Job. Manager-side discovery queues are separate.
    pub fn isJobQuiescent(self: *const Executor, job_id: JobId) bool {
        if (self.in_flight_by_job.contains(job_id)) return false;

        if (self.cursors.get(job_id)) |job_cursors| {
            if (job_cursors.count() != 0) return false;
        }

        var anchor_iter = self.anchors.keyIterator();
        while (anchor_iter.next()) |key| {
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

    pub fn wakeFd(self: *Executor) std.posix.fd_t {
        return self.pool.wakeFd();
    }

    pub fn drainWake(self: *Executor) u64 {
        return self.pool.drainWake();
    }

    /// Releases every resource retained for a cancelled Job. Cursors
    /// currently owned by workers are closed when their stale completions
    /// return to the main thread.
    pub fn cancelJob(
        self: *Executor,
        manager: *const io_manager.Manager,
        job_id: JobId,
    ) void {
        self.closeCursorsForJob(job_id);

        const tree = manager.treeIndex(job_id) orelse return;
        for (tree.roots()) |root_id| {
            const key: RootKey = .{
                .job_id = job_id,
                .root_id = root_id,
            };
            if (self.anchors.fetchRemove(key)) |removed| {
                var anchor = removed.value.anchor;
                anchor.deinit();
                self.ledger.release(
                    removed.value.ledger_handle,
                    .discovery_executor,
                ) catch unreachable;
            }
        }
    }

    /// Dispatches discovery batches until the Manager has no eligible entry
    /// or the bounded pool applies backpressure.
    pub fn dispatchReady(
        self: *Executor,
        manager: *io_manager.Manager,
    ) !usize {
        var submitted: usize = 0;

        while (manager.dispatchDiscovery()) |token| {
            var lease: CursorLease = undefined;
            var owns_cursor = false;

            if (self.takeCursor(token.job_id, token.entry_id)) |retained| {
                lease = retained;
                owns_cursor = true;
            } else {
                self.prepareCursorSlot(token.job_id) catch |err| {
                    _ = manager.failDiscovery(token);
                    self.closeAnchorIfComplete(manager, token.job_id);
                    return err;
                };

                const anchor = self.getOrOpenAnchor(manager, token) catch |err| {
                    _ = manager.failDiscovery(token);
                    self.closeAnchorIfComplete(manager, token.job_id);
                    return err;
                } orelse {
                    _ = manager.failDiscovery(token);
                    continue;
                };
                const tree = manager.treeIndex(token.job_id) orelse {
                    _ = manager.failDiscovery(token);
                    continue;
                };

                const cursor = anchor.openCursorForEntry(
                    self.allocator,
                    tree,
                    token.entry_id,
                ) catch {
                    _ = manager.failDiscovery(token);
                    self.closeAnchorIfComplete(manager, token.job_id);
                    continue;
                };
                const handle = self.ledger.register(
                    token.job_id,
                    .discovery_cursor,
                    .discovery_executor,
                ) catch |err| {
                    var cursor_to_close = cursor;
                    cursor_to_close.deinit();
                    _ = manager.failDiscovery(token);
                    self.closeAnchorIfComplete(manager, token.job_id);
                    return err;
                };
                lease = .{
                    .cursor = cursor,
                    .ledger_handle = handle,
                };
                owns_cursor = true;
            }

            std.debug.assert(owns_cursor);
            self.reserveInFlightSlot(token.job_id) catch |err| {
                // The cursor slot was prepared before opening or taking the
                // cursor, so ownership can safely return to the retained map.
                self.storeCursorAssumeCapacity(token.job_id, token.entry_id, lease);
                if (!manager.yieldDiscovery(token)) {
                    if (self.takeCursor(token.job_id, token.entry_id)) |retained| {
                        var cursor_to_close = retained.cursor;
                        cursor_to_close.deinit();
                        self.ledger.release(
                            retained.ledger_handle,
                            .discovery_executor,
                        ) catch unreachable;
                    }
                    self.closeAnchorIfComplete(manager, token.job_id);
                }
                return err;
            };
            self.ledger.transfer(
                lease.ledger_handle,
                .discovery_executor,
                .discovery_worker,
            ) catch unreachable;
            if (self.pool.trySubmit(.{
                .token = token,
                .cursor = lease.cursor,
                .ledger_handle = lease.ledger_handle,
            })) {
                // Cursor ownership transferred to the worker pool.
                self.addInFlightAssumeCapacity(token.job_id);
                submitted += 1;
                continue;
            }

            // Backpressure is nonblocking. Retain the cursor for the next
            // dispatch and return this entry to its priority queue.
            self.ledger.transfer(
                lease.ledger_handle,
                .discovery_worker,
                .discovery_executor,
            ) catch unreachable;
            self.storeCursorAssumeCapacity(token.job_id, token.entry_id, lease);
            if (!manager.yieldDiscovery(token)) {
                if (self.takeCursor(token.job_id, token.entry_id)) |retained| {
                    var cursor_to_close = retained.cursor;
                    cursor_to_close.deinit();
                    self.ledger.release(
                        retained.ledger_handle,
                        .discovery_executor,
                    ) catch unreachable;
                }
                self.closeAnchorIfComplete(manager, token.job_id);
            }
            break;
        }

        return submitted;
    }

    /// Reconciles all currently available batches on the Manager thread.
    pub fn drainCompletions(
        self: *Executor,
        manager: *io_manager.Manager,
    ) !usize {
        var drained: usize = 0;
        var first_error: ?anyerror = null;

        while (self.pool.tryPopResult()) |completion_value| {
            var completion = completion_value;
            defer self.finishInFlight(completion.token.job_id);
            drained += 1;

            if (completion.failed) {
                self.ledger.release(
                    completion.ledger_handle,
                    .discovery_worker,
                ) catch unreachable;
                _ = manager.failDiscovery(completion.token);
                self.closeAnchorIfComplete(manager, completion.token.job_id);
                continue;
            }

            if (completion.batch == null) {
                if (completion.cursor) |*cursor| cursor.deinit();
                self.ledger.release(
                    completion.ledger_handle,
                    .discovery_worker,
                ) catch unreachable;
                _ = manager.failDiscovery(completion.token);
                self.closeAnchorIfComplete(manager, completion.token.job_id);
                continue;
            }

            if (completion.cursor != null) {
                self.prepareCursorSlot(
                    completion.token.job_id,
                ) catch |err| {
                    if (completion.batch) |*batch| batch.deinit();
                    if (completion.cursor) |*cursor| cursor.deinit();
                    self.ledger.release(
                        completion.ledger_handle,
                        .discovery_worker,
                    ) catch unreachable;
                    _ = manager.failDiscovery(completion.token);
                    self.closeAnchorIfComplete(manager, completion.token.job_id);
                    if (first_error == null) first_error = err;
                    continue;
                };
            }

            const accepted = manager.completeDiscovery(
                completion.token,
                &completion.batch.?,
            ) catch |err| {
                if (completion.batch) |*batch| batch.deinit();
                if (completion.cursor) |*cursor| cursor.deinit();
                self.ledger.release(
                    completion.ledger_handle,
                    .discovery_worker,
                ) catch unreachable;
                _ = manager.failDiscovery(completion.token);
                self.closeAnchorIfComplete(manager, completion.token.job_id);
                if (first_error == null) first_error = err;
                continue;
            };

            if (!accepted) {
                if (completion.batch) |*batch| batch.deinit();
                if (completion.cursor) |*cursor| cursor.deinit();
                self.ledger.release(
                    completion.ledger_handle,
                    .discovery_worker,
                ) catch unreachable;
                self.closeAnchorIfComplete(manager, completion.token.job_id);
                continue;
            }

            // completeDiscovery consumes the batch on acceptance.
            completion.batch = null;
            if (completion.cursor) |cursor| {
                self.ledger.transfer(
                    completion.ledger_handle,
                    .discovery_worker,
                    .discovery_executor,
                ) catch unreachable;
                self.storeCursorAssumeCapacity(
                    completion.token.job_id,
                    completion.token.entry_id,
                    .{
                        .cursor = cursor,
                        .ledger_handle = completion.ledger_handle,
                    },
                );
                completion.cursor = null;
            } else {
                self.ledger.release(
                    completion.ledger_handle,
                    .discovery_worker,
                ) catch unreachable;
            }

            self.closeAnchorIfComplete(manager, completion.token.job_id);
        }

        if (first_error) |err| return err;
        return drained;
    }

    fn getOrOpenAnchor(
        self: *Executor,
        manager: *io_manager.Manager,
        token: DiscoveryToken,
    ) !?*io_discovery.Anchor {
        const tree = manager.treeIndex(token.job_id) orelse return null;
        const root_id = tree.rootForEntry(token.entry_id) orelse return null;
        const key: RootKey = .{
            .job_id = token.job_id,
            .root_id = root_id,
        };
        if (self.anchors.getPtr(key)) |lease| return &lease.anchor;

        self.anchors.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        const path = manager.discoveryRootPath(token.job_id, root_id) orelse return null;
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        const anchor = io_discovery.Anchor.open(path_z) catch
            return null;
        const handle = self.ledger.register(
            token.job_id,
            .discovery_anchor,
            .discovery_executor,
        ) catch |err| {
            var anchor_to_close = anchor;
            anchor_to_close.deinit();
            return err;
        };
        self.anchors.putAssumeCapacity(key, .{
            .anchor = anchor,
            .ledger_handle = handle,
        });
        return &self.anchors.getPtr(key).?.anchor;
    }

    fn closeAnchorIfComplete(
        self: *Executor,
        manager: *const io_manager.Manager,
        job_id: JobId,
    ) void {
        if (manager.discoveryComplete(job_id) != true) return;

        self.closeCursorsForJob(job_id);
        const tree = manager.treeIndex(job_id) orelse return;
        for (tree.roots()) |root_id| {
            const key: RootKey = .{
                .job_id = job_id,
                .root_id = root_id,
            };
            if (self.anchors.fetchRemove(key)) |entry| {
                var anchor = entry.value.anchor;
                anchor.deinit();
                self.ledger.release(
                    entry.value.ledger_handle,
                    .discovery_executor,
                ) catch unreachable;
            }
        }
    }

    fn takeCursor(
        self: *Executor,
        job_id: JobId,
        entry_id: u64,
    ) ?CursorLease {
        const job_cursors = self.cursors.getPtr(job_id) orelse return null;
        const retained = job_cursors.fetchRemove(entry_id) orelse return null;
        return retained.value;
    }

    fn prepareCursorSlot(self: *Executor, job_id: JobId) !void {
        if (self.cursors.getPtr(job_id)) |job_cursors| {
            try job_cursors.ensureUnusedCapacity(self.allocator, 1);
            return;
        }

        try self.cursors.ensureUnusedCapacity(self.allocator, 1);
        var job_cursors: std.AutoHashMapUnmanaged(u64, CursorLease) = .empty;
        errdefer job_cursors.deinit(self.allocator);
        try job_cursors.ensureUnusedCapacity(self.allocator, 1);
        self.cursors.putAssumeCapacity(job_id, job_cursors);
    }

    fn storeCursorAssumeCapacity(
        self: *Executor,
        job_id: JobId,
        entry_id: u64,
        cursor: CursorLease,
    ) void {
        self.cursors.getPtr(job_id).?.putAssumeCapacity(entry_id, cursor);
    }

    fn closeCursorsForJob(self: *Executor, job_id: JobId) void {
        const removed = self.cursors.fetchRemove(job_id) orelse return;
        var job_cursors = removed.value;
        var cursor_iter = job_cursors.valueIterator();
        while (cursor_iter.next()) |lease| {
            var cursor = lease.cursor;
            cursor.deinit();
            self.ledger.release(
                lease.ledger_handle,
                .discovery_executor,
            ) catch unreachable;
        }
        job_cursors.deinit(self.allocator);
    }
};

fn executeBatch(raw_context: ?*anyopaque, task: Task) Completion {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    var cursor = task.cursor;

    const batch = cursor.nextBatch(context.allocator, context.batch_size) catch {
        cursor.deinit();
        return .{
            .token = task.token,
            .ledger_handle = task.ledger_handle,
            .failed = true,
        };
    };

    if (batch.complete) {
        cursor.deinit();
        return .{
            .token = task.token,
            .ledger_handle = task.ledger_handle,
            .batch = batch,
        };
    }

    return .{
        .token = task.token,
        .ledger_handle = task.ledger_handle,
        .cursor = cursor,
        .batch = batch,
    };
}

fn discardCompletion(raw_context: ?*anyopaque, completion: Completion) void {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    var discarded = completion;
    if (discarded.batch) |*batch| batch.deinit();
    if (discarded.cursor) |*cursor| cursor.deinit();
    context.ledger.release(
        discarded.ledger_handle,
        .discovery_worker,
    ) catch unreachable;
}
