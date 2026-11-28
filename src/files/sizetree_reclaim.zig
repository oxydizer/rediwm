//! Fallible worker maintenance under the service mutex. Mutators only
//! identify candidates and wake a worker, including when all workers are idle.
const std = @import("std");
const c = @import("c.zig").api;
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Id = tree.Id;
const no_id = tree.no_id;
const Allocator = std.mem.Allocator;

pub const State = struct {
    children: Id = no_id,
    owners: std.DoublyLinkedList = .{},
    retry_after_ms: i64 = 0,
};

// Factor four leaves room for normal growth, including hash tables' load
// factor and power-of-two rounding. Keep 50% headroom after a shrink.
const shared_floor = 256;
pub const local_floor = 32;

pub fn oversized(capacity: usize, retained: usize, floor: usize) bool {
    return capacity > 4 *| @max(retained, floor);
}

fn target(retained: usize, floor: usize) usize {
    return if (retained == 0) 0 else @max(retained + retained / 2, floor);
}

pub fn shrinkList(comptime T: type, a: Allocator, list: *std.ArrayList(T), retained: usize, floor: usize) !void {
    if (!oversized(list.capacity, retained, floor)) return;
    var replacement: std.ArrayList(T) = .empty;
    try replacement.ensureTotalCapacityPrecise(a, target(retained, floor));
    replacement.appendSliceAssumeCapacity(list.items);
    list.deinit(a);
    list.* = replacement;
}

pub fn shrinkMap(a: Allocator, map: anytype, floor: usize) !void {
    const count = map.count();
    if (!oversized(map.capacity(), count, floor)) return;
    var replacement: @TypeOf(map.*) = .empty;
    try replacement.ensureTotalCapacity(a, @intCast(target(count, floor)));
    var entries = map.iterator();
    while (entries.next()) |entry| replacement.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
    map.deinit(a);
    map.* = replacement;
}

pub fn sharedOversized(svc: *const Service) bool {
    const live = svc.liveNodeCount();
    const paths = svc.paths.count();
    return oversized(svc.nodes.capacity, live, shared_floor) or
        oversized(svc.by_key.capacity(), live, shared_floor) or
        oversized(svc.inactive_roots.capacity, svc.nodes.items.len, shared_floor) or
        oversized(svc.paths.capacity(), paths, shared_floor) or
        oversized(svc.inactive_paths.capacity, paths, shared_floor);
}

pub fn childrenRemoved(svc: *Service, id: Id) void {
    const node = &svc.nodes.items[id];
    if (!oversized(node.children.capacity, node.children.items.len, local_floor)) return;
    if (svc.reclamation.children == id or node.shrink_prev != no_id) return;
    node.shrink_next = svc.reclamation.children;
    if (node.shrink_next != no_id) svc.nodes.items[node.shrink_next].shrink_prev = id;
    svc.reclamation.children = id;
    _ = c.pthread_cond_signal(&svc.cond);
}

pub fn unlinkChildren(svc: *Service, id: Id) void {
    const node = &svc.nodes.items[id];
    if (node.shrink_prev != no_id) {
        svc.nodes.items[node.shrink_prev].shrink_next = node.shrink_next;
    } else if (svc.reclamation.children == id) {
        svc.reclamation.children = node.shrink_next;
    } else return;
    if (node.shrink_next != no_id) svc.nodes.items[node.shrink_next].shrink_prev = node.shrink_prev;
    node.shrink_prev = no_id;
    node.shrink_next = no_id;
}

fn hasWork(svc: *const Service) bool {
    return sharedOversized(svc) or svc.reclamation.children != no_id or svc.reclamation.owners.first != null;
}

pub fn run(svc: *Service) void {
    if (!hasWork(svc) or retryDelay(svc) > 0) return;
    pass(svc) catch {
        svc.reclamation.retry_after_ms = tree.nowMs() + 1000;
        return;
    };
    svc.reclamation.retry_after_ms = 0;
}

/// Called with the mutex held after finding no scans or resolutions to
/// dispatch. Retry after OOM even if the service receives no more requests.
pub fn wait(svc: *Service) void {
    if (!hasWork(svc)) {
        svc.beforeWait();
        _ = c.pthread_cond_wait(&svc.cond, &svc.mutex);
        svc.resumedAfterWait(@src());
        return;
    }
    const delay = retryDelay(svc);
    if (delay == 0) {
        // Another bounded batch is ready. Give requesters a turn first.
        svc.unlock();
        svc.lockAt(@src());
        return;
    }
    var until: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &until);
    const ns = until.tv_nsec + delay * std.time.ns_per_ms;
    until.tv_sec += @intCast(@divTrunc(ns, std.time.ns_per_s));
    until.tv_nsec = @intCast(@mod(ns, std.time.ns_per_s));
    svc.beforeWait();
    _ = c.pthread_cond_timedwait(&svc.cond, &svc.mutex, &until);
    svc.resumedAfterWait(@src());
}

fn retryDelay(svc: *const Service) i64 {
    const after = svc.reclamation.retry_after_ms;
    return if (after == 0) 0 else @max(0, after - tree.nowMs());
}

pub fn pass(svc: *Service) !void {
    const a = svc.allocator;
    const live = svc.liveNodeCount();
    const paths = svc.paths.count();
    // Limit each turn to one shared replacement. These operations can hold
    // the mutex longer than the normal scan and request bookkeeping.
    if (oversized(svc.nodes.capacity, live, shared_floor)) return compactNodes(svc);
    if (oversized(svc.by_key.capacity(), live, shared_floor)) return shrinkMap(a, &svc.by_key, shared_floor);
    if (oversized(svc.inactive_roots.capacity, svc.nodes.items.len, shared_floor))
        return shrinkList(Id, a, &svc.inactive_roots, svc.nodes.items.len, shared_floor);
    if (oversized(svc.paths.capacity(), paths, shared_floor)) return shrinkMap(a, &svc.paths, shared_floor);
    if (oversized(svc.inactive_paths.capacity, paths, shared_floor))
        return shrinkList(*tree.PathEntry, a, &svc.inactive_paths, paths, shared_floor);
    for (0..16) |_| {
        const id = svc.reclamation.children;
        if (id == no_id) break;
        const children = &svc.nodes.items[id].children;
        try shrinkList(Id, a, children, children.items.len, local_floor);
        unlinkChildren(svc, id);
    }
    for (0..4) |_| {
        const link = svc.reclamation.owners.first orelse break;
        const owner: *@import("sizetree_demand.zig").Storage = @fieldParentPtr("shrink_link", link);
        try owner.reclaim(svc);
    }
}

fn remap(ids: []const Id, id: Id) Id {
    if (id == no_id) return no_id;
    const mapped = ids[id];
    std.debug.assert(mapped != no_id);
    return mapped;
}

fn compactNodes(svc: *Service) !void {
    const a = svc.allocator;
    const capacity = target(svc.liveNodeCount(), shared_floor);
    const ids = try a.alloc(Id, if (capacity == 0) 0 else svc.nodes.items.len);
    defer a.free(ids);
    var nodes: std.ArrayList(tree.Node) = .empty;
    errdefer nodes.deinit(a);
    try nodes.ensureTotalCapacityPrecise(a, capacity);
    var by_key: @TypeOf(svc.by_key) = .empty;
    errdefer by_key.deinit(a);
    try by_key.ensureTotalCapacity(a, @intCast(capacity));
    var roots: std.ArrayList(Id) = .empty;
    errdefer roots.deinit(a);
    try roots.ensureTotalCapacityPrecise(a, capacity);

    // Copy in old slot order to preserve root LRU tie-breaking. The copied
    // nodes still borrow names and children until the replacement is published.
    if (capacity != 0) for (svc.nodes.items, ids) |node, *id| {
        id.* = no_id;
        if (!node.live) continue;
        id.* = @intCast(nodes.items.len);
        nodes.appendAssumeCapacity(node);
        by_key.putAssumeCapacityNoClobber(node.key, id.*);
    };
    for (svc.inactive_roots.items) |id| roots.appendAssumeCapacity(remap(ids, id));

    // All allocation has succeeded. No completion can publish while the
    // mutex is held. Scans find the same generation by inode after a move,
    // and resolution jobs have stable PathEntry pointers, independent of IDs.
    for (nodes.items, 0..) |*node, id| {
        node.parent = remap(ids, node.parent);
        for (node.children.items) |*child| child.* = remap(ids, child.*);
        node.queue_prev = remap(ids, node.queue_prev);
        node.queue_next = remap(ids, node.queue_next);
        node.shrink_prev = remap(ids, node.shrink_prev);
        node.shrink_next = remap(ids, node.shrink_next);
        var path = node.paths;
        while (path) |entry| : (path = entry.bound_next) entry.node = @intCast(id);
    }
    for (&svc.queues) |*queue| {
        queue.first = remap(ids, queue.first);
        queue.last = remap(ids, queue.last);
    }
    svc.reclamation.children = remap(ids, svc.reclamation.children);
    svc.nodes.deinit(a);
    svc.nodes = nodes;
    svc.by_key.deinit(a);
    svc.by_key = by_key;
    svc.inactive_roots.deinit(a);
    svc.inactive_roots = roots;
    svc.free_head = no_id;
}
