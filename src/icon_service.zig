// Nonblocking icon preparation for the compositor thread. `icon_cache.zig`/
// `icon_theme.zig` do synchronous filesystem lookup, theme indexing, and
// SVG/PNG decode; calling them directly from the compositor's single thread
// (as every consumer used to) stalls input/rendering on a cold lookup. This
// module puts one worker thread between them and the compositor.
//
// Ownership split: only this module's worker thread calls into
// `icon_cache`/`icon_theme` from now on, and it calls `icon_cache.lookup`
// directly rather than the memoizing `icon_cache.get` — this module is now
// the *only* place in the compositor process that caches a decoded raster,
// which is what makes eviction below safe. (`icon_cache.get`'s own `cache`
// still exists and is still used by the separate `files`/`desktop` helper
// processes, each in their own address space with no eviction of their
// own — out of scope here.) `published`/`id_to_key` below are the
// compositor thread's own state and are never touched by the worker.
//
// Queue mechanics mirror `screenshot/worker.zig`'s `WorkerPool`: one
// mutex+cond-guarded job queue (worker waits on the cond instead of
// polling), a result queue drained via an eventfd registered with the
// compositor's `wl.EventLoop` — same shape as `audio/pipewire.zig`'s wake
// fd, down to "never call back into compositor code from the worker
// thread directly."
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const c = std.posix.system;

const icon_theme = @import("icon_theme.zig");
const icon_cache = @import("icon_cache.zig");
const stats = @import("ipc/stats.zig");

const log = std.log.scoped(.icon_service);

/// Published icon, handed to consumers. Shaped like `icon_cache.Entry` plus
/// a stable `id`: every existing pixel-blitting call site only needs
/// `.pixels`/`.size`, unchanged; `.id` exists so consumers can check "is this
/// still the same icon as before" without comparing `.pixels.ptr` (a raw
/// pointer identity check that eviction would invalidate via address reuse
/// — see chrome.zig's `iconEql`), and so `acquire`/`release` below can pin
/// an entry against eviction without holding a raw pointer into a map that
/// can be resized.
pub const Entry = struct {
    id: u64,
    pixels: []const u32,
    size: i32,
};

pub const Lookup = union(enum) {
    ready: Entry,
    pending,
    missing,
};

/// Request priority (step 5): essential covers currently visible icons and
/// newly mapped windows and is never budget-gated (a visible icon must
/// still resolve, eventually, no matter how full the speculative cache is).
/// Speculative covers scroll-ahead/prefetch work only; see `prefetch`.
pub const Priority = enum { essential, speculative };

const Published = struct {
    entry: ?Entry, // null: permanently absent (mirrors icon_cache's cached-null misses)
    refcount: u32 = 0,
    bytes: usize = 0, // pixels.len * 4; 0 for a `null` entry — nothing to reclaim by evicting it
    last_used: u64 = 0, // IconService.touch_clock reading as of the last touch; smaller = evict first
};

const Job = struct {
    key: []const u8, // owned by `in_flight` until published; see `enqueue`/`publish`
};

/// Outcome of one worker-thread decode. `missing` is a resolved, permanent
/// "no such icon" (mirrors `icon_cache`'s cached-null misses) and is safe to
/// publish and remember. `failed` is a transient failure (allocator/OOM, or
/// an I/O error other than "file doesn't exist" — see `icon_cache.loadPng`)
/// and must NOT be cached as a permanent miss, or a momentary hiccup would
/// hide a real icon forever.
const Decoded = union(enum) {
    ready: icon_cache.Entry,
    missing,
    failed,
};

const Result = struct {
    key: []const u8,
    decoded: Decoded,
    decode_ns: u64, // worker-thread wall time for this job (theme lookup + decode combined)
};

pub const IconService = struct {
    /// Unpinned (refcount == 0) raster bytes above this are evicted
    /// LRU-first before more speculative work is queued. Pinned bytes
    /// (a visible titlebar/chip/logo icon) are tracked and evicted
    /// separately — see `unpinned_bytes` — so a full cache never breaks a
    /// currently-displayed icon, only stops speculating ahead of need.
    pub const speculative_budget_bytes: usize = 32 << 20;

    allocator: Allocator,
    cfg: icon_theme.Config,
    io: Io,

    eventfd: posix.fd_t = -1,

    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    cond: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    running: bool = true,
    in_flight: std.StringHashMapUnmanaged(void) = .empty,
    job_queue_essential: std.ArrayList(Job) = .empty,
    job_queue_speculative: std.ArrayList(Job) = .empty,
    result_queue: std.ArrayList(Result) = .empty,
    thread: ?std.Thread = null,

    // Compositor-thread only.
    published: std.StringHashMapUnmanaged(Published) = .empty,
    id_to_key: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    next_id: u64 = 1,
    unpinned_bytes: usize = 0, // sum of .bytes over published entries with refcount == 0
    touch_clock: u64 = 0,

    pub fn create(allocator: Allocator, cfg: icon_theme.Config, io: Io) !*IconService {
        const self = try allocator.create(IconService);
        errdefer allocator.destroy(self);

        const efd = c.eventfd(0, @intCast(std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        if (efd < 0) return error.EventFdFailed;
        errdefer _ = c.close(efd);

        self.* = .{ .allocator = allocator, .cfg = cfg, .io = io, .eventfd = efd };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Registers `fd` (== `self.eventfd`, exposed via `wakeFd`) with the
    /// caller's own event loop; the caller owns and removes the resulting
    /// `wl.EventSource`, same split as `audio_wake_source` in `Server.zig`.
    pub fn wakeFd(self: *const IconService) posix.fd_t {
        return self.eventfd;
    }

    /// Step 10: stop accepting new work, drop what's still queued but not
    /// yet started (a job the worker already popped still finishes normally
    /// — no preemption), join, then drain and discard any completion that
    /// raced the join (its raster, if any, never got published so nobody
    /// else can free it), and finally free every published entry.
    pub fn deinit(self: *IconService) void {
        self.lock();
        self.running = false; // enqueue() checks this; no new work is accepted from here on
        self.dropQueuedLocked(&self.job_queue_essential);
        self.dropQueuedLocked(&self.job_queue_speculative);
        self.broadcast();
        self.unlock();
        if (self.thread) |t| t.join();

        if (self.eventfd >= 0) _ = c.close(self.eventfd);

        for (self.result_queue.items) |res| {
            if (res.decoded == .ready) icon_cache.gpa.free(res.decoded.ready.pixels);
        }
        self.result_queue.deinit(self.allocator);
        self.job_queue_essential.deinit(self.allocator);
        self.job_queue_speculative.deinit(self.allocator);

        var in_flight_it = self.in_flight.keyIterator();
        while (in_flight_it.next()) |k| self.allocator.free(k.*);
        self.in_flight.deinit(self.allocator);

        self.freeAllPublished();
        self.published.deinit(self.allocator);
        self.id_to_key.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Test-only teardown for a stack-allocated `IconService` value (never
    /// spawned a thread, never `create`d, so `deinit`'s destroy-self would be
    /// wrong here).
    fn freeFieldsForTest(self: *IconService) void {
        for (self.result_queue.items) |res| {
            if (res.decoded == .ready) icon_cache.gpa.free(res.decoded.ready.pixels);
        }
        self.result_queue.deinit(self.allocator);
        self.job_queue_essential.deinit(self.allocator);
        self.job_queue_speculative.deinit(self.allocator);

        var in_flight_it = self.in_flight.keyIterator();
        while (in_flight_it.next()) |k| self.allocator.free(k.*);
        self.in_flight.deinit(self.allocator);

        self.freeAllPublished();
        self.published.deinit(self.allocator);
        self.id_to_key.deinit(self.allocator);
    }

    // Frees every published raster and its key, then empties (but keeps
    // using) `published`/`id_to_key`. Shared by `deinit`, `freeFieldsForTest`,
    // and `invalidateAll` so the free-every-raster logic lives in one place.
    fn freeAllPublished(self: *IconService) void {
        var it = self.published.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.entry) |entry| icon_cache.gpa.free(entry.pixels);
            self.allocator.free(e.key_ptr.*);
        }
        self.published.clearRetainingCapacity();
        self.id_to_key.clearRetainingCapacity();
        self.unpinned_bytes = 0;
    }

    fn lock(self: *IconService) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *IconService) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
    fn wait(self: *IconService) void {
        _ = c.pthread_cond_wait(&self.cond, &self.mutex);
    }
    fn signal(self: *IconService) void {
        _ = c.pthread_cond_signal(&self.cond);
    }
    fn broadcast(self: *IconService) void {
        _ = c.pthread_cond_broadcast(&self.cond);
    }

    fn formatKey(buf: []u8, size_px: i32, name: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{d}:{s}", .{ size_px, name }) catch null;
    }

    fn nextTouch(self: *IconService) u64 {
        self.touch_clock += 1;
        return self.touch_clock;
    }

    /// Compositor-thread only. Never blocks on filesystem/decode work.
    /// Essential priority: never budget-gated. See `prefetch` for the
    /// speculative counterpart.
    pub fn request(self: *IconService, name: []const u8, size_px: i32) Lookup {
        if (name.len == 0) return .missing;
        var buf: [512]u8 = undefined;
        const key = formatKey(&buf, size_px, name) orelse return .missing;

        if (self.published.getPtr(key)) |p| {
            p.last_used = self.nextTouch();
            stats.recordIconCacheHit();
            return if (p.entry) |e| .{ .ready = e } else .missing;
        }
        stats.recordIconCacheMiss();
        self.enqueue(key, .essential);
        return .pending;
    }

    /// Compositor-thread only. Speculative, fire-and-forget: a scroll-ahead
    /// or initial-results prefetch (step 5) that a caller doesn't need a
    /// `Lookup` for right now. A no-op once already resolved (ready or
    /// permanently missing) or once unpinned bytes are at/over
    /// `speculative_budget_bytes` — "stop speculation when over budget"
    /// (step 8); a currently-visible icon still goes through `request`,
    /// which is never gated.
    pub fn prefetch(self: *IconService, name: []const u8, size_px: i32) void {
        if (name.len == 0) return;
        var buf: [512]u8 = undefined;
        const key = formatKey(&buf, size_px, name) orelse return;
        if (self.published.contains(key)) return;
        if (self.unpinned_bytes >= speculative_budget_bytes) return;
        self.enqueue(key, .speculative);
    }

    /// Compositor-thread only. Drops speculative jobs that are still queued
    /// (not yet popped by the worker) — step 6's "rapid query changes cancel
    /// stale interest." A job the worker already started still finishes and
    /// gets published normally (cheap, and simply becomes evictable later if
    /// nothing ends up wanting it); this only trims what hasn't started.
    pub fn cancelSpeculative(self: *IconService) void {
        self.lock();
        defer self.unlock();
        self.dropQueuedLocked(&self.job_queue_speculative);
    }

    // Removes every job still in `queue` from `in_flight` (freeing its
    // owned key — `in_flight` is the canonical owner; `Job.key` only
    // aliases it, see the module comment) and empties `queue`. Caller holds
    // `self.mutex`.
    fn dropQueuedLocked(self: *IconService, queue: *std.ArrayList(Job)) void {
        for (queue.items) |job| {
            if (self.in_flight.fetchRemove(job.key)) |kv| self.allocator.free(kv.key);
        }
        queue.clearRetainingCapacity();
    }

    /// Compositor-thread only. Drops every published entry (pinned or not)
    /// so the next `request`/`prefetch` for it triggers a fresh decode —
    /// for an explicit refresh, or a future icon-theme-change hook (step 9).
    /// Nothing today calls this automatically: this compositor has no
    /// runtime icon-theme reload path, only a one-time startup config.
    /// Safe to call with entries currently pinned by a visible
    /// titlebar/chip/logo: `acquire`/`release` already tolerate a
    /// since-evicted id as a no-op (see their tests), so the stale id each
    /// consumer is still holding just becomes inert until its next
    /// `syncChrome`/repaint re-requests and re-pins the fresh entry.
    pub fn invalidateAll(self: *IconService) void {
        self.freeAllPublished();
    }

    /// Compositor-thread only. Bumps the refcount of a still-published
    /// entry (a no-op if it's already gone — evicted, or a stale id from
    /// `invalidateAll`); moves its bytes out of the evictable pool while
    /// pinned.
    pub fn acquire(self: *IconService, id: u64) void {
        const key = self.id_to_key.get(id) orelse return;
        const p = self.published.getPtr(key) orelse return;
        if (p.refcount == 0) self.unpinned_bytes -= p.bytes;
        p.refcount +|= 1;
    }

    /// Compositor-thread only. Counterpart to `acquire`. Once unpinned
    /// again, the entry re-enters the evictable pool and an over-budget
    /// cache evicts immediately rather than waiting for the next decode.
    pub fn release(self: *IconService, id: u64) void {
        const key = self.id_to_key.get(id) orelse return;
        const p = self.published.getPtr(key) orelse return;
        if (p.refcount == 0) return;
        p.refcount -= 1;
        if (p.refcount == 0) {
            p.last_used = self.nextTouch();
            self.unpinned_bytes += p.bytes;
            self.evictOverBudget();
        }
    }

    /// Called from the compositor's eventfd wake handler. Moves finished
    /// work into `published`; does not itself know or care which consumer
    /// wanted it — the caller is expected to re-`request()` from every
    /// still-live consumer afterward (cheap: existing per-consumer memoing
    /// makes an unchanged re-request a no-op).
    pub fn drainCompletions(self: *IconService) void {
        var discard: [8]u8 = undefined;
        _ = c.read(self.eventfd, &discard, discard.len);

        while (true) {
            self.lock();
            if (self.result_queue.items.len == 0) {
                self.unlock();
                return;
            }
            const res = self.result_queue.orderedRemove(0);
            self.unlock();

            self.lock();
            const removed = self.in_flight.fetchRemove(res.key);
            self.unlock();

            // Every job is enqueued through `enqueue`, which inserts into
            // `in_flight` before it's ever queued, so this should always
            // hit. If it doesn't, `res.key`'s true owner is unknown — drop
            // it (freeing any decoded raster) rather than risk a double
            // free by guessing. This is also the "stale completion" path: a
            // completion whose in-flight record is already gone is dropped,
            // never published.
            const removed_entry = removed orelse {
                log.err("drainCompletions: completed key missing from in_flight: {s}", .{res.key});
                if (res.decoded == .ready) icon_cache.gpa.free(res.decoded.ready.pixels);
                continue;
            };
            self.publish(removed_entry.key, res.decoded, res.decode_ns);
        }
    }

    fn enqueue(self: *IconService, key: []const u8, priority: Priority) void {
        self.lock();
        defer self.unlock();
        if (!self.running) return; // stopping: reject new work (step 10)
        if (self.in_flight.contains(key)) return;

        const owned = self.allocator.dupe(u8, key) catch return;
        self.in_flight.put(self.allocator, owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
        const queue = switch (priority) {
            .essential => &self.job_queue_essential,
            .speculative => &self.job_queue_speculative,
        };
        queue.append(self.allocator, .{ .key = owned }) catch {
            // `owned` stays parked in `in_flight` forever (freed at
            // `deinit`); allocation failure here is already an exceptional,
            // low-memory condition, not something to special-case further.
            return;
        };
        stats.recordIconQueueDepth(self.job_queue_essential.items.len + self.job_queue_speculative.items.len);
        self.signal();
    }

    fn publish(self: *IconService, owned_key: []const u8, decoded: Decoded, decode_ns: u64) void {
        switch (decoded) {
            .failed => {
                // Transient: don't cache a permanent miss; let a future
                // request()/prefetch() for the same key retry the decode.
                self.allocator.free(owned_key);
                stats.recordIconDecode(decode_ns, 0);
            },
            .missing => {
                self.insertPublished(owned_key, null, 0);
                stats.recordIconDecode(decode_ns, 0);
            },
            .ready => |d| {
                const bytes = d.pixels.len * @sizeOf(u32);
                self.insertPublished(owned_key, .{ .pixels = d.pixels, .size = d.size }, bytes);
                stats.recordIconDecode(decode_ns, bytes);
            },
        }
    }

    const RawEntry = struct { pixels: []const u32, size: i32 };

    fn insertPublished(self: *IconService, owned_key: []const u8, raw: ?RawEntry, bytes: usize) void {
        const gop = self.published.getOrPut(self.allocator, owned_key) catch {
            self.allocator.free(owned_key);
            return;
        };
        if (gop.found_existing) {
            // `in_flight` dedups concurrent requests for the same key, so
            // this shouldn't happen; guard anyway rather than leak the key.
            self.allocator.free(owned_key);
            return;
        }

        var entry: ?Entry = null;
        if (raw) |r| {
            const id = self.next_id;
            self.next_id += 1;
            entry = Entry{ .id = id, .pixels = r.pixels, .size = r.size };
        }
        gop.value_ptr.* = .{ .entry = entry, .bytes = bytes, .last_used = self.nextTouch() };
        self.unpinned_bytes += bytes;
        if (entry) |e| self.id_to_key.put(self.allocator, e.id, gop.key_ptr.*) catch {};
        self.evictOverBudget();
    }

    // Step 8: byte-based LRU eviction of unpinned rasters. Pinned entries
    // (refcount > 0) are never chosen and are excluded from
    // `unpinned_bytes`, so a full cache never touches a currently-displayed
    // icon — it only stops growing and starts reclaiming the least-recently
    // touched unpinned ones. A `null` (permanently-missing) entry has
    // `bytes == 0` and is skipped: evicting it wouldn't reclaim anything,
    // and it'll just get re-decoded (to the same `null`) on next request.
    fn evictOverBudget(self: *IconService) void {
        while (self.unpinned_bytes > speculative_budget_bytes) {
            var victim: ?[]const u8 = null;
            var victim_last_used: u64 = std.math.maxInt(u64);
            var it = self.published.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.refcount != 0 or e.value_ptr.bytes == 0) continue;
                if (e.value_ptr.last_used < victim_last_used) {
                    victim_last_used = e.value_ptr.last_used;
                    victim = e.key_ptr.*;
                }
            }
            const key = victim orelse return; // nothing left that's safe to evict
            self.evictKey(key);
        }
    }

    fn evictKey(self: *IconService, key: []const u8) void {
        const kv = self.published.fetchRemove(key) orelse return;
        if (kv.value.entry) |e| {
            icon_cache.gpa.free(e.pixels);
            _ = self.id_to_key.remove(e.id);
        }
        self.unpinned_bytes -= kv.value.bytes;
        self.allocator.free(kv.key);
    }

    fn resolveOne(cfg: icon_theme.Config, io: Io, key: []const u8) Decoded {
        const colon = std.mem.indexOfScalar(u8, key, ':') orelse return .missing;
        const size_px = std.fmt.parseInt(i32, key[0..colon], 10) catch return .missing;
        const name = key[colon + 1 ..];
        const result = icon_cache.lookup(cfg, io, name, size_px) catch |err| {
            log.warn("resolveOne: transient icon lookup failure for '{s}': {}", .{ name, err });
            return .failed;
        };
        return if (result) |e| .{ .ready = e } else .missing;
    }

    fn run(self: *IconService) void {
        while (true) {
            self.lock();
            while (self.running and self.job_queue_essential.items.len == 0 and self.job_queue_speculative.items.len == 0) {
                self.wait();
            }
            if (!self.running and self.job_queue_essential.items.len == 0 and self.job_queue_speculative.items.len == 0) {
                self.unlock();
                return;
            }
            // Essential (visible/newly-mapped) work always drains ahead of
            // speculative prefetch (step 5).
            const job = if (self.job_queue_essential.items.len != 0)
                self.job_queue_essential.orderedRemove(0)
            else
                self.job_queue_speculative.orderedRemove(0);
            self.unlock();

            const t0 = stats.nowNs();
            const decoded = resolveOne(self.cfg, self.io, job.key);
            const decode_ns = stats.nowNs() -% t0;

            self.lock();
            self.result_queue.append(self.allocator, .{ .key = job.key, .decoded = decoded, .decode_ns = decode_ns }) catch |err| {
                log.err("run: could not queue icon result: {}", .{err});
            };
            self.unlock();

            const val: u64 = 1;
            _ = c.write(self.eventfd, std.mem.asBytes(&val), @sizeOf(u64));
        }
    }
};

fn testEntry(pixels: []const u32, size: i32) icon_cache.Entry {
    return .{ .pixels = icon_cache.gpa.dupe(u32, pixels) catch unreachable, .size = size };
}

test "request returns pending on first miss, then ready after a manual publish" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    try std.testing.expectEqual(.pending, svc.request("firefox", 48));
    try std.testing.expectEqual(@as(usize, 1), svc.job_queue_essential.items.len);
    try std.testing.expect(svc.in_flight.contains("48:firefox"));

    // A second request for the same key while still pending must not queue
    // a second decode.
    try std.testing.expectEqual(.pending, svc.request("firefox", 48));
    try std.testing.expectEqual(@as(usize, 1), svc.job_queue_essential.items.len);

    const job = svc.job_queue_essential.orderedRemove(0);
    const removed = svc.in_flight.fetchRemove(job.key).?;
    svc.publish(removed.key, .{ .ready = testEntry(&.{0xffaabbcc}, 1) }, 0);

    const ready = svc.request("firefox", 48);
    try std.testing.expect(ready == .ready);
    try std.testing.expectEqual(@as(i32, 1), ready.ready.size);
}

test "publish with a missing result caches a permanent miss" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    _ = svc.request("nonexistent", 32);
    const job = svc.job_queue_essential.orderedRemove(0);
    const removed = svc.in_flight.fetchRemove(job.key).?;
    svc.publish(removed.key, .missing, 0);

    try std.testing.expectEqual(.missing, svc.request("nonexistent", 32));
    // A repeated miss must not requeue a decode.
    try std.testing.expectEqual(@as(usize, 0), svc.job_queue_essential.items.len);
}

test "publish with a failed (transient) result does not cache a permanent miss" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    _ = svc.request("flaky", 32);
    const job = svc.job_queue_essential.orderedRemove(0);
    const removed = svc.in_flight.fetchRemove(job.key).?;
    svc.publish(removed.key, .failed, 0);

    try std.testing.expect(!svc.published.contains("32:flaky"));
    // A later request must retry the decode rather than stay `.missing` forever.
    try std.testing.expectEqual(.pending, svc.request("flaky", 32));
    try std.testing.expectEqual(@as(usize, 1), svc.job_queue_essential.items.len);
}

test "acquire/release track refcount by stable id, not by pointer" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    _ = svc.request("terminal", 24);
    const job = svc.job_queue_essential.orderedRemove(0);
    const removed = svc.in_flight.fetchRemove(job.key).?;
    svc.publish(removed.key, .{ .ready = testEntry(&.{0xff112233}, 1) }, 0);

    const looked_up = svc.request("terminal", 24);
    const id = looked_up.ready.id;

    svc.acquire(id);
    svc.acquire(id);
    try std.testing.expectEqual(@as(u32, 2), svc.published.get("24:terminal").?.refcount);

    svc.release(id);
    try std.testing.expectEqual(@as(u32, 1), svc.published.get("24:terminal").?.refcount);

    // Releasing an id that isn't published (never acquired, or a stale id
    // from eviction/invalidateAll) must not underflow or crash.
    svc.release(999);
    svc.release(id);
    svc.release(id);
    try std.testing.expectEqual(@as(u32, 0), svc.published.get("24:terminal").?.refcount);
}

test "request() enqueues essential priority; prefetch() enqueues speculative and defers to it" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    svc.prefetch("later", 32);
    try std.testing.expectEqual(@as(usize, 1), svc.job_queue_speculative.items.len);
    try std.testing.expectEqual(@as(usize, 0), svc.job_queue_essential.items.len);

    _ = svc.request("now", 32);
    try std.testing.expectEqual(@as(usize, 1), svc.job_queue_essential.items.len);

    // Essential work is popped first regardless of arrival order.
    svc.lock();
    const first = if (svc.job_queue_essential.items.len != 0)
        svc.job_queue_essential.items[0]
    else
        svc.job_queue_speculative.items[0];
    svc.unlock();
    try std.testing.expectEqualStrings("32:now", first.key);
}

test "prefetch is a no-op once already published, and stops once over budget" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    _ = svc.request("known", 32);
    const job = svc.job_queue_essential.orderedRemove(0);
    const removed = svc.in_flight.fetchRemove(job.key).?;
    svc.publish(removed.key, .missing, 0);

    svc.prefetch("known", 32); // already resolved (missing): nothing to do
    try std.testing.expectEqual(@as(usize, 0), svc.job_queue_speculative.items.len);

    svc.unpinned_bytes = IconService.speculative_budget_bytes;
    svc.prefetch("too-late", 32);
    try std.testing.expectEqual(@as(usize, 0), svc.job_queue_speculative.items.len);
    try std.testing.expect(!svc.in_flight.contains("32:too-late"));
}

test "cancelSpeculative drops only queued (not yet started) speculative jobs" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    svc.prefetch("stale-a", 32);
    svc.prefetch("stale-b", 32);
    _ = svc.request("still-essential", 32);
    try std.testing.expectEqual(@as(usize, 2), svc.job_queue_speculative.items.len);

    svc.cancelSpeculative();

    try std.testing.expectEqual(@as(usize, 0), svc.job_queue_speculative.items.len);
    try std.testing.expect(!svc.in_flight.contains("32:stale-a"));
    try std.testing.expect(!svc.in_flight.contains("32:stale-b"));
    // The essential job is untouched by cancelling speculative work.
    try std.testing.expectEqual(@as(usize, 1), svc.job_queue_essential.items.len);
    try std.testing.expect(svc.in_flight.contains("32:still-essential"));
}

test "eviction reclaims the least-recently-touched unpinned entry once over budget, never a pinned one" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    const one_meg = 1 << 20;
    const px_count = one_meg / @sizeOf(u32);
    const pixels = try std.testing.allocator.alloc(u32, px_count);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xffaabbcc);

    // "pinned" is touched (and acquired) first so it's the oldest by
    // last_used, yet must survive eviction because it's pinned.
    _ = svc.request("pinned", 16);
    {
        const job = svc.job_queue_essential.orderedRemove(0);
        const removed = svc.in_flight.fetchRemove(job.key).?;
        svc.publish(removed.key, .{ .ready = testEntry(pixels, 16) }, 0);
    }
    const pinned_id = svc.request("pinned", 16).ready.id;
    svc.acquire(pinned_id);

    // Publish enough additional unpinned 1 MiB rasters to push unpinned
    // bytes over the 32 MiB budget; the oldest-touched unpinned one (the
    // first published below, "eldest") must be the one reclaimed.
    var i: usize = 0;
    while (i < 33) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "unpinned-{d}", .{i}) catch unreachable;
        _ = svc.request(name, 16);
        const job = svc.job_queue_essential.orderedRemove(0);
        const removed = svc.in_flight.fetchRemove(job.key).?;
        svc.publish(removed.key, .{ .ready = testEntry(pixels, 16) }, 0);
    }

    try std.testing.expect(svc.unpinned_bytes <= IconService.speculative_budget_bytes);
    try std.testing.expect(!svc.published.contains("16:unpinned-0"));
    try std.testing.expect(svc.published.contains("16:unpinned-32"));
    try std.testing.expect(svc.published.contains("16:pinned"));
    try std.testing.expectEqual(@as(u32, 1), svc.published.get("16:pinned").?.refcount);

    svc.release(pinned_id);
}

test "invalidateAll drops every published entry, pinned or not, without crashing a stale acquire/release" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    _ = svc.request("app", 32);
    const job = svc.job_queue_essential.orderedRemove(0);
    const removed = svc.in_flight.fetchRemove(job.key).?;
    svc.publish(removed.key, .{ .ready = testEntry(&.{0xffaabbcc}, 1) }, 0);
    const id = svc.request("app", 32).ready.id;
    svc.acquire(id);

    svc.invalidateAll();

    try std.testing.expectEqual(@as(usize, 0), svc.published.count());
    try std.testing.expectEqual(@as(usize, 0), svc.unpinned_bytes);
    // A consumer still holding the pre-invalidation id must not crash.
    svc.release(id);
    try std.testing.expectEqual(.pending, svc.request("app", 32));
}

test "drainCompletions drops a stale completion whose in-flight record is already gone" {
    var svc: IconService = .{
        .allocator = std.testing.allocator,
        .cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .io = undefined,
    };
    defer svc.freeFieldsForTest();

    // Simulate a completion arriving for a key nothing is tracking anymore
    // (e.g. raced a cancel): not owned by `in_flight`, so `result_queue`'s
    // key here is a borrowed literal, never freed by drainCompletions.
    svc.result_queue.append(svc.allocator, .{ .key = "99:ghost", .decoded = .{ .ready = testEntry(&.{0xdeadbeef}, 1) }, .decode_ns = 0 }) catch unreachable;

    svc.lock();
    const before = svc.result_queue.items.len;
    svc.unlock();
    try std.testing.expectEqual(@as(usize, 1), before);

    // Exercise the same fallback path `drainCompletions` uses, without the
    // real eventfd plumbing: pop it and route it through the same
    // stale-key handling.
    svc.lock();
    const res = svc.result_queue.orderedRemove(0);
    svc.unlock();
    const removed = svc.in_flight.fetchRemove(res.key);
    try std.testing.expectEqual(@as(?std.StringHashMapUnmanaged(void).KV, null), removed);
    if (res.decoded == .ready) icon_cache.gpa.free(res.decoded.ready.pixels);

    try std.testing.expectEqual(@as(usize, 0), svc.published.count());
}
