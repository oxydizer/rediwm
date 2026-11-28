//! The folder-size service (`sizetree.zig`) against real directories.
const std = @import("std");
const st = @import("sizetree.zig");
const c = @import("c.zig").api;
const ops = @import("ops.zig");
const makeTestDir = @import("../files_tests.zig").makeTestDir;

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn sh(root: []const u8, command: []const u8) !void {
    const cmd = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "cd '{s}' && {s}",
        .{ root, command },
        0,
    );
    defer std.testing.allocator.free(cmd);
    if (c.system(cmd.ptr) != 0) return error.FixtureCommandFailed;
}
fn yes(_: u32, _: u32, _: ?u64) ?bool {
    return true;
}
fn no(_: u32, _: u32, _: ?u64) ?bool {
    return false;
}
fn settle(s: *st.Service) void {
    var i: usize = 0;
    while (s.busy()) : (i += 1) {
        _ = c.usleep(1000);
        if (i > 60000) @panic("never settled");
    }
}
fn expected(path: []const u8) !i64 {
    var buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrintSentinel(&buf, "find '{s}' -xdev -type f -printf '%s\\n' | awk '{{s+=$1}} END {{print s+0}}'", .{path}, 0);
    const pipe = c.popen(cmd.ptr, "r") orelse return error.PipeFailed;
    var out: [64]u8 = undefined;
    const n = c.fread(&out, 1, out.len, pipe);
    if (c.pclose(pipe) != 0 or n == 0) return error.ExpectedSizeFailed;
    return std.fmt.parseInt(i64, std.mem.trim(u8, out[0..n], " \n"), 10);
}
fn ask(owner: *st.Owner, path: []const u8, o: st.RequestOptions) st.Info {
    const s = owner.service;
    s.request(owner, path, .visible, o);
    settle(s);
    return s.lookup(path);
}

test "tree adds up, subfolders reuse the parent's walk, revalidate sees changes" {
    var tmp_buf: [256]u8 = undefined;
    const root = try makeTestDir(&tmp_buf);
    defer ops.deleteRecursive(std.testing.allocator, root) catch unreachable;
    var a_buf: [512]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    try sh(root, "mkdir -p a/b/c d && printf 12345 > f && printf 1234567890 > a/b/c/g && head -c 5000 /dev/zero > d/h && ln f a/f2 && ln -s f l");
    const s = try st.Service.create(std.testing.allocator, 3, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    var info = ask(&owner, root, .{});
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(try expected(root), info.bytes);
    // A subfolder: known from the parent's walk.
    info = ask(&owner, a, .{});
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(try expected(a), info.bytes);
    // Changes: grow a file, add a folder, remove one, rename one.
    try sh(root, "head -c 777 /dev/zero >> a/b/c/g && mkdir a/new && printf xyz > a/new/z && rm -rf d && mv a/b a/b2");
    info = ask(&owner, root, .{});
    try std.testing.expect(info.bytes != try expected(root)); // not revalidated yet
    s.revalidate_ms = 0;
    s.request(&owner, root, .visible, .{ .revalidate = true });
    const during = s.lookup(root).status;
    try std.testing.expect(during == .revalidating or during == .exact);
    settle(s);
    info = s.lookup(root);
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(try expected(root), info.bytes);
    try std.testing.expectEqual(try expected(a), s.lookup(a).bytes);
}

test "child first, then parent; move between folders" {
    var tmp_buf: [256]u8 = undefined;
    const root = try makeTestDir(&tmp_buf);
    defer ops.deleteRecursive(std.testing.allocator, root) catch unreachable;
    var x_buf: [512]u8 = undefined;
    var y_buf: [512]u8 = undefined;
    var z_buf: [512]u8 = undefined;
    const x = try std.fmt.bufPrint(&x_buf, "{s}/x", .{root});
    const y = try std.fmt.bufPrint(&y_buf, "{s}/x/y", .{root});
    const z = try std.fmt.bufPrint(&z_buf, "{s}/z", .{root});
    try sh(root, "mkdir -p x/y z && printf 1111 > x/y/one && printf 22 > z/two");
    const s = try st.Service.create(std.testing.allocator, 2, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    try std.testing.expectEqual(@as(i64, 4), ask(&owner, y, .{}).bytes);
    try std.testing.expectEqual(@as(i64, 6), ask(&owner, root, .{}).bytes);
    try sh(root, "mv x/y z/y");
    s.revalidate_ms = 0;
    const info = ask(&owner, root, .{ .revalidate = true });
    try std.testing.expectEqual(@as(i64, 6), info.bytes);
    try std.testing.expectEqual(@as(i64, 0), s.lookup(x).bytes);
    try std.testing.expectEqual(@as(i64, 6), ask(&owner, z, .{}).bytes);
}

test "slow disks wait for a click; stop and force" {
    var tmp_buf: [256]u8 = undefined;
    const root = try makeTestDir(&tmp_buf);
    defer ops.deleteRecursive(std.testing.allocator, root) catch unreachable;
    try sh(root, "mkdir q && printf 123 > q/r");
    const s = try st.Service.create(std.testing.allocator, 2, no);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    try std.testing.expectEqual(st.Status.idle, ask(&owner, root, .{}).status);
    const info = ask(&owner, root, .{ .force = true });
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(@as(i64, 3), info.bytes);
}

test "stopping a big walk, then forcing it to finish" {
    var tmp_buf: [256]u8 = undefined;
    const root = try makeTestDir(&tmp_buf);
    defer ops.deleteRecursive(std.testing.allocator, root) catch unreachable;
    try sh(root, "for i in $(seq 1 60); do mkdir -p d$i/e/f; for j in 1 2 3; do printf %0100d 0 > d$i/e/f/x$j; done; done");
    const s = try st.Service.create(std.testing.allocator, 1, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    s.request(&owner, root, .visible, .{});
    _ = c.usleep(2000);
    s.stopPath(&owner, root);
    settle(s);
    const stopped = s.lookup(root);
    s.request(&owner, root, .visible, .{}); // auto request does not restart it
    settle(s);
    try std.testing.expectEqual(stopped.status, s.lookup(root).status);
    const info = ask(&owner, root, .{ .force = true });
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(@as(i64, 60 * 3 * 100), info.bytes);
}

test "random tree, overlapping requests from many threads" {
    if (c.system("command -v python3 >/dev/null") != 0) return error.SkipZigTest;
    var tmp_buf: [256]u8 = undefined;
    const workspace = try makeTestDir(&tmp_buf);
    defer ops.deleteRecursive(std.testing.allocator, workspace) catch unreachable;
    var root_buf: [512]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/tree", .{workspace});
    var list_buf: [512]u8 = undefined;
    const list_path = try std.fmt.bufPrintSentinel(&list_buf, "{s}/dirs", .{workspace}, 0);
    try sh(workspace, "mkdir tree");
    try sh(root, "python3 -c \"import os,random\nrandom.seed(7)\ndirs=['.']\nfor i in range(1500):\n  p=os.path.join(random.choice(dirs),'d%d'%i); os.mkdir(p); dirs.append(p)\nfor i in range(4000):\n  open(os.path.join(random.choice(dirs),'f%d'%i),'wb').write(b'x'*random.randint(0,3000))\nopen('../dirs','w').write('\\n'.join(dirs[1:200]))\"");
    const s = try st.Service.create(std.testing.allocator, 4, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    var buf: [100000]u8 = undefined;
    const fd = c.open(list_path, c.O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    const count = c.read(fd, &buf, buf.len);
    _ = c.close(fd);
    if (count <= 0) return error.ReadFailed;
    const n: usize = @intCast(count);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| std.testing.allocator.free(p);
        paths.deinit(std.testing.allocator);
    }
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |rel| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, rel[2..] });
        errdefer std.testing.allocator.free(path);
        try paths.append(std.testing.allocator, path);
    }
    // Deep folders first, then the root, interleaved.
    var i: usize = paths.items.len;
    while (i > 0) {
        i -= 1;
        s.request(&owner, paths.items[i], if (i % 2 == 0) .visible else .background, .{});
        if (i == 100) s.request(&owner, root, .visible, .{});
    }
    settle(s);
    try std.testing.expectEqual(try expected(root), s.lookup(root).bytes);
    for (paths.items[0..40]) |p| {
        const info = s.lookup(p);
        try std.testing.expectEqual(st.Status.exact, info.status);
        try std.testing.expectEqual(try expected(p), info.bytes);
    }
    // Revalidate everything after random changes.
    try sh(root, "python3 -c \"import os,random,shutil\nrandom.seed(9)\nds=[r for r,_,_ in os.walk('.')]\nfor i in range(30):\n  d=random.choice(ds)\n  if d!='.' and os.path.exists(d) and random.random()<0.3: shutil.rmtree(d)\n  elif os.path.exists(d): open(os.path.join(d,'n%d'%i),'wb').write(b'y'*777)\"");
    s.revalidate_ms = 0;
    s.request(&owner, root, .visible, .{ .revalidate = true });
    settle(s);
    try std.testing.expectEqual(try expected(root), s.lookup(root).bytes);
}

test "a folder with 20000 subfolders: fast, and lookups never wait long" {
    if (c.system("command -v python3 >/dev/null") != 0) return error.SkipZigTest;
    var tmp_buf: [256]u8 = undefined;
    const root = try makeTestDir(&tmp_buf);
    defer ops.deleteRecursive(std.testing.allocator, root) catch unreachable;
    try sh(root, "python3 -c \"import os\nfor i in range(20000):\n  os.mkdir('d%d'%i); open('d%d/f'%i,'wb').write(b'z'*10)\"");
    const s = try st.Service.create(std.testing.allocator, 4, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    var start = nowNs();
    s.request(&owner, root, .visible, .{});
    var worst: u64 = 0;
    while (s.busy()) {
        const t = nowNs();
        _ = s.lookup(root);
        worst = @max(worst, nowNs() - t);
        _ = c.usleep(200);
    }
    const info = s.lookup(root);
    try std.testing.expectEqual(@as(i64, 200000), info.bytes);
    try std.testing.expect(worst < 100_000_000);
    s.revalidate_ms = 0;
    start = nowNs();
    s.request(&owner, root, .visible, .{ .revalidate = true });
    settle(s);
    try std.testing.expectEqual(@as(i64, 200000), s.lookup(root).bytes);
}

test "forgetting drops queued work until asked again; no threads measures nothing" {
    var tmp_buf: [256]u8 = undefined;
    const root = try makeTestDir(&tmp_buf);
    defer ops.deleteRecursive(std.testing.allocator, root) catch unreachable;
    try sh(root, "mkdir a");
    const idle = try st.Service.create(std.testing.allocator, 0, yes);
    defer idle.destroy();
    var idle_owner = idle.registerOwner();
    defer idle_owner.deinit();
    idle.request(&idle_owner, root, .visible, .{});
    try std.testing.expect(idle.busy());
    try std.testing.expectEqual(st.Status.measuring, idle.lookup(root).status);
    idle.forgetPath(&idle_owner, root);
    try std.testing.expect(!idle.busy());
    idle.request(&idle_owner, root, .visible, .{});
    try std.testing.expect(idle.busy());
    idle.stopPath(&idle_owner, root);
    try std.testing.expect(!idle.busy());

    try sh(root, "mkdir -p a/b/c/d/e/f && printf 1 > a/b/c/d/e/f/g");
    const s = try st.Service.create(std.testing.allocator, 1, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    try std.testing.expectEqual(@as(i64, 1), ask(&owner, root, .{}).bytes);
    s.revalidate_ms = 0;
    s.request(&owner, root, .visible, .{ .revalidate = true });
    s.forgetPath(&owner, root);
    settle(s);
    // Stopped midway: the old total stays, shown as being measured again.
    const info = s.lookup(root);
    try std.testing.expect(info.status == .stale or info.status == .revalidating or info.status == .exact);
    try std.testing.expectEqual(@as(i64, 1), ask(&owner, root, .{}).bytes);
    try std.testing.expectEqual(st.Status.exact, s.lookup(root).status);
}
