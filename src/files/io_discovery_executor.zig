//! Bounded worker handoff for incremental Files directory discovery.
//!
//! The Manager and TreeIndex remain main-thread-owned. A worker receives
//! exclusive ownership of one directory cursor for one bounded batch, then
//! returns the cursor and batch for main-thread reconciliation.
const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
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

/// A directory the worker must open before reading it. Built on the
/// coordinator from Manager state without filesystem access; the blocking
/// opens happen on the worker (threading §13, C4).
const OpenRequest = struct {
    root_id: u64,
    /// The job's root anchor, borrowed: the executor keeps it open while the
    /// job has work in flight. -1 when the worker must open the root first.
    anchor_fd: c_int = -1,
    /// Owned. Set when `anchor_fd` is -1.
    root_path: ?[:0]u8 = null,
    /// Worker-held ledger entry for the anchor the worker opens.
    anchor_handle: ?LedgerHandle = null,
    /// Owned names from the root down to the entry.
    components: [][:0]u8,

    fn deinit(self: *OpenRequest, allocator: Allocator) void {
        if (self.root_path) |path| allocator.free(path);
        io_discovery.freeComponents(allocator, self.components);
    }
};

/// Exactly one of `cursor` (a retained cursor) and `open` is set.
const Task = struct {
    token: DiscoveryToken,
    ledger_handle: LedgerHandle,
    cursor: ?io_discovery.Cursor = null,
    open: ?OpenRequest = null,

    pub fn stallKey(self: Task) u64 {
        return self.token.job_id;
    }
};

const Completion = struct {
    token: DiscoveryToken,
    ledger_handle: LedgerHandle,
    cursor: ?io_discovery.Cursor = null,
    batch: ?io_discovery.Batch = null,
    failed: bool = false,
    /// A root anchor the worker opened, with its worker-held entry. The
    /// handle is set whenever the task asked for a root to be opened.
    anchor: ?io_discovery.Anchor = null,
    anchor_handle: ?LedgerHandle = null,
    anchor_root_id: u64 = 0,
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
        return initWithLedgerElastic(allocator, ledger, worker_count, worker_count, capacity, batch_size);
    }

    /// As `initWithLedger`, with up to `worker_cap` workers while some are
    /// stuck (worker-pools §4.3).
    pub fn initWithLedgerElastic(
        allocator: Allocator,
        ledger: *Ledger,
        worker_count: usize,
        worker_cap: usize,
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

        const pool = try Pool.initElastic(
            allocator,
            worker_count,
            worker_cap,
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

    /// Releases a retained resource by its stable ledger handle.
    /// Worker-owned resources are never present in these retained maps.
    pub fn releaseResource(self: *Executor, handle: LedgerHandle) !void {
        const owner = self.ledger.ownerOf(handle) orelse
            return error.UnknownResource;
        if (owner != .discovery_executor)
            return error.ResourceOwnerMismatch;
        const job_id = self.ledger.jobIdOf(handle) orelse
            return error.UnknownResource;
        const kind = self.ledger.kindOf(handle) orelse
            return error.UnknownResource;

        var job_iter = self.cursors.iterator();
        while (job_iter.next()) |job_entry| {
            var cursor_iter = job_entry.value_ptr.iterator();
            while (cursor_iter.next()) |entry| {
                if (entry.value_ptr.ledger_handle.id != handle.id) continue;
                if (kind != .discovery_cursor or job_entry.key_ptr.* != job_id)
                    return error.ResourceLedgerMismatch;
                const entry_id = entry.key_ptr.*;
                const removed = job_entry.value_ptr.fetchRemove(entry_id).?;
                var cursor = removed.value.cursor;
                cursor.deinit();
                self.ledger.release(
                    removed.value.ledger_handle,
                    .discovery_executor,
                ) catch unreachable;
                return;
            }
        }

        var anchor_iter = self.anchors.keyIterator();
        while (anchor_iter.next()) |key_ptr| {
            const key = key_ptr.*;
            const lease = self.anchors.get(key) orelse continue;
            if (lease.ledger_handle.id != handle.id) continue;
            if (kind != .discovery_anchor or key.job_id != job_id)
                return error.ResourceLedgerMismatch;
            // Workers borrow the anchor's fd to open cursors: never close it
            // under one, even for a terminal (cancelled) job.
            if (self.in_flight_by_job.contains(job_id)) return error.ResourceBusy;
            const removed = self.anchors.fetchRemove(key).?;
            var anchor = removed.value.anchor;
            anchor.deinit();
            self.ledger.release(
                removed.value.ledger_handle,
                .discovery_executor,
            ) catch unreachable;
            return;
        }

        return error.ResourceNotOwnedByDiscoveryExecutor;
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

    pub fn runningTasks(self: *Executor, out: []io_workers.Running) usize {
        return self.pool.runningTasks(out);
    }

    pub fn grow(self: *Executor, stuck_after_ms: i64) usize {
        return self.pool.grow(stuck_after_ms);
    }

    pub fn queuedCount(self: *Executor) usize {
        return self.pool.queuedCount();
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
                // No cursor yet: the worker opens it, and the root anchor too
                // if this is the job's first unit for that root.
                switch (try self.dispatchOpen(manager, token)) {
                    .submitted => submitted += 1,
                    .failed => {},
                    .full => break,
                }
                continue;
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
            self.adoptAnchor(&completion);

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

    const DispatchOutcome = enum { submitted, failed, full };

    /// Submits a unit whose cursor the worker opens. Does no filesystem
    /// access: the path components come from the Manager's tree, and an
    /// existing anchor is lent by fd.
    fn dispatchOpen(
        self: *Executor,
        manager: *io_manager.Manager,
        token: DiscoveryToken,
    ) !DispatchOutcome {
        self.prepareCursorSlot(token.job_id) catch |err| {
            _ = manager.failDiscovery(token);
            self.closeAnchorIfComplete(manager, token.job_id);
            return err;
        };
        const tree = manager.treeIndex(token.job_id) orelse {
            _ = manager.failDiscovery(token);
            return .failed;
        };
        const root_id = tree.rootForEntry(token.entry_id) orelse {
            _ = manager.failDiscovery(token);
            return .failed;
        };
        var open: OpenRequest = .{
            .root_id = root_id,
            .components = io_discovery.relativeComponents(self.allocator, tree, token.entry_id) catch {
                _ = manager.failDiscovery(token);
                self.closeAnchorIfComplete(manager, token.job_id);
                return .failed;
            },
        };
        var open_owned = true;
        defer if (open_owned) open.deinit(self.allocator);

        if (self.anchors.get(.{ .job_id = token.job_id, .root_id = root_id })) |anchor| {
            open.anchor_fd = anchor.anchor.fd;
        } else {
            const path = manager.discoveryRootPath(token.job_id, root_id) orelse {
                _ = manager.failDiscovery(token);
                return .failed;
            };
            open.root_path = try self.allocator.dupeSentinel(u8, path, 0);
            open.anchor_handle = try self.ledger.register(token.job_id, .discovery_anchor, .discovery_worker);
        }
        errdefer if (open.anchor_handle) |handle| self.ledger.release(handle, .discovery_worker) catch unreachable;

        const cursor_handle = try self.ledger.register(token.job_id, .discovery_cursor, .discovery_worker);
        errdefer self.ledger.release(cursor_handle, .discovery_worker) catch unreachable;

        try self.reserveInFlightSlot(token.job_id);
        if (self.pool.trySubmit(.{ .token = token, .ledger_handle = cursor_handle, .open = open })) {
            open_owned = false;
            self.addInFlightAssumeCapacity(token.job_id);
            return .submitted;
        }

        // Backpressure is nonblocking: give the entry back to its queue.
        self.ledger.release(cursor_handle, .discovery_worker) catch unreachable;
        if (open.anchor_handle) |handle| self.ledger.release(handle, .discovery_worker) catch unreachable;
        open.anchor_handle = null;
        if (!manager.yieldDiscovery(token)) self.closeAnchorIfComplete(manager, token.job_id);
        return .full;
    }

    /// Stores, or gives up, the root anchor a worker opened for a completion.
    fn adoptAnchor(self: *Executor, completion: *Completion) void {
        const handle = completion.anchor_handle orelse return;
        completion.anchor_handle = null;
        var anchor = completion.anchor orelse {
            self.ledger.release(handle, .discovery_worker) catch unreachable;
            return;
        };
        completion.anchor = null;
        const key: RootKey = .{ .job_id = completion.token.job_id, .root_id = completion.anchor_root_id };
        if (self.anchors.contains(key)) {
            // Cannot happen with one unit in flight per job; stay correct anyway.
            anchor.deinit();
            self.ledger.release(handle, .discovery_worker) catch unreachable;
            return;
        }
        self.anchors.put(self.allocator, key, .{ .anchor = anchor, .ledger_handle = handle }) catch {
            anchor.deinit();
            self.ledger.release(handle, .discovery_worker) catch unreachable;
            return;
        };
        self.ledger.transfer(handle, .discovery_worker, .discovery_executor) catch unreachable;
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

fn executeBatch(raw_context: ?*anyopaque, task_value: Task) Completion {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    var task = task_value;
    var opened_anchor: ?io_discovery.Anchor = null;
    var cursor: io_discovery.Cursor = if (task.cursor) |retained| retained else cursor: {
        var open = task.open.?;
        defer open.deinit(context.allocator);
        var anchor_fd = open.anchor_fd;
        if (anchor_fd < 0) {
            opened_anchor = io_discovery.Anchor.open(open.root_path.?) catch null;
            if (opened_anchor) |anchor| anchor_fd = anchor.fd;
        }
        const failed: Completion = .{
            .token = task.token,
            .ledger_handle = task.ledger_handle,
            .failed = true,
            .anchor = opened_anchor,
            .anchor_handle = open.anchor_handle,
            .anchor_root_id = open.root_id,
        };
        if (anchor_fd < 0) return failed;
        break :cursor io_discovery.openCursorAt(anchor_fd, open.components) catch return failed;
    };
    const anchor_handle = if (task.open) |open| open.anchor_handle else null;
    const anchor_root_id = if (task.open) |open| open.root_id else 0;
    task.open = null;

    var completion: Completion = .{
        .token = task.token,
        .ledger_handle = task.ledger_handle,
        .anchor = opened_anchor,
        .anchor_handle = anchor_handle,
        .anchor_root_id = anchor_root_id,
    };
    const batch = cursor.nextBatch(context.allocator, context.batch_size) catch {
        cursor.deinit();
        completion.failed = true;
        return completion;
    };
    completion.batch = batch;
    if (batch.complete) {
        cursor.deinit();
    } else {
        completion.cursor = cursor;
    }
    return completion;
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
    if (discarded.anchor) |*anchor| anchor.deinit();
    if (discarded.anchor_handle) |handle| context.ledger.release(handle, .discovery_worker) catch unreachable;
}

test "discovery executor releases retained cursors and anchors" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    _ = try std.fmt.bufPrint(
        &temp_buffer,
        "/tmp/rediwm_discovery_release_XXXXXX\x00",
        .{},
    );
    const temp_ptr = c.mkdtemp(@ptrCast(&temp_buffer)) orelse
        return error.MkdtempFailed;
    const temp_path = std.mem.span(@as([*:0]const u8, @ptrCast(temp_ptr)));
    const temp_z = try allocator.dupeSentinel(u8, temp_path, 0);
    defer allocator.free(temp_z);
    defer _ = c.rmdir(temp_z);

    var ledger = Ledger.init(allocator);
    defer ledger.deinit();
    var executor = try Executor.initWithLedger(allocator, &ledger, 1, 1, 1);
    defer executor.deinit();

    const job_id: JobId = 71;
    const root_id: u64 = 9;
    const cursor = try io_discovery.Cursor.open(temp_z);
    const cursor_fd = cursor.fd;
    const cursor_handle = try ledger.register(
        job_id,
        .discovery_cursor,
        .discovery_executor,
    );
    var job_cursors: std.AutoHashMapUnmanaged(u64, CursorLease) = .empty;
    errdefer job_cursors.deinit(allocator);
    try job_cursors.put(allocator, 3, .{
        .cursor = cursor,
        .ledger_handle = cursor_handle,
    });
    try executor.cursors.put(allocator, job_id, job_cursors);

    const anchor = try io_discovery.Anchor.open(temp_z);
    const anchor_fd = anchor.fd;
    const anchor_handle = try ledger.register(
        job_id,
        .discovery_anchor,
        .discovery_executor,
    );
    try executor.anchors.put(allocator, .{
        .job_id = job_id,
        .root_id = root_id,
    }, .{
        .anchor = anchor,
        .ledger_handle = anchor_handle,
    });

    try executor.releaseResource(cursor_handle);
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(cursor_fd, c.F_GETFD));
    try std.testing.expect(ledger.ownerOf(cursor_handle) == null);

    try executor.releaseResource(anchor_handle);
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(anchor_fd, c.F_GETFD));
    try std.testing.expect(ledger.ownerOf(anchor_handle) == null);
    try std.testing.expect(ledger.isJobEmpty(job_id));

    try std.testing.expectError(
        error.UnknownResource,
        executor.releaseResource(cursor_handle),
    );
}
