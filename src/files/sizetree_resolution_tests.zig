//! Deterministic ownership, cancellation, and allocation tests for resolution.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Resolution = tree.Resolution;

fn auto(_: u32, _: u32) bool {
    return true;
}

fn key(ino: u64) tree.Key {
    return .{ .dev = 1, .ino = ino };
}

fn takeResolution(svc: *Service) !Resolution {
    var buf: [4096]u8 = undefined;
    return switch (svc.take(&buf).?.work) {
        .resolve => |job| job,
        .scan => error.UnexpectedScan,
    };
}

test "sizetree retries each path and resolution queue allocation failure" {
    // Path entry, key, path map, viewport list, and owner map.
    for (0..5) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const a = failing.allocator();
        const svc = try Service.create(a, 0, auto);
        defer svc.destroy();
        var owner = svc.registerOwner();
        defer owner.deinit();

        failing.fail_index = failing.alloc_index + offset;
        svc.request(&owner, "/root", .visible, .{});
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(!svc.busy());
        try std.testing.expectEqual(tree.Status.unknown, svc.lookup("/root").status);
        try std.testing.expect(!@import("sizetree_resolution.zig").hasReady(svc));

        failing.fail_index = std.math.maxInt(usize);
        svc.request(&owner, "/root", .visible, .{});
        try std.testing.expect(svc.busy());
        // A queued job already owns everything needed for dispatch.
        failing.fail_index = failing.alloc_index;
        const job = try takeResolution(svc);
        defer job.deinit(a);
        try std.testing.expectEqualStrings("/root", job.path);
        failing.fail_index = std.math.maxInt(usize);
        _ = svc.resolved(job, key(1), true);
        try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
    }
}

test "sizetree reschedules resolution on node allocation failure" {
    // Node name, inode index, inactive-root heap, and node storage.
    for (0..4) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const a = failing.allocator();
        const svc = try Service.create(a, 0, auto);
        defer svc.destroy();
        var owner = svc.registerOwner();
        defer owner.deinit();
        svc.request(&owner, "/root", .visible, .{});
        const first = try takeResolution(svc);
        defer first.deinit(a);

        failing.fail_index = failing.alloc_index + offset;
        _ = svc.resolved(first, key(1), true);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(tree.Status.measuring, svc.lookup("/root").status);
        try std.testing.expectEqual(@as(usize, 0), svc.nodes.items.len);
        try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());

        failing.fail_index = std.math.maxInt(usize);
        svc.request(&owner, "/root", .visible, .{});
        const second = try takeResolution(svc);
        defer second.deinit(a);
        try std.testing.expect(first.id != second.id);
        _ = svc.resolved(second, key(1), true);
        try std.testing.expectEqual(tree.Status.measuring, svc.lookup("/root").status);
        try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
        try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
    }
}

test "sizetree skips queued jobs cancelled by stop or forget" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/stopped", .visible, .{});
    svc.request(&owner, "/forgotten", .visible, .{});
    svc.stopPath(&owner, "/stopped");
    svc.forgetPath(&owner, "/forgotten");
    try std.testing.expect(!svc.busy());
    svc.request(&owner, "/stopped", .visible, .{});
    try std.testing.expect(!svc.busy());

    // Re-request both before dispatch. Only the new jobs are eligible.
    svc.request(&owner, "/forgotten", .background, .{});
    svc.request(&owner, "/stopped", .visible, .{ .force = true });
    const stopped = try takeResolution(svc);
    defer stopped.deinit(a);
    const forgotten = try takeResolution(svc);
    defer forgotten.deinit(a);
    try std.testing.expectEqualStrings("/forgotten", forgotten.path);
    try std.testing.expectEqualStrings("/stopped", stopped.path);
    try std.testing.expect(!@import("sizetree_resolution.zig").hasReady(svc));
    _ = svc.resolved(forgotten, key(1), true);
    _ = svc.resolved(stopped, key(2), false);
    try std.testing.expectEqual(@as(usize, 2), svc.queued_count);
}

test "sizetree ignores cancelled in-flight results without touching another subtree" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    const other = try svc.newNode(key(1), "/other", .visible);
    const child = try svc.newNode(key(2), "child", .visible);
    try svc.attach(other, child);

    svc.request(&owner, "/stopped", .visible, .{});
    const stopped = try takeResolution(svc);
    defer stopped.deinit(a);
    svc.request(&owner, "/forgotten", .visible, .{});
    const forgotten = try takeResolution(svc);
    defer forgotten.deinit(a);
    @import("sizetree_demand.zig").adjustDirect(svc, other, null, .visible);

    svc.stopPath(&owner, stopped.path);
    svc.forgetPath(&owner, forgotten.path);
    const before = svc.generation.load(.acquire);
    _ = svc.resolved(stopped, key(1), true);
    _ = svc.resolved(forgotten, key(3), true);
    try std.testing.expectEqual(before, svc.generation.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), svc.by_key.count());
    try std.testing.expectEqual(@as(usize, 2), svc.queued_count);
    try std.testing.expect(!svc.nodes.items[other].paused and !svc.nodes.items[child].paused);
    try std.testing.expect(svc.paths.get(stopped.path).?.node == tree.no_id);
    try std.testing.expect(svc.paths.get(forgotten.path).?.node == tree.no_id);
}

test "sizetree repeated requests keep one resolution and use the latest priority and force" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/root", .background, .{});
    svc.request(&owner, "/root", .background, .{});
    try std.testing.expect(svc.resolve_ready[1].first != null and svc.resolve_ready[1].first == svc.resolve_ready[1].last);
    const job = try takeResolution(svc);
    defer job.deinit(a);
    svc.request(&owner, "/root", .visible, .{ .force = true });
    svc.request(&owner, "/root", .background, .{});
    try std.testing.expect(!@import("sizetree_resolution.zig").hasReady(svc));
    _ = svc.resolved(job, key(1), false);
    const id = svc.by_key.get(key(1)).?;
    try std.testing.expectEqual(@as(?tree.Level, .visible), svc.nodes.items[id].queued);
    _ = svc.resolved(job, key(2), true);
    try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
}

test "sizetree resolution jobs outlive removed keys and cannot publish into recreated entries" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    // Simulate future removal directly in the fixture, after releasing
    // the owner and unlinking ready work. The in-flight job keeps its pin.
    svc.request(&owner, "/root", .background, .{});
    const old = try takeResolution(svc);
    defer old.deinit(a);
    svc.forgetPath(&owner, "/root");
    svc.paths.fetchRemove("/root").?.value.release(a);
    try std.testing.expectEqualStrings("/root", old.path);
    _ = svc.resolved(old, key(1), true);
    try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());
    svc.request(&owner, "/root", .visible, .{});
    _ = svc.resolved(old, key(1), true);
    try std.testing.expectEqual(tree.Status.measuring, svc.lookup("/root").status);
    try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());

    const fresh = try takeResolution(svc);
    defer fresh.deinit(a);
    try std.testing.expect(old.id != fresh.id);
    _ = svc.resolved(fresh, key(2), true);
    _ = svc.resolved(old, null, false);
    const id = svc.by_key.get(key(2)).?;
    try std.testing.expectEqual(id, svc.paths.get("/root").?.node);
    try std.testing.expect(svc.by_key.get(key(1)) == null);
}

test "sizetree queues re-resolution of a missing root without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/root", .visible, .{});
    const first = try takeResolution(svc);
    defer first.deinit(a);
    _ = svc.resolved(first, key(1), true);
    var buf: [4096]u8 = undefined;
    const scan = svc.take(&buf).?;
    const id = scan.work.scan.ref.id;

    failing.fail_index = failing.alloc_index;
    svc.lostScan(id, scan.path.?);
    const second = try takeResolution(svc);
    defer second.deinit(a);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(tree.Status.measuring, svc.lookup("/root").status);

    failing.fail_index = std.math.maxInt(usize);
    _ = svc.resolved(second, key(2), true);
    const new_id = svc.paths.get("/root").?.node;
    try std.testing.expectEqual(new_id, svc.by_key.get(key(2)).?);
    try std.testing.expect(new_id != id);
    try std.testing.expectEqual(@as(?tree.Level, .visible), svc.nodes.items[new_id].queued);
}
