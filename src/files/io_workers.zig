//! Bounded, filesystem-agnostic worker pool for Files I/O work.
//!
//! The pool owns task/result storage and worker threads, but knows nothing
//! about Jobs, Operations, windows, or filesystem semantics.
const std = @import("std");
const platform = @import("platform");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

/// A task a worker is running: its `stallKey` (0 when the Task type has
/// none) and when the worker took it, in monotonic milliseconds.
pub const Running = struct { key: u64, since_ms: i64 };

/// An extra worker exits after this long without work (worker-pools §4.3).
pub const idle_exit_ms: i64 = 30_000;

pub fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

/// Creates a pool for copied Task and Result values.
///
/// `execute` runs on a worker thread. Its context must remain valid until
/// `deinit` returns and must be safe for concurrent access by all workers.
/// It must not access UI or main-thread-owned manager state.
///
/// `discard_result` is called by `deinit` for results that were produced but
/// not collected. It is the caller's opportunity to release result-owned
/// resources. Results collected with `tryPopResult` belong to the caller.
pub fn WorkerPool(comptime Task: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        const keyed = switch (@typeInfo(Task)) {
            .@"struct", .@"union" => @hasDecl(Task, "stallKey"),
            else => false,
        };

        allocator: Allocator,
        tasks: []Task,
        results: []Result,
        task_head: usize = 0,
        task_tail: usize = 0,
        task_count: usize = 0,
        result_head: usize = 0,
        result_tail: usize = 0,
        result_count: usize = 0,
        outstanding: usize = 0,
        stopping: bool = false,
        mutex: c.pthread_mutex_t = undefined,
        condition: c.pthread_cond_t = undefined,
        event_fd: std.posix.fd_t,
        /// One slot per possible worker (`cap`), under `mutex`.
        threads: []?std.Thread,
        slots: []Slot,
        /// Per worker slot, under `mutex`: the task it runs, if any.
        running: []?Running,
        /// Workers the pool keeps runnable; extra ones started by `grow`
        /// exit after `idle_exit_ms` without work, down to this.
        target: usize,
        /// Live worker threads, under `mutex`.
        alive: usize = 0,
        /// The threshold of the last `grow`, under `mutex`.
        stuck_after_ms: i64 = std.math.maxInt(i64),
        execute: *const fn (?*anyopaque, Task) Result,
        discard_result: *const fn (?*anyopaque, Result) void,
        context: ?*anyopaque,

        const Slot = enum { empty, alive, exited };

        /// `worker_count` and `capacity` must both be greater than zero.
        /// Capacity bounds all accepted work, including results not yet
        /// collected, so a worker can always publish its result.
        pub fn init(
            allocator: Allocator,
            worker_count: usize,
            capacity: usize,
            context: ?*anyopaque,
            execute: *const fn (?*anyopaque, Task) Result,
            discard_result: *const fn (?*anyopaque, Result) void,
        ) !*Self {
            return initElastic(allocator, worker_count, worker_count, capacity, context, execute, discard_result);
        }

        /// Starts `target` workers; `grow` may start more, up to `cap`,
        /// while workers are stuck (worker-pools §4.3).
        pub fn initElastic(
            allocator: Allocator,
            target: usize,
            cap: usize,
            capacity: usize,
            context: ?*anyopaque,
            execute: *const fn (?*anyopaque, Task) Result,
            discard_result: *const fn (?*anyopaque, Result) void,
        ) !*Self {
            if (target == 0 or cap < target) return error.InvalidWorkerCount;
            if (capacity == 0) return error.InvalidCapacity;

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const tasks = try allocator.alloc(Task, capacity);
            errdefer allocator.free(tasks);
            const results = try allocator.alloc(Result, capacity);
            errdefer allocator.free(results);
            const threads = try allocator.alloc(?std.Thread, cap);
            errdefer allocator.free(threads);
            @memset(threads, null);
            const slots = try allocator.alloc(Slot, cap);
            errdefer allocator.free(slots);
            @memset(slots, .empty);
            const running = try allocator.alloc(?Running, cap);
            errdefer allocator.free(running);
            @memset(running, null);
            const event_fd = platform.wake.create() orelse return error.EventFdFailed;
            errdefer _ = c.close(event_fd);

            self.* = .{
                .allocator = allocator,
                .tasks = tasks,
                .results = results,
                .event_fd = event_fd,
                .threads = threads,
                .slots = slots,
                .running = running,
                .target = target,
                .execute = execute,
                .discard_result = discard_result,
                .context = context,
            };

            if (c.pthread_mutex_init(&self.mutex, null) != 0)
                return error.MutexInitFailed;
            errdefer _ = c.pthread_mutex_destroy(&self.mutex);

            if (c.pthread_cond_init(&self.condition, null) != 0)
                return error.ConditionInitFailed;
            errdefer _ = c.pthread_cond_destroy(&self.condition);

            var spawned: usize = 0;
            errdefer {
                self.lock();
                self.stopping = true;
                _ = c.pthread_cond_broadcast(&self.condition);
                self.unlock();
                for (threads[0..spawned]) |thread| thread.?.join();
            }

            while (spawned < target) : (spawned += 1) {
                threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{ self, spawned });
                slots[spawned] = .alive;
                self.alive += 1;
            }

            return self;
        }

        /// Starts workers for queued work while some are stuck: a worker that
        /// has run one task for `stuck_after_ms` stops counting toward the
        /// target, and a replacement starts while the pool is under its cap.
        /// Also joins workers that exited idle (they have returned, so this
        /// does not wait). Returns how many it started.
        pub fn grow(self: *Self, stuck_after_ms: i64) usize {
            var exited: [16]std.Thread = undefined;
            var exited_count: usize = 0;
            var started: usize = 0;
            self.lock();
            for (self.slots, 0..) |*slot, index| {
                if (slot.* != .exited or exited_count == exited.len) continue;
                exited[exited_count] = self.threads[index].?;
                exited_count += 1;
                self.threads[index] = null;
                slot.* = .empty;
            }
            self.stuck_after_ms = stuck_after_ms;
            if (!self.stopping and self.task_count > 0) {
                var runnable = self.runnableLocked();
                var wanted = @min(self.task_count, self.target -| runnable);
                for (self.slots, 0..) |*slot, index| {
                    if (wanted == 0) break;
                    if (slot.* != .empty) continue;
                    self.threads[index] = std.Thread.spawn(.{}, workerMain, .{ self, index }) catch break;
                    slot.* = .alive;
                    self.alive += 1;
                    runnable += 1;
                    wanted -= 1;
                    started += 1;
                }
            }
            self.unlock();
            for (exited[0..exited_count]) |thread| thread.join();
            return started;
        }

        /// Workers not stuck in a task, under `mutex`.
        fn runnableLocked(self: *Self) usize {
            const now = monotonicMs();
            var stuck: usize = 0;
            for (self.running) |slot| {
                const task = slot orelse continue;
                if (now - task.since_ms >= self.stuck_after_ms) stuck += 1;
            }
            return self.alive - stuck;
        }

        /// Live worker threads; for tests and the bench.
        pub fn workerCount(self: *Self) usize {
            self.lock();
            defer self.unlock();
            return self.alive;
        }

        /// Attempts to submit without blocking. False means the pool is
        /// stopping or its outstanding-work capacity is exhausted.
        pub fn trySubmit(self: *Self, task: Task) bool {
            self.lock();
            defer self.unlock();

            if (self.stopping or self.outstanding == self.tasks.len) return false;

            self.tasks[self.task_tail] = task;
            self.task_tail = (self.task_tail + 1) % self.tasks.len;
            self.task_count += 1;
            self.outstanding += 1;
            _ = c.pthread_cond_signal(&self.condition);
            return true;
        }

        /// Returns one completed result, or null when none is available.
        /// Collecting a result releases one outstanding-work slot.
        pub fn tryPopResult(self: *Self) ?Result {
            self.lock();
            defer self.unlock();

            if (self.result_count == 0) return null;
            const result = self.results[self.result_head];
            self.result_head = (self.result_head + 1) % self.results.len;
            self.result_count -= 1;
            self.outstanding -= 1;
            return result;
        }

        /// Copies the tasks workers are running now into `out`; returns how
        /// many. A task that runs long without returning is stuck in a
        /// syscall (worker-pools §4.2): work yields in bounded units.
        pub fn runningTasks(self: *Self, out: []Running) usize {
            self.lock();
            defer self.unlock();
            var count: usize = 0;
            for (self.running) |slot| {
                const task = slot orelse continue;
                if (count == out.len) break;
                out[count] = task;
                count += 1;
            }
            return count;
        }

        /// Accepted tasks no worker has taken yet.
        pub fn queuedCount(self: *Self) usize {
            self.lock();
            defer self.unlock();
            return self.task_count;
        }

        /// No accepted task is queued, running, or waiting to be collected.
        pub fn isIdle(self: *Self) bool {
            self.lock();
            defer self.unlock();
            return self.outstanding == 0;
        }

        /// Event descriptor for the main thread's poll loop.
        pub fn wakeFd(self: *const Self) std.posix.fd_t {
            return self.event_fd;
        }

        /// Drain the eventfd after it becomes readable. The result queue is
        /// authoritative; the eventfd is only a coalesced wake-up signal.
        pub fn drainWake(self: *Self) u64 {
            var count: u64 = 0;
            var drained: u64 = 0;
            while (true) {
                const rc = std.posix.system.read(
                    self.event_fd,
                    std.mem.asBytes(&count),
                    @sizeOf(u64),
                );
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {
                        std.debug.assert(rc == @sizeOf(u64));
                        drained +|= count;
                    },
                    .INTR => continue,
                    .AGAIN => return drained,
                    else => std.debug.panic(
                        "I/O worker eventfd read failed: {s}",
                        .{@tagName(std.posix.errno(rc))},
                    ),
                }
            }
        }

        /// Stops accepting work, finishes all accepted tasks, and joins every
        /// worker. Uncollected results are passed to `discard_result`.
        pub fn deinit(self: *Self) void {
            self.lock();
            self.stopping = true;
            _ = c.pthread_cond_broadcast(&self.condition);
            self.unlock();

            for (self.threads) |thread| if (thread) |t| t.join();

            while (self.result_count > 0) {
                const result = self.results[self.result_head];
                self.result_head = (self.result_head + 1) % self.results.len;
                self.result_count -= 1;
                self.discard_result(self.context, result);
            }

            _ = c.close(self.event_fd);
            _ = c.pthread_cond_destroy(&self.condition);
            _ = c.pthread_mutex_destroy(&self.mutex);
            self.allocator.free(self.threads);
            self.allocator.free(self.running);
            self.allocator.free(self.slots);
            self.allocator.free(self.results);
            self.allocator.free(self.tasks);
            self.allocator.destroy(self);
        }

        fn lock(self: *Self) void {
            _ = c.pthread_mutex_lock(&self.mutex);
        }

        fn unlock(self: *Self) void {
            _ = c.pthread_mutex_unlock(&self.mutex);
        }

        fn workerMain(self: *Self, index: usize) void {
            while (true) {
                self.lock();
                var idle_since: ?i64 = null;
                while (self.task_count == 0 and !self.stopping) {
                    if (self.alive <= self.target) {
                        idle_since = null;
                        _ = c.pthread_cond_wait(&self.condition, &self.mutex);
                        continue;
                    }
                    // An extra worker: leave once idle long enough.
                    const since = idle_since orelse monotonicMs();
                    idle_since = since;
                    if (monotonicMs() - since >= idle_exit_ms) {
                        self.slots[index] = .exited;
                        self.alive -= 1;
                        self.unlock();
                        return;
                    }
                    var until: c.struct_timespec = undefined;
                    _ = c.clock_gettime(c.CLOCK_REALTIME, &until);
                    until.tv_sec += @intCast(@divTrunc(idle_exit_ms, 1000) + 1);
                    _ = c.pthread_cond_timedwait(&self.condition, &self.mutex, &until);
                }
                if (self.stopping and self.task_count == 0) {
                    self.unlock();
                    return;
                }

                const task = self.tasks[self.task_head];
                self.task_head = (self.task_head + 1) % self.tasks.len;
                self.task_count -= 1;
                self.running[index] = .{ .key = if (keyed) task.stallKey() else 0, .since_ms = monotonicMs() };
                self.unlock();

                const result = self.execute(self.context, task);

                // Every accepted task reserves a result slot until collection.
                // Therefore this insertion cannot overflow.
                self.lock();
                self.running[index] = null;
                self.results[self.result_tail] = result;
                self.result_tail = (self.result_tail + 1) % self.results.len;
                self.result_count += 1;
                // An extra worker nothing waits for leaves at once: the
                // stall it stood in for is over, or others cover the queue.
                const leave = self.alive > self.target and self.task_count == 0 and
                    self.runnableLocked() > self.target;
                if (leave) {
                    self.slots[index] = .exited;
                    self.alive -= 1;
                }
                self.unlock();

                self.signalWake();
                if (leave) return;
            }
        }

        fn signalWake(self: *Self) void {
            const one: u64 = 1;
            while (true) {
                const rc = std.posix.system.write(
                    self.event_fd,
                    std.mem.asBytes(&one),
                    @sizeOf(u64),
                );
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {
                        std.debug.assert(rc == @sizeOf(u64));
                        return;
                    },
                    .INTR => continue,
                    // A saturated eventfd is already readable.
                    .AGAIN => return,
                    else => std.debug.panic(
                        "I/O worker eventfd write failed: {s}",
                        .{@tagName(std.posix.errno(rc))},
                    ),
                }
            }
        }
    };
}

test "worker pool joins active work and discards accepted results on shutdown" {
    const TestPool = WorkerPool(u8, u8);
    const TestContext = struct {
        pool: ?*TestPool = null,
        started: std.atomic.Value(bool) = .init(false),
        executed: usize = 0,
        discarded: usize = 0,
    };
    const callbacks = struct {
        fn execute(raw_context: ?*anyopaque, task: u8) u8 {
            const context: *TestContext = @ptrCast(@alignCast(raw_context.?));
            context.executed += 1;

            if (task == 1) {
                context.started.store(true, .release);
                const pool = context.pool.?;
                pool.lock();
                _ = c.pthread_cond_broadcast(&pool.condition);
                pool.unlock();
                while (true) {
                    pool.lock();
                    const stopping = pool.stopping;
                    pool.unlock();
                    if (stopping) break;
                }
            }

            return task;
        }

        fn discard(raw_context: ?*anyopaque, _: u8) void {
            const context: *TestContext = @ptrCast(@alignCast(raw_context.?));
            context.discarded += 1;
        }
    };

    var context: TestContext = .{};
    const pool = try TestPool.init(
        std.testing.allocator,
        1,
        2,
        @ptrCast(&context),
        callbacks.execute,
        callbacks.discard,
    );
    var pool_owned = true;
    defer if (pool_owned) pool.deinit();
    context.pool = pool;

    try std.testing.expect(pool.trySubmit(1));

    pool.lock();
    while (!context.started.load(.acquire)) {
        _ = c.pthread_cond_wait(&pool.condition, &pool.mutex);
    }
    pool.unlock();
    try std.testing.expect(pool.trySubmit(2));

    // The first task waits for shutdown to begin. The second remains queued.
    // deinit must join both tasks before discarding their uncollected results.
    pool.deinit();
    pool_owned = false;

    try std.testing.expectEqual(@as(usize, 2), context.executed);
    try std.testing.expectEqual(@as(usize, 2), context.discarded);
}

test "a stuck worker is replaced for queued work, up to the cap" {
    const TestPool = WorkerPool(u8, u8);
    const Gate = struct {
        var open: std.atomic.Value(bool) = .init(false);
        var parked: std.atomic.Value(u32) = .init(0);
        fn execute(_: ?*anyopaque, task: u8) u8 {
            if (task == 1) {
                _ = parked.fetchAdd(1, .acq_rel);
                while (!open.load(.acquire)) _ = std.posix.system.poll(&.{}, 0, 1);
            }
            return task;
        }
        fn discard(_: ?*anyopaque, _: u8) void {}
    };
    Gate.open.store(false, .release);
    Gate.parked.store(0, .release);
    const pool = try TestPool.initElastic(std.testing.allocator, 1, 2, 8, null, Gate.execute, Gate.discard);
    defer pool.deinit();
    defer Gate.open.store(true, .release);

    // The one worker hangs; a second task waits behind it.
    try std.testing.expect(pool.trySubmit(1));
    while (Gate.parked.load(.acquire) == 0) _ = std.posix.system.poll(&.{}, 0, 1);
    try std.testing.expect(pool.trySubmit(2));
    try std.testing.expectEqual(@as(usize, 0), pool.grow(60_000)); // not stuck yet

    // Stuck (threshold 0): a replacement starts and runs the second task.
    try std.testing.expectEqual(@as(usize, 1), pool.grow(0));
    try std.testing.expectEqual(@as(usize, 2), pool.workerCount());
    for (0..2000) |_| {
        if (pool.tryPopResult()) |result| {
            try std.testing.expectEqual(@as(u8, 2), result);
            break;
        }
        _ = std.posix.system.poll(&.{}, 0, 1);
    } else return error.Timeout;

    // At the cap, a second stuck worker gets no third.
    try std.testing.expect(pool.trySubmit(1));
    while (Gate.parked.load(.acquire) < 2) _ = std.posix.system.poll(&.{}, 0, 1);
    try std.testing.expect(pool.trySubmit(3));
    try std.testing.expectEqual(@as(usize, 0), pool.grow(0));
}
