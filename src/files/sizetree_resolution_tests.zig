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
    // Path map, map key, job path, and queue storage.
    for (0..4) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const a = failing.allocator();
        const svc = try Service.create(a, 0, auto);
        defer svc.destroy();

        failing.fail_index = failing.alloc_index + offset;
        svc.request("/root", .visible, .{});
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(!svc.busy());
        try std.testing.expectEqual(tree.Status.unknown, svc.lookup("/root").status);
        try std.testing.expectEqual(@as(usize, 0), svc.resolve.items.len);

        failing.fail_index = std.math.maxInt(usize);
        svc.request("/root", .visible, .{});
        try std.testing.expect(svc.busy());
        // A queued job already owns everything needed for dispatch.
        failing.fail_index = failing.alloc_index;
        const job = try takeResolution(svc);
        defer job.deinit(a);
        try std.testing.expectEqualStrings("/root", job.path);
        failing.fail_index = std.math.maxInt(usize);
        svc.resolved(job, key(1), true);
        try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
    }
}

test "sizetree clears the current resolution on node allocation failure and retries" {
    // Node name, inode index, and node storage.
    for (0..3) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const a = failing.allocator();
        const svc = try Service.create(a, 0, auto);
        defer svc.destroy();
        svc.request("/root", .visible, .{});
        const first = try takeResolution(svc);
        defer first.deinit(a);

        failing.fail_index = failing.alloc_index + offset;
        svc.resolved(first, key(1), true);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(tree.Status.unknown, svc.lookup("/root").status);
        try std.testing.expectEqual(@as(usize, 0), svc.nodes.items.len);
        try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());

        failing.fail_index = std.math.maxInt(usize);
        svc.request("/root", .visible, .{});
        const second = try takeResolution(svc);
        defer second.deinit(a);
        try std.testing.expect(first.id != second.id);
        svc.resolved(second, key(1), true);
        try std.testing.expectEqual(tree.Status.measuring, svc.lookup("/root").status);
        try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
        try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
    }
}

test "sizetree skips queued jobs cancelled by stop or forget" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();

    svc.request("/stopped", .visible, .{});
    svc.request("/forgotten", .visible, .{});
    svc.stopPath("/stopped");
    svc.forgetPath("/forgotten");
    try std.testing.expect(!svc.busy());
    svc.request("/stopped", .visible, .{});
    try std.testing.expect(!svc.busy());

    // Re-request both before dispatch. Only the new jobs are eligible.
    svc.request("/forgotten", .background, .{});
    svc.request("/stopped", .visible, .{ .force = true });
    const forgotten = try takeResolution(svc);
    defer forgotten.deinit(a);
    const stopped = try takeResolution(svc);
    defer stopped.deinit(a);
    try std.testing.expectEqualStrings("/forgotten", forgotten.path);
    try std.testing.expectEqualStrings("/stopped", stopped.path);
    try std.testing.expectEqual(@as(usize, 0), svc.resolve.items.len);
    svc.resolved(forgotten, key(1), true);
    svc.resolved(stopped, key(2), false);
    try std.testing.expectEqual(@as(usize, 2), svc.queued_count);
}

test "sizetree ignores cancelled in-flight results without touching another subtree" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    const other = try svc.newNode(key(1), "/other", .visible);
    const child = try svc.newNode(key(2), "child", .visible);
    try svc.attach(other, child);

    svc.request("/stopped", .visible, .{});
    const stopped = try takeResolution(svc);
    defer stopped.deinit(a);
    svc.request("/forgotten", .visible, .{});
    const forgotten = try takeResolution(svc);
    defer forgotten.deinit(a);
    svc.enqueueSubtree(other, .visible);

    svc.stopPath(stopped.path);
    svc.forgetPath(forgotten.path);
    const before = svc.generation.load(.acquire);
    svc.resolved(stopped, key(1), true);
    svc.resolved(forgotten, key(3), true);
    try std.testing.expectEqual(before, svc.generation.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), svc.by_key.count());
    try std.testing.expectEqual(@as(usize, 2), svc.queued_count);
    try std.testing.expect(!svc.nodes.items[other].paused and !svc.nodes.items[child].paused);
    try std.testing.expect(svc.paths.get(stopped.path).?.node == null);
    try std.testing.expect(svc.paths.get(forgotten.path).?.node == null);
}

test "sizetree repeated requests keep one resolution and use the latest priority and force" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();

    svc.request("/root", .background, .{});
    svc.request("/root", .background, .{});
    try std.testing.expectEqual(@as(usize, 1), svc.resolve.items.len);
    const job = try takeResolution(svc);
    defer job.deinit(a);
    svc.request("/root", .visible, .{ .force = true });
    svc.request("/root", .background, .{});
    try std.testing.expectEqual(@as(usize, 0), svc.resolve.items.len);
    svc.resolved(job, key(1), false);
    const id = svc.by_key.get(key(1)).?;
    try std.testing.expectEqual(@as(?tree.Level, .visible), svc.nodes.items[id].queued);
    svc.resolved(job, key(2), true);
    try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
}

test "sizetree resolution jobs outlive removed keys and cannot publish into recreated entries" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();

    // Simulate future removal directly in the fixture.
    svc.request("/root", .background, .{});
    a.free(svc.paths.fetchRemove("/root").?.key);
    svc.request("/root", .background, .{});
    const old = try takeResolution(svc);
    defer old.deinit(a);
    try std.testing.expectEqualStrings("/root", old.path);
    try std.testing.expectEqual(@as(usize, 0), svc.resolve.items.len);

    a.free(svc.paths.fetchRemove("/root").?.key);
    svc.resolved(old, key(1), true);
    try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());
    svc.request("/root", .visible, .{});
    svc.resolved(old, key(1), true);
    try std.testing.expectEqual(tree.Status.measuring, svc.lookup("/root").status);
    try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());

    const fresh = try takeResolution(svc);
    defer fresh.deinit(a);
    try std.testing.expect(old.id != fresh.id);
    svc.resolved(fresh, key(2), true);
    svc.resolved(old, null, false);
    const id = svc.by_key.get(key(2)).?;
    try std.testing.expectEqual(id, svc.liveId(svc.paths.get("/root").?.node.?).?);
    try std.testing.expect(svc.by_key.get(key(1)) == null);
}

test "sizetree retries a missing root after re-resolution cannot allocate" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();

    svc.request("/root", .visible, .{});
    const first = try takeResolution(svc);
    defer first.deinit(a);
    svc.resolved(first, key(1), true);
    var buf: [4096]u8 = undefined;
    const scan = svc.take(&buf).?;
    const id = scan.work.scan.ref.id;

    failing.fail_index = failing.alloc_index;
    svc.lostScan(id, scan.path.?);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!svc.busy());
    try std.testing.expectEqual(tree.Status.unknown, svc.lookup("/root").status);

    failing.fail_index = std.math.maxInt(usize);
    svc.request("/root", .visible, .{});
    const second = try takeResolution(svc);
    defer second.deinit(a);
    svc.resolved(second, key(2), true);
    const new_id = svc.liveId(svc.paths.get("/root").?.node.?).?;
    try std.testing.expectEqual(new_id, svc.by_key.get(key(2)).?);
    try std.testing.expect(new_id != id);
    try std.testing.expectEqual(@as(?tree.Level, .visible), svc.nodes.items[new_id].queued);
}
