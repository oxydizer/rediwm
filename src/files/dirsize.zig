const std = @import("std");
const c = @import("c.zig").api;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const STATX_ATTR_MOUNT_ROOT: u64 = 0x2000;
pub const queue_capacity: usize = 256;
pub const buffer_size: usize = 65536;

pub const InodeKey = struct {
    dev: u64,
    ino: u64,
};

pub const Job = struct {
    allocator: Allocator,
    dev_id: u64,
    ref_count: std.atomic.Value(usize) = .init(1),
    pending: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(i64) = .init(0),
    files: std.atomic.Value(usize) = .init(0),
    dirs: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    partial: std.atomic.Value(bool) = .init(false),
    hardlink_mutex: c.pthread_mutex_t = undefined,
    seen_hardlinks: std.AutoHashMap(InodeKey, void),

    pub fn create(allocator: Allocator, dev_id: u64) !*Job {
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .dev_id = dev_id,
            .ref_count = .init(1),
            .pending = .init(0),
            .seen_hardlinks = std.AutoHashMap(InodeKey, void).init(allocator),
        };
        if (c.pthread_mutex_init(&self.hardlink_mutex, null) != 0) return error.MutexInitFailed;
        return self;
    }

    pub fn ref(self: *Job) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *Job) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            _ = c.pthread_mutex_destroy(&self.hardlink_mutex);
            self.seen_hardlinks.deinit();
            self.allocator.destroy(self);
        }
    }

    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
    }

    pub fn isDone(self: *const Job) bool {
        return self.pending.load(.acquire) == 0;
    }
};

pub const QueueEntry = struct {
    job: *Job,
    dir_fd: c_int,
};

const WorkerContext = struct {
    allocator: Allocator,
    buffers: [64]?[]align(@alignOf(linux.dirent64)) u8 = @splat(null),

    pub fn init(allocator: Allocator) WorkerContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WorkerContext) void {
        for (&self.buffers) |*b| {
            if (b.*) |slice| {
                self.allocator.free(slice);
                b.* = null;
            }
        }
    }

    pub fn getBuffer(self: *WorkerContext, depth: usize) ![]align(@alignOf(linux.dirent64)) u8 {
        if (depth < self.buffers.len) {
            if (self.buffers[depth]) |slice| {
                return slice;
            }
            const slice = try self.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(linux.dirent64)), buffer_size);
            self.buffers[depth] = slice;
            return slice;
        }
        return self.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(linux.dirent64)), buffer_size);
    }

    pub fn releaseBuffer(self: *WorkerContext, depth: usize, buf: []align(@alignOf(linux.dirent64)) u8) void {
        if (depth >= self.buffers.len) {
            self.allocator.free(buf);
        }
    }
};

pub const Pool = struct {
    allocator: Allocator,
    threads: []std.Thread,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    cond_push: c.pthread_cond_t = undefined,
    stop: std.atomic.Value(bool) = .init(false),
    done_fd: c_int = -1,

    queue: [queue_capacity]QueueEntry = undefined,
    queue_head: usize = 0,
    queue_tail: usize = 0,
    queue_count: usize = 0,

    pub fn init(allocator: Allocator) !*Pool {
        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);

        const done_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (done_fd < 0) return error.EventFdFailed;
        errdefer _ = c.close(done_fd);

        self.* = .{
            .allocator = allocator,
            .threads = &.{},
            .done_fd = done_fd,
        };

        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        if (c.pthread_cond_init(&self.cond_push, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond_push);

        const nproc_raw = c.sysconf(c._SC_NPROCESSORS_ONLN);
        const nproc: usize = if (nproc_raw > 0) @intCast(nproc_raw) else 1;
        const thread_count: usize = @min(@max(1, 2 * nproc), 16);

        var spawned: std.ArrayList(std.Thread) = .empty;
        errdefer {
            self.stop.store(true, .release);
            _ = c.pthread_mutex_lock(&self.mutex);
            _ = c.pthread_cond_broadcast(&self.cond);
            _ = c.pthread_mutex_unlock(&self.mutex);
            for (spawned.items) |t| t.join();
            spawned.deinit(allocator);
        }

        for (0..thread_count) |_| {
            const t = try std.Thread.spawn(.{}, workerLoop, .{ self, allocator });
            try spawned.append(allocator, t);
        }

        self.threads = try spawned.toOwnedSlice(allocator);
        return self;
    }

    pub fn deinit(self: *Pool) void {
        self.stop.store(true, .release);
        _ = c.pthread_mutex_lock(&self.mutex);
        _ = c.pthread_cond_broadcast(&self.cond);
        _ = c.pthread_cond_broadcast(&self.cond_push);
        _ = c.pthread_mutex_unlock(&self.mutex);

        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);

        while (self.queue_count > 0) {
            const entry = self.queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % queue_capacity;
            self.queue_count -= 1;
            _ = c.close(entry.dir_fd);
            entry.job.unref();
        }

        _ = c.close(self.done_fd);
        _ = c.pthread_cond_destroy(&self.cond_push);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.allocator.destroy(self);
    }

    pub fn notifyDone(self: *Pool, job: *Job) void {
        _ = job;
        const val: u64 = 1;
        _ = c.write(self.done_fd, &val, @sizeOf(u64));
    }

    pub fn drainDone(self: *Pool) void {
        var val: u64 = undefined;
        _ = c.read(self.done_fd, &val, @sizeOf(u64));
    }

    pub fn tryPush(self: *Pool, job: *Job, dir_fd: c_int) bool {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (self.stop.load(.acquire) or self.queue_count >= queue_capacity) {
            return false;
        }
        self.queue[self.queue_tail] = .{ .job = job, .dir_fd = dir_fd };
        self.queue_tail = (self.queue_tail + 1) % queue_capacity;
        self.queue_count += 1;
        _ = c.pthread_cond_signal(&self.cond);
        return true;
    }

    pub fn startJob(self: *Pool, path: []const u8) !*Job {
        var path_buf: [4096]u8 = undefined;
        const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});

        const root_fd = c.open(path_z, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (root_fd < 0) {
            const err = std.c._errno().*;
            if (err == c.EACCES) {
                const job = try Job.create(self.allocator, 0);
                job.partial.store(true, .release);
                job.pending.store(0, .release);
                self.notifyDone(job);
                return job;
            }
            return switch (err) {
                c.ENOENT => error.FileNotFound,
                c.ENOTDIR => error.NotDirectory,
                else => error.OpenFailed,
            };
        }
        errdefer _ = c.close(root_fd);

        var root_stx: linux.Statx = undefined;
        const stat_rc = linux.statx(
            root_fd,
            "",
            linux.AT.EMPTY_PATH | linux.AT.STATX_DONT_SYNC,
            linux.STATX{ .TYPE = true, .INO = true },
            &root_stx,
        );
        if (linux.errno(stat_rc) != .SUCCESS) {
            return error.StatFailed;
        }
        if ((root_stx.mode & linux.S.IFMT) != linux.S.IFDIR) {
            return error.NotDirectory;
        }

        const dev_id = (@as(u64, root_stx.dev_major) << 32) | root_stx.dev_minor;
        const job = try Job.create(self.allocator, dev_id);
        errdefer job.unref();

        job.pending.store(1, .release);
        job.ref();

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        while (self.queue_count >= queue_capacity and !self.stop.load(.acquire)) {
            _ = c.pthread_cond_wait(&self.cond_push, &self.mutex);
        }
        if (self.stop.load(.acquire)) {
            job.unref();
            return error.PoolStopped;
        }

        self.queue[self.queue_tail] = .{ .job = job, .dir_fd = root_fd };
        self.queue_tail = (self.queue_tail + 1) % queue_capacity;
        self.queue_count += 1;
        _ = c.pthread_cond_signal(&self.cond);

        return job;
    }
};

fn workerLoop(self: *Pool, allocator: Allocator) void {
    var ctx = WorkerContext.init(allocator);
    defer ctx.deinit();

    while (true) {
        var entry: QueueEntry = undefined;
        {
            _ = c.pthread_mutex_lock(&self.mutex);
            while (self.queue_count == 0 and !self.stop.load(.acquire)) {
                _ = c.pthread_cond_wait(&self.cond, &self.mutex);
            }
            if (self.stop.load(.acquire) and self.queue_count == 0) {
                _ = c.pthread_mutex_unlock(&self.mutex);
                return;
            }
            entry = self.queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % queue_capacity;
            self.queue_count -= 1;
            _ = c.pthread_cond_signal(&self.cond_push);
            _ = c.pthread_mutex_unlock(&self.mutex);
        }

        defer {
            _ = c.close(entry.dir_fd);
            if (entry.job.pending.fetchSub(1, .acq_rel) == 1) {
                self.notifyDone(entry.job);
            }
            entry.job.unref();
        }

        if (entry.job.cancelled.load(.acquire)) {
            continue;
        }

        walkDirectory(self, &ctx, entry.job, entry.dir_fd, 0);
    }
}

fn walkDirectory(pool: *Pool, ctx: *WorkerContext, job: *Job, dir_fd: c_int, depth: usize) void {
    const buf = ctx.getBuffer(depth) catch {
        job.partial.store(true, .release);
        return;
    };
    defer ctx.releaseBuffer(depth, buf);

    var local_bytes: i64 = 0;
    var local_files: usize = 0;
    var local_dirs: usize = 0;
    var local_count: usize = 0;

    defer {
        if (local_bytes > 0 or local_files > 0 or local_dirs > 0) {
            _ = job.bytes.fetchAdd(local_bytes, .monotonic);
            _ = job.files.fetchAdd(local_files, .monotonic);
            _ = job.dirs.fetchAdd(local_dirs, .monotonic);
        }
    }

    while (true) {
        if (job.cancelled.load(.acquire)) return;
        const rc = linux.getdents64(dir_fd, buf.ptr, buf.len);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            if (err != .NOENT and err != .BADF) {
                job.partial.store(true, .release);
            }
            return;
        }
        const nread = rc;
        if (nread == 0) return;

        var pos: usize = 0;
        while (pos < nread) {
            if (job.cancelled.load(.acquire)) return;
            const d: *const linux.dirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += d.reclen;

            const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var stx: linux.Statx = undefined;
            const stat_rc = linux.statx(
                dir_fd,
                name_ptr,
                linux.AT.SYMLINK_NOFOLLOW | linux.AT.STATX_DONT_SYNC | linux.AT.NO_AUTOMOUNT,
                linux.STATX{ .SIZE = true, .NLINK = true, .INO = true, .TYPE = true },
                &stx,
            );
            const stat_err = linux.errno(stat_rc);
            if (stat_err != .SUCCESS) {
                job.partial.store(true, .release);
                continue;
            }

            const mode_type = stx.mode & linux.S.IFMT;
            const is_dir = mode_type == linux.S.IFDIR;

            if (is_dir) {
                const raw_attr: u64 = @bitCast(stx.attributes);
                if ((raw_attr & STATX_ATTR_MOUNT_ROOT) != 0) continue;

                const dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
                if (dev != job.dev_id) continue;

                const sub_fd = c.openat(dir_fd, name_ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
                if (sub_fd < 0) {
                    job.partial.store(true, .release);
                    continue;
                }
                local_dirs += 1;

                _ = job.pending.fetchAdd(1, .monotonic);
                job.ref();
                if (!pool.tryPush(job, sub_fd)) {
                    walkDirectory(pool, ctx, job, sub_fd, depth + 1);
                    _ = c.close(sub_fd);
                    if (job.pending.fetchSub(1, .acq_rel) == 1) {
                        pool.notifyDone(job);
                    }
                    job.unref();
                }
            } else {
                const is_reg = mode_type == linux.S.IFREG;
                if (is_reg and stx.nlink > 1) {
                    const dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
                    const key = InodeKey{ .dev = dev, .ino = stx.ino };
                    _ = c.pthread_mutex_lock(&job.hardlink_mutex);
                    const gop = job.seen_hardlinks.getOrPut(key) catch {
                        _ = c.pthread_mutex_unlock(&job.hardlink_mutex);
                        job.partial.store(true, .release);
                        continue;
                    };
                    const already_seen = gop.found_existing;
                    _ = c.pthread_mutex_unlock(&job.hardlink_mutex);

                    if (!already_seen) {
                        local_bytes += @intCast(stx.size);
                        local_files += 1;
                    }
                } else {
                    local_bytes += @intCast(stx.size);
                    local_files += 1;
                }
            }

            local_count += 1;
            if (local_count >= 4096) {
                _ = job.bytes.fetchAdd(local_bytes, .monotonic);
                _ = job.files.fetchAdd(local_files, .monotonic);
                _ = job.dirs.fetchAdd(local_dirs, .monotonic);
                local_bytes = 0;
                local_files = 0;
                local_dirs = 0;
                local_count = 0;
                if (job.cancelled.load(.acquire)) return;
            }
        }
    }
}
