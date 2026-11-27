//! Inactive path entries are evicted independently of their measured nodes.
const std = @import("std");
const tree = @import("sizetree.zig");
const demand = @import("sizetree_demand.zig");
const eviction = @import("sizetree_eviction.zig");
const lru = @import("sizetree_lru.zig");
const Service = tree.Service;
const Entry = tree.PathEntry;
const Heap = lru.Heap(*Entry, void, indexOf, older);

// Retain recently used paths across many listings. Most directories seen by
// a recursive scan never need a separate path entry.
pub const default_path_budget = 32_768;

fn indexOf(_: void, entry: *Entry) *usize {
    return &entry.eviction_index;
}

fn older(_: void, a: *Entry, b: *Entry) bool {
    return a.access_stamp < b.access_stamp;
}

fn eligible(svc: *const Service, entry: *const Entry) bool {
    if (entry.owners != 0 or entry.resolution != null) return false;
    if (entry.node == tree.no_id) return true;
    const node = &svc.nodes.items[entry.node];
    // pathOf uses the head as an absolute prefix for the entire subtree.
    return !node.path_missing or node.paths != entry;
}

pub fn sync(svc: *Service, entry: *Entry) void {
    if (!eligible(svc, entry)) {
        Heap.remove(&svc.inactive_paths, {}, entry);
    } else if (entry.eviction_index == lru.not_indexed) {
        Heap.insert(&svc.inactive_paths, {}, entry);
    }
}

pub fn touch(svc: *Service, entry: *Entry) void {
    entry.access_stamp = eviction.nextAccess(svc);
    Heap.refreshed(svc.inactive_paths.items, {}, entry);
    if (entry.node != tree.no_id) eviction.touch(svc, entry.node, entry.access_stamp);
}

/// Called after owner records and node bindings are consistent. A cancelled
/// dispatched job can outlive the map entry via its own reference.
pub fn maintain(svc: *Service) void {
    var changed = false;
    while (svc.paths.count() > svc.path_entry_budget and svc.inactive_paths.items.len != 0) {
        const entry = svc.inactive_paths.items[0];
        std.debug.assert(eligible(svc, entry));
        std.debug.assert(demand.pathLevel(entry) == null);
        Heap.remove(&svc.inactive_paths, {}, entry);
        svc.cancelResolution(entry);
        if (entry.node != tree.no_id) demand.unbind(entry, svc);
        const removed = svc.paths.remove(entry.path);
        std.debug.assert(removed);
        entry.release(svc.allocator);
        changed = true;
    }
    if (changed) svc.bump();
}
