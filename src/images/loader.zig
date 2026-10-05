//! A bounded, latest-request-wins decoder. Only this worker calls GdkPixbuf.
const std = @import("std");
const c = @import("../files/c.zig").api;
const Stamp = @import("cache.zig").Stamp;
const decode = @import("decode.zig");
const a = std.heap.c_allocator;
pub const Image = decode.Image;
pub const load = decode.load;
pub const makeThumbnail = decode.makeThumbnail;

pub const Job = struct { index: usize, thumbnail: bool = false };
pub const Result = struct { job: Job, generation: u64, image: ?Image, err: ?anyerror, stamp: ?Stamp = null };
pub const Loader = struct {
    paths: []const [:0]const u8,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    thread: ?std.Thread = null,
    fds: [2]c_int = undefined,
    stop: bool = false,
    generation: u64 = 0,
    jobs: [32]Job = undefined,
    count: usize = 0,
    next: usize = 0,
    results: [8]?Result = @splat(null),
    head: usize = 0,
    tail: usize = 0,
    results_count: usize = 0,

    pub fn init(paths: []const [:0]const u8) !*Loader {
        const self = try a.create(Loader);
        errdefer a.destroy(self);
        self.* = .{ .paths = paths };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        if (c.pipe2(&self.fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.PipeFailed;
        errdefer {
            _ = c.close(self.fds[0]);
            _ = c.close(self.fds[1]);
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn deinit(self: *Loader) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stop = true;
        _ = c.pthread_cond_signal(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
        self.thread.?.join();
        for (&self.results) |*slot| {
            if (slot.*) |r| {
                if (r.image) |im| im.deinit();
                slot.* = null;
            }
        }
        _ = c.close(self.fds[0]);
        _ = c.close(self.fds[1]);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        a.destroy(self);
    }
    pub fn request(self: *Loader, jobs: []const Job) u64 {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.generation += 1;
        @memcpy(self.jobs[0..jobs.len], jobs);
        self.count = jobs.len;
        self.next = 0;
        // Drain any unread results from old generations
        var i: usize = 0;
        while (i < self.results_count) {
            const idx = (self.head + i) % self.results.len;
            if (self.results[idx]) |r| {
                if (r.generation != self.generation) {
                    if (r.image) |im| im.deinit();
                    self.results[idx] = null;
                    var b: [1]u8 = undefined;
                    _ = c.read(self.fds[0], &b, 1);
                }
            }
            i += 1;
        }
        while (self.results_count > 0 and self.results[self.head] == null) {
            self.head = (self.head + 1) % self.results.len;
            self.results_count -= 1;
        }
        _ = c.pthread_cond_signal(&self.cond);
        return self.generation;
    }
    pub fn take(self: *Loader) ?Result {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.results_count == 0) return null;
        var byte: [1]u8 = undefined;
        _ = c.read(self.fds[0], &byte, 1);
        const r = self.results[self.head];
        self.results[self.head] = null;
        self.head = (self.head + 1) % self.results.len;
        self.results_count -= 1;
        _ = c.pthread_cond_signal(&self.cond);
        return r;
    }
    fn run(self: *Loader) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        while (!self.stop) {
            if (self.next == self.count or self.results_count == self.results.len) {
                _ = c.pthread_cond_wait(&self.cond, &self.mutex);
                continue;
            }
            const job = self.jobs[self.next];
            const generation = self.generation;
            self.next += 1;
            _ = c.pthread_mutex_unlock(&self.mutex);
            const stamp = Stamp.read(self.paths[job.index]);
            var err: ?anyerror = null;
            const im = load(self.paths[job.index], job.thumbnail) catch |e| blk: {
                err = e;
                break :blk null;
            };
            _ = c.pthread_mutex_lock(&self.mutex);
            if (self.stop) {
                if (im) |image| image.deinit();
                continue;
            }
            if (self.results_count < self.results.len) {
                self.results[self.tail] = .{ .job = job, .generation = generation, .image = im, .err = err, .stamp = stamp };
                self.tail = (self.tail + 1) % self.results.len;
                self.results_count += 1;
                _ = c.write(self.fds[1], "x", 1);
            } else {
                if (im) |image| image.deinit();
            }
        }
    }
};
