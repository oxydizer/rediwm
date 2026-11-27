//! Prepare a directory's changes before publishing them under the service mutex.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Id = tree.Id;
const no_id = tree.no_id;
const Key = tree.Key;

const Change = struct {
    key: Key,
    existing: ?Id,
    attach: bool,
    name: ?[]u8,
};

const Plan = struct {
    listed: std.AutoHashMapUnmanaged(Key, void) = .empty,
    changes: std.ArrayList(Change) = .empty,

    fn deinit(self: *Plan, a: std.mem.Allocator) void {
        for (self.changes.items) |change| if (change.name) |name| a.free(name);
        self.changes.deinit(a);
        self.listed.deinit(a);
    }

    fn prepare(self: *Plan, svc: *Service, id: Id, found: []const Service.Child) !void {
        const a = svc.allocator;
        try self.listed.ensureTotalCapacity(a, @intCast(found.len));
        try self.changes.ensureTotalCapacity(a, found.len);

        var new_count: usize = 0;
        var attachments: usize = 0;
        for (found) |child| {
            const entry = self.listed.getOrPutAssumeCapacity(child.key);
            if (entry.found_existing) continue; // Use the first name for a key.
            const existing = svc.by_key.get(child.key);
            const attach = if (existing) |old| svc.nodes.items[old].parent != id else true;
            if (attach) if (existing) |old| {
                if (old == id or svc.isAncestor(old, id)) continue;
            };
            if (attach) attachments += 1;
            if (existing == null) new_count += 1;
            const name = if (existing != null and std.mem.eql(u8, svc.nodes.items[existing.?].name, child.name))
                null
            else
                try a.dupe(u8, child.name);
            self.changes.appendAssumeCapacity(.{
                .key = child.key,
                .existing = existing,
                .attach = attach,
                .name = name,
            });
        }

        var extra_slots = new_count;
        var free = svc.free_head;
        while (free != no_id and extra_slots != 0) : (extra_slots -= 1)
            free = svc.nodes.items[free].parent;
        try svc.nodes.ensureUnusedCapacity(a, extra_slots);
        if (new_count != 0) try svc.by_key.ensureUnusedCapacity(a, @intCast(new_count));
        try svc.nodes.items[id].children.ensureUnusedCapacity(a, attachments);
    }

    fn apply(self: *Plan, svc: *Service, id: Id) void {
        const parent = &svc.nodes.items[id];
        // Move listed nodes before deleting omitted subtrees. A listed node
        // can still be linked below an omitted child in the cached tree.
        for (self.changes.items) |*change| {
            if (change.existing) |child| {
                svc.nodes.items[child].path_missing = false;
                svc.nodes.items[child].waiting_for_parent = false;
                if (change.name) |name| {
                    svc.allocator.free(svc.nodes.items[child].name);
                    svc.nodes.items[child].name = name;
                }
                if (change.attach) {
                    svc.detach(child);
                    svc.attachPrepared(id, child);
                }
            } else {
                const child = svc.newNodePrepared(change.key, change.name.?, parent.level);
                svc.attachPrepared(id, child);
                change.existing = child;
            }
            change.name = null;
        }

        var i: usize = 0;
        while (i < parent.children.items.len) {
            const child = parent.children.items[i];
            if (self.listed.contains(svc.nodes.items[child].key)) {
                i += 1;
                continue;
            }
            svc.detach(child);
            svc.freeSubtree(child);
        }

        for (self.changes.items) |change| {
            const child = change.existing.?;
            const node = &svc.nodes.items[child];
            if (node.self_pending and node.queued == null and !node.scanning)
                svc.enqueue(child, node.level);
        }
    }
};

pub fn finishScan(svc: *Service, id: Id, own: i64, found: []const Service.Child, unreadable: bool) !void {
    var plan: Plan = .{};
    defer plan.deinit(svc.allocator);
    try plan.prepare(svc, id, found);
    plan.apply(svc, id);

    const node = &svc.nodes.items[id];
    const own_delta = own - node.own;
    const unread_delta: i64 = @as(i64, @intFromBool(unreadable)) - @intFromBool(node.self_unreadable);
    const rescan = node.rescan;
    const pending_delta: i64 = @as(i64, @intFromBool(rescan)) - @intFromBool(node.self_pending);
    node.own = own;
    node.self_unreadable = unreadable;
    node.self_pending = rescan;
    node.scanning = false;
    node.rescan = false;
    // Keep the pending contribution across an immediate rescan.
    svc.propagate(id, own_delta, pending_delta, unread_delta);
    if (rescan) svc.enqueue(id, node.level);
    svc.bump();
}
