//! Shared folder measurements with independently owned demand.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const want = std.testing.expect;
const equal = std.testing.expectEqual;

fn auto(_: u32, _: u32, _: ?u64) ?bool {
    return true;
}

fn key(ino: u64) tree.Key {
    return .{ .dev = 1, .ino = ino };
}

fn resolve(svc: *Service, path: []const u8, ino: u64) !tree.Id {
    var buf: [4096]u8 = undefined;
    const job = switch (svc.take(&buf).?.work) {
        .resolve => |job| job,
        .scan => return error.UnexpectedScan,
    };
    defer job.deinit(svc.allocator);
    try std.testing.expectEqualStrings(path, job.path);
    try want(!svc.resolved(job, key(ino), true));
    return svc.by_key.get(key(ino)).?;
}

fn discovered(ino: u64, name: []const u8) Service.Child {
    return .{ .key = key(ino), .name = @constCast(name) };
}

test "sizetree owners request idempotently and stop and close independently" {
    const svc = try Service.create(std.testing.allocator, 0, auto);
    defer svc.destroy();
    var first = svc.registerOwner();
    defer first.deinit();
    var second = svc.registerOwner();
    var second_open = true;
    defer if (second_open) second.deinit();

    for (0..10) |_| svc.request(&first, "/root", .visible, .{});
    svc.request(&second, "/root", .background, .{ .force = true });
    const path = svc.paths.get("/root").?;
    try equal(@as(usize, 2), path.owners);
    try equal([2]usize{ 1, 0 }, path.automatic);
    try want(svc.resolve_ready[0].first == path and svc.resolve_ready[0].last == path);
    const root = try resolve(svc, "/root", 1);
    try equal(@as(?tree.Level, .visible), svc.nodes.items[root].queued);

    svc.stopPath(&first, "/root");
    first.clear(); // Navigating away and back preserves this view's Stop.
    svc.request(&first, "/root", .visible, .{});
    try equal(tree.Status.idle, svc.lookupOwned(&first, "/root").status);
    try equal(tree.Status.measuring, svc.lookupOwned(&second, "/root").status);
    try equal(@as(?tree.Level, .background), svc.nodes.items[root].queued);

    svc.request(&first, "/root", .visible, .{ .force = true });
    try equal(@as(?tree.Level, .visible), svc.nodes.items[root].queued);
    second.deinit();
    second_open = false;
    try equal(@as(?tree.Level, .visible), svc.nodes.items[root].queued);
    svc.unqueue(root);
    try svc.finishScan(root, 19, &.{}, false);
    first.clear();
    try want(!svc.rootHasDemand(root));
    try equal(@as(usize, 0), path.owners);
    try equal(@as(i64, 19), svc.lookup("/root").bytes);
}

test "sizetree dropping an ancestor or descendant keeps the other request active" {
    for ([_]bool{ false, true }) |ancestor_first| {
        const svc = try Service.create(std.testing.allocator, 0, auto);
        defer svc.destroy();
        var descendant = svc.registerOwner();
        defer descendant.deinit();
        var ancestor = svc.registerOwner();
        defer ancestor.deinit();
        svc.request(&descendant, "/root/child", .background, .{});
        const child = try resolve(svc, "/root/child", 2);
        svc.unqueue(child);
        svc.request(&ancestor, "/root", .visible, .{});
        const root = try resolve(svc, "/root", 1);
        svc.unqueue(root);
        try svc.finishScan(root, 0, &.{discovered(2, "child")}, false);
        try equal(@as(usize, 2), svc.nodes.items[root].subtree_demand);
        try equal(@as(?tree.Level, .visible), svc.nodes.items[child].queued);

        if (ancestor_first) {
            ancestor.clear();
            try want(svc.nodes.items[root].paused);
            try equal(@as(?tree.Level, .background), svc.nodes.items[child].queued);
            descendant.clear();
        } else {
            descendant.clear();
            try equal(@as(?tree.Level, .visible), svc.nodes.items[child].queued);
            ancestor.clear();
        }
        try want(!svc.rootHasDemand(root));
        try equal(@as(?tree.Level, null), svc.nodes.items[child].queued);
        try equal(@as(usize, 0), svc.queued_count);
    }
}

test "sizetree viewport changes release automatic demand and retain explicit measurements" {
    const svc = try Service.create(std.testing.allocator, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    owner.beginViewport();
    svc.request(&owner, "/explicit", .visible, .{});
    svc.request(&owner, "/automatic", .visible, .{});
    svc.request(&owner, "/explicit", .background, .{ .force = true });
    owner.endViewport();
    const explicit = try resolve(svc, "/explicit", 1);
    svc.unqueue(explicit);
    const automatic = try resolve(svc, "/automatic", 2);
    svc.unqueue(automatic);
    svc.enqueue(explicit, .visible);
    svc.enqueue(automatic, .visible);
    owner.beginViewport();
    owner.endViewport();
    try want(svc.rootHasDemand(explicit));
    try want(!svc.rootHasDemand(automatic));
    try equal(@as(?tree.Level, .background), svc.nodes.items[explicit].queued);
    try equal(@as(?tree.Level, null), svc.nodes.items[automatic].queued);
    owner.clear();
    try want(!svc.busy());
}

test "sizetree keeps demand across a move and re-resolves a deleted binding" {
    const svc = try Service.create(std.testing.allocator, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    const source = try svc.newNode(key(1), "/source", .background);
    const dest = try svc.newNode(key(2), "/dest", .background);
    const child = try svc.newNode(key(3), "child", .background);
    try svc.attach(source, child);
    svc.request(&owner, "/source/child", .visible, .{ .force = true });
    try equal(child, try resolve(svc, "/source/child", 3));
    const old_ref = svc.refOf(child);
    try want(svc.rootHasDemand(source));
    try want(!svc.rootHasDemand(dest));

    try svc.finishScan(dest, 7, &.{discovered(3, "renamed")}, false);
    try want(!svc.rootHasDemand(source));
    try want(svc.rootHasDemand(dest));
    var path: [4096]u8 = undefined;
    const scan = svc.take(&path).?;
    try equal(child, svc.liveId(scan.work.scan.ref).?);
    try std.testing.expectEqualStrings("/dest/renamed", scan.path.?);
    try svc.finishScan(dest, 7, &.{}, false);
    try want(!svc.rootHasDemand(dest));
    try equal(@as(?tree.Id, null), svc.liveId(old_ref));
    const replacement = try resolve(svc, "/source/child", 4);
    try equal(child, replacement);
    try want(svc.rootHasDemand(replacement));
    try equal(@as(?tree.Id, null), svc.liveId(old_ref));
}

test "sizetree releasing the last owner needs no allocation and rejects in-flight work" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var first = svc.registerOwner();
    defer first.deinit();
    var last = svc.registerOwner();
    var last_open = true;
    defer if (last_open) last.deinit();

    svc.request(&first, "/inflight", .visible, .{});
    svc.request(&last, "/inflight", .visible, .{});
    svc.request(&last, "/queued", .visible, .{});
    var path: [4096]u8 = undefined;
    const job = svc.take(&path).?.work.resolve;
    defer job.deinit(a);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    first.clear();
    try want(svc.paths.get("/inflight").?.resolution != null);
    last.deinit();
    last_open = false;
    try want(!svc.busy());
    try want(!svc.resolved(job, key(1), true));
    try equal(@as(u32, 0), svc.by_key.count());
    try want(!failing.has_induced_failure);
}

test "sizetree retries an independently demanded child when its parent's recovery is cancelled" {
    const svc = try Service.create(std.testing.allocator, 0, auto);
    defer svc.destroy();
    var ancestor = svc.registerOwner();
    defer ancestor.deinit();
    var descendant = svc.registerOwner();
    defer descendant.deinit();

    svc.request(&descendant, "/root/child", .visible, .{});
    const child = try resolve(svc, "/root/child", 2);
    svc.unqueue(child);
    svc.request(&ancestor, "/root", .visible, .{});
    const root = try resolve(svc, "/root", 1);
    svc.unqueue(root);
    try svc.finishScan(root, 0, &.{discovered(2, "child")}, false);
    var buf: [4096]u8 = undefined;
    const scan = svc.take(&buf).?;
    try equal(child, scan.work.scan.ref.id);
    svc.lostScan(child, scan.path.?);
    try want(svc.nodes.items[child].waiting_for_parent);
    try equal(@as(?tree.Level, .visible), svc.nodes.items[root].queued);

    ancestor.clear();
    try equal(@as(?tree.Level, null), svc.nodes.items[root].queued);
    try equal(@as(?tree.Level, .visible), svc.nodes.items[child].queued);
    const retry = svc.take(&buf).?;
    try equal(child, retry.work.scan.ref.id);
    svc.lostScan(child, retry.path.?);
    try equal(child, try resolve(svc, "/root/child", 2));
    try equal(@as(?tree.Level, .visible), svc.nodes.items[child].queued);
}

test "sizetree promotes and demotes queued resolution with owner demand" {
    const svc = try Service.create(std.testing.allocator, 0, auto);
    defer svc.destroy();
    var background = svc.registerOwner();
    defer background.deinit();
    var foreground = svc.registerOwner();
    defer foreground.deinit();

    svc.request(&background, "/shared", .background, .{});
    svc.request(&foreground, "/shared", .visible, .{});
    const entry = svc.paths.get("/shared").?;
    const token = entry.resolution.?;
    try equal(@as(?tree.Level, .visible), entry.queued);
    svc.request(&foreground, "/next", .visible, .{});
    svc.forgetPath(&foreground, "/shared");
    try equal(@as(?tree.Level, .background), entry.queued);
    try equal(@as(?u64, token), entry.resolution);
    const next = try resolve(svc, "/next", 1);
    svc.unqueue(next);
    _ = try resolve(svc, "/shared", 2);
}
