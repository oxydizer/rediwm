//! View-owned requests and their aggregate contributions to the shared tree.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Id = tree.Id;
const Level = tree.Level;
const Entry = tree.PathEntry;
const no_id = tree.no_id;
const schedule = @import("sizetree_schedule.zig");

const Record = struct {
    automatic: ?Level = null,
    explicit: ?Level = null,
    auto_index: usize = 0,
    seen: u64 = 0,
    stopped: bool = false,
};

/// One view owns this registration on its UI thread. The service only sees
/// aggregate contributions, so workers never retain a pointer to the view.
pub const Owner = struct {
    service: *Service,
    records: std.AutoHashMapUnmanaged(*Entry, Record) = .empty,
    visible: std.ArrayList(*Entry) = .empty,
    epoch: u64 = 0,

    /// Navigation releases measurements but keeps this view's Stop choices.
    pub fn clear(self: *Owner) void {
        self.release(true);
    }

    fn release(self: *Owner, keep_stopped: bool) void {
        const svc = self.service;
        svc.lock();
        defer svc.unlock();
        var it = self.records.iterator();
        while (it.next()) |item| {
            if (keep_stopped and item.value_ptr.stopped) continue;
            const entry = item.key_ptr.*;
            update(svc, entry, item.value_ptr.*, .{});
            entry.owners -= 1;
            // Removing the current slot does not relocate any other slot.
            self.records.removeByPtr(item.key_ptr);
        }
        if (self.records.count() == 0) self.records.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
    }

    pub fn deinit(self: *Owner) void {
        self.release(false);
        const a = self.service.allocator;
        self.records.deinit(a);
        self.visible.deinit(a);
        self.* = undefined;
    }

    pub fn beginViewport(self: *Owner) void {
        self.epoch += 1;
    }

    pub fn endViewport(self: *Owner) void {
        const svc = self.service;
        svc.lock();
        defer svc.unlock();
        var i: usize = 0;
        while (i < self.visible.items.len) {
            const entry = self.visible.items[i];
            const record = self.records.getPtr(entry).?;
            if (record.seen == self.epoch) {
                i += 1;
            } else {
                const old = record.*;
                self.removeAutomatic(record);
                update(svc, entry, old, record.*);
                self.prune(entry, record.*);
            }
        }
    }

    fn removeAutomatic(self: *Owner, record: *Record) void {
        if (record.automatic == null) return;
        const index = record.auto_index;
        _ = self.visible.swapRemove(index);
        if (index < self.visible.items.len)
            self.records.getPtr(self.visible.items[index]).?.auto_index = index;
        record.automatic = null;
    }

    fn prune(self: *Owner, entry: *Entry, record: Record) void {
        if (record.automatic == null and record.explicit == null and !record.stopped) {
            _ = self.records.remove(entry);
            entry.owners -= 1;
        }
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
    count(&entry.automatic, old.automatic, false);
    count(&entry.explicit, explicitLevel(old), false);
    count(&entry.automatic, new.automatic, true);
    count(&entry.explicit, explicitLevel(new), true);
    const after = pathLevel(entry);
    if (entry.node != no_id) adjustDirect(svc, entry.node, before, after);
    if (after == null) {
        svc.cancelResolution(entry);
    } else if (before != after and entry.queued != null) {
        svc.queueResolution(entry);
    }
}

pub fn request(svc: *Service, owner: *Owner, path: []const u8, level: Level, options: tree.RequestOptions) void {
    _ = requestOwned(svc, owner, path, level, options);
}

/// False means registration ran out of memory and the view may retry.
pub fn requestOwned(svc: *Service, owner: *Owner, path: []const u8, level: Level, options: tree.RequestOptions) bool {
    std.debug.assert(owner.service == svc);
    svc.lock();
    defer svc.unlock();
    const entry = svc.getOrCreatePath(path) catch return false;
    const record = owner.records.getPtr(entry) orelse blk: {
        if (!options.force) owner.visible.ensureUnusedCapacity(svc.allocator, 1) catch return false;
        const new = owner.records.getOrPut(svc.allocator, entry) catch return false;
        new.value_ptr.* = .{};
        entry.owners += 1;
        break :blk new.value_ptr;
    };
    const old = record.*;
    if (record.stopped and !options.force) return true;
    if (options.force) {
        record.stopped = false;
        record.explicit = level;
    } else {
        if (record.automatic == null) {
            owner.visible.ensureUnusedCapacity(svc.allocator, 1) catch return false;
            record.auto_index = owner.visible.items.len;
            owner.visible.appendAssumeCapacity(entry);
        }
        record.automatic = level;
        record.seen = owner.epoch;
    }
    update(svc, entry, old, record.*);
    if (pathLevel(entry) == null) return true;
    if (entry.node == no_id) {
        svc.queueResolution(entry);
    } else if (options.revalidate) {
        svc.revalidateNode(entry.node);
    }
    return true;
}

pub fn stopPath(svc: *Service, owner: *Owner, path: []const u8) void {
    std.debug.assert(owner.service == svc);
    svc.lock();
    defer svc.unlock();
    const entry = svc.paths.get(path) orelse return;
    const record = owner.records.getPtr(entry) orelse return;
    const old = record.*;
    owner.removeAutomatic(record);
    record.explicit = null;
    record.stopped = true;
    update(svc, entry, old, record.*);
    svc.bump();
}

pub fn forgetPath(svc: *Service, owner: *Owner, path: []const u8) void {
    std.debug.assert(owner.service == svc);
    svc.lock();
    defer svc.unlock();
    const entry = svc.paths.get(path) orelse return;
    const record = owner.records.getPtr(entry) orelse return;
    const old = record.*;
    owner.removeAutomatic(record);
    record.explicit = null;
    update(svc, entry, old, record.*);
    owner.prune(entry, record.*);
}

pub fn stopped(owner: *const Owner, entry: *Entry) bool {
    return if (owner.records.get(entry)) |record| record.stopped else false;
}

pub fn adjustAncestors(svc: *Service, start: Id, removed: usize, added: usize) void {
    if (removed == added) return;
    var id = start;
    while (id != no_id) {
        const node = &svc.nodes.items[id];
        node.subtree_demand = node.subtree_demand - removed + added;
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
    adjustDirect(svc, id, null, pathLevel(entry));
}

pub fn unbind(entry: *Entry, svc: *Service) void {
    const id = entry.node;
    if (entry.bound_prev) |prev| {
        prev.bound_next = entry.bound_next;
    } else {
        svc.nodes.items[id].paths = entry.bound_next;
    }
    if (entry.bound_next) |next_entry| next_entry.bound_prev = entry.bound_prev;
    entry.node = no_id;
    entry.bound_prev = null;
    entry.bound_next = null;
}

/// Used while freeing a detached subtree. Its aggregate has already been
/// removed from surviving ancestors, and its nodes are about to be reset.
pub fn invalidate(svc: *Service, id: Id) void {
    while (svc.nodes.items[id].paths) |entry| {
        unbind(entry, svc);
        entry.auto_allowed = true;
        if (pathLevel(entry) != null) svc.queueResolution(entry);
    }
}
