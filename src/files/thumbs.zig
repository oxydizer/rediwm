//! Thumbnails for image files in Files. A small pool of low-priority worker
//! threads decodes what the view asks for, nearest the viewport first; the UI
//! thread reads finished rasters from an LRU after an eventfd wake. Like
//! `dirsize.zig`, the workers never touch Cairo or Wayland, and nothing here
//! polls: with no jobs the threads sleep on a condition variable.
//!
//! Rasters are at most `thumb_decode.box` px on the long edge, premultiplied
//! ARGB32. The cache is keyed by path and checked against the mtime and size
//! the folder listing reported, so an edited file misses and is re-requested.
const std = @import("std");
const c = @import("c.zig").api;
const decode = @import("thumb_decode.zig");

const a = std.heap.c_allocator;

/// Rasters held in memory: roughly 500 thumbnails.
const max_bytes: usize = 32 << 20;
/// Failures hold no pixels but still count, so a huge folder cannot grow it.
const max_entries: usize = 4096;
/// Finished work waiting for the UI thread; workers pause beyond this.
const max_results: usize = 32;
const worker_count = 2;
const worker_nice = 5;

extern fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;

pub const Want = struct {
    path: []const u8,
    mtime: i64,
    bytes: i64,
    is_symlink: bool = false,
};

pub const Thumb = struct {
    pixels: []const u32,
    w: i32,
    h: i32,
};

const Job = struct {
    path: [:0]u8,
    mtime: i64,
    bytes: i64,
    is_symlink: bool,
};

const Result = struct {
    job: Job,
    /// Null when the file could not be thumbnailed.
    decoded: ?decode.Decoded,
};

const Entry = struct {
    /// Null records a failure so it is not retried until the file changes.
    pixels: ?[]u32,
    w: i32,
    h: i32,
    mtime: i64,
    bytes: i64,
    tick: u64,
};

/// What a worker is decoding; `request` skips it.
const Active = struct { path: []const u8, mtime: i64, bytes: i64 };

pub fn pathHash(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, path);
}

pub const Service = struct {
    ctx: decode.Context,
    cache_dir: ?[]u8,

    // UI thread only.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    clock: u64 = 0,
    bytes: usize = 0,

    // Shared, under `mutex`.
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    stopping: bool = false,
    queue: std.ArrayList(Job) = .empty,
    active: [worker_count]?Active = @splat(null),
    results: std.ArrayList(Result) = .empty,

    wake_fd: c_int = -1,
    threads: [worker_count]?std.Thread = @splat(null),

    /// `cache_dir` is the shared thumbnail cache's root (see
    /// `thumb_decode.cacheDir`); null keeps everything in memory.
    pub fn create(cache_dir: ?[]const u8) !*Service {
        return start(cache_dir, worker_count);
    }

    fn start(cache_dir_in: ?[]const u8, workers: usize) !*Service {
        const self = try a.create(Service);
        errdefer a.destroy(self);
        const cache_dir: ?[]u8 = if (cache_dir_in) |dir| try a.dupe(u8, dir) else null;
        errdefer if (cache_dir) |dir| a.free(dir);
        const fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (fd < 0) return error.EventFdFailed;
        errdefer _ = c.close(fd);
        self.* = .{ .ctx = .{ .cache_dir = cache_dir }, .cache_dir = cache_dir, .wake_fd = fd };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        errdefer self.stopWorkers();
        for (0..workers) |i| self.threads[i] = try std.Thread.spawn(.{}, workerLoop, .{ self, i });
        return self;
    }

    fn stopWorkers(self: *Service) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stopping = true;
        _ = c.pthread_cond_broadcast(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
        for (&self.threads) |*thread| {
            if (thread.*) |t| t.join();
            thread.* = null;
        }
    }

    /// Joins the workers: a decode in progress finishes first.
    pub fn deinit(self: *Service) void {
        self.stopWorkers();
        for (self.queue.items) |job| a.free(job.path);
        self.queue.deinit(a);
        for (self.results.items) |result| {
            a.free(result.job.path);
            if (result.decoded) |d| d.deinit();
        }
        self.results.deinit(a);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.pixels) |pixels| a.free(pixels);
            freeKey(entry.key_ptr.*);
        }
        self.entries.deinit(a);
        _ = c.close(self.wake_fd);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        if (self.cache_dir) |dir| a.free(dir);
        a.destroy(self);
    }

    /// Readable when `drain` has something to take.
    pub fn wakeFd(self: *const Service) c_int {
        return self.wake_fd;
    }

    /// The raster for `path` if it was made from a file that still looks like
    /// (`mtime`, `bytes`). Marks it recently used.
    pub fn lookup(self: *Service, path: []const u8, mtime: i64, bytes: i64) ?Thumb {
        const entry = self.entries.getPtr(path) orelse return null;
        if (entry.mtime != mtime or entry.bytes != bytes) return null;
        const pixels = entry.pixels orelse return null;
        self.clock += 1;
        entry.tick = self.clock;
        return .{ .pixels = pixels, .w = entry.w, .h = entry.h };
    }

    /// A decision (raster or failure) already exists for this file state.
    fn resolved(self: *const Service, want: Want) bool {
        const entry = self.entries.get(want.path) orelse return false;
        return entry.mtime == want.mtime and entry.bytes == want.bytes;
    }

    /// Replaces the queue with `wants`, most urgent first. Work already
    /// finished, failed or running is skipped; a job still queued from an
    /// earlier call that is not wanted now is dropped, so scrolling away
    /// cancels it.
    pub fn request(self: *Service, wants: []const Want) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        for (self.queue.items) |job| a.free(job.path);
        self.queue.clearRetainingCapacity();
        for (wants) |want| {
            if (self.resolved(want) or self.inFlight(want)) continue;
            const path = a.dupeZ(u8, want.path) catch continue;
            self.queue.append(a, .{ .path = path, .mtime = want.mtime, .bytes = want.bytes, .is_symlink = want.is_symlink }) catch {
                a.free(path);
                continue;
            };
        }
        if (self.queue.items.len > 0) _ = c.pthread_cond_broadcast(&self.cond);
    }

    fn inFlight(self: *const Service, want: Want) bool {
        for (self.active) |maybe| {
            const active = maybe orelse continue;
            if (active.mtime == want.mtime and active.bytes == want.bytes and std.mem.eql(u8, active.path, want.path)) return true;
        }
        for (self.results.items) |result| {
            if (result.job.mtime == want.mtime and result.job.bytes == want.bytes and std.mem.eql(u8, result.job.path, want.path)) return true;
        }
        return false;
    }

    /// Takes finished work into the cache. Appends the `pathHash` of each
    /// path that gained a raster, so the caller can repaint just those cells.
    pub fn drain(self: *Service, arrived: *std.ArrayList(u64)) void {
        var count: u64 = undefined;
        _ = c.read(self.wake_fd, &count, @sizeOf(u64));
        _ = c.pthread_mutex_lock(&self.mutex);
        var finished = self.results;
        self.results = .empty;
        // Workers may have been waiting for room.
        _ = c.pthread_cond_broadcast(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
        defer finished.deinit(a);
        for (finished.items) |result| {
            // `store` takes the path, so hash it first.
            const hash = pathHash(result.job.path);
            if (self.store(result)) arrived.append(a, hash) catch {};
        }
        self.evict();
    }

    /// Returns whether the entry now has pixels.
    fn store(self: *Service, result: Result) bool {
        const job = result.job;
        const pixels: ?[]u32 = if (result.decoded) |d| d.pixels else null;
        const w: i32 = if (result.decoded) |d| d.w else 0;
        const h: i32 = if (result.decoded) |d| d.h else 0;
        const value: Entry = .{ .pixels = pixels, .w = w, .h = h, .mtime = job.mtime, .bytes = job.bytes, .tick = self.nextTick() };
        if (self.entries.getPtr(job.path)) |existing| {
            if (existing.pixels) |old| {
                self.bytes -= old.len * 4;
                a.free(old);
            }
            existing.* = value;
            // The existing key stays; this path copy is surplus.
            a.free(job.path);
        } else {
            self.entries.put(a, job.path, value) catch {
                if (pixels) |p| a.free(p);
                a.free(job.path);
                return false;
            };
        }
        if (pixels) |p| self.bytes += p.len * 4;
        return pixels != null;
    }

    fn nextTick(self: *Service) u64 {
        self.clock += 1;
        return self.clock;
    }

    /// Drops the least recently used entries until within budget. Linear in
    /// the entry count, which the caps keep to a few thousand at most.
    fn evict(self: *Service) void {
        while (self.bytes > max_bytes or self.entries.count() > max_entries) {
            var oldest: ?[]const u8 = null;
            var oldest_tick: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.tick < oldest_tick) {
                    oldest_tick = entry.value_ptr.tick;
                    oldest = entry.key_ptr.*;
                }
            }
            const key = oldest orelse return;
            const removed = self.entries.fetchRemove(key) orelse return;
            if (removed.value.pixels) |pixels| {
                self.bytes -= pixels.len * 4;
                a.free(pixels);
            }
            freeKey(removed.key);
        }
    }

    fn workerLoop(self: *Service, index: usize) void {
        // Thumbnails are never urgent: yield to the UI and other programs.
        _ = setpriority(0, @intCast(std.os.linux.gettid()), worker_nice);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        while (!self.stopping) {
            if (self.queue.items.len == 0 or self.results.items.len >= max_results) {
                _ = c.pthread_cond_wait(&self.cond, &self.mutex);
                continue;
            }
            const job = self.queue.orderedRemove(0);
            self.active[index] = .{ .path = job.path, .mtime = job.mtime, .bytes = job.bytes };
            _ = c.pthread_mutex_unlock(&self.mutex);

            const outcome = decode.generate(self.ctx, job.path, job.mtime, job.bytes, job.is_symlink);
            // Copies for the cache write, which runs after the UI has its pixels.
            var write: ?Write = null;
            switch (outcome) {
                .ok => |decoded| if (decoded.cacheable and self.ctx.cache_dir != null) {
                    write = Write.copy(job.path, decoded);
                },
                else => {},
            }

            _ = c.pthread_mutex_lock(&self.mutex);
            self.active[index] = null;
            if (self.stopping) {
                discard(job, outcome);
                if (write) |w| w.deinit();
                break;
            }
            switch (outcome) {
                .stale => a.free(job.path),
                .failed => self.publish(.{ .job = job, .decoded = null }),
                .ok => |decoded| self.publish(.{ .job = job, .decoded = decoded }),
            }
            _ = c.pthread_mutex_unlock(&self.mutex);
            if (write) |w| {
                decode.writeShared(self.ctx, w.path, w.decoded);
                w.deinit();
            }
            _ = c.pthread_mutex_lock(&self.mutex);
        }
    }

    fn publish(self: *Service, result: Result) void {
        self.results.append(a, result) catch {
            a.free(result.job.path);
            if (result.decoded) |d| d.deinit();
            return;
        };
        const one: u64 = 1;
        _ = c.write(self.wake_fd, &one, @sizeOf(u64));
    }
};

const Write = struct {
    path: []u8,
    decoded: decode.Decoded,

    fn copy(path: []const u8, decoded: decode.Decoded) ?Write {
        const owned_path = a.dupe(u8, path) catch return null;
        const pixels = a.dupe(u32, decoded.pixels) catch {
            a.free(owned_path);
            return null;
        };
        var own = decoded;
        own.pixels = pixels;
        return .{ .path = owned_path, .decoded = own };
    }

    fn deinit(self: Write) void {
        a.free(self.path);
        self.decoded.deinit();
    }
};

fn discard(job: Job, outcome: decode.Outcome) void {
    a.free(job.path);
    switch (outcome) {
        .ok => |decoded| decoded.deinit(),
        else => {},
    }
}

/// Keys are `dupeZ` allocations: one byte longer than the string.
fn freeKey(key: []const u8) void {
    a.free(@constCast(key.ptr)[0 .. key.len + 1]);
}

// ---- tests --------------------------------------------------------------

fn writeTestPng(path: [:0]const u8, w: i32, h: i32, rgba: [4]f64) !void {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h);
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface);
    defer c.cairo_destroy(cr);
    c.cairo_set_source_rgba(cr, rgba[0], rgba[1], rgba[2], rgba[3]);
    c.cairo_paint(cr);
    try std.testing.expectEqual(@as(c_uint, c.CAIRO_STATUS_SUCCESS), c.cairo_surface_write_to_png(surface, path.ptr));
}

const TestDir = struct {
    path: [:0]u8,

    fn init() !TestDir {
        var template = "/tmp/rediwm-thumbs-XXXXXX".*;
        const made = c.mkdtemp(&template) orelse return error.TmpDirFailed;
        return .{ .path = try std.testing.allocator.dupeZ(u8, std.mem.span(made)) };
    }

    fn file(self: TestDir, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ self.path, name }, 0);
    }

    fn deinit(self: TestDir) void {
        var cmd: [256]u8 = undefined;
        const text = std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{self.path}) catch unreachable;
        _ = c.system(text.ptr);
        std.testing.allocator.free(self.path);
    }
};

fn waitDrain(service: *Service, arrived: *std.ArrayList(u64)) !void {
    var fd = c.struct_pollfd{ .fd = service.wakeFd(), .events = c.POLLIN, .revents = 0 };
    try std.testing.expect(c.poll(&fd, 1, 10_000) > 0);
    service.drain(arrived);
}

fn statOf(path: [:0]const u8) !struct { mtime: i64, bytes: i64 } {
    var st: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.stat(path.ptr, &st));
    return .{ .mtime = st.st_mtim.tv_sec, .bytes = st.st_size };
}

test "service decodes in the background, wakes the UI and caches by file state" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const image = try dir.file("wide.png");
    defer std.testing.allocator.free(image);
    try writeTestPng(image, 400, 200, .{ 1, 0, 0, 1 });
    const st = try statOf(image);

    const service = try Service.create(null);
    defer service.deinit();
    try std.testing.expect(service.lookup(image, st.mtime, st.bytes) == null);

    var arrived: std.ArrayList(u64) = .empty;
    defer arrived.deinit(a);
    service.request(&.{.{ .path = image, .mtime = st.mtime, .bytes = st.bytes }});
    try waitDrain(service, &arrived);
    try std.testing.expectEqual(@as(usize, 1), arrived.items.len);
    try std.testing.expectEqual(pathHash(image), arrived.items[0]);

    const thumb = service.lookup(image, st.mtime, st.bytes) orelse return error.MissingThumb;
    // 400x200 fits a 128 box as 128x64, solid red.
    try std.testing.expectEqual(@as(i32, 128), thumb.w);
    try std.testing.expectEqual(@as(i32, 64), thumb.h);
    try std.testing.expectEqual(@as(u32, 0xffff0000), thumb.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), thumb.pixels[thumb.pixels.len - 1]);
    // A different file state is a miss; an unchanged one is not re-queued.
    try std.testing.expect(service.lookup(image, st.mtime + 1, st.bytes) == null);
    try std.testing.expect(service.resolved(.{ .path = image, .mtime = st.mtime, .bytes = st.bytes }));
    service.request(&.{.{ .path = image, .mtime = st.mtime, .bytes = st.bytes }});
    try std.testing.expectEqual(@as(usize, 0), service.queue.items.len);
}

test "service shares thumbnails through the freedesktop cache" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const image = try dir.file("photo.png");
    defer std.testing.allocator.free(image);
    try writeTestPng(image, 512, 512, .{ 0, 0, 1, 1 });
    const st = try statOf(image);
    const cache = try dir.file("cache");
    defer std.testing.allocator.free(cache);

    var arrived: std.ArrayList(u64) = .empty;
    defer arrived.deinit(a);
    {
        const first = try Service.create(cache);
        defer first.deinit();
        first.request(&.{.{ .path = image, .mtime = st.mtime, .bytes = st.bytes }});
        try waitDrain(first, &arrived);
        try std.testing.expect(first.lookup(image, st.mtime, st.bytes) != null);
    } // deinit joins the worker, so the write-back has finished.

    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(std.testing.allocator);
    try decode.fileUri(&uri, std.testing.allocator, image);
    const entry = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/thumbnails/normal/{s}.png", .{ cache, &decode.uriHash(uri.items) }, 0);
    defer std.testing.allocator.free(entry);
    var entry_stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.stat(entry.ptr, &entry_stat));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), entry_stat.st_mode & 0o777);

    // A second process (or a later visit) reads it back instead of decoding.
    const hit = decode.generate(.{ .cache_dir = cache }, image, st.mtime, st.bytes, false);
    defer switch (hit) {
        .ok => |d| d.deinit(),
        else => {},
    };
    try std.testing.expect(hit == .ok);
    try std.testing.expect(hit.ok.from_shared);
    try std.testing.expectEqual(@as(i32, 128), hit.ok.w);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), hit.ok.pixels[0]);
    // An entry written for an older version of the file is ignored.
    const older: c.struct_timespec = .{ .tv_sec = @intCast(st.mtime - 100), .tv_nsec = 0 };
    try std.testing.expectEqual(@as(c_int, 0), c.utimensat(c.AT_FDCWD, image.ptr, &[2]c.struct_timespec{ older, older }, 0));
    const changed = try statOf(image);
    const stale = decode.generate(.{ .cache_dir = cache }, image, changed.mtime, changed.bytes, false);
    defer switch (stale) {
        .ok => |d| d.deinit(),
        else => {},
    };
    try std.testing.expect(stale == .ok);
    try std.testing.expect(!stale.ok.from_shared);
}

test "service remembers failures and ignores files that changed since listing" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const bad = try dir.file("broken.png");
    defer std.testing.allocator.free(bad);
    const f = c.fopen(bad.ptr, "w") orelse return error.OpenFailed;
    _ = c.fputs("not really a png at all", f);
    _ = c.fclose(f);
    const st = try statOf(bad);

    const service = try Service.create(null);
    defer service.deinit();
    var arrived: std.ArrayList(u64) = .empty;
    defer arrived.deinit(a);
    service.request(&.{.{ .path = bad, .mtime = st.mtime, .bytes = st.bytes }});
    try waitDrain(service, &arrived);
    try std.testing.expectEqual(@as(usize, 0), arrived.items.len);
    try std.testing.expect(service.lookup(bad, st.mtime, st.bytes) == null);
    // Known failure: not queued again until the file changes.
    try std.testing.expect(service.resolved(.{ .path = bad, .mtime = st.mtime, .bytes = st.bytes }));
    service.request(&.{.{ .path = bad, .mtime = st.mtime, .bytes = st.bytes }});
    try std.testing.expectEqual(@as(usize, 0), service.queue.items.len);

    // The listing is out of date: no entry and no wake.
    const other = try dir.file("later.png");
    defer std.testing.allocator.free(other);
    try writeTestPng(other, 300, 300, .{ 0, 1, 0, 1 });
    const other_st = try statOf(other);
    service.request(&.{.{ .path = other, .mtime = other_st.mtime - 5, .bytes = other_st.bytes }});
    var fd = c.struct_pollfd{ .fd = service.wakeFd(), .events = c.POLLIN, .revents = 0 };
    try std.testing.expectEqual(@as(c_int, 0), c.poll(&fd, 1, 300));
    try std.testing.expect(service.entries.get(other) == null);
}

test "a new request replaces queued work and skips what is already running" {
    const service = try Service.start(null, 0);
    defer service.deinit();
    service.request(&.{
        .{ .path = "/x/a.png", .mtime = 1, .bytes = 1 },
        .{ .path = "/x/b.png", .mtime = 1, .bytes = 1 },
        .{ .path = "/x/c.png", .mtime = 1, .bytes = 1 },
    });
    try std.testing.expectEqual(@as(usize, 3), service.queue.items.len);
    service.active[0] = .{ .path = "/x/d.png", .mtime = 1, .bytes = 1 };
    service.request(&.{
        .{ .path = "/x/c.png", .mtime = 1, .bytes = 1 },
        .{ .path = "/x/d.png", .mtime = 1, .bytes = 1 },
        .{ .path = "/x/e.png", .mtime = 1, .bytes = 1 },
    });
    // a and b scrolled away, d is being decoded; the order is the caller's.
    try std.testing.expectEqual(@as(usize, 2), service.queue.items.len);
    try std.testing.expectEqualStrings("/x/c.png", service.queue.items[0].path);
    try std.testing.expectEqualStrings("/x/e.png", service.queue.items[1].path);
    service.active[0] = null;
}

test "least recently used rasters are evicted first" {
    const service = try Service.start(null, 0);
    defer service.deinit();
    const names = [_][]const u8{ "/x/a.png", "/x/b.png", "/x/c.png" };
    for (names) |name| {
        const key = try a.dupeZ(u8, name);
        const pixels = try a.alloc(u32, 4);
        @memset(pixels, 0xff00ff00);
        try service.entries.put(a, key, .{ .pixels = pixels, .w = 2, .h = 2, .mtime = 1, .bytes = 1, .tick = service.nextTick() });
        service.bytes += 16;
    }
    // Touch `a`, so `b` is now the oldest.
    try std.testing.expect(service.lookup("/x/a.png", 1, 1) != null);
    // 40 bytes under the budget, leaving the three small ones 8 bytes over it.
    const big = try a.alloc(u32, (max_bytes - 40) / 4);
    @memset(big, 0);
    try service.entries.put(a, try a.dupeZ(u8, "/x/big.png"), .{ .pixels = big, .w = 1, .h = 1, .mtime = 1, .bytes = 1, .tick = service.nextTick() });
    service.bytes += big.len * 4;
    service.evict();
    try std.testing.expect(service.bytes <= max_bytes);
    try std.testing.expect(service.lookup("/x/b.png", 1, 1) == null);
    for ([_][]const u8{ "/x/a.png", "/x/c.png", "/x/big.png" }) |name| try std.testing.expect(service.lookup(name, 1, 1) != null);
}
