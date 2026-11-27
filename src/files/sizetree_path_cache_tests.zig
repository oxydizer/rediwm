//! Deterministic path-cache tests with independent path and live-node limits.
const std = @import("std");
const tree = @import("sizetree.zig");
const resolution = @import("sizetree_resolution.zig");
const Service = tree.Service;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn auto(_: u32, _: u32) bool {
    return true;
}

fn key(ino: u64) tree.Key {
    return .{ .dev = 1, .ino = ino };
}

fn child(ino: u64, name: []const u8) Service.Child {
    return .{ .key = key(ino), .name = @constCast(name) };
}

fn resolve(svc: *Service, owner: *tree.Owner, path: []const u8, ino: u64, allowed: bool) !tree.Id {
    svc.request(owner, path, .visible, .{});
    const job = resolution.take(svc) orelse return error.MissingResolution;
    defer job.deinit(svc.allocator);
    try std.testing.expectEqualStrings(path, job.path);
    try expect(!svc.resolved(job, key(ino), allowed));
    return svc.by_key.get(key(ino)) orelse error.MissingNode;
}

fn finish(svc: *Service, id: tree.Id, bytes: i64, found: []const Service.Child) !void {
    svc.unqueue(id);
    try svc.finishScan(id, bytes, found, false);
}

test "path LRU refreshes hits and requests, and rebinding reuses a retained measurement" {
    const svc = try Service.createWithBudgets(std.testing.allocator, 0, auto, .{ .path_entries = 2 });
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    const root = try resolve(svc, &owner, "/root", 1, true);
    try finish(svc, root, 21, &.{});
    const ref = svc.refOf(root);
    svc.request(&owner, "/unbound", .visible, .{});
    owner.clear();
    try expect(!resolution.hasReady(svc));
    try equal(@as(i64, 21), svc.lookup("/root").bytes);
    svc.request(&owner, "/c", .visible, .{});
    try expect(!svc.paths.contains("/unbound"));
    owner.clear();

    svc.request(&owner, "/root", .visible, .{});
    owner.clear();
    svc.request(&owner, "/d", .visible, .{});
    try expect(!svc.paths.contains("/c"));
    owner.clear();
    _ = svc.lookup("/d"); // An unbound cache hit also refreshes its entry.
    svc.request(&owner, "/e", .visible, .{});
    try expect(!svc.paths.contains("/root"));
    try expect(svc.nodes.items[root].paths == null);
    try equal(@as(?tree.Id, root), svc.liveId(ref));
    try equal(@as(i64, 21), svc.nodes.items[root].total);
    try equal(@as(u32, 0), svc.nodes.items[root].pending);
    try expect(!svc.rootHasDemand(root));
    owner.clear();

    try equal(root, try resolve(svc, &owner, "/root", 1, true));
    try equal(@as(i64, 21), svc.lookup("/root").bytes);
    try equal(@as(usize, 0), svc.queued_count);
    try expect(svc.rootHasDemand(root));
}

test "path budget protects multiple owners, retained Stop choices, and policy-denied entries" {
    const svc = try Service.createWithBudgets(std.testing.allocator, 0, auto, .{ .path_entries = 0 });
    defer svc.destroy();
    var first = svc.registerOwner();
    var first_open = true;
    defer if (first_open) first.deinit();
    var second = svc.registerOwner();
    defer second.deinit();

    const shared = try resolve(svc, &first, "/shared", 1, true);
    svc.request(&second, "/shared", .visible, .{});
    const slow = try resolve(svc, &second, "/slow", 2, false);
    try equal(@as(u32, 2), svc.paths.count());
    try equal(@as(usize, 2), svc.paths.get("/shared").?.owners);
    try equal(tree.Status.idle, svc.lookup("/slow").status);
    try expect(!svc.rootHasDemand(slow));

    svc.stopPath(&first, "/shared");
    first.clear();
    try expect(svc.rootHasDemand(shared));
    second.beginViewport();
    second.endViewport();
    try expect(!svc.paths.contains("/slow"));
    try expect(!svc.rootHasDemand(shared));
    try equal(tree.Status.idle, svc.lookupOwned(&first, "/shared").status);
    try equal(@as(usize, 1), svc.paths.get("/shared").?.owners);
    svc.request(&first, "/shared", .visible, .{});
    try expect(!svc.busy());

    first.deinit();
    first_open = false;
    try equal(@as(u32, 0), svc.paths.count());
    try equal(@as(usize, 2), svc.liveNodeCount());
}

test "path eviction keeps the recovery prefix for descendant scans until topology is repaired" {
    const svc = try Service.createWithBudgets(std.testing.allocator, 0, auto, .{ .path_entries = 0 });
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    const root = try resolve(svc, &owner, "/root", 1, true);
    try finish(svc, root, 11, &.{child(2, "member")});
    owner.clear();
    const member = svc.by_key.get(key(2)).?;
    svc.lostScan(member, "/root/member");
    try equal(member, try resolve(svc, &owner, "/moved", 2, true));
    try finish(svc, member, 23, &.{child(3, "nested")});
    owner.clear();
    try expect(svc.paths.contains("/moved"));

    try equal(member, try resolve(svc, &owner, "/new", 2, true));
    try expect(!svc.paths.contains("/moved"));
    try finish(svc, member, 23, &.{child(3, "nested")});
    owner.clear();
    try expect(svc.paths.contains("/new"));
    const nested = try resolve(svc, &owner, "/new/nested", 3, true);
    var buf: [4096]u8 = undefined;
    const scan = svc.take(&buf).?;
    try equal(@as(?tree.Id, nested), svc.liveId(scan.work.scan.ref));
    try std.testing.expectEqualStrings("/new/nested", scan.path.?);
    try finish(svc, nested, 31, &.{});
    owner.clear();

    try equal(root, try resolve(svc, &owner, "/root", 1, true));
    try finish(svc, root, 11, &.{child(2, "repaired")});
    svc.maintainBudget();
    try expect(!svc.paths.contains("/new"));
    try equal(@as(i64, 65), svc.lookup("/root").bytes);
    try equal(@as(u32, 0), svc.nodes.items[root].pending);
    try expect(svc.rootHasDemand(root));
}

test "path eviction follows whole-root invalidation and survives node slot reuse" {
    const svc = try Service.createWithBudgets(std.testing.allocator, 0, auto, .{
        .live_nodes = 0,
        .path_entries = 1,
    });
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    const root = try resolve(svc, &owner, "/root", 1, true);
    try finish(svc, root, 11, &.{});
    svc.lostScan(root, "/root");
    try equal(root, try resolve(svc, &owner, "/root", 1, true));
    try equal(root, try resolve(svc, &owner, "/alias", 1, true));
    const ref = svc.refOf(root);
    _ = svc.lookup("/root");
    owner.clear();
    try equal(@as(usize, 0), svc.liveNodeCount());
    try expect(!svc.paths.contains("/alias")); // Releasing the recovery head made it eligible.
    try equal(tree.no_id, svc.paths.get("/root").?.node);
    try equal(root, try resolve(svc, &owner, "/root", 2, true));
    try equal(@as(?tree.Id, null), svc.liveId(ref));
    try equal(@as(i64, 0), svc.lookup("/root").bytes);
    try equal(@as(u32, 1), svc.nodes.items[root].pending);
}
