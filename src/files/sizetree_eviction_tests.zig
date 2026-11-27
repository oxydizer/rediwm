//! Small-budget tests exercise LRU and worker interleavings without threads.
const std = @import("std");
const tree = @import("sizetree.zig");
const resolution = @import("sizetree_resolution.zig");
const Service = tree.Service;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn auto(_: u32, _: u32, _: ?u64) ?bool {
    return true;
}

fn key(ino: u64) tree.Key {
    return .{ .dev = 1, .ino = ino };
}

fn child(ino: u64, name: []const u8) Service.Child {
    return .{ .key = key(ino), .name = @constCast(name) };
}

fn request(svc: *Service, owner: *tree.Owner, path: []const u8, ino: u64) !tree.Id {
    svc.request(owner, path, .visible, .{});
    const job = resolution.take(svc) orelse return error.MissingResolution;
    defer job.deinit(svc.allocator);
    try std.testing.expectEqualStrings(path, job.path);
    try expect(!svc.resolved(job, key(ino), true));
    return svc.by_key.get(key(ino)) orelse error.MissingNode;
}

fn finish(svc: *Service, id: tree.Id, bytes: i64, found: []const Service.Child) !void {
    svc.unqueue(id);
    try svc.finishScan(id, bytes, found, false);
}

test "sizetree evicts the oldest whole root and a lookup or request refreshes recency" {
    const svc = try Service.createWithBudget(std.testing.allocator, 0, auto, 4);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    const first = try request(svc, &owner, "/first", 1);
    try finish(svc, first, 1, &.{child(2, "child")});
    const first_child = try request(svc, &owner, "/first/child", 2);
    try finish(svc, first_child, 2, &.{});
    const second = try request(svc, &owner, "/second", 3);
    try finish(svc, second, 3, &.{});
    const third = try request(svc, &owner, "/third", 4);
    try finish(svc, third, 4, &.{});
    owner.clear();

    try equal(@as(i64, 2), svc.lookup("/first/child").bytes);
    svc.request(&owner, "/second", .visible, .{});
    owner.clear();
    // A scan that finishes after demand disappears does not refresh recency.
    try finish(svc, third, 9, &.{});
    const fourth = try request(svc, &owner, "/fourth", 5);
    try equal(tree.Status.unknown, svc.lookup("/third").status);
    try expect(!svc.by_key.contains(key(4)));
    try expect(svc.by_key.contains(key(1)) and svc.by_key.contains(key(3)));

    // A background scan grows an active root, but does not touch the LRU.
    // The two-node first root is now the oldest and must disappear together.
    try finish(svc, fourth, 5, &.{child(6, "child")});
    svc.maintainBudget();
    try equal(@as(usize, 3), svc.liveNodeCount());
    try expect(!svc.by_key.contains(key(1)) and !svc.by_key.contains(key(2)));
    try equal(tree.Status.unknown, svc.lookup("/first/child").status);
    try equal(@as(i64, 3), svc.lookup("/second").bytes);
    try equal(@as(i64, 5), svc.nodes.items[fourth].total);
    try equal(@as(u32, 1), svc.nodes.items[fourth].pending);

    const restored = try request(svc, &owner, "/first", 1);
    try finish(svc, restored, 11, &.{});
    try equal(@as(i64, 11), svc.lookup("/first").bytes);
}

test "sizetree protects over-budget trees until the last descendant owner releases demand" {
    const svc = try Service.createWithBudget(std.testing.allocator, 0, auto, 1);
    defer svc.destroy();
    var root_owner = svc.registerOwner();
    defer root_owner.deinit();
    var child_owner = svc.registerOwner();
    defer child_owner.deinit();
    var other_owner = svc.registerOwner();
    defer other_owner.deinit();

    const root = try request(svc, &root_owner, "/root", 1);
    try finish(svc, root, 13, &.{child(2, "child")});
    const member = try request(svc, &child_owner, "/root/child", 2);
    try finish(svc, member, 23, &.{});
    const other = try request(svc, &other_owner, "/other", 3);
    root_owner.clear();
    try expect(svc.rootHasDemand(root) and svc.rootHasDemand(other));
    try equal(@as(usize, 3), svc.liveNodeCount());
    try equal(@as(i64, 36), svc.lookup("/root").bytes);
    try equal(@as(u32, 0), svc.nodes.items[root].pending);

    child_owner.clear();
    try equal(@as(usize, 1), svc.liveNodeCount());
    try expect(!svc.by_key.contains(key(1)) and !svc.by_key.contains(key(2)));
    try expect(svc.rootHasDemand(other));
    try equal(@as(u32, 1), svc.nodes.items[other].pending);
}

test "sizetree moves root recency and descendant demand with reconciled subtrees" {
    const svc = try Service.createWithBudget(std.testing.allocator, 0, auto, 4);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    var member_owner = svc.registerOwner();
    defer member_owner.deinit();

    const source = try request(svc, &owner, "/source", 1);
    const dest = try request(svc, &owner, "/dest", 2);
    const old = try request(svc, &owner, "/old", 3);
    try finish(svc, old, 3, &.{});
    owner.clear();
    const member = try request(svc, &member_owner, "/source/member", 4);
    try finish(svc, member, 7, &.{});
    try finish(svc, source, 11, &.{child(4, "member")});
    try expect(svc.rootHasDemand(source));
    try finish(svc, dest, 13, &.{child(4, "moved")});
    try expect(!svc.rootHasDemand(source) and svc.rootHasDemand(dest));
    try equal(dest, svc.nodes.items[member].parent);
    try equal(@as(i64, 11), svc.nodes.items[source].total);
    try equal(@as(i64, 20), svc.nodes.items[dest].total);
    try equal(@as(u32, 0), svc.nodes.items[dest].pending);

    member_owner.clear();
    _ = try request(svc, &owner, "/fresh", 5);
    // The child's request made both merged trees newer than /old. It must
    // never remain indexed as a standalone victim after either attachment.
    try expect(!svc.by_key.contains(key(3)));
    try expect(svc.by_key.contains(key(1)) and svc.by_key.contains(key(4)));
    try equal(@as(i64, 20), svc.lookup("/dest").bytes);
}

test "sizetree evicts an in-flight scan without allocating and preserves unresolved work" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const svc = try Service.createWithBudget(a, 0, auto, 0);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    var unresolved = svc.registerOwner();
    defer unresolved.deinit();

    const root = try request(svc, &owner, "/root", 1);
    try finish(svc, root, 11, &.{ child(2, "one"), child(3, "two") });
    var path_buf: [4096]u8 = undefined;
    const scan = svc.take(&path_buf).?.work.scan;
    try equal(@as(usize, 1), svc.queued_count);

    svc.request(&unresolved, "/alias", .visible, .{});
    const job = resolution.take(svc) orelse return error.MissingResolution;
    defer job.deinit(a);
    svc.request(&unresolved, "/queued", .visible, .{});

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    owner.clear();
    try expect(!failing.has_induced_failure);
    try equal(@as(usize, 0), svc.liveNodeCount());
    try equal(@as(usize, 0), svc.queued_count);
    try equal(@as(?tree.Id, null), svc.liveId(scan.ref));
    try equal(tree.Status.unknown, svc.lookup("/root").status);
    try equal(tree.Status.measuring, svc.lookup("/alias").status);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    // Resolution uses its independently pinned path and re-creates the inode.
    try expect(!svc.resolved(job, key(1), true));
    const replacement = svc.by_key.get(key(1)).?;
    try equal(root, replacement);
    try finish(svc, replacement, 29, &.{child(4, "reused")});
    try equal(scan.ref.id, svc.by_key.get(key(4)).?);
    try equal(@as(?tree.Id, null), svc.liveId(scan.ref));
    try equal(@as(i64, 29), svc.lookup("/alias").bytes);
    try equal(@as(u32, 1), svc.nodes.items[replacement].pending);
    const queued = resolution.take(svc) orelse return error.MissingResolution;
    defer queued.deinit(a);
    try std.testing.expectEqualStrings("/queued", queued.path);
}

test "sizetree eviction does not requeue policy-denied automatic requests" {
    const svc = try Service.createWithBudget(std.testing.allocator, 0, auto, 0);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    svc.request(&owner, "/slow", .visible, .{});
    const job = resolution.take(svc) orelse return error.MissingResolution;
    defer job.deinit(svc.allocator);
    try expect(!svc.resolved(job, key(1), false));
    try equal(@as(usize, 0), svc.liveNodeCount());
    try equal(tree.Status.idle, svc.lookup("/slow").status);
    try expect(!svc.busy());

    svc.request(&owner, "/slow", .visible, .{ .force = true });
    const retry = resolution.take(svc) orelse return error.MissingResolution;
    defer retry.deinit(svc.allocator);
    try expect(!svc.resolved(retry, key(1), false));
    try expect(svc.rootHasDemand(svc.by_key.get(key(1)).?));
}
