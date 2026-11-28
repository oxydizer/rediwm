//! View-owned requests and their aggregate contributions to the shared tree.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Id = tree.Id;
const Level = tree.Level;
const Entry = tree.PathEntry;
const no_id = tree.no_id;
const schedule = @import("sizetree_schedule.zig");
const eviction = @import("sizetree_eviction.zig");
const path_cache = @import("sizetree_path_cache.zig");
const storage_reclaim = @import("sizetree_reclaim.zig");
const c = @import("c.zig").api;

const Record = struct {
    automatic: ?Level = null,
    explicit: ?Level = null,
    automatic_revalidate: bool = false,
    explicit_revalidate: bool = false,
    auto_index: usize = 0,
    seen: u64 = 0,
    stopped: bool = false,
};

/// The view can move its Owner. Workers borrow only this stable storage,
/// under the service mutex and only while linked for reclamation.
pub const Storage = struct {
    records: std.AutoHashMapUnmanaged(*Entry, Record) = .empty,
    visible: std.ArrayList(*Entry) = .empty,
    shrink_link: std.DoublyLinkedList.Node = .{},

    fn scheduleReclaim(self: *Storage, svc: *Service) void {
        const floor = storage_reclaim.local_floor;
        if (!storage_reclaim.oversized(self.records.capacity(), self.records.count(), floor) and
            !storage_reclaim.oversized(self.visible.capacity, self.visible.items.len, floor)) return;
        const queue = &svc.reclamation.owners;
        if (queue.first == &self.shrink_link or self.shrink_link.prev != null) return;
        queue.append(&self.shrink_link);
        _ = c.pthread_cond_signal(&svc.cond);
    }

    fn unlink(self: *Storage, svc: *Service) void {
        const queue = &svc.reclamation.owners;
        if (queue.first != &self.shrink_link and self.shrink_link.prev == null) return;
        queue.remove(&self.shrink_link);
        self.shrink_link = .{};
    }

    pub fn reclaim(self: *Storage, svc: *Service) !void {
        const floor = storage_reclaim.local_floor;
        try storage_reclaim.shrinkMap(svc.allocator, &self.records, floor);
        try storage_reclaim.shrinkList(*Entry, svc.allocator, &self.visible, self.visible.items.len, floor);
        self.unlink(svc);
    }

    fn removeAutomatic(self: *Storage, record: *Record) void {
        if (record.automatic == null) return;
        const index = record.auto_index;
        _ = self.visible.swapRemove(index);
        if (index < self.visible.items.len)
            self.records.getPtr(self.visible.items[index]).?.auto_index = index;
        record.automatic = null;
    }

    fn prune(self: *Storage, svc: *Service, entry: *Entry, record: Record) void {
        if (record.automatic == null and record.explicit == null and !record.stopped) {
            _ = self.records.remove(entry);
            entry.owners -= 1;
            path_cache.sync(svc, entry);
        }
    }
};

/// One view owns this registration on its UI thread.
pub const Owner = struct {
    service: *Service,
    storage: ?*Storage = null,
    epoch: u64 = 0,

    /// Navigation releases measurements but keeps this view's Stop choices.
    pub fn clear(self: *Owner) void {
        self.release(true);
    }

    fn release(self: *Owner, keep_stopped: bool) void {
        const storage = self.storage orelse return;
        const svc = self.service;
        svc.lockAt(@src());
        defer svc.unlock();
        var it = storage.records.iterator();
        while (it.next()) |item| {
            if (keep_stopped and item.value_ptr.stopped) continue;
            const entry = item.key_ptr.*;
            update(svc, entry, item.value_ptr.*, .{});
            entry.owners -= 1;
            // Removing the current slot does not relocate any other slot.
            storage.records.removeByPtr(item.key_ptr);
            path_cache.sync(svc, entry);
        }
        storage.visible.clearRetainingCapacity();
        if (keep_stopped) {
            if (storage.records.count() == 0 and
                !storage_reclaim.oversized(storage.records.capacity(), 0, storage_reclaim.local_floor))
                storage.records.clearRetainingCapacity();
            storage.scheduleReclaim(svc);
        } else {
            storage.unlink(svc);
        }
        svc.maintainBudget();
    }

    pub fn deinit(self: *Owner) void {
        self.release(false);
        if (self.storage) |storage| {
            const a = self.service.allocator;
            storage.records.deinit(a);
            storage.visible.deinit(a);
            a.destroy(storage);
        }
        self.* = undefined;
    }

    pub fn beginViewport(self: *Owner) void {
        self.epoch += 1;
    }

    pub fn endViewport(self: *Owner) void {
        const storage = self.storage orelse return;
        const svc = self.service;
        svc.lockAt(@src());
        defer svc.unlock();
        var i: usize = 0;
        while (i < storage.visible.items.len) {
            const entry = storage.visible.items[i];
            const record = storage.records.getPtr(entry).?;
            if (record.seen == self.epoch) {
                i += 1;
            } else {
                const old = record.*;
                storage.removeAutomatic(record);
                update(svc, entry, old, record.*);
                storage.prune(svc, entry, record.*);
            }
        }
        svc.maintainBudget();
        storage.scheduleReclaim(svc);
    }
};

pub fn best(levels: [2]usize) ?Level {
    if (levels[0] != 0) return .visible;
    if (levels[1] != 0) return .background;
    return null;
}

pub fn higher(a: ?Level, b: ?Level) ?Level {
    return if (a == .visible or b == .visible) .visible else a orelse b;
}

pub fn pathLevel(entry: *const Entry) ?Level {
    return higher(best(entry.explicit), if (entry.auto_allowed) best(entry.automatic) else null);
}

pub fn resolutionLevel(entry: *const Entry) ?Level {
    return higher(best(entry.explicit), best(entry.automatic));
}

fn count(counts: *[2]usize, level: ?Level, add: bool) void {
    const l = level orelse return;
    const n = &counts[@backingInt(l)];
    if (add) n.* += 1 else n.* -= 1;
}

fn explicitLevel(record: Record) ?Level {
    return if (record.explicit != null) higher(record.explicit, record.automatic) else null;
}

fn update(svc: *Service, entry: *Entry, old: Record, new: Record) void {
    const before = pathLevel(entry);
    const resolution_before = resolutionLevel(entry);
    if (old.automatic_revalidate and old.automatic != null)
        entry.automatic_revalidate_demand -= 1;
    if (old.explicit_revalidate and old.explicit != null)
        entry.explicit_revalidate_demand -= 1;
    if (new.automatic_revalidate and new.automatic != null)
        entry.automatic_revalidate_demand += 1;
    if (new.explicit_revalidate and new.explicit != null)
        entry.explicit_revalidate_demand += 1;
    count(&entry.automatic, old.automatic, false);
    count(&entry.explicit, explicitLevel(old), false);
    count(&entry.automatic, new.automatic, true);
    count(&entry.explicit, explicitLevel(new), true);
    const after = pathLevel(entry);
    if (entry.node != no_id) adjustDirect(svc, entry.node, before, after);
    const resolution_after = resolutionLevel(entry);
    if (resolution_after == null) {
        svc.cancelResolution(entry);
    } else if (resolution_before != resolution_after and entry.queued != null) {
        svc.queueResolution(entry);
    }
}

pub fn request(svc: *Service, owner: *Owner, path: []const u8, level: Level, options: tree.RequestOptions) void {
    _ = requestOwned(svc, owner, path, level, options);
}

/// False means registration ran out of memory and the view may retry.
pub fn requestOwned(svc: *Service, owner: *Owner, path: []const u8, level: Level, options: tree.RequestOptions) bool {
    std.debug.assert(owner.service == svc);
    svc.lockAt(@src());
    defer svc.unlock();
    // A new entry may be eligible if its owner registration fails.
    defer path_cache.maintain(svc);
    const storage = owner.storage orelse blk: {
        const storage = svc.allocator.create(Storage) catch return false;
        storage.* = .{};
        owner.storage = storage;
        break :blk storage;
    };
    const entry = svc.getOrCreatePath(path) catch return false;
    const record = storage.records.getPtr(entry) orelse blk: {
        if (!options.force) storage.visible.ensureUnusedCapacity(svc.allocator, 1) catch return false;
        const new = storage.records.getOrPut(svc.allocator, entry) catch return false;
        new.value_ptr.* = .{};
        entry.owners += 1;
        path_cache.sync(svc, entry);
        break :blk new.value_ptr;
    };
    const old = record.*;
    if (record.stopped and !options.force) return true;
    if (options.force) {
        record.stopped = false;
        record.explicit = level;
        record.explicit_revalidate = options.revalidate;
    } else {
        if (record.automatic == null) {
            storage.visible.ensureUnusedCapacity(svc.allocator, 1) catch return false;
            record.auto_index = storage.visible.items.len;
            storage.visible.appendAssumeCapacity(entry);
        }
        record.automatic = level;
        record.automatic_revalidate = options.revalidate;
        record.seen = owner.epoch;
    }
    // A fresh request can re-evaluate disk policy for an evicted binding.
    if (entry.node == no_id) entry.auto_allowed = true;
    update(svc, entry, old, record.*);
    path_cache.touch(svc, entry);
    var validate = false;
    if (options.directory_key) |key| {
        validate = entry.node != no_id and
            !std.meta.eql(svc.nodes.items[entry.node].key, key);
        if (entry.node == no_id or validate) {
            if (!std.meta.eql(entry.expected_key, options.directory_key)) {
                svc.cancelResolution(entry);
                entry.expected_key = key;
            }
        }
    }
    if (validate) {
        svc.queueResolution(entry);
        svc.bump();
        return true;
    }
    if (pathLevel(entry) == null) return true;
    if (entry.node == no_id) {
        svc.queueResolution(entry);
    } else if (entry.resolution == null and options.revalidate and
        (options.force or entry.auto_allowed))
    {
        svc.revalidateNode(entry.node);
    }
    return true;
}

pub fn stopPath(svc: *Service, owner: *Owner, path: []const u8) void {
    std.debug.assert(owner.service == svc);
    const storage = owner.storage orelse return;
    svc.lockAt(@src());
    defer svc.unlock();
    const entry = svc.paths.get(path) orelse return;
    const record = storage.records.getPtr(entry) orelse return;
    const old = record.*;
    storage.removeAutomatic(record);
    record.explicit = null;
    record.stopped = true;
    update(svc, entry, old, record.*);
    svc.bump();
    svc.maintainBudget();
    storage.scheduleReclaim(svc);
}

pub fn forgetPath(svc: *Service, owner: *Owner, path: []const u8) void {
    std.debug.assert(owner.service == svc);
    const storage = owner.storage orelse return;
    svc.lockAt(@src());
    defer svc.unlock();
    const entry = svc.paths.get(path) orelse return;
    const record = storage.records.getPtr(entry) orelse return;
    const old = record.*;
    storage.removeAutomatic(record);
    record.explicit = null;
    update(svc, entry, old, record.*);
    storage.prune(svc, entry, record.*);
    svc.maintainBudget();
    storage.scheduleReclaim(svc);
}

pub fn stopped(owner: *const Owner, entry: *Entry) bool {
    const storage = owner.storage orelse return false;
    return if (storage.records.get(entry)) |record| record.stopped else false;
}

pub fn adjustAncestors(svc: *Service, start: Id, removed: usize, added: usize) void {
    if (removed == added) return;
    var id = start;
    while (id != no_id) {
        const node = &svc.nodes.items[id];
        node.subtree_demand = node.subtree_demand - removed + added;
        if (node.parent == no_id) eviction.syncRoot(svc, id);
        id = node.parent;
    }
}

pub fn adjustDirect(svc: *Service, id: Id, before: ?Level, after: ?Level) void {
    if (before == after) return;
    const node = &svc.nodes.items[id];
    count(&node.direct_demand, before, false);
    count(&node.direct_demand, after, true);
    adjustAncestors(svc, id, @intFromBool(before != null), @intFromBool(after != null));
    const was_paused = node.paused;
    refresh(svc, id);
    if (was_paused != node.paused) svc.bump();
}

pub fn effective(svc: *const Service, id: Id) ?Level {
    if (id == no_id) return null;
    const node = &svc.nodes.items[id];
    return if (node.paused) null else node.level;
}

/// Only branches whose effective inherited priority changes need visiting.
pub fn refresh(svc: *Service, root: Id) void {
    var id = root;
    while (id != no_id) {
        const node = &svc.nodes.items[id];
        const inherited = effective(svc, node.parent);
        const wanted = higher(best(node.direct_demand), inherited);
        const changed = wanted != effective(svc, id);
        if (changed) {
            svc.unqueue(id);
            node.paused = wanted == null;
            node.level = wanted orelse .background;
            if (wanted == null) node.rescan = false;
        }
        if (wanted) |level| {
            // Losing the parent's demand also cancels its recovery scan.
            // Independently demanded children must get their own retry.
            const retry = node.waiting_for_parent and inherited == null;
            if (retry) node.waiting_for_parent = false;
            if ((changed or retry) and !node.waiting_for_parent and node.self_pending and !node.scanning)
                svc.enqueue(id, level);
        }
        id = schedule.next(svc, root, id, changed);
    }
}

/// The binding lists let deletion invalidate only paths attached to the node.
pub fn bind(svc: *Service, entry: *Entry, id: Id) void {
    std.debug.assert(entry.node == no_id);
    const node = &svc.nodes.items[id];
    entry.node = id;
    entry.bound_next = node.paths;
    if (node.paths) |head| head.bound_prev = entry;
    node.paths = entry;
    if (node.path_missing) {
        path_cache.sync(svc, entry);
        if (entry.bound_next) |previous| path_cache.sync(svc, previous);
    }
    adjustDirect(svc, id, null, pathLevel(entry));
}

pub fn unbind(entry: *Entry, svc: *Service) void {
    const id = entry.node;
    const was_recovery_path = svc.nodes.items[id].path_missing and entry.bound_prev == null;
    if (entry.bound_prev) |prev| {
        prev.bound_next = entry.bound_next;
    } else {
        svc.nodes.items[id].paths = entry.bound_next;
    }
    if (entry.bound_next) |next_entry| next_entry.bound_prev = entry.bound_prev;
    entry.node = no_id;
    entry.bound_prev = null;
    const next = entry.bound_next;
    entry.bound_next = null;
    if (was_recovery_path) {
        if (next) |head| path_cache.sync(svc, head);
        path_cache.sync(svc, entry);
    }
}

/// Used while freeing a detached subtree. Its aggregate has already been
/// removed from surviving ancestors, and its nodes are about to be reset.
pub fn invalidate(svc: *Service, id: Id, reason: Service.Removal) void {
    while (svc.nodes.items[id].paths) |entry| {
        std.debug.assert(reason != .evicted or pathLevel(entry) == null);
        unbind(entry, svc);
        // A filesystem removal retries active paths. After eviction, wait
        // for a fresh request so policy-denied paths remain idle.
        if (reason == .removed) {
            entry.auto_allowed = true;
            if (pathLevel(entry) != null) svc.queueResolution(entry);
        }
    }
}
