//! Folder sizes for every Files window: one service per process that keeps a
//! tree of the folders it has measured and adds sizes up from it
//! (docs: project plan "folder-size-cache", stage 2).
//!
//! Each node is one directory, keyed by device and inode. A node knows the
//! apparent size of the files directly in it (`own`) and holds, for its whole
//! subtree, the total size, how many directories are still waiting to be
//! read (`pending`) and how many could not be read fully (`unreadable`).
//! Totals are only ever changed by one thread holding the lock, so a parent's
//! total is always its own files plus its children's totals. Work is one
//! directory at a time, so a huge folder cannot hold up the others, and a
//! folder measured as part of its parent is never walked twice.
//!
//! Windows ask by path from the UI thread and never wait: `request` queues
//! work, `lookup` reads what is known. Workers resolve a path to its node
//! (opening it, which may block on a slow disk) and read directories.
//!
//! Nothing here watches the filesystem yet: a measured folder is measured
//! again when a window asks to `revalidate` it and its result is older than
//! `revalidate_after_ms`, keeping its last total (shown as approximate) while
//! the walk runs.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;
const dirwalk = platform.dirwalk;
const worker = @import("sizetree_worker.zig");

pub const revalidate_after_ms: i64 = 120_000;

/// How urgently a folder is wanted. Lower runs first.
pub const Level = enum(u2) {
    /// On screen now.
    visible = 0,
    /// Wanted, but nobody is looking at it.
    background = 1,
};
const level_count = 2;

pub const Status = enum {
    /// Never asked for, or the path could not be opened.
    unknown,
    /// Not measured automatically (a slow, removable or network disk), or
    /// stopped by the user; a click measures it.
    idle,
    /// Being added up for the first time: `bytes` grows.
    measuring,
    /// Being measured again: `bytes` is the previous total.
    revalidating,
    /// Part of it could not be read: `bytes` is a lower bound.
    partial,
    exact,
};

pub const Info = struct {
    bytes: i64 = 0,
    status: Status = .unknown,

    pub fn known(self: Info) bool {
        return switch (self.status) {
            .partial, .exact, .revalidating => true,
            else => false,
        };
    }
};

pub const RequestOptions = struct {
    /// Measure even on a disk that is not measured automatically, and undo a
    /// `stop`. A click on the size does this.
    force: bool = false,
    /// Measure again if the last result is older than `revalidate_after_ms`.
    revalidate: bool = false,
};

pub const Key = struct { dev: u64, ino: u64 };
const Id = u32;
const no_id: Id = std.math.maxInt(Id);
const Ref = struct { id: Id, gen: u32 };

const Node = struct {
    gen: u32 = 0,
    live: bool = false,
    key: Key = .{ .dev = 0, .ino = 0 },
    /// Parent of a live node, or the next free slot after deletion.
    parent: Id = no_id,
    children: std.ArrayList(Id) = .empty,
    /// The base name under a parent; the full path for a root.
    name: []u8 = &.{},
    own: i64 = 0,
    total: i64 = 0,
    /// Directories in the subtree, this one included, waiting to be read.
    pending: u32 = 0,
    /// Directories in the subtree that could not be read fully.
    unreadable: u32 = 0,
    self_pending: bool = false,
    self_unreadable: bool = false,
    /// The subtree has been added up completely at least once.
    complete: bool = false,
    completed_ms: i64 = 0,
    queued: ?Level = null,
    level: Level = .background,
    scanning: bool = false,
    /// A stopped or forgotten path must not schedule this node again.
    paused: bool = false,
    /// Asked for again while a worker was reading it.
    rescan: bool = false,
};

const PathEntry = struct {
    node: ?Ref = null,
    resolving: bool = false,
    /// Not measured automatically: a slow disk, or stopped by the user.
    idle: bool = false,
    /// Stopped by the user; only a forced request starts it again.
    stopped: bool = false,
    /// Nobody looks at it now (`forgetPath`); any request undoes it.
    dropped: bool = false,
    level: Level = .background,
    force: bool = false,
};

const Queue = struct {
    items: std.ArrayList(Ref) = .empty,
    head: usize = 0,

    fn push(self: *Queue, a: Allocator, ref: Ref) !void {
        if (self.head > 1024 and self.head * 2 > self.items.items.len) {
            const rest = self.items.items.len - self.head;
            std.mem.copyForwards(Ref, self.items.items[0..rest], self.items.items[self.head..]);
            self.items.shrinkRetainingCapacity(rest);
            self.head = 0;
        }
        try self.items.append(a, ref);
    }

    fn pop(self: *Queue) ?Ref {
        if (self.head >= self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
            return null;
        }
        const ref = self.items.items[self.head];
        self.head += 1;
        return ref;
    }

    fn deinit(self: *Queue, a: Allocator) void {
        self.items.deinit(a);
    }
};

/// Whether a disk is measured without being asked: a local disk that is
/// neither spinning nor attached over USB. Network and virtual filesystems
/// are not. Overridable for tests.
pub const AutoPolicy = *const fn (dev_major: u32, dev_minor: u32) bool;

pub fn defaultAutoPolicy(dev_major: u32, dev_minor: u32) bool {
    if (builtin.os.tag != .linux) return false;
    const major: u64 = dev_major;
    const minor: u64 = dev_minor;
    // `stat`'s encoding of the device number (glibc `makedev`).
    const st_dev = ((major & 0xfff) << 8) | ((major & ~@as(u64, 0xfff)) << 32) | (minor & 0xff) | ((minor & ~@as(u64, 0xff)) << 12);
    const disk = platform.mounts.diskOf(st_dev) orelse return false;
    return !disk.serial;
}

/// Tree, queue, and scan helpers exposed for the worker and tests are internal.
/// Call them with the service mutex held, or from a test with no workers.
/// The worker entry point and path resolution helpers manage their own
/// locking and must be entered with the mutex unlocked.
pub const Service = struct {
    allocator: Allocator,
    threads: []std.Thread = &.{},
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    stop: bool = false,
    policy: AutoPolicy,
    /// Results older than this are measured again on a `revalidate` request.
    revalidate_ms: i64 = revalidate_after_ms,

    nodes: std.ArrayList(Node) = .empty,
    free_head: Id = no_id,
    by_key: std.AutoHashMapUnmanaged(Key, Id) = .empty,
    paths: std.StringHashMapUnmanaged(PathEntry) = .empty,
    resolve: std.ArrayList([]const u8) = .empty,
    resolve_head: usize = 0,
    /// Give scans the next turn after dispatching a resolution.
    prefer_scan: bool = false,
    queues: [level_count]Queue = .{ .{}, .{} },
    /// Known per device: measured automatically or not.
    auto: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    working: usize = 0,
    /// Nodes whose `queued` is set.
    queued_count: usize = 0,
    /// Changes whenever a total or status may have changed.
    generation: std.atomic.Value(u64) = .init(0),

    pub fn create(allocator: Allocator, threads: usize, policy: AutoPolicy) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .policy = policy };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        var spawned: std.ArrayList(std.Thread) = .empty;
        errdefer {
            self.requestStop();
            for (spawned.items) |t| t.join();
            spawned.deinit(allocator);
        }
        // No threads: nothing is ever measured (tests).
        for (0..threads) |_| try spawned.append(allocator, try std.Thread.spawn(.{}, workerLoop, .{self}));
        self.threads = try spawned.toOwnedSlice(allocator);
        return self;
    }

    /// A sensible worker count: metadata reads gain little past a few.
    pub fn defaultThreads() usize {
        const n = c.sysconf(c._SC_NPROCESSORS_ONLN);
        const count: usize = if (n > 0) @intCast(n) else 1;
        return std.math.clamp(count / 2, 2, 6);
    }

    pub fn requestStop(self: *Service) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stop = true;
        _ = c.pthread_cond_broadcast(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    /// Stops the workers (waiting for each to finish its directory) and frees
    /// everything. Safe from a reaper thread.
    pub fn destroy(self: *Service) void {
        self.requestStop();
        for (self.threads) |t| t.join();
        const a = self.allocator;
        a.free(self.threads);
        for (self.nodes.items) |*node| if (node.live) {
            a.free(node.name);
            node.children.deinit(a);
        };
        self.nodes.deinit(a);
        self.by_key.deinit(a);
        var it = self.paths.keyIterator();
        while (it.next()) |k| a.free(k.*);
        self.paths.deinit(a);
        self.resolve.deinit(a);
        for (&self.queues) |*q| q.deinit(a);
        self.auto.deinit(a);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        a.destroy(self);
    }

    pub fn lock(self: *Service) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }

    pub fn unlock(self: *Service) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    pub fn bump(self: *Service) void {
        _ = self.generation.fetchAdd(1, .release);
    }

    // ---- UI side ----

    /// Asks for the size of the folder at `path` (absolute). Cheap: windows
    /// call it for every folder they paint.
    pub fn request(self: *Service, path: []const u8, level: Level, options: RequestOptions) void {
        self.lock();
        defer self.unlock();
        self.requestLocked(path, level, options) catch {};
    }

    fn requestLocked(self: *Service, path: []const u8, level: Level, options: RequestOptions) !void {
        const a = self.allocator;
        const gop = try self.paths.getOrPut(a, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = a.dupe(u8, path) catch |err| {
                self.paths.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        const entry = gop.value_ptr;
        entry.dropped = false;
        if (entry.stopped and !options.force) return;
        if (options.force) {
            entry.stopped = false;
            entry.idle = false;
            entry.force = true;
        }
        if (@intFromEnum(level) < @intFromEnum(entry.level) or !gop.found_existing) entry.level = level;

        const node_id = if (entry.node) |ref| self.liveId(ref) else null;
        if (node_id == null) {
            entry.node = null;
            if (!entry.resolving) {
                entry.resolving = true;
                try self.resolve.append(a, gop.key_ptr.*);
                _ = c.pthread_cond_signal(&self.cond);
            }
            return;
        }
        if (entry.idle) return;
        const id = node_id.?;
        const node = &self.nodes.items[id];
        if (options.revalidate and node.complete and node.pending == 0 and nowMs() - node.completed_ms >= self.revalidate_ms) {
            try self.markSubtree(id, level);
        } else if (node.pending > 0) {
            try self.enqueueSubtree(id, level);
        }
    }

    /// What is known about `path`. Never blocks on the filesystem.
    pub fn lookup(self: *Service, path: []const u8) Info {
        self.lock();
        defer self.unlock();
        const entry = self.paths.getPtr(path) orelse return .{};
        const id = (if (entry.node) |ref| self.liveId(ref) else null) orelse
            return .{ .status = if (entry.resolving) .measuring else if (entry.idle) .idle else .unknown };
        const node = &self.nodes.items[id];
        if (node.pending > 0) {
            if (entry.idle or entry.stopped)
                return .{ .bytes = node.total, .status = if (node.complete) .revalidating else .idle };
            return .{ .bytes = node.total, .status = if (node.complete) .revalidating else .measuring };
        }
        return .{ .bytes = node.total, .status = if (node.unreadable > 0) .partial else .exact };
    }

    /// The user stopped this folder: its queued directories are dropped, and
    /// it is not measured again until a forced request.
    pub fn stopPath(self: *Service, path: []const u8) void {
        self.lock();
        defer self.unlock();
        const entry = self.paths.getPtr(path) orelse return;
        entry.stopped = true;
        entry.force = false;
        if (entry.node) |ref| if (self.liveId(ref)) |id| self.dequeueSubtree(id);
        self.bump();
    }

    /// Nobody is looking at these folders any more: their queued directories
    /// are dropped. A later request queues them again; what was added up
    /// stays.
    pub fn forgetPath(self: *Service, path: []const u8) void {
        self.lock();
        defer self.unlock();
        const entry = self.paths.getPtr(path) orelse return;
        entry.dropped = true;
        if (entry.node) |ref| if (self.liveId(ref)) |id| self.dequeueSubtree(id);
    }

    /// Whether any directory is waiting or being read.
    pub fn busy(self: *Service) bool {
        self.lock();
        defer self.unlock();
        if (self.working > 0) return true;
        for (self.resolve.items[self.resolve_head..]) |path| {
            const entry = self.paths.getPtr(path) orelse continue;
            if (!entry.stopped and !entry.dropped) return true;
        }
        return self.queued_count > 0;
    }

    // ---- the tree ----

    pub fn liveId(self: *Service, ref: Ref) ?Id {
        if (ref.id >= self.nodes.items.len) return null;
        const node = &self.nodes.items[ref.id];
        return if (node.live and node.gen == ref.gen) ref.id else null;
    }

    pub fn refOf(self: *Service, id: Id) Ref {
        return .{ .id = id, .gen = self.nodes.items[id].gen };
    }

    pub fn newNode(self: *Service, key: Key, name: []const u8, level: Level) !Id {
        const a = self.allocator;
        const owned = try a.dupe(u8, name);
        errdefer a.free(owned);
        try self.by_key.ensureUnusedCapacity(a, 1);
        const id: Id = if (self.free_head != no_id) blk: {
            const reused = self.free_head;
            self.free_head = self.nodes.items[reused].parent;
            break :blk reused;
        } else blk: {
            try self.nodes.append(a, .{});
            break :blk @intCast(self.nodes.items.len - 1);
        };
        const node = &self.nodes.items[id];
        const gen = node.gen +% 1;
        node.* = .{ .gen = gen, .live = true, .key = key, .name = owned, .level = level, .self_pending = true, .pending = 1 };
        self.by_key.putAssumeCapacity(key, id);
        return id;
    }

    /// Adds deltas to `id` and every ancestor, noting subtrees that become
    /// complete.
    fn propagate(self: *Service, start: Id, total: i64, pending: i64, unreadable: i64) void {
        var id = start;
        const now = nowMs();
        while (id != no_id) {
            const node = &self.nodes.items[id];
            node.total += total;
            node.pending = @intCast(@as(i64, node.pending) + pending);
            node.unreadable = @intCast(@as(i64, node.unreadable) + unreadable);
            if (node.pending == 0 and pending < 0) {
                node.complete = true;
                node.completed_ms = now;
            }
            id = node.parent;
        }
    }

    pub fn attach(self: *Service, parent: Id, child: Id) !void {
        try self.nodes.items[parent].children.append(self.allocator, child);
        const node = &self.nodes.items[child];
        node.parent = parent;
        self.propagate(parent, node.total, node.pending, node.unreadable);
    }

    fn detach(self: *Service, child: Id) void {
        const node = &self.nodes.items[child];
        const parent = node.parent;
        if (parent == no_id) return;
        const siblings = &self.nodes.items[parent].children;
        if (std.mem.indexOfScalar(Id, siblings.items, child)) |i| _ = siblings.swapRemove(i);
        node.parent = no_id;
        self.propagate(parent, -node.total, -@as(i64, node.pending), -@as(i64, node.unreadable));
    }

    /// Frees a detached subtree. A worker reading one of its directories
    /// finds the node gone (its generation changed) and drops the result.
    fn freeSubtree(self: *Service, root: Id) void {
        std.debug.assert(self.nodes.items[root].parent == no_id);
        var id = root;
        while (id != no_id) {
            const node = &self.nodes.items[id];
            // Consume each child link on the way down, then free the node
            // and follow its parent link once all its children are gone.
            if (node.children.pop()) |child| {
                id = child;
                continue;
            }
            const parent = node.parent;
            self.freeOne(id);
            id = parent;
        }
    }

    fn freeOne(self: *Service, id: Id) void {
        const node = &self.nodes.items[id];
        if (!node.live) return;
        self.setQueued(node, null);
        _ = self.by_key.remove(node.key);
        self.allocator.free(node.name);
        node.children.deinit(self.allocator);
        const gen = node.gen;
        node.* = .{ .gen = gen +% 1, .parent = self.free_head };
        self.free_head = id;
    }

    fn setQueued(self: *Service, node: *Node, level: ?Level) void {
        if (node.queued == null and level != null) self.queued_count += 1;
        if (node.queued != null and level == null) self.queued_count -= 1;
        node.queued = level;
    }

    pub fn enqueue(self: *Service, id: Id, level: Level) !void {
        const node = &self.nodes.items[id];
        if (node.paused) return;
        if (node.scanning) {
            node.rescan = node.rescan or !node.self_pending;
            if (@intFromEnum(level) < @intFromEnum(node.level)) node.level = level;
            return;
        }
        if (node.queued) |q| if (@intFromEnum(q) <= @intFromEnum(level)) return;
        try self.queues[@intFromEnum(level)].push(self.allocator, self.refOf(id));
        self.setQueued(node, level);
        node.level = level;
        _ = c.pthread_cond_signal(&self.cond);
    }

    /// Queues every directory below `root` still waiting to be read, raising
    /// its level if it was queued lower.
    pub fn enqueueSubtree(self: *Service, root: Id, level: Level) !void {
        var stack: std.ArrayList(Id) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, root);
        while (stack.pop()) |id| {
            const node = &self.nodes.items[id];
            node.paused = false;
            if (node.pending == 0) continue;
            if (@intFromEnum(level) < @intFromEnum(node.level)) node.level = level;
            if (node.self_pending) try self.enqueue(id, level);
            try stack.appendSlice(self.allocator, node.children.items);
        }
    }

    /// Marks every directory below `root` to be read again, keeping totals.
    fn markSubtree(self: *Service, root: Id, level: Level) !void {
        var stack: std.ArrayList(Id) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, root);
        while (stack.pop()) |id| {
            const node = &self.nodes.items[id];
            node.paused = false;
            node.level = level;
            if (!node.self_pending) {
                node.self_pending = true;
                self.propagate(id, 0, 1, 0);
            }
            try self.enqueue(id, level);
            try stack.appendSlice(self.allocator, node.children.items);
        }
        self.bump();
    }

    pub fn dequeueSubtree(self: *Service, root: Id) void {
        var stack: std.ArrayList(Id) = .empty;
        defer stack.deinit(self.allocator);
        stack.append(self.allocator, root) catch return;
        while (stack.pop()) |id| {
            const node = &self.nodes.items[id];
            self.setQueued(node, null);
            node.paused = true;
            node.rescan = false;
            node.level = .background;
            stack.appendSlice(self.allocator, node.children.items) catch return;
        }
    }

    /// The node's path, built from its ancestors' names.
    fn pathOf(self: *Service, id: Id, buf: []u8) ?[:0]const u8 {
        var parts: [256][]const u8 = undefined;
        var count: usize = 0;
        var at = id;
        while (at != no_id) {
            if (count == parts.len) return null;
            parts[count] = self.nodes.items[at].name;
            count += 1;
            at = self.nodes.items[at].parent;
        }
        var len: usize = 0;
        var i = count;
        while (i > 0) {
            i -= 1;
            const part = parts[i];
            const sep: usize = if (i == count - 1 or (len > 0 and buf[len - 1] == '/')) 0 else 1;
            if (len + sep + part.len + 1 > buf.len) return null;
            if (sep == 1) {
                buf[len] = '/';
                len += 1;
            }
            @memcpy(buf[len .. len + part.len], part);
            len += part.len;
        }
        buf[len] = 0;
        return buf[0..len :0];
    }

    // ---- workers ----

    const Work = union(enum) {
        resolve: []u8,
        scan: struct { ref: Ref, key: Key },
    };

    pub fn take(self: *Service, path_buf: []u8) ?struct { work: Work, path: ?[:0]const u8 } {
        while (!self.stop) {
            if (!self.prefer_scan and self.resolve_head < self.resolve.items.len) {
                const key = self.resolve.items[self.resolve_head];
                self.resolve_head += 1;
                if (self.resolve_head == self.resolve.items.len) {
                    self.resolve.clearRetainingCapacity();
                    self.resolve_head = 0;
                }
                if (self.paths.getPtr(key)) |entry| if (entry.stopped or entry.dropped) {
                    // Asked for again later, it is queued again.
                    entry.resolving = false;
                    continue;
                };
                const copy = self.allocator.dupe(u8, key) catch {
                    if (self.paths.getPtr(key)) |entry| entry.resolving = false;
                    continue;
                };
                self.prefer_scan = true;
                return .{ .work = .{ .resolve = copy }, .path = null };
            }
            for (&self.queues, 0..) |*q, level| {
                while (q.pop()) |ref| {
                    const id = self.liveId(ref) orelse continue;
                    const node = &self.nodes.items[id];
                    if (node.queued == null or @intFromEnum(node.queued.?) != level) continue;
                    self.setQueued(node, null);
                    if (node.scanning or !node.self_pending) continue;
                    const path = self.pathOf(id, path_buf) orelse {
                        self.failScan(id);
                        continue;
                    };
                    node.scanning = true;
                    self.prefer_scan = false;
                    return .{ .work = .{ .scan = .{ .ref = ref, .key = node.key } }, .path = path };
                }
            }
            // No eligible scan remains. Allow resolution to proceed
            // without waiting for another worker or request.
            if (self.resolve_head < self.resolve.items.len) {
                self.prefer_scan = false;
                continue;
            }
            _ = c.pthread_cond_wait(&self.cond, &self.mutex);
        }
        return null;
    }

    pub const Child = struct { key: Key, name: []u8 };

    /// The directory is not where its path says: renamed or removed since
    /// its parent was read. Its parent is read again, which renames or drops
    /// it; it stays waiting meanwhile.
    pub fn lostScan(self: *Service, id: Id, path: []const u8) void {
        const node = &self.nodes.items[id];
        node.scanning = false;
        node.rescan = false;
        const parent = node.parent;
        const level = node.level;
        if (parent == no_id) {
            if (self.paths.getPtr(path)) |entry| {
                if (entry.node) |ref| {
                    if (self.liveId(ref) == id) {
                        entry.node = null;
                        if (!entry.stopped and !entry.dropped) {
                            entry.resolving = false;
                            self.requestLocked(path, level, .{}) catch {
                                entry.resolving = false;
                                self.failScan(id);
                                return;
                            };
                        }
                        self.bump();
                        return;
                    }
                }
            }
            return self.failScan(id);
        }
        const up = &self.nodes.items[parent];
        if (up.scanning) {
            up.rescan = true;
        } else {
            if (!up.self_pending) {
                up.self_pending = true;
                self.propagate(parent, 0, 1, 0);
            }
            self.enqueue(parent, level) catch self.failScan(id);
        }
    }

    /// The directory could not be opened: it counts as unreadable and keeps
    /// what was known below it.
    pub fn failScan(self: *Service, id: Id) void {
        const node = &self.nodes.items[id];
        node.scanning = false;
        node.rescan = false;
        const unread_delta: i64 = @as(i64, 1) - @intFromBool(node.self_unreadable);
        node.self_unreadable = true;
        if (node.self_pending) {
            node.self_pending = false;
            self.propagate(id, 0, -1, unread_delta);
        } else self.propagate(id, 0, 0, unread_delta);
        self.bump();
    }

    pub fn finishScan(self: *Service, id: Id, own: i64, found: []const Child, unreadable: bool) !void {
        const node = &self.nodes.items[id];
        node.scanning = false;
        const own_delta = own - node.own;
        node.own = own;
        const unread_delta: i64 = @as(i64, @intFromBool(unreadable)) - @intFromBool(node.self_unreadable);
        node.self_unreadable = unreadable;
        self.propagate(id, own_delta, 0, unread_delta);

        // Children that are gone, or were moved elsewhere.
        var listed: std.AutoHashMapUnmanaged(Key, void) = .empty;
        defer listed.deinit(self.allocator);
        try listed.ensureTotalCapacity(self.allocator, @intCast(found.len));
        for (found) |f| listed.putAssumeCapacity(f.key, {});
        var i: usize = 0;
        while (i < self.nodes.items[id].children.items.len) {
            const child = self.nodes.items[id].children.items[i];
            if (listed.contains(self.nodes.items[child].key)) {
                i += 1;
                continue;
            }
            // A window that asked for it by path finds it again by path.
            self.detach(child);
            self.freeSubtree(child);
        }
        for (found) |f| {
            if (self.by_key.get(f.key)) |existing| {
                const ex = &self.nodes.items[existing];
                if (ex.parent == id) {
                    if (!std.mem.eql(u8, ex.name, f.name)) {
                        const renamed = try self.allocator.dupe(u8, f.name);
                        self.allocator.free(ex.name);
                        self.nodes.items[existing].name = renamed;
                    }
                    // Lost under its old name (`lostScan`): read it now.
                    const child = &self.nodes.items[existing];
                    if (child.self_pending and child.queued == null and !child.scanning) try self.enqueue(existing, self.nodes.items[id].level);
                    continue;
                }
                if (existing == id or self.isAncestor(existing, id)) continue;
                // Moved here from elsewhere, or measured before as a root.
                self.detach(existing);
                const renamed = try self.allocator.dupe(u8, f.name);
                self.allocator.free(self.nodes.items[existing].name);
                self.nodes.items[existing].name = renamed;
                try self.attach(id, existing);
                if (self.nodes.items[id].paused) self.dequeueSubtree(existing);
                continue;
            }
            const child = try self.newNode(f.key, f.name, self.nodes.items[id].level);
            self.nodes.items[child].paused = self.nodes.items[id].paused;
            try self.attach(id, child);
            try self.enqueue(child, self.nodes.items[id].level);
        }

        const after = &self.nodes.items[id];
        after.self_pending = false;
        self.propagate(id, 0, -1, 0);
        if (after.rescan) {
            after.rescan = false;
            after.self_pending = true;
            self.propagate(id, 0, 1, 0);
            try self.enqueue(id, after.level);
        }
        self.bump();
    }

    fn isAncestor(self: *Service, maybe: Id, of: Id) bool {
        var at = self.nodes.items[of].parent;
        while (at != no_id) : (at = self.nodes.items[at].parent) if (at == maybe) return true;
        return false;
    }

    pub const workerLoop = worker.workerLoop;

    pub fn resolvePath(self: *Service, path: []const u8) void {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return self.resolved(path, null, false);
        const fd = c.open(z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return self.resolved(path, null, false);
        defer _ = c.close(fd);
        const info = dirwalk.statFd(fd) orelse return self.resolved(path, null, false);
        if (info.kind != .directory) return self.resolved(path, null, false);
        const key: Key = .{ .dev = info.dev, .ino = info.ino };
        self.lock();
        const known = self.auto.get(key.dev);
        self.unlock();
        const auto = known orelse blk: {
            const allowed = self.policy(@intCast(key.dev >> 32), @truncate(key.dev));
            self.lock();
            self.auto.put(self.allocator, key.dev, allowed) catch {};
            self.unlock();
            break :blk allowed;
        };
        self.resolved(path, key, auto);
    }

    pub fn resolved(self: *Service, path: []const u8, key: ?Key, auto: bool) void {
        self.lock();
        defer self.unlock();
        defer self.bump();
        const entry = self.paths.getPtr(path) orelse return;
        entry.resolving = false;
        const k = key orelse {
            entry.node = null;
            return;
        };
        const id = self.by_key.get(k) orelse (self.newNode(k, path, entry.level) catch return);
        entry.node = self.refOf(id);
        if (entry.stopped or entry.dropped) {
            self.dequeueSubtree(id);
            return;
        }
        if (!auto and !entry.force) {
            entry.idle = true;
            return;
        }
        entry.idle = false;
        self.enqueueSubtree(id, entry.level) catch {};
    }
};

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

test {
    _ = @import("sizetree_internal_tests.zig");
}
