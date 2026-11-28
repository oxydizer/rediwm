//! Whole-root LRU under the service mutex. Only inactive roots are indexed.
const std = @import("std");
const tree = @import("sizetree.zig");
const lru = @import("sizetree_lru.zig");
const Service = tree.Service;
const Id = tree.Id;
const no_id = tree.no_id;

// Keep several large walks warm. The limit counts directories, not files
// or bytes, and allows an active walk of any size to finish.
pub const default_live_node_budget = 100_000;
pub const not_indexed = lru.not_indexed;
const Heap = lru.Heap(Id, *Service, indexOf, older);

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
    const root = rootOf(svc, id);
    const node = &svc.nodes.items[root];
    if (stamp <= node.recency) return;
    node.recency = stamp;
    Heap.refreshed(svc.inactive_roots.items, svc, root);
}

/// Called when a root appears or its bound demand changes. Keep its previous
/// access stamp so a worker-driven topology change does not make it newer.
pub fn syncRoot(svc: *Service, root: Id) void {
    if (svc.rootHasDemand(root)) {
        remove(svc, root);
    } else if (svc.nodes.items[root].eviction_index == not_indexed) {
        Heap.insert(&svc.inactive_roots, svc, root);
    }
}

pub fn remove(svc: *Service, root: Id) void {
    Heap.remove(&svc.inactive_roots, svc, root);
}

fn indexOf(svc: *Service, root: Id) *usize {
    return &svc.nodes.items[root].eviction_index;
}

fn older(svc: *Service, a: Id, b: Id) bool {
    const left = svc.nodes.items[a].recency;
    const right = svc.nodes.items[b].recency;
    return left < right or (left == right and a < b);
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
