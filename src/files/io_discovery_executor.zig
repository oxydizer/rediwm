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

const JobId = io_manager.JobId;
const DiscoveryToken = io_manager.DiscoveryToken;

const RootKey = struct {
    job_id: JobId,
    root_id: u64,
};

const Task = struct {
    token: DiscoveryToken,
    cursor: io_discovery.Cursor,
};

const Completion = struct {
    token: DiscoveryToken,
    cursor: ?io_discovery.Cursor = null,
    batch: ?io_discovery.Batch = null,
    failed: bool = false,
};

const Context = struct {
    allocator: Allocator,
    batch_size: usize,
};

const Pool = io_workers.WorkerPool(Task, Completion);

pub const Executor = struct {
    allocator: Allocator,
    context: *Context,
    pool: *Pool,
    anchors: std.AutoHashMapUnmanaged(RootKey, io_discovery.Anchor) = .empty,
    cursors: std.AutoHashMapUnmanaged(
        JobId,
        std.AutoHashMapUnmanaged(u64, io_discovery.Cursor),
    ) = .empty,

    pub fn init(
        allocator: Allocator,
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
        };
    }

    pub fn deinit(self: *Executor) void {
        // Accepted tasks finish before the pool returns. Its discard callback
        // releases any results that were not collected by the main thread.
        self.pool.deinit();

        var job_cursor_iter = self.cursors.valueIterator();
        while (job_cursor_iter.next()) |job_cursors| {
            var cursor_iter = job_cursors.valueIterator();
            while (cursor_iter.next()) |cursor| cursor.deinit();
            job_cursors.deinit(self.allocator);
        }
        self.cursors.deinit(self.allocator);

        var anchor_iter = self.anchors.valueIterator();
        while (anchor_iter.next()) |anchor| anchor.deinit();
        self.anchors.deinit(self.allocator);

        self.allocator.destroy(self.context);
        self.* = undefined;
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
                var anchor = removed.value;
                anchor.deinit();
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
            var cursor: io_discovery.Cursor = undefined;
            var owns_cursor = false;

            if (self.takeCursor(token.job_id, token.entry_id)) |retained| {
                cursor = retained;
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

                cursor = anchor.openCursorForEntry(
                    self.allocator,
                    tree,
                    token.entry_id,
                ) catch {
                    _ = manager.failDiscovery(token);
                    self.closeAnchorIfComplete(manager, token.job_id);
                    continue;
                };
                owns_cursor = true;
            }

            std.debug.assert(owns_cursor);
            if (self.pool.trySubmit(.{
                .token = token,
                .cursor = cursor,
            })) {
                // Cursor ownership transferred to the worker pool.
                submitted += 1;
                continue;
            }

            // Backpressure is nonblocking. Retain the cursor for the next
            // dispatch and return this entry to its priority queue.
            self.storeCursorAssumeCapacity(token.job_id, token.entry_id, cursor);
            if (!manager.yieldDiscovery(token)) {
                if (self.takeCursor(token.job_id, token.entry_id)) |retained| {
                    var cursor_to_close = retained;
                    cursor_to_close.deinit();
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
            drained += 1;

            if (completion.failed) {
                _ = manager.failDiscovery(completion.token);
                self.closeAnchorIfComplete(manager, completion.token.job_id);
                continue;
            }

            if (completion.batch == null) {
                if (completion.cursor) |*cursor| cursor.deinit();
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
                _ = manager.failDiscovery(completion.token);
                self.closeAnchorIfComplete(manager, completion.token.job_id);
                if (first_error == null) first_error = err;
                continue;
            };

            if (!accepted) {
                if (completion.batch) |*batch| batch.deinit();
                if (completion.cursor) |*cursor| cursor.deinit();
                self.closeAnchorIfComplete(manager, completion.token.job_id);
                continue;
            }

            // completeDiscovery consumes the batch on acceptance.
            completion.batch = null;
            if (completion.cursor) |cursor| {
                self.storeCursorAssumeCapacity(
                    completion.token.job_id,
                    completion.token.entry_id,
                    cursor,
                );
                completion.cursor = null;
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
        if (self.anchors.getPtr(key)) |anchor| return anchor;

        self.anchors.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        const path = manager.discoveryRootPath(token.job_id, root_id) orelse return null;
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        const anchor = io_discovery.Anchor.open(path_z) catch
            return null;
        self.anchors.putAssumeCapacity(key, anchor);
        return self.anchors.getPtr(key).?;
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
                var anchor = entry.value;
                anchor.deinit();
            }
        }
    }

    fn takeCursor(
        self: *Executor,
        job_id: JobId,
        entry_id: u64,
    ) ?io_discovery.Cursor {
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
        var job_cursors: std.AutoHashMapUnmanaged(u64, io_discovery.Cursor) = .empty;
        errdefer job_cursors.deinit(self.allocator);
        try job_cursors.ensureUnusedCapacity(self.allocator, 1);
        self.cursors.putAssumeCapacity(job_id, job_cursors);
    }

    fn storeCursorAssumeCapacity(
        self: *Executor,
        job_id: JobId,
        entry_id: u64,
        cursor: io_discovery.Cursor,
    ) void {
        self.cursors.getPtr(job_id).?.putAssumeCapacity(entry_id, cursor);
    }

    fn closeCursorsForJob(self: *Executor, job_id: JobId) void {
        const removed = self.cursors.fetchRemove(job_id) orelse return;
        var job_cursors = removed.value;
        var cursor_iter = job_cursors.valueIterator();
        while (cursor_iter.next()) |cursor| cursor.deinit();
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
            .failed = true,
        };
    };

    if (batch.complete) {
        cursor.deinit();
        return .{
            .token = task.token,
            .batch = batch,
        };
    }

    return .{
        .token = task.token,
        .cursor = cursor,
        .batch = batch,
    };
}

fn discardCompletion(_: ?*anyopaque, completion: Completion) void {
    var discarded = completion;
    if (discarded.batch) |*batch| batch.deinit();
    if (discarded.cursor) |*cursor| cursor.deinit();
}
