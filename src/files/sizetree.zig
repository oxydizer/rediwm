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
const worker = @import("sizetree_worker.zig");
const schedule = @import("sizetree_schedule.zig");
const reconcile = @import("sizetree_reconcile.zig");
const demand = @import("sizetree_demand.zig");
const resolution = @import("sizetree_resolution.zig");
const eviction = @import("sizetree_eviction.zig");

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
    /// The last total is available while this view has stopped measuring.
    stale,
    /// Part of it could not be read: `bytes` is a lower bound.
    partial,
    exact,
};

pub const Info = struct {
    bytes: i64 = 0,
    status: Status = .unknown,

    pub fn known(self: Info) bool {
        return switch (self.status) {
            .partial, .exact, .revalidating, .stale => true,
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
pub const Id = u32;
pub const no_id: Id = std.math.maxInt(Id);
const Ref = struct { id: Id, gen: u32 };

const Node = struct {
    gen: u32 = 0,
    live: bool = false,
    key: Key = .{ .dev = 0, .ino = 0 },
    /// Parent of a live node, or the next free slot after deletion.
    parent: Id = no_id,
    children: std.ArrayList(Id) = .empty,
    child_index: usize = 0,
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
    queue_prev: Id = no_id,
    queue_next: Id = no_id,
    level: Level = .background,
    scanning: bool = false,
    /// No direct or inherited demand currently covers this node.
    paused: bool = true,
    direct_demand: [2]usize = .{ 0, 0 },
    subtree_demand: usize = 0,
    recency: u64 = 0,
    eviction_index: usize = eviction.not_indexed,
    paths: ?*PathEntry = null,
    path_missing: bool = false,
    waiting_for_parent: bool = false,
    /// Asked for again while a worker was reading it.
    rescan: bool = false,
};

pub const PathEntry = resolution.PathEntry;
pub const Resolution = resolution.Job;
pub const Owner = demand.Owner;

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
    live_node_budget: usize,
    inactive_roots: std.ArrayList(Id) = .empty,
    access_clock: u64 = 0,

    nodes: std.ArrayList(Node) = .empty,
    free_head: Id = no_id,
    by_key: std.AutoHashMapUnmanaged(Key, Id) = .empty,
    paths: std.StringHashMapUnmanaged(*PathEntry) = .empty,
    resolve_ready: [level_count]resolution.Queue = @splat(.{}),
    next_resolution: u64 = 0,
    /// Give scans the next turn after dispatching a resolution.
    prefer_scan: bool = false,
    queues: [level_count]schedule.Queue = .{ .{}, .{} },
    /// Known per device: measured automatically or not.
    auto: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    working: usize = 0,
    /// Nodes whose `queued` is set.
    queued_count: usize = 0,
    /// Changes whenever a total or status may have changed.
    generation: std.atomic.Value(u64) = .init(0),

    pub fn create(allocator: Allocator, threads: usize, policy: AutoPolicy) !*Service {
        return createWithBudget(allocator, threads, policy, eviction.default_live_node_budget);
    }

    /// Soft limit on live directory nodes. Demanded trees may exceed it.
    pub fn createWithBudget(allocator: Allocator, threads: usize, policy: AutoPolicy, live_node_budget: usize) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .policy = policy, .live_node_budget = live_node_budget };
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
        self.inactive_roots.deinit(a);
        self.by_key.deinit(a);
        var it = self.paths.valueIterator();
        while (it.next()) |entry| {
            std.debug.assert(entry.*.owners == 0);
            entry.*.release(a);
        }
        self.paths.deinit(a);
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

    /// The caller owns this registration and releases it before the service.
    pub fn registerOwner(self: *Service) Owner {
        return .{ .service = self };
    }

    pub const request = demand.request;
    pub const requestOwned = demand.requestOwned;
    pub const stopPath = demand.stopPath;
    pub const forgetPath = demand.forgetPath;
    pub const getOrCreatePath = resolution.getOrCreatePath;
    pub const queueResolution = resolution.queue;
    pub const cancelResolution = resolution.cancel;

    pub fn revalidateNode(self: *Service, id: Id) void {
        const node = &self.nodes.items[id];
        if (!node.paused and node.complete and node.pending == 0 and nowMs() - node.completed_ms >= self.revalidate_ms)
            self.markSubtree(id);
    }

    /// Cached information is shared. The requesting view controls its own
    /// running/idle status while another view can continue measuring.
    pub fn lookup(self: *Service, path: []const u8) Info {
        return self.lookupOwned(null, path);
    }

    pub fn lookupOwned(self: *Service, owner: ?*const Owner, path: []const u8) Info {
        self.lock();
        defer self.unlock();
        const entry = self.paths.get(path) orelse return .{};
        const is_stopped = if (owner) |view| demand.stopped(view, entry) else false;
        if (entry.node == no_id) {
            if (is_stopped or !entry.auto_allowed) return .{ .status = .idle };
            return .{ .status = if (entry.resolution != null) .measuring else .unknown };
        }
        eviction.touch(self, entry.node, eviction.nextAccess(self));
        const node = &self.nodes.items[entry.node];
        if (node.pending > 0) {
            const status: Status = if (is_stopped or node.paused)
                (if (node.complete) .stale else .idle)
            else if (node.complete)
                .revalidating
            else
                .measuring;
            return .{ .bytes = node.total, .status = status };
        }
        return .{ .bytes = node.total, .status = if (node.unreadable > 0) .partial else .exact };
    }

    /// Constant-time query under the service mutex for structural roots.
    pub fn rootHasDemand(self: *const Service, root: Id) bool {
        const node = &self.nodes.items[root];
        std.debug.assert(node.live and node.parent == no_id);
        return node.subtree_demand != 0;
    }

    /// The inode index has exactly one entry per live node, including reused slots.
    pub fn liveNodeCount(self: *const Service) usize {
        return self.by_key.count();
    }

    pub const maintainBudget = eviction.maintain;

    /// Whether any directory is waiting or being read.
    pub fn busy(self: *Service) bool {
        self.lock();
        defer self.unlock();
        if (self.working > 0) return true;
        return resolution.hasReady(self) or self.queued_count > 0;
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
        if (self.free_head == no_id) try self.reserveNodeSlots(1);
        const id = self.newNodePrepared(key, owned, level);
        eviction.syncRoot(self, id);
        return id;
    }

    pub fn reserveNodeSlots(self: *Service, extra: usize) !void {
        const slots = self.nodes.items.len + extra;
        // Every slot could become an inactive root. Reserve during fallible
        // preparation so releasing demand and changing topology never allocate.
        try self.inactive_roots.ensureTotalCapacity(self.allocator, slots);
        try self.nodes.ensureTotalCapacity(self.allocator, slots);
    }

    /// Takes ownership of the name after reservation. The caller must attach
    /// the node or register it as a root before running maintenance.
    pub fn newNodePrepared(self: *Service, key: Key, owned: []u8, level: Level) Id {
        const id: Id = if (self.free_head != no_id) blk: {
            const reused = self.free_head;
            self.free_head = self.nodes.items[reused].parent;
            break :blk reused;
        } else blk: {
            self.nodes.appendAssumeCapacity(.{});
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
    pub fn propagate(self: *Service, start: Id, total: i64, pending: i64, unreadable: i64) void {
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
        try self.nodes.items[parent].children.ensureUnusedCapacity(self.allocator, 1);
        self.attachPrepared(parent, child);
    }

    pub fn attachPrepared(self: *Service, parent: Id, child: Id) void {
        const children = &self.nodes.items[parent].children;
        const index = children.items.len;
        children.appendAssumeCapacity(child);
        const node = &self.nodes.items[child];
        std.debug.assert(node.parent == no_id);
        eviction.remove(self, child);
        node.parent = parent;
        node.child_index = index;
        node.path_missing = false;
        self.propagate(parent, node.total, node.pending, node.unreadable);
        demand.adjustAncestors(self, parent, 0, node.subtree_demand);
        // A merged root inherits the most recent access to either tree.
        if (node.recency != 0) eviction.touch(self, parent, node.recency);
        node.recency = 0;
        demand.refresh(self, child);
    }

    pub fn detach(self: *Service, child: Id) void {
        const node = &self.nodes.items[child];
        const parent = node.parent;
        if (parent == no_id) return;
        node.recency = self.nodes.items[eviction.rootOf(self, parent)].recency;
        const siblings = &self.nodes.items[parent].children;
        const index = node.child_index;
        std.debug.assert(siblings.items[index] == child);
        _ = siblings.swapRemove(index);
        if (index < siblings.items.len) self.nodes.items[siblings.items[index]].child_index = index;
        node.parent = no_id;
        self.propagate(parent, -node.total, -@as(i64, node.pending), -@as(i64, node.unreadable));
        demand.adjustAncestors(self, parent, node.subtree_demand, 0);
        eviction.syncRoot(self, child);
    }

    pub const Removal = enum { removed, evicted };

    /// Frees a detached subtree. A worker reading one of its directories
    /// finds the node gone (its generation changed) and drops the result.
    pub fn freeSubtree(self: *Service, root: Id, reason: Removal) void {
        std.debug.assert(self.nodes.items[root].parent == no_id);
        eviction.remove(self, root);
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
            self.freeOne(id, reason);
            id = parent;
        }
    }

    fn freeOne(self: *Service, id: Id, reason: Removal) void {
        const node = &self.nodes.items[id];
        if (!node.live) return;
        self.unqueue(id);
        demand.invalidate(self, id, reason);
        _ = self.by_key.remove(node.key);
        self.allocator.free(node.name);
        node.children.deinit(self.allocator);
        const gen = node.gen;
        node.* = .{ .gen = gen +% 1, .parent = self.free_head };
        self.free_head = id;
    }

    pub const unqueue = schedule.unqueue;
    pub const enqueue = schedule.enqueue;
    const markSubtree = schedule.markSubtree;
    pub const retryScan = schedule.retryScan;

    /// The node's path, built from its ancestors' names.
    fn pathOf(self: *Service, id: Id, buf: []u8) ?[:0]const u8 {
        var parts: [256][]const u8 = undefined;
        var count: usize = 0;
        var at = id;
        while (at != no_id) {
            if (count == parts.len) return null;
            const node = &self.nodes.items[at];
            if (node.path_missing) if (node.paths) |entry| {
                // A path resolved directly after the cached location went
                // missing. Use it until a parent scan repairs the topology.
                parts[count] = entry.path;
                count += 1;
                break;
            };
            parts[count] = node.name;
            count += 1;
            at = node.parent;
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
        resolve: Resolution,
        scan: struct { ref: Ref, key: Key },
    };

    pub fn take(self: *Service, path_buf: []u8) ?struct { work: Work, path: ?[:0]const u8 } {
        while (!self.stop) {
            if (!self.prefer_scan) if (resolution.take(self)) |job| {
                self.prefer_scan = true;
                return .{ .work = .{ .resolve = job }, .path = null };
            };
            for (&self.queues) |*q| {
                while (q.first != no_id) {
                    const id = q.first;
                    const node = &self.nodes.items[id];
                    const ref = self.refOf(id);
                    self.unqueue(id);
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
            if (resolution.hasReady(self)) {
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
        node.waiting_for_parent = false;
        var current_buf: [4096]u8 = undefined;
        if (self.pathOf(id, &current_buf)) |current| {
            if (!std.mem.eql(u8, current, path)) {
                // The cached location changed while the worker was reading.
                self.enqueue(id, node.level);
                return;
            }
        }
        const parent = node.parent;
        const parent_active = demand.effective(self, parent) != null;
        const parent_failed = if (parent_active) blk: {
            const up = self.nodes.items[parent];
            break :blk up.self_unreadable and !up.self_pending and !up.scanning;
        } else false;
        if (!parent_active or parent_failed) {
            node.path_missing = true;
            while (node.paths) |entry| {
                const old = demand.pathLevel(entry);
                demand.unbind(entry, self);
                demand.adjustDirect(self, id, old, null);
                entry.auto_allowed = true;
                if (demand.pathLevel(entry) != null) self.queueResolution(entry);
            }
            if (parent_failed) self.failScan(id) else self.bump();
            return;
        }
        node.waiting_for_parent = true;
        const up = &self.nodes.items[parent];
        if (up.scanning) {
            up.rescan = true;
        } else {
            if (!up.self_pending) {
                up.self_pending = true;
                self.propagate(parent, 0, 1, 0);
            }
            self.enqueue(parent, up.level);
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
        for (node.children.items) |child| {
            const member = &self.nodes.items[child];
            if (!member.waiting_for_parent) continue;
            member.waiting_for_parent = false;
            self.enqueue(child, member.level);
        }
        self.bump();
    }

    pub const finishScan = reconcile.finishScan;

    pub fn isAncestor(self: *Service, maybe: Id, of: Id) bool {
        var at = self.nodes.items[of].parent;
        while (at != no_id) : (at = self.nodes.items[at].parent) if (at == maybe) return true;
        return false;
    }

    pub const workerLoop = worker.workerLoop;

    pub const resolvePath = resolution.resolvePath;
    pub const resolved = resolution.resolved;
};

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

test {
    _ = @import("sizetree_internal_tests.zig");
    _ = @import("sizetree_reconcile_tests.zig");
    _ = @import("sizetree_resolution_tests.zig");
    _ = @import("sizetree_demand_tests.zig");
    _ = @import("sizetree_eviction_tests.zig");
}
