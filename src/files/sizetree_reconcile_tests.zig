//! Fault injection for directory reconciliation and scan scheduling.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const demand = @import("sizetree_demand.zig");
const Id = tree.Id;
const no_id = tree.no_id;

fn auto(_: u32, _: u32) bool {
    return true;
}

fn key(ino: u64) tree.Key {
    return .{ .dev = 1, .ino = ino };
}

fn checkTree(svc: *Service) !void {
    var live: usize = 0;
    var queued: usize = 0;
    for (svc.nodes.items, 0..) |node, index| {
        if (!node.live) continue;
        const id: Id = @intCast(index);
        live += 1;
        if (node.queued != null) queued += 1;
        try std.testing.expectEqual(id, svc.by_key.get(node.key).?);
        if (node.parent != no_id) {
            const parent = svc.nodes.items[node.parent];
            try std.testing.expect(parent.live);
            try std.testing.expectEqual(id, parent.children.items[node.child_index]);
        }
        var demands = node.direct_demand[0] + node.direct_demand[1];
        var total = node.own;
        var pending: u32 = @intFromBool(node.self_pending);
        var unreadable: u32 = @intFromBool(node.self_unreadable);
        for (node.children.items, 0..) |child, child_index| {
            const member = svc.nodes.items[child];
            try std.testing.expect(member.live);
            try std.testing.expectEqual(id, member.parent);
            try std.testing.expectEqual(child_index, member.child_index);
            demands += member.subtree_demand;
            total += member.total;
            pending += member.pending;
            unreadable += member.unreadable;
        }
        try std.testing.expectEqual(demands, node.subtree_demand);
        try std.testing.expectEqual(total, node.total);
        try std.testing.expectEqual(pending, node.pending);
        try std.testing.expectEqual(unreadable, node.unreadable);
    }
    try std.testing.expectEqual(live, svc.by_key.count());
    var free_count: usize = 0;
    var free = svc.free_head;
    while (free != no_id) {
        try std.testing.expect(free_count < svc.nodes.items.len - live);
        const node = svc.nodes.items[free];
        try std.testing.expect(!node.live);
        free_count += 1;
        free = node.parent;
    }
    try std.testing.expectEqual(svc.nodes.items.len - live, free_count);
    try std.testing.expectEqual(queued, svc.queued_count);
    var linked: usize = 0;
    for (svc.queues, 0..) |queue, level| {
        var prev = no_id;
        var id = queue.first;
        while (id != no_id) {
            try std.testing.expect(linked < queued);
            const node = svc.nodes.items[id];
            try std.testing.expect(node.live and !node.paused);
            try std.testing.expectEqual(level, @backingInt(node.queued.?));
            try std.testing.expectEqual(prev, node.queue_prev);
            linked += 1;
            prev = id;
            id = node.queue_next;
        }
        try std.testing.expectEqual(prev, queue.last);
    }
    try std.testing.expectEqual(queued, linked);
}

fn reconcileWithFailure(fail_offset: usize) !bool {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const svc = try Service.create(failing.allocator(), 0, auto);
    defer svc.destroy();

    const ancestor = try svc.newNode(key(1), "/ancestor", .visible);
    const root = try svc.newNode(key(2), "root", .visible);
    const renamed = try svc.newNode(key(3), "old-name", .background);
    const source = try svc.newNode(key(4), "/source", .background);
    const moved = try svc.newNode(key(5), "old-location", .background);
    const moved_leaf = try svc.newNode(key(6), "leaf", .background);
    const independent = try svc.newNode(key(7), "/independent", .background);
    const removed = try svc.newNode(key(8), "removed", .background);
    const rescued = try svc.newNode(key(9), "rescued", .background);
    const spare = try svc.newNode(key(10), "/spare", .background);
    const spare_ref = svc.refOf(spare);
    svc.freeSubtree(spare);
    try svc.attach(ancestor, root);
    try svc.attach(root, renamed);
    try svc.attach(root, removed);
    try svc.attach(removed, rescued);
    try svc.attach(source, moved);
    try svc.attach(moved, moved_leaf);
    try svc.finishScan(moved_leaf, 11, &.{}, true);
    try svc.finishScan(renamed, 13, &.{}, false);
    try svc.finishScan(rescued, 17, &.{}, false);
    demand.adjustDirect(svc, root, null, .visible);
    svc.unqueue(root);
    svc.nodes.items[root].scanning = true;
    svc.nodes.items[root].rescan = true;
    const moved_ref = svc.refOf(moved);
    const independent_ref = svc.refOf(independent);
    const removed_ref = svc.refOf(removed);
    const root_before = svc.nodes.items[root];
    const published = svc.generation.load(.acquire);
    const old_slot_count = svc.nodes.items.len;

    var found: [38]Service.Child = undefined;
    const existing = [_]Service.Child{
        .{ .key = key(3), .name = @constCast("renamed") },
        .{ .key = key(5), .name = @constCast("moved") },
        .{ .key = key(7), .name = @constCast("independent") },
        .{ .key = key(9), .name = @constCast("rescued") },
        .{ .key = key(3), .name = @constCast("duplicate-rename") },
        .{ .key = key(1), .name = @constCast("cycle") },
        .{ .key = key(2), .name = @constCast("self") },
        .{ .key = key(100), .name = @constCast("first") },
        .{ .key = key(100), .name = @constCast("duplicate-new") },
    };
    @memcpy(found[0..existing.len], &existing);
    for (found[existing.len..], 101..) |*child, ino| {
        child.* = .{ .key = key(ino), .name = @constCast("new") };
    }

    failing.fail_index = failing.alloc_index + fail_offset;
    // Force every growth path through alloc rather than an in-place resize.
    failing.resize_fail_index = failing.resize_index;
    const failed = if (svc.finishScan(root, 19, &found, true)) |_| false else |err| blk: {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(failing.has_induced_failure);
        try checkTree(svc);
        const after = svc.nodes.items[root];
        try std.testing.expectEqual(root_before.own, after.own);
        try std.testing.expectEqual(root_before.total, after.total);
        try std.testing.expectEqual(root_before.pending, after.pending);
        try std.testing.expectEqual(root_before.unreadable, after.unreadable);
        try std.testing.expectEqual(root_before.completed_ms, after.completed_ms);
        try std.testing.expect(after.scanning and after.rescan);
        try std.testing.expectEqual(published, svc.generation.load(.acquire));
        try std.testing.expectEqualSlices(Id, &.{ renamed, removed }, after.children.items);
        try std.testing.expectEqualStrings("old-name", svc.nodes.items[renamed].name);
        try std.testing.expectEqualStrings("old-location", svc.nodes.items[moved].name);
        try std.testing.expectEqualStrings("/independent", svc.nodes.items[independent].name);
        try std.testing.expectEqual(source, svc.nodes.items[moved].parent);
        try std.testing.expectEqual(no_id, svc.nodes.items[independent].parent);
        try std.testing.expectEqual(removed, svc.nodes.items[rescued].parent);
        try std.testing.expectEqual(removed, svc.liveId(removed_ref).?);
        try std.testing.expectEqual(old_slot_count, svc.nodes.items.len);
        try std.testing.expectEqual(spare, svc.free_head);
        try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
        try std.testing.expect(svc.by_key.get(key(100)) == null);

        // The worker releases the in-flight job and requeues it without
        // allocating, even though the allocator is still failing.
        svc.unqueue(removed);
        svc.retryScan(root);
        svc.enqueue(removed, .visible);
        var path: [4096]u8 = undefined;
        const job = svc.take(&path).?;
        try std.testing.expectEqual(root, svc.liveId(job.work.scan.ref).?);
        try std.testing.expectEqualStrings("/ancestor/root", job.path.?);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try svc.finishScan(root, 19, &found, true);
        break :blk true;
    };

    try checkTree(svc);
    try std.testing.expectEqual(root, svc.nodes.items[renamed].parent);
    try std.testing.expectEqualStrings("renamed", svc.nodes.items[renamed].name);
    try std.testing.expectEqual(moved, svc.liveId(moved_ref).?);
    try std.testing.expectEqual(root, svc.nodes.items[moved].parent);
    try std.testing.expectEqual(moved, svc.nodes.items[moved_leaf].parent);
    try std.testing.expectEqual(@as(i64, 0), svc.nodes.items[source].total);
    try std.testing.expectEqual(independent, svc.liveId(independent_ref).?);
    try std.testing.expectEqual(root, svc.nodes.items[independent].parent);
    try std.testing.expectEqual(root, svc.nodes.items[rescued].parent);
    try std.testing.expectEqual(@as(?Id, null), svc.liveId(removed_ref));
    try std.testing.expectEqual(@as(?Id, null), svc.liveId(spare_ref));
    try std.testing.expectEqual(@as(?Id, spare), svc.by_key.get(key(100)));
    try std.testing.expectEqualStrings("first", svc.nodes.items[spare].name);
    try std.testing.expectEqual(ancestor, svc.nodes.items[root].parent);
    try std.testing.expectEqual(no_id, svc.nodes.items[ancestor].parent);
    try std.testing.expectEqual(@as(i64, 60), svc.nodes.items[ancestor].total);
    try std.testing.expectEqual(@as(u32, 2), svc.nodes.items[ancestor].unreadable);
    try std.testing.expect(svc.nodes.items[root].self_pending and !svc.nodes.items[root].complete);
    try std.testing.expectEqual(@as(?tree.Level, .visible), svc.nodes.items[root].queued);
    return failed;
}

test "sizetree scan preparation is atomic at every allocation failure" {
    var offset: usize = 0;
    while (offset < 100) : (offset += 1) {
        if (!try reconcileWithFailure(offset)) break;
    } else return error.FaultInjectionDidNotReachSuccess;
    // Map and plan storage, names, node storage, key growth, and child growth.
    try std.testing.expect(offset >= 38);
}

test "sizetree promotion, cancellation and rescan scheduling need no allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const svc = try Service.create(failing.allocator(), 0, auto);
    defer svc.destroy();

    const root = try svc.newNode(key(1), "/root", .background);
    const child = try svc.newNode(key(2), "child", .background);
    const other = try svc.newNode(key(3), "/other", .background);
    try svc.attach(root, child);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    demand.adjustDirect(svc, root, null, .background);
    demand.adjustDirect(svc, other, null, .background);
    demand.adjustDirect(svc, root, .background, .visible);
    try checkTree(svc);
    var path: [4096]u8 = undefined;
    try std.testing.expectEqual(root, svc.take(&path).?.work.scan.ref.id);
    svc.retryScan(root);
    demand.adjustDirect(svc, root, .visible, null);
    try checkTree(svc);
    try std.testing.expectEqual(other, svc.take(&path).?.work.scan.ref.id);
    svc.nodes.items[other].rescan = true;
    try svc.finishScan(other, 3, &.{}, false);
    try std.testing.expect(!svc.nodes.items[other].complete);
    try std.testing.expectEqual(@as(u32, 1), svc.nodes.items[other].pending);
    try std.testing.expectEqual(other, svc.take(&path).?.work.scan.ref.id);
    try svc.finishScan(other, 4, &.{}, false);
    try std.testing.expect(svc.nodes.items[other].complete);
    demand.adjustDirect(svc, root, null, .visible);
    try std.testing.expectEqual(root, svc.take(&path).?.work.scan.ref.id);
    try std.testing.expectEqual(child, svc.take(&path).?.work.scan.ref.id);
    demand.adjustDirect(svc, root, .visible, null);
    svc.retryScan(root);
    svc.retryScan(child);
    try std.testing.expectEqual(@as(usize, 0), svc.queued_count);
    try std.testing.expectEqual(@as(u32, 2), svc.nodes.items[root].pending);
    try std.testing.expect(!svc.nodes.items[root].complete);
    try std.testing.expect(!failing.has_induced_failure);
    try checkTree(svc);
}
