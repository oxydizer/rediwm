//! Path bindings and the allocation-free ready queue for path resolution.
const std = @import("std");
const c = @import("c.zig").api;
const platform = @import("platform");
const dirwalk = platform.dirwalk;
const tree = @import("sizetree.zig");
const demand = @import("sizetree_demand.zig");
const eviction = @import("sizetree_eviction.zig");
const lru = @import("sizetree_lru.zig");
const path_cache = @import("sizetree_path_cache.zig");
const Service = tree.Service;
const Key = tree.Key;
const no_id = tree.no_id;

/// A collision only drops a memoized answer. A miss runs the same policy
/// callback as before, outside the service mutex.
pub const DevicePolicyCache = struct {
    pub const capacity = 256;
    pub const Identity = struct {
        dev: u64,
        mount_id: ?u64,

        fn cacheable(self: Identity) bool {
            // A legacy anonymous device lookup can match the wrong mount.
            return self.mount_id != null or self.dev >> 32 != 0;
        }

        fn index(self: Identity) usize {
            return @intCast((std.hash.int(self.dev) ^ std.hash.int(self.mount_id orelse 0)) % capacity);
        }
    };
    const Slot = struct { identity: Identity, allowed: bool };
    slots: [capacity]?Slot = @splat(null),

    pub fn get(self: *const DevicePolicyCache, identity: Identity) ?bool {
        if (!identity.cacheable()) return null;
        const slot = self.slots[identity.index()] orelse return null;
        return if (slot.identity.dev == identity.dev and slot.identity.mount_id == identity.mount_id) slot.allowed else null;
    }

    pub fn put(self: *DevicePolicyCache, identity: Identity, result: ?bool) void {
        const allowed = result orelse return;
        if (!identity.cacheable()) return;
        self.slots[identity.index()] = .{ .identity = identity, .allowed = allowed };
    }
};

pub const PathEntry = struct {
    path: []u8,
    // The map holds one reference. Dispatched jobs pin their path separately.
    refs: std.atomic.Value(usize) = .init(1),
    // Owner records and node bindings borrow the map's reference. Eviction
    // requires zero owners and unlinks the binding before dropping that pin.
    owners: usize = 0,
    node: tree.Id = no_id,
    expected_key: ?Key = null,
    bound_prev: ?*PathEntry = null,
    bound_next: ?*PathEntry = null,
    automatic: [2]usize = .{ 0, 0 },
    explicit: [2]usize = .{ 0, 0 },
    automatic_revalidate_demand: usize = 0,
    explicit_revalidate_demand: usize = 0,
    auto_allowed: bool = true,
    access_stamp: u64 = 0,
    eviction_index: usize = lru.not_indexed,
    resolution: ?u64 = null,
    queued: ?tree.Level = null,
    prev: ?*PathEntry = null,
    next: ?*PathEntry = null,

    pub fn release(self: *PathEntry, a: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        a.free(self.path);
        a.destroy(self);
    }
};

pub const Job = struct {
    entry: *PathEntry,
    path: []const u8,
    id: u64,

    pub fn deinit(self: Job, a: std.mem.Allocator) void {
        self.entry.release(a);
    }
};

pub fn getOrCreatePath(svc: *Service, path: []const u8) !*PathEntry {
    if (svc.paths.get(path)) |entry| return entry;
    const a = svc.allocator;
    const entry = try a.create(PathEntry);
    errdefer a.destroy(entry);
    const owned = try a.dupe(u8, path);
    errdefer a.free(owned);
    entry.* = .{ .path = owned };
    // Any entry may become evictable. Reserve before publishing it.
    try svc.inactive_paths.ensureTotalCapacity(a, @as(usize, svc.paths.count()) + 1);
    try svc.paths.put(a, owned, entry);
    path_cache.sync(svc, entry);
    return entry;
}

pub const Queue = struct {
    first: ?*PathEntry = null,
    last: ?*PathEntry = null,
};

pub fn hasReady(svc: *const Service) bool {
    return svc.resolve_ready[0].first != null or svc.resolve_ready[1].first != null;
}

pub fn queue(svc: *Service, entry: *PathEntry) void {
    const level = demand.resolutionLevel(entry) orelse return;
    if (svc.stop) return;
    if (entry.resolution != null) {
        // An in-flight job uses the latest priority when it completes.
        const queued = entry.queued orelse return;
        if (queued == level) return;
        unlink(svc, entry);
    }
    const ready = &svc.resolve_ready[@backingInt(level)];
    entry.prev = ready.last;
    if (ready.last) |last| last.next = entry else ready.first = entry;
    ready.last = entry;
    entry.queued = level;
    if (entry.resolution == null) {
        svc.next_resolution += 1;
        entry.resolution = svc.next_resolution;
    }
    _ = c.pthread_cond_signal(&svc.cond);
}

fn unlink(svc: *Service, entry: *PathEntry) void {
    const level = entry.queued orelse return;
    const ready = &svc.resolve_ready[@backingInt(level)];
    if (entry.prev) |prev| prev.next = entry.next else ready.first = entry.next;
    if (entry.next) |next| next.prev = entry.prev else ready.last = entry.prev;
    entry.prev = null;
    entry.next = null;
    entry.queued = null;
}

pub fn cancel(svc: *Service, entry: *PathEntry) void {
    unlink(svc, entry);
    entry.resolution = null;
}

pub fn take(svc: *Service) ?Job {
    for (&svc.resolve_ready) |*ready| {
        const entry = ready.first orelse continue;
        unlink(svc, entry);
        _ = entry.refs.fetchAdd(1, .monotonic);
        return .{ .entry = entry, .path = entry.path, .id = entry.resolution.? };
    }
    return null;
}

fn current(svc: *Service, job: Job) bool {
    if (svc.stop or svc.paths.get(job.path) != job.entry) return false;
    return job.entry.resolution == job.id and demand.resolutionLevel(job.entry) != null;
}

pub fn resolvePath(svc: *Service, job: Job) bool {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{job.path}, 0) catch return resolved(svc, job, null, false);
    const fd = c.open(z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return resolved(svc, job, null, false);
    defer _ = c.close(fd);
    const info = dirwalk.statFd(fd) orelse return resolved(svc, job, null, false);
    if (info.kind != .directory) return resolved(svc, job, null, false);
    const key: Key = .{ .dev = info.dev, .ino = info.ino };
    const identity: DevicePolicyCache.Identity = .{ .dev = info.dev, .mount_id = platform.mounts.idOfFd(fd) };
    svc.lock();
    const known = svc.auto.get(identity);
    const active = current(svc, job);
    svc.unlock();
    if (!active) return false;
    const auto = known orelse blk: {
        const result = svc.policy(@intCast(info.dev >> 32), @truncate(info.dev), identity.mount_id);
        svc.lock();
        if (current(svc, job)) svc.auto.put(identity, result);
        svc.unlock();
        break :blk result orelse false;
    };
    return resolved(svc, job, key, auto);
}

pub fn resolved(svc: *Service, job: Job, key: ?Key, auto: bool) bool {
    svc.lock();
    defer svc.unlock();
    if (!current(svc, job)) return false;
    const entry = job.entry;
    entry.resolution = null;
    defer svc.bump();
    const k = key orelse {
        if (entry.node != no_id) {
            demand.adjustDirect(svc, entry.node, demand.pathLevel(entry), null);
            demand.unbind(entry, svc);
        }
        return false;
    };
    const level = demand.resolutionLevel(entry).?;
    const id = svc.by_key.get(k) orelse (svc.newNode(k, job.path, level) catch {
        svc.queueResolution(entry);
        return true;
    });
    if (entry.node == id) {
        const before = demand.pathLevel(entry);
        entry.auto_allowed = auto;
        demand.adjustDirect(svc, id, before, demand.pathLevel(entry));
    } else {
        if (entry.node != no_id) {
            demand.adjustDirect(svc, entry.node, demand.pathLevel(entry), null);
            demand.unbind(entry, svc);
        }
        entry.auto_allowed = auto;
        demand.bind(svc, entry, id);
    }
    eviction.touch(svc, id, entry.access_stamp);
    if (entry.explicit_revalidate_demand != 0 or
        (entry.auto_allowed and entry.automatic_revalidate_demand != 0))
        svc.revalidateNode(id);
    const node = &svc.nodes.items[id];
    if (node.path_missing and !node.self_pending and !node.paused) {
        node.self_pending = true;
        svc.propagate(id, 0, 1, 0);
    }
    if (node.self_pending and !node.paused and !node.scanning) svc.enqueue(id, node.level);
    svc.maintainBudget();
    return false;
}
