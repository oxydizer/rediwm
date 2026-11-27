//! Deterministic ownership, cancellation, and allocation tests for resolution.
const std = @import("std");
const c = @import("c.zig").api;
const platform = @import("platform");
const tree = @import("sizetree.zig");
const DevicePolicyCache = @import("sizetree_resolution.zig").DevicePolicyCache;
const Service = tree.Service;
const Resolution = tree.Resolution;

fn auto(_: u32, _: u32, _: ?u64) ?bool {
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

test "sizetree replaces obsolete path bindings without discarding other bindings" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    var other = svc.registerOwner();
    defer other.deinit();

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(1) });
    const first = try takeResolution(svc);
    defer first.deinit(a);
    _ = svc.resolved(first, key(1), true);

    const old_id = svc.by_key.get(key(1)).?;
    svc.unqueue(old_id);
    svc.nodes.items[old_id].self_pending = false;
    svc.nodes.items[old_id].pending = 0;
    svc.nodes.items[old_id].complete = true;
    svc.nodes.items[old_id].own = 100;
    svc.nodes.items[old_id].total = 100;

    svc.request(&other, "/alias", .visible, .{ .directory_key = key(1) });
    const alias = try takeResolution(svc);
    defer alias.deinit(a);
    _ = svc.resolved(alias, key(1), true);

    try std.testing.expectEqual(tree.Status.exact, svc.lookupIdentity(&owner, "/root", key(1)).status);
    try std.testing.expectEqual(tree.Status.unknown, svc.lookupIdentity(&owner, "/root", key(2)).status);
    try std.testing.expectEqual(@as(usize, 2), svc.nodes.items[old_id].subtree_demand);

    // An unchanged identity keeps the existing measurement.
    svc.request(&owner, "/root", .visible, .{ .directory_key = key(1) });
    try std.testing.expect(!svc.busy());

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(2) });
    try std.testing.expectEqual(old_id, svc.paths.get("/root").?.node);
    try std.testing.expectEqual(@as(usize, 2), svc.nodes.items[old_id].subtree_demand);
    try std.testing.expectEqual(tree.Status.unknown, svc.lookupIdentity(&owner, "/root", key(2)).status);
    try std.testing.expectEqual(@as(i64, 100), svc.lookupIdentity(&other, "/alias", key(1)).bytes);

    const replacement = try takeResolution(svc);
    defer replacement.deinit(a);
    _ = svc.resolved(replacement, key(2), true);
    try std.testing.expectEqual(@as(usize, 1), svc.nodes.items[old_id].subtree_demand);
    const new_id = svc.by_key.get(key(2)).?;
    try std.testing.expect(new_id != old_id);
    try std.testing.expectEqual(new_id, svc.paths.get("/root").?.node);
    try std.testing.expectEqual(tree.Status.measuring, svc.lookupIdentity(&owner, "/root", key(2)).status);
    try std.testing.expectEqual(@as(i64, 0), svc.lookupIdentity(&owner, "/root", key(2)).bytes);
    try std.testing.expectEqual(tree.Status.exact, svc.lookupIdentity(&other, "/alias", key(1)).status);
    try std.testing.expectEqual(@as(u32, 2), svc.by_key.count());
}

test "sizetree identity changes supersede in-flight resolution" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(1) });
    const obsolete = try takeResolution(svc);
    defer obsolete.deinit(a);

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(2) });
    const current = try takeResolution(svc);
    defer current.deinit(a);
    try std.testing.expect(obsolete.id != current.id);

    _ = svc.resolved(obsolete, key(1), true);
    try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());
    try std.testing.expectEqual(@as(?u64, current.id), svc.paths.get("/root").?.resolution);

    _ = svc.resolved(current, key(2), true);
    _ = svc.resolved(obsolete, key(1), true);
    try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
    try std.testing.expectEqual(svc.by_key.get(key(2)).?, svc.paths.get("/root").?.node);
}

test "sizetree filesystem resolution overrides stale observed identity" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(1) });
    const job = try takeResolution(svc);
    defer job.deinit(a);
    _ = svc.resolved(job, key(2), true);

    try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
    try std.testing.expectEqual(tree.Status.unknown, svc.lookupIdentity(&owner, "/root", key(1)).status);
    try std.testing.expectEqual(tree.Status.measuring, svc.lookupIdentity(&owner, "/root", key(2)).status);

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(2) });
    try std.testing.expectEqual(@as(?u64, null), svc.paths.get("/root").?.resolution);
    try std.testing.expectEqual(tree.Status.measuring, svc.lookupIdentity(&owner, "/root", key(2)).status);
}

test "sizetree matching observation cannot cancel pending validation" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var stale = svc.registerOwner();
    defer stale.deinit();
    var current = svc.registerOwner();
    defer current.deinit();

    svc.request(&stale, "/root", .visible, .{ .directory_key = key(1) });
    const initial = try takeResolution(svc);
    defer initial.deinit(a);
    _ = svc.resolved(initial, key(2), true);

    const id = svc.by_key.get(key(2)).?;
    svc.unqueue(id);
    svc.nodes.items[id].self_pending = false;
    svc.nodes.items[id].pending = 0;
    svc.nodes.items[id].complete = true;
    svc.nodes.items[id].own = 200;
    svc.nodes.items[id].total = 200;

    svc.request(&current, "/root", .visible, .{ .directory_key = key(2) });
    svc.request(&stale, "/root", .visible, .{ .directory_key = key(1) });
    const validation = try takeResolution(svc);
    defer validation.deinit(a);

    svc.request(&current, "/root", .visible, .{ .directory_key = key(2) });
    try std.testing.expectEqual(@as(?u64, validation.id), svc.paths.get("/root").?.resolution);
    try std.testing.expectEqual(id, svc.paths.get("/root").?.node);

    _ = svc.resolved(validation, key(2), true);
    try std.testing.expectEqual(@as(?u64, null), svc.paths.get("/root").?.resolution);

    // Repeating the matching identity does not start new work.
    svc.request(&current, "/root", .visible, .{ .directory_key = key(2) });
    try std.testing.expect(!svc.busy());
    try std.testing.expectEqual(tree.Status.exact, svc.lookupIdentity(&current, "/root", key(2)).status);
    try std.testing.expectEqual(@as(i64, 200), svc.lookupIdentity(&current, "/root", key(2)).bytes);

    // A previously checked identity may subsequently become valid.
    svc.request(&stale, "/root", .visible, .{ .directory_key = key(1) });
    const replacement = try takeResolution(svc);
    defer replacement.deinit(a);
    try std.testing.expect(replacement.id != validation.id);
    _ = svc.resolved(replacement, key(1), true);
    try std.testing.expectEqual(tree.Status.measuring, svc.lookupIdentity(&stale, "/root", key(1)).status);
    try std.testing.expectEqual(tree.Status.unknown, svc.lookupIdentity(&current, "/root", key(2)).status);
}

test "sizetree stale window cannot discard current window measurement" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var stale = svc.registerOwner();
    defer stale.deinit();
    var current = svc.registerOwner();
    defer current.deinit();

    svc.request(&stale, "/root", .visible, .{ .directory_key = key(1) });
    const initial = try takeResolution(svc);
    defer initial.deinit(a);
    _ = svc.resolved(initial, key(2), true);

    const id = svc.by_key.get(key(2)).?;
    svc.unqueue(id);
    svc.nodes.items[id].self_pending = false;
    svc.nodes.items[id].pending = 0;
    svc.nodes.items[id].complete = true;
    svc.nodes.items[id].own = 200;
    svc.nodes.items[id].total = 200;

    svc.request(&current, "/root", .visible, .{ .directory_key = key(2) });
    try std.testing.expect(!svc.busy());

    svc.request(&stale, "/root", .visible, .{ .directory_key = key(1) });
    const validation = try takeResolution(svc);
    defer validation.deinit(a);

    try std.testing.expectEqual(id, svc.paths.get("/root").?.node);
    try std.testing.expectEqual(tree.Status.unknown, svc.lookupIdentity(&stale, "/root", key(1)).status);
    try std.testing.expectEqual(tree.Status.exact, svc.lookupIdentity(&current, "/root", key(2)).status);
    try std.testing.expectEqual(@as(i64, 200), svc.lookupIdentity(&current, "/root", key(2)).bytes);

    // Repeated requests must not supersede the same validation.
    svc.request(&stale, "/root", .visible, .{ .directory_key = key(1) });
    try std.testing.expectEqual(@as(?u64, validation.id), svc.paths.get("/root").?.resolution);

    _ = svc.resolved(validation, key(2), true);

    try std.testing.expectEqual(id, svc.paths.get("/root").?.node);
    try std.testing.expectEqual(@as(u32, 1), svc.by_key.count());
    try std.testing.expectEqual(@as(usize, 1), svc.nodes.items[id].subtree_demand);
    try std.testing.expectEqual(tree.Status.unknown, svc.lookupIdentity(&stale, "/root", key(1)).status);
    try std.testing.expectEqual(tree.Status.exact, svc.lookupIdentity(&current, "/root", key(2)).status);
    try std.testing.expectEqual(@as(i64, 200), svc.lookupIdentity(&current, "/root", key(2)).bytes);
    try std.testing.expect(!svc.busy());
}

test "sizetree identity validation preserves automatic scan restrictions" {
    const a = std.testing.allocator;
    const svc = try Service.create(a, 0, auto);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(1) });
    const initial = try takeResolution(svc);
    defer initial.deinit(a);
    _ = svc.resolved(initial, key(1), false);

    const old_id = svc.by_key.get(key(1)).?;
    try std.testing.expectEqual(tree.Status.idle, svc.lookup("/root").status);
    try std.testing.expectEqual(@as(usize, 0), svc.nodes.items[old_id].subtree_demand);
    try std.testing.expectEqual(@as(usize, 0), svc.queued_count);

    svc.request(&owner, "/root", .visible, .{ .directory_key = key(2) });
    try std.testing.expect(!svc.paths.get("/root").?.auto_allowed);
    try std.testing.expectEqual(@as(usize, 0), svc.nodes.items[old_id].subtree_demand);
    try std.testing.expectEqual(@as(usize, 0), svc.queued_count);

    const replacement = try takeResolution(svc);
    defer replacement.deinit(a);
    _ = svc.resolved(replacement, key(2), false);

    const new_id = svc.by_key.get(key(2)).?;
    try std.testing.expectEqual(new_id, svc.paths.get("/root").?.node);
    try std.testing.expectEqual(@as(usize, 0), svc.nodes.items[new_id].subtree_demand);
    try std.testing.expectEqual(@as(usize, 0), svc.queued_count);
    try std.testing.expectEqual(tree.Status.idle, svc.lookupIdentity(&owner, "/root", key(2)).status);
    try std.testing.expect(!svc.busy());

    // Explicit measurement still overrides the automatic policy.
    svc.request(&owner, "/root", .visible, .{
        .directory_key = key(2),
        .force = true,
    });
    try std.testing.expectEqual(@as(usize, 1), svc.nodes.items[new_id].subtree_demand);
    try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
}

test "device policy memoization distinguishes mounts and leaves ambiguous results uncached" {
    var cache: DevicePolicyCache = .{};
    const home: DevicePolicyCache.Identity = .{ .dev = 61, .mount_id = 224 };
    const other: DevicePolicyCache.Identity = .{ .dev = 61, .mount_id = 225 };
    const legacy_anonymous: DevicePolicyCache.Identity = .{ .dev = 61, .mount_id = null };
    const legacy_block: DevicePolicyCache.Identity = .{ .dev = 8 << 32 | 1, .mount_id = null };
    const mounted_block: DevicePolicyCache.Identity = .{ .dev = legacy_block.dev, .mount_id = 224 };

    cache.put(home, true);
    try std.testing.expectEqual(@as(?bool, true), cache.get(home));
    try std.testing.expectEqual(null, cache.get(other));
    cache.put(other, null);
    try std.testing.expectEqual(null, cache.get(other));
    cache.put(other, false);
    try std.testing.expectEqual(@as(?bool, false), cache.get(other));
    try std.testing.expect(cache.get(home) != false);

    cache.put(legacy_anonymous, true);
    try std.testing.expectEqual(null, cache.get(legacy_anonymous));
    cache.put(legacy_block, true);
    try std.testing.expectEqual(@as(?bool, true), cache.get(legacy_block));
    try std.testing.expectEqual(null, cache.get(mounted_block));
}

fn autoWithMount(_: u32, _: u32, mount_id: ?u64) ?bool {
    return if (mount_id != null) true else null;
}

test "sizetree passes the opened directory mount identity to automatic policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    var buf: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0);
    const fd = c.open(z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.TestSetupFailed;
    defer _ = c.close(fd);
    const id = platform.mounts.idOfFd(fd) orelse return error.SkipZigTest;
    const info = platform.dirwalk.statFd(fd) orelse return error.TestSetupFailed;

    const svc = try Service.create(a, 0, autoWithMount);
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();
    svc.request(&owner, path, .visible, .{});
    const job = try takeResolution(svc);
    defer job.deinit(a);
    try std.testing.expect(!svc.resolvePath(job));
    try std.testing.expectEqual(@as(?bool, true), svc.auto.get(.{ .dev = info.dev, .mount_id = id }));
    try std.testing.expectEqual(tree.Status.measuring, svc.lookup(path).status);
    try std.testing.expectEqual(@as(usize, 1), svc.queued_count);
}

test "sizetree retries each path and resolution queue allocation failure" {
    // Path entry, key, inactive-path heap, path map, viewport list, owner map.
    for (0..6) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const a = failing.allocator();
        const svc = try Service.createWithBudgets(a, 0, auto, .{ .path_entries = 0 });
        defer svc.destroy();
        var owner = svc.registerOwner();
        defer owner.deinit();

        failing.fail_index = failing.alloc_index + offset;
        svc.request(&owner, "/root", .visible, .{});
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(!svc.busy());
        try std.testing.expectEqual(tree.Status.unknown, svc.lookup("/root").status);
        try std.testing.expectEqual(@as(u32, 0), svc.paths.count());
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
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const svc = try Service.createWithBudgets(a, 0, auto, .{ .path_entries = 0 });
    defer svc.destroy();
    var owner = svc.registerOwner();
    defer owner.deinit();

    svc.request(&owner, "/root", .background, .{});
    const old = try takeResolution(svc);
    defer old.deinit(a);
    try std.testing.expectEqual(@as(u32, 1), svc.paths.count());
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    svc.forgetPath(&owner, "/root");
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(u32, 0), svc.paths.count());
    try std.testing.expectEqual(@as(usize, 1), old.entry.refs.load(.acquire));
    try std.testing.expectEqualStrings("/root", old.path);
    _ = svc.resolved(old, key(1), true);
    try std.testing.expectEqual(@as(u32, 0), svc.by_key.count());
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    svc.request(&owner, "/root", .visible, .{});
    try std.testing.expect(svc.paths.get("/root").? != old.entry);
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
