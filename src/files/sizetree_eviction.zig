//! Whole-root LRU under the service mutex. Only inactive roots are indexed.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Id = tree.Id;
const no_id = tree.no_id;

// Keep several large walks warm. The limit counts directories, not files
// or bytes, and allows an active walk of any size to finish.
pub const default_live_node_budget = 100_000;
pub const not_indexed = std.math.maxInt(usize);

pub fn nextAccess(svc: *Service) u64 {
    svc.access_clock += 1;
    return svc.access_clock;
}

pub fn rootOf(svc: *const Service, id: Id) Id {
    var root = id;
    while (svc.nodes.items[root].parent != no_id) root = svc.nodes.items[root].parent;
    return root;
}

pub fn touch(svc: *Service, id: Id, stamp: u64) void {
    const node = &svc.nodes.items[rootOf(svc, id)];
    if (stamp <= node.recency) return;
    node.recency = stamp;
    if (node.eviction_index != not_indexed) siftDown(svc, node.eviction_index);
}

/// Called when a root appears or its bound demand changes. Keep its previous
/// access stamp so a worker-driven topology change does not make it newer.
pub fn syncRoot(svc: *Service, root: Id) void {
    if (svc.rootHasDemand(root)) {
        remove(svc, root);
    } else if (svc.nodes.items[root].eviction_index == not_indexed) {
        const index = svc.inactive_roots.items.len;
        svc.inactive_roots.appendAssumeCapacity(root);
        svc.nodes.items[root].eviction_index = index;
        siftUp(svc, index);
    }
}

pub fn remove(svc: *Service, root: Id) void {
    const node = &svc.nodes.items[root];
    const index = node.eviction_index;
    if (index == not_indexed) return;
    node.eviction_index = not_indexed;
    const last = svc.inactive_roots.pop().?;
    if (index == svc.inactive_roots.items.len) return;
    svc.inactive_roots.items[index] = last;
    svc.nodes.items[last].eviction_index = index;
    if (index > 0 and older(svc, index, (index - 1) / 2)) {
        siftUp(svc, index);
    } else {
        siftDown(svc, index);
    }
}

fn older(svc: *const Service, a: usize, b: usize) bool {
    const ids = svc.inactive_roots.items;
    const left = svc.nodes.items[ids[a]].recency;
    const right = svc.nodes.items[ids[b]].recency;
    return left < right or (left == right and ids[a] < ids[b]);
}

fn swap(svc: *Service, a: usize, b: usize) void {
    const ids = svc.inactive_roots.items;
    std.mem.swap(Id, &ids[a], &ids[b]);
    svc.nodes.items[ids[a]].eviction_index = a;
    svc.nodes.items[ids[b]].eviction_index = b;
}

fn siftUp(svc: *Service, start: usize) void {
    var index = start;
    while (index > 0) {
        const parent = (index - 1) / 2;
        if (!older(svc, index, parent)) break;
        swap(svc, index, parent);
        index = parent;
    }
}

fn siftDown(svc: *Service, start: usize) void {
    var index = start;
    const len = svc.inactive_roots.items.len;
    while (index < len / 2) {
        const left = 2 * index + 1;
        const right = left + 1;
        const oldest = if (right < len and older(svc, right, left)) right else left;
        if (!older(svc, oldest, index)) break;
        swap(svc, index, oldest);
        index = oldest;
    }
}

/// Run only at safe points, after demand changes or scan publication finish.
/// A pass visits just the roots it must evict and the nodes being freed.
pub fn maintain(svc: *Service) void {
    var changed = false;
    while (svc.liveNodeCount() > svc.live_node_budget and svc.inactive_roots.items.len != 0) {
        const root = svc.inactive_roots.items[0];
        std.debug.assert(!svc.rootHasDemand(root));
        svc.freeSubtree(root, .evicted);
        changed = true;
    }
    if (changed) svc.bump();
}
