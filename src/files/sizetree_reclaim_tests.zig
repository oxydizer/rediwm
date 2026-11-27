//! Verify allocated capacities and exercise worker interleavings directly.
const std = @import("std");
const c = @import("c.zig").api;
const tree = @import("sizetree.zig");
const reclaim = @import("sizetree_reclaim.zig");
const resolution = @import("sizetree_resolution.zig");
const worker = @import("sizetree_worker.zig");
const Service = tree.Service;
const Id = tree.Id;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const peak = 1200;

fn auto(_: u32, _: u32) bool {
    return true;
}

fn key(ino: u64) tree.Key {
    return .{ .dev = 1, .ino = ino };
}

fn bind(svc: *Service, owner: *tree.Owner, path: []const u8, ino: u64) !Id {
    try expect(svc.requestOwned(owner, path, .visible, .{}));
    const job = resolution.take(svc) orelse return error.MissingResolution;
    defer job.deinit(svc.allocator);
    try std.testing.expectEqualStrings(path, job.path);
    try expect(!svc.resolved(job, key(ino), true));
    return svc.by_key.get(key(ino)).?;
}

fn child(ino: u64) Service.Child {
    return .{ .key = key(ino), .name = @constCast("member") };
}

fn finish(svc: *Service, id: Id, bytes: i64, found: []const Service.Child) !void {
    svc.unqueue(id);
    try svc.finishScan(id, bytes, found, false);
}

test "sizetree reclaims scattered slots and shared containers while preserving work and LRU order" {
    const svc = try Service.createWithBudgets(std.testing.allocator, 0, auto, .{ .path_entries = 6 });
    defer svc.destroy();
    var old = svc.registerOwner();
    defer old.deinit();
    var burst = svc.registerOwner();
    defer burst.deinit();
    var active = svc.registerOwner();
    defer active.deinit();

    const first = try bind(svc, &old, "/first", 1);
    try finish(svc, first, 11, &.{});
    const bulk = try bind(svc, &burst, "/bulk", 2);
    var children: [peak]Service.Child = undefined;
    for (&children, 100..) |*item, ino| item.* = child(ino);
    try finish(svc, bulk, 1, &children);
    var path_buf: [4096]u8 = undefined;
    const stale = svc.take(&path_buf).?.work.scan.ref;
    for (0..peak) |i| {
        var name: [32]u8 = undefined;
        try expect(svc.requestOwned(&burst, try std.fmt.bufPrint(&name, "/bulk/{d}", .{i}), .visible, .{}));
    }
    // Retain the peak while creating a live island beyond the soon-dead slots.
    // The pending bulk paths must not get in the way of the test resolutions.
    for (0..peak) |i| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "/bulk/{d}", .{i});
        svc.stopPath(&burst, path);
    }
    const root = try bind(svc, &active, "/root", 3);
    var direct_children: [200]Service.Child = undefined;
    direct_children[0] = child(4);
    for (direct_children[1..], 2000..) |*item, ino| item.* = child(ino);
    try finish(svc, root, 21, &direct_children);
    try finish(svc, root, 21, direct_children[0..1]);
    const member = svc.by_key.get(key(4)).?;
    try finish(svc, member, 31, &.{ child(5), .{ .key = key(6), .name = @constCast("other") } });
    const nested = try bind(svc, &active, "/root/member/member", 5);
    const latest = try bind(svc, &old, "/latest", 7);
    try finish(svc, latest, 71, &.{});
    svc.forgetPath(&active, "/root"); // Only the independently demanded descendant protects this root.
    svc.forgetPath(&active, "/root/member/member");
    svc.lostScan(member, "/root/member");
    var recovery = svc.registerOwner();
    defer recovery.deinit();
    try equal(member, try bind(svc, &recovery, "/moved", 4));
    try finish(svc, member, 31, &.{ child(5), .{ .key = key(6), .name = @constCast("other") } });
    _ = try bind(svc, &active, "/moved/member", 5);
    _ = try bind(svc, &active, "/moved/other", 6);
    recovery.clear();
    try expect(svc.nodes.items[member].path_missing);

    svc.live_node_budget = 6;
    burst.deinit(); // Releases retained Stops as well as the large root.
    burst = svc.registerOwner();
    old.clear();
    try expect(!svc.by_key.contains(key(2)));
    try equal(@as(usize, 6), svc.liveNodeCount());
    const other_id = svc.by_key.get(key(6)).?;
    svc.unqueue(nested);
    svc.unqueue(other_id);
    svc.enqueue(nested, .visible);
    svc.enqueue(other_id, .visible);
    const in_flight = svc.take(&path_buf).?.work.scan.ref;
    try equal(nested, in_flight.id);
    try std.testing.expectEqualStrings("/moved/member", std.mem.sliceTo(&path_buf, 0));
    svc.request(&active, "/resolving", .background, .{});
    const resolving = resolution.take(svc).?;
    defer resolving.deinit(svc.allocator);
    svc.request(&active, "/queued", .background, .{});
    try expect(svc.nodes.items.len > peak);
    try expect(svc.nodes.capacity > 4 * 256);
    try expect(svc.by_key.capacity() > 4 * 256);
    try expect(svc.inactive_roots.capacity > 4 * 256);
    try expect(svc.paths.capacity() > 4 * 256);
    try expect(svc.inactive_paths.capacity > 4 * 256);
    try equal(first, svc.inactive_roots.items[0]);
    const oldest_path = svc.inactive_paths.items[0];
    const queued_count = svc.queued_count;

    while (reclaim.sharedOversized(svc)) try reclaim.pass(svc);
    try reclaim.pass(svc); // The queued child-array candidate moved with the root.

    try equal(@as(usize, 6), svc.nodes.items.len);
    try equal(@as(usize, 256), svc.nodes.capacity);
    try equal(@as(u32, 512), svc.by_key.capacity());
    try equal(@as(usize, 256), svc.inactive_roots.capacity);
    try equal(@as(u32, 512), svc.paths.capacity());
    try equal(@as(usize, 256), svc.inactive_paths.capacity);
    try equal(tree.no_id, svc.free_head);
    try equal(key(1), svc.nodes.items[svc.inactive_roots.items[0]].key);
    try equal(oldest_path, svc.inactive_paths.items[0]);
    try equal(queued_count, svc.queued_count);
    try equal(@as(?Id, null), svc.liveId(stale));
    const mapped_root = svc.by_key.get(key(3)).?;
    const mapped_member = svc.by_key.get(key(4)).?;
    const mapped_nested = svc.liveId(in_flight).?;
    try expect(root != mapped_root and member != mapped_member and nested != mapped_nested);
    try equal(mapped_member, svc.paths.get("/moved").?.node);
    try equal(mapped_nested, svc.paths.get("/moved/member").?.node);
    try equal(mapped_member, svc.nodes.items[mapped_nested].parent);
    try equal(@as(usize, 32), svc.nodes.items[mapped_root].children.capacity);
    try equal(@as(usize, 2), svc.nodes.items[mapped_root].subtree_demand);
    try equal(@as(i64, 52), svc.nodes.items[mapped_root].total);
    try equal(@as(u32, 2), svc.nodes.items[mapped_root].pending);
    try finish(svc, mapped_nested, 41, &.{});
    const queued = svc.take(&path_buf).?.work.resolve;
    defer queued.deinit(svc.allocator);
    try std.testing.expectEqualStrings("/queued", queued.path);
    const other = svc.take(&path_buf).?;
    try equal(key(6), other.work.scan.ref.key);
    try std.testing.expectEqualStrings("/moved/other", other.path.?);
    try finish(svc, svc.liveId(other.work.scan.ref).?, 51, &.{});
    try equal(@as(i64, 144), svc.nodes.items[mapped_root].total);
    try equal(@as(u32, 0), svc.nodes.items[mapped_root].pending);

    try expect(!svc.resolved(resolving, stale.key, true));
    try equal(@as(?Id, null), svc.liveId(stale));
    try expect(!svc.by_key.contains(key(1))); // Dispatch and eviction still honor the original LRU.
    try expect(!svc.resolved(queued, key(8), true));
    try equal(@as(Id, 0), svc.by_key.get(key(8)).?); // Reuse an ID freed after compaction.
}

test "sizetree node compaction publishes nothing when any preparation allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const svc = try Service.create(failing.allocator(), 0, auto);
    defer svc.destroy();
    for (1..peak) |ino| _ = try svc.newNode(key(ino), "/old", .background);
    const last = try svc.newNode(key(peak), "/keep", .visible);
    const ref = svc.refOf(last);
    for (0..last) |id| svc.freeSubtree(@intCast(id), .evicted);
    const nodes = svc.nodes.items.ptr;
    const roots = svc.inactive_roots.items.ptr;
    const free_head = svc.free_head;
    var capacity = svc.nodes.capacity;

    for (0..4) |allocation| {
        failing.fail_index = failing.alloc_index + allocation;
        try std.testing.expectError(error.OutOfMemory, reclaim.pass(svc));
        try equal(nodes, svc.nodes.items.ptr);
        try equal(roots, svc.inactive_roots.items.ptr);
        try equal(capacity, svc.nodes.capacity);
        try equal(free_head, svc.free_head);
        try equal(last, svc.liveId(ref).?);
        try equal(last, svc.by_key.get(key(peak)).?);
    }
    failing.fail_index = std.math.maxInt(usize);
    try reclaim.pass(svc);
    try equal(@as(Id, 0), svc.liveId(ref).?);
    capacity = svc.nodes.capacity;
    const allocations = failing.allocations;
    for (0..10) |_| try reclaim.pass(svc);
    try equal(allocations, failing.allocations);
    try equal(capacity, svc.nodes.capacity);
}

test "sizetree reclaims child and owner capacities with headroom across two growth cycles" {
    const svc = try Service.create(std.testing.allocator, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    const root = try bind(svc, &owner, "/root", 1);
    for (0..2) |_| {
        var children: [200]Service.Child = undefined;
        for (&children, 2..) |*item, ino| item.* = child(ino);
        try finish(svc, root, 23, &children);
        owner.beginViewport();
        for (0..200) |i| {
            var name: [32]u8 = undefined;
            try expect(svc.requestOwned(&owner, try std.fmt.bufPrint(&name, "/view/{d}", .{i}), .visible, .{}));
        }
        owner.endViewport();
        svc.stopPath(&owner, "/view/0");
        const storage = owner.storage.?;
        try expect(storage.visible.capacity >= 200);
        try expect(storage.records.capacity() >= 200);
        try expect(svc.nodes.items[root].children.capacity >= 200);

        try finish(svc, root, 29, children[0..2]);
        owner.beginViewport();
        svc.request(&owner, "/root", .visible, .{});
        svc.request(&owner, "/view/1", .visible, .{});
        owner.endViewport();
        try expect(svc.rootHasDemand(root));
        try reclaim.pass(svc);
        try equal(@as(usize, 32), svc.nodes.items[root].children.capacity);
        try equal(@as(usize, 32), storage.visible.capacity);
        try equal(@as(u32, 64), storage.records.capacity());
        try equal(@as(i64, 29), svc.lookup("/root").bytes);
        try equal(tree.Status.idle, svc.lookupOwned(&owner, "/view/0").status);

        // Modest regrowth leaves the same allocations in place.
        const children_ptr = svc.nodes.items[root].children.items.ptr;
        const visible_ptr = storage.visible.items.ptr;
        try finish(svc, root, 29, children[0..16]);
        svc.request(&owner, "/view/2", .visible, .{});
        try reclaim.pass(svc);
        try equal(children_ptr, svc.nodes.items[root].children.items.ptr);
        try equal(visible_ptr, storage.visible.items.ptr);
        try equal(@as(usize, 3), storage.visible.items.len);
    }
}

test "sizetree workers reuse large scratch on large reads and release it after small reads or idle" {
    const a = std.testing.allocator;
    var scratch: worker.Scratch = .{};
    defer scratch.deinit(a);
    try scratch.found.resize(a, 8192);
    try scratch.names.resize(a, 512 * 1024);
    const found_capacity = scratch.found.capacity;
    const names_capacity = scratch.names.capacity;
    scratch.releaseExcess(a, false);
    try equal(found_capacity, scratch.found.capacity);
    try equal(names_capacity, scratch.names.capacity);
    scratch.found.shrinkRetainingCapacity(20);
    scratch.names.shrinkRetainingCapacity(200);
    scratch.releaseExcess(a, false);
    try equal(@as(usize, 0), scratch.found.capacity);
    try equal(@as(usize, 0), scratch.names.capacity);
    try scratch.found.resize(a, 8192);
    try scratch.names.resize(a, 512 * 1024);
    scratch.releaseExcess(a, true);
    try equal(@as(usize, 0), scratch.found.capacity);
    try equal(@as(usize, 0), scratch.names.capacity);
}

test "sizetree device policy memoization bounds storage and checks identity on collisions" {
    var cache: resolution.DevicePolicyCache = .{};
    for (0..4096) |dev| {
        cache.put(dev, dev % 2 == 0);
        try equal(@as(?bool, dev % 2 == 0), cache.get(dev));
    }
    try equal(@as(usize, 256), cache.slots.len);
    var retained: usize = 0;
    for (0..4096) |dev| {
        if (cache.get(dev)) |allowed| {
            try equal(dev % 2 == 0, allowed);
            retained += 1;
        }
    }
    try expect(retained > 0 and retained <= cache.slots.len);
}

test "sizetree idle worker retries reclamation without further requests" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const svc = try Service.createWithBudget(failing.allocator(), 1, auto, 1);
    defer svc.destroy();
    {
        svc.lock();
        defer svc.unlock();
        for (0..peak) |ino| _ = try svc.newNode(key(ino), "/old", .background);
        failing.fail_index = failing.alloc_index;
        svc.maintainBudget();
        try equal(@as(usize, 1), svc.liveNodeCount());
        try expect(!failing.has_induced_failure);
        try expect(svc.nodes.capacity > 4 * 256);
    }
    try waitForMaintenance(svc, true);
    svc.lock();
    failing.fail_index = std.math.maxInt(usize);
    svc.unlock();
    try waitForMaintenance(svc, false);
}

fn waitForMaintenance(svc: *Service, failed: bool) !void {
    const start = tree.nowMs();
    while (tree.nowMs() - start < 5000) {
        svc.lock();
        const ready = if (failed) svc.reclamation.retry_after_ms != 0 else svc.nodes.capacity == 256;
        svc.unlock();
        if (ready) return;
        const delay: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 10 * std.time.ns_per_ms };
        _ = c.nanosleep(&delay, null);
    }
    return error.MaintenanceTimedOut;
}
