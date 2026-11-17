//! Bounded, filesystem-agnostic worker pool for Files I/O work.
//!
//! The pool owns task/result storage and worker threads, but knows nothing
//! about Jobs, Operations, windows, or filesystem semantics.
const std = @import("std");
const platform = @import("platform");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

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
        threads: []std.Thread,
        execute: *const fn (?*anyopaque, Task) Result,
        discard_result: *const fn (?*anyopaque, Result) void,
        context: ?*anyopaque,

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
            if (worker_count == 0) return error.InvalidWorkerCount;
            if (capacity == 0) return error.InvalidCapacity;

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const tasks = try allocator.alloc(Task, capacity);
            errdefer allocator.free(tasks);
            const results = try allocator.alloc(Result, capacity);
            errdefer allocator.free(results);
            const threads = try allocator.alloc(std.Thread, worker_count);
            errdefer allocator.free(threads);
            const event_fd = platform.wake.create() orelse return error.EventFdFailed;
            errdefer _ = c.close(event_fd);

            self.* = .{
                .allocator = allocator,
                .tasks = tasks,
                .results = results,
                .event_fd = event_fd,
                .threads = threads,
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
                for (threads[0..spawned]) |thread| thread.join();
            }

            while (spawned < worker_count) : (spawned += 1) {
                threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{self});
            }

            return self;
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

            for (self.threads) |thread| thread.join();

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

        fn workerMain(self: *Self) void {
            while (true) {
                self.lock();
                while (self.task_count == 0 and !self.stopping) {
                    _ = c.pthread_cond_wait(&self.condition, &self.mutex);
                }
                if (self.stopping and self.task_count == 0) {
                    self.unlock();
                    return;
                }

                const task = self.tasks[self.task_head];
                self.task_head = (self.task_head + 1) % self.tasks.len;
                self.task_count -= 1;
                self.unlock();

                const result = self.execute(self.context, task);

                // Every accepted task reserves a result slot until collection.
                // Therefore this insertion cannot overflow.
                self.lock();
                self.results[self.result_tail] = result;
                self.result_tail = (self.result_tail + 1) % self.results.len;
                self.result_count += 1;
                self.unlock();

                self.signalWake();
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
