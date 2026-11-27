//! Folder-size service bookkeeping and scheduling tests.
const std = @import("std");
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Level = tree.Level;
const demand = @import("sizetree_demand.zig");

fn testAutoPolicy(_: u32, _: u32, _: ?u64) ?bool {
    return true;
}

test "sizetree alternates resolution and scanning while preserving scan priority" {
    const allocator = std.testing.allocator;
    const svc = try Service.create(allocator, 0, testAutoPolicy);
    defer svc.destroy();

    const background = try svc.newNode(.{ .dev = 1, .ino = 1 }, "/background", .background);
    const visible = try svc.newNode(.{ .dev = 1, .ino = 2 }, "/visible", .visible);
    demand.adjustDirect(svc, background, null, .background);
    demand.adjustDirect(svc, visible, null, .visible);
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/resolve1", .visible, .{});
    svc.request(&owner, "/resolve2", .visible, .{});
    svc.request(&owner, "/resolve3", .visible, .{});
    svc.request(&owner, "/resolve4", .visible, .{});

    var path_buf: [4096]u8 = undefined;
    const expected = [_][]const u8{
        "/resolve1",
        "/visible",
        "/resolve2",
        "/background",
        "/resolve3",
        "/resolve4",
    };
    for (expected, 0..) |path, i| {
        const job = svc.take(&path_buf).?;
        switch (job.work) {
            .resolve => |owned| {
                defer owned.deinit(allocator);
                try std.testing.expect(i != 1 and i != 3);
                try std.testing.expectEqualStrings(path, owned.path);
            },
            .scan => |scan| {
                try std.testing.expect(i == 1 or i == 3);
                try std.testing.expectEqualStrings(path, job.path.?);
                try std.testing.expectEqual(if (i == 1) visible else background, scan.ref.id);
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 0), svc.queued_count);
    try std.testing.expect(!@import("sizetree_resolution.zig").hasReady(svc));
}

test "sizetree pauses children discovered by an in-flight scan" {
    const allocator = std.testing.allocator;
    const svc = try Service.create(allocator, 0, testAutoPolicy);
    defer svc.destroy();

    const root = try svc.newNode(.{ .dev = 1, .ino = 1 }, "/root", .visible);
    demand.adjustDirect(svc, root, null, .visible);
    svc.unqueue(root);
    svc.nodes.items[root].scanning = true;

    // Navigation away pauses the root while its worker is still reading it.
    demand.adjustDirect(svc, root, .visible, null);
    try std.testing.expect(svc.nodes.items[root].paused);

    const child_name = try allocator.dupe(u8, "child");
    defer allocator.free(child_name);
    const found = [_]Service.Child{
        .{
            .key = .{ .dev = 1, .ino = 2 },
            .name = child_name,
        },
    };

    // The in-flight scan completes and discovers a child after cancellation.
    try svc.finishScan(root, 0, &found, false);

    try std.testing.expectEqual(@as(usize, 1), svc.nodes.items[root].children.items.len);
    const child = svc.nodes.items[root].children.items[0];
    try std.testing.expect(svc.nodes.items[child].paused);
    try std.testing.expect(svc.nodes.items[child].queued == null);
    try std.testing.expectEqual(@as(usize, 0), svc.queued_count);

    // A later request resumes pending work in the subtree.
    demand.adjustDirect(svc, root, null, .visible);

    try std.testing.expect(!svc.nodes.items[root].paused);
    try std.testing.expect(!svc.nodes.items[child].paused);
    try std.testing.expectEqual(@as(?Level, .visible), svc.nodes.items[child].queued);
    try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
}

test "sizetree deletes every detached descendant without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const svc = try Service.create(failing.allocator(), 0, testAutoPolicy);
    defer svc.destroy();

    const root = try svc.newNode(.{ .dev = 1, .ino = 1 }, "/root", .visible);
    const branch = try svc.newNode(.{ .dev = 1, .ino = 2 }, "branch", .visible);
    const nested = try svc.newNode(.{ .dev = 1, .ino = 3 }, "nested", .visible);
    const sibling = try svc.newNode(.{ .dev = 1, .ino = 4 }, "sibling", .visible);
    try svc.attach(root, branch);
    try svc.attach(branch, nested);
    try svc.attach(branch, sibling);
    demand.adjustDirect(svc, branch, null, .visible);
    const root_ref = svc.refOf(root);
    const deleted = [_]@TypeOf(root){ branch, nested, sibling };
    const stale_refs = .{ svc.refOf(branch), svc.refOf(nested), svc.refOf(sibling) };

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try svc.finishScan(root, 17, &.{}, false);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), svc.queued_count);
    try std.testing.expectEqual(@as(u32, 0), svc.nodes.items[root].pending);
    try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
    inline for (stale_refs) |ref| try std.testing.expect(svc.liveId(ref) == null);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    var seen: [deleted.len]bool = @splat(false);
    for (0..deleted.len) |i| {
        const reused = try svc.newNode(.{ .dev = 2, .ino = i }, "reused", .visible);
        const index = std.mem.indexOfScalar(@TypeOf(root), &deleted, reused) orelse
            return error.UnexpectedReusedSlot;
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |reused| try std.testing.expect(reused);
    inline for (stale_refs) |ref| try std.testing.expect(svc.liveId(ref) == null);

    try std.testing.expectEqual(root, svc.liveId(root_ref).?);
    try std.testing.expectEqual(root, svc.by_key.get(.{ .dev = 1, .ino = 1 }).?);
    const surviving = &svc.nodes.items[root];
    try std.testing.expectEqualStrings("/root", surviving.name);
    try std.testing.expectEqual(@as(i64, 17), surviving.total);
    try std.testing.expectEqual(@as(usize, 0), surviving.children.items.len);
}

test "sizetree deletes a deep chain without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const svc = try Service.create(failing.allocator(), 0, testAutoPolicy);
    defer svc.destroy();

    const depth = 65_536;
    const leaf = try svc.newNode(.{ .dev = 1, .ino = 1 }, "leaf", .visible);
    const leaf_ref = svc.refOf(leaf);
    var head = leaf;
    // Build from the leaf up so attaching each node updates just one parent.
    for (2..depth + 1) |ino| {
        const parent = try svc.newNode(.{ .dev = 1, .ino = ino }, "parent", .visible);
        try svc.attach(parent, head);
        head = parent;
    }
    const root = try svc.newNode(.{ .dev = 1, .ino = depth + 1 }, "/root", .visible);
    try svc.attach(root, head);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try svc.finishScan(root, 0, &.{}, false);

    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(svc.liveId(leaf_ref) == null);
    try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
    try std.testing.expectEqual(@as(u32, 0), svc.nodes.items[root].pending);
    for (svc.nodes.items[0..root]) |node| try std.testing.expect(!node.live);
}
