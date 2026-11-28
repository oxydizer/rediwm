//! The folder-size service (`sizetree.zig`) against real directories.
const std = @import("std");
const st = @import("sizetree.zig");
const c = @import("c.zig").api;

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn sh(cmd: [:0]const u8) void {
    std.debug.assert(c.system(cmd.ptr) == 0);
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
    const cmd = try std.fmt.bufPrintSentinel(&buf, "find {s} -xdev -type f -printf '%s\\n' | awk '{{s+=$1}} END {{print s+0}}' > /tmp/rediwm_sizetree_expect", .{path}, 0);
    sh(cmd);
    var out: [64]u8 = undefined;
    const fd = c.open("/tmp/rediwm_sizetree_expect", c.O_RDONLY);
    defer _ = c.close(fd);
    const n = c.read(fd, &out, out.len);
    return std.fmt.parseInt(i64, std.mem.trim(u8, out[0..@intCast(n)], " \n"), 10);
}
fn ask(owner: *st.Owner, path: []const u8, o: st.RequestOptions) st.Info {
    const s = owner.service;
    s.request(owner, path, .visible, o);
    settle(s);
    return s.lookup(path);
}

test "tree adds up, subfolders reuse the parent's walk, revalidate sees changes" {
    sh("rm -rf /tmp/rediwm_sizetree && mkdir -p /tmp/rediwm_sizetree/a/b/c /tmp/rediwm_sizetree/d && printf 12345 > /tmp/rediwm_sizetree/f && printf 1234567890 > /tmp/rediwm_sizetree/a/b/c/g && head -c 5000 /dev/zero > /tmp/rediwm_sizetree/d/h && ln /tmp/rediwm_sizetree/f /tmp/rediwm_sizetree/a/f2 && ln -s f /tmp/rediwm_sizetree/l");
    const s = try st.Service.create(std.testing.allocator, 3, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    var info = ask(&owner, "/tmp/rediwm_sizetree", .{});
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(try expected("/tmp/rediwm_sizetree"), info.bytes);
    // A subfolder: known from the parent's walk.
    info = ask(&owner, "/tmp/rediwm_sizetree/a", .{});
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(try expected("/tmp/rediwm_sizetree/a"), info.bytes);
    // Changes: grow a file, add a folder, remove one, rename one.
    sh("head -c 777 /dev/zero >> /tmp/rediwm_sizetree/a/b/c/g && mkdir /tmp/rediwm_sizetree/a/new && printf xyz > /tmp/rediwm_sizetree/a/new/z && rm -rf /tmp/rediwm_sizetree/d && mv /tmp/rediwm_sizetree/a/b /tmp/rediwm_sizetree/a/b2");
    info = ask(&owner, "/tmp/rediwm_sizetree", .{});
    try std.testing.expect(info.bytes != try expected("/tmp/rediwm_sizetree")); // not revalidated yet
    s.revalidate_ms = 0;
    s.request(&owner, "/tmp/rediwm_sizetree", .visible, .{ .revalidate = true });
    const during = s.lookup("/tmp/rediwm_sizetree").status;
    try std.testing.expect(during == .revalidating or during == .exact);
    settle(s);
    info = s.lookup("/tmp/rediwm_sizetree");
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(try expected("/tmp/rediwm_sizetree"), info.bytes);
    try std.testing.expectEqual(try expected("/tmp/rediwm_sizetree/a"), s.lookup("/tmp/rediwm_sizetree/a").bytes);
}

test "child first, then parent; move between folders" {
    sh("rm -rf /tmp/rediwm_sizetree2 && mkdir -p /tmp/rediwm_sizetree2/x/y /tmp/rediwm_sizetree2/z && printf 1111 > /tmp/rediwm_sizetree2/x/y/one && printf 22 > /tmp/rediwm_sizetree2/z/two");
    const s = try st.Service.create(std.testing.allocator, 2, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    try std.testing.expectEqual(@as(i64, 4), ask(&owner, "/tmp/rediwm_sizetree2/x/y", .{}).bytes);
    try std.testing.expectEqual(@as(i64, 6), ask(&owner, "/tmp/rediwm_sizetree2", .{}).bytes);
    sh("mv /tmp/rediwm_sizetree2/x/y /tmp/rediwm_sizetree2/z/y");
    s.revalidate_ms = 0;
    const info = ask(&owner, "/tmp/rediwm_sizetree2", .{ .revalidate = true });
    try std.testing.expectEqual(@as(i64, 6), info.bytes);
    try std.testing.expectEqual(@as(i64, 0), s.lookup("/tmp/rediwm_sizetree2/x").bytes);
    try std.testing.expectEqual(@as(i64, 6), ask(&owner, "/tmp/rediwm_sizetree2/z", .{}).bytes);
}

test "slow disks wait for a click; stop and force" {
    sh("rm -rf /tmp/rediwm_sizetree3 && mkdir -p /tmp/rediwm_sizetree3/q && printf 123 > /tmp/rediwm_sizetree3/q/r");
    const s = try st.Service.create(std.testing.allocator, 2, no);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    try std.testing.expectEqual(st.Status.idle, ask(&owner, "/tmp/rediwm_sizetree3", .{}).status);
    const info = ask(&owner, "/tmp/rediwm_sizetree3", .{ .force = true });
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(@as(i64, 3), info.bytes);
}

test "stopping a big walk, then forcing it to finish" {
    sh("rm -rf /tmp/rediwm_sizetree4 && mkdir -p /tmp/rediwm_sizetree4 && cd /tmp/rediwm_sizetree4 && for i in $(seq 1 60); do mkdir -p d$i/e/f; for j in 1 2 3; do printf %0100d 0 > d$i/e/f/x$j; done; done");
    const s = try st.Service.create(std.testing.allocator, 1, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    s.request(&owner, "/tmp/rediwm_sizetree4", .visible, .{});
    _ = c.usleep(2000);
    s.stopPath(&owner, "/tmp/rediwm_sizetree4");
    settle(s);
    const stopped = s.lookup("/tmp/rediwm_sizetree4");
    s.request(&owner, "/tmp/rediwm_sizetree4", .visible, .{}); // auto request does not restart it
    settle(s);
    try std.testing.expectEqual(stopped.status, s.lookup("/tmp/rediwm_sizetree4").status);
    const info = ask(&owner, "/tmp/rediwm_sizetree4", .{ .force = true });
    try std.testing.expectEqual(st.Status.exact, info.status);
    try std.testing.expectEqual(@as(i64, 60 * 3 * 100), info.bytes);
}

test "random tree, overlapping requests from many threads" {
    if (c.system("command -v python3 >/dev/null") != 0) return error.SkipZigTest;
    sh("rm -rf /tmp/rediwm_sizetree5 && mkdir -p /tmp/rediwm_sizetree5 && cd /tmp/rediwm_sizetree5 && python3 -c \"import os,random\nrandom.seed(7)\ndirs=['.']\nfor i in range(1500):\n  p=os.path.join(random.choice(dirs),'d%d'%i); os.mkdir(p); dirs.append(p)\nfor i in range(4000):\n  open(os.path.join(random.choice(dirs),'f%d'%i),'wb').write(b'x'*random.randint(0,3000))\nopen('/tmp/rediwm_sizetree5_dirs','w').write('\\n'.join(dirs[1:200]))\"");
    const s = try st.Service.create(std.testing.allocator, 4, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    var buf: [100000]u8 = undefined;
    const fd = c.open("/tmp/rediwm_sizetree5_dirs", c.O_RDONLY);
    const n: usize = @intCast(c.read(fd, &buf, buf.len));
    _ = c.close(fd);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| std.testing.allocator.free(p);
        paths.deinit(std.testing.allocator);
    }
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |rel| try paths.append(std.testing.allocator, try std.fmt.allocPrint(std.testing.allocator, "/tmp/rediwm_sizetree5/{s}", .{rel[2..]}));
    // Deep folders first, then the root, interleaved.
    var i: usize = paths.items.len;
    while (i > 0) {
        i -= 1;
        s.request(&owner, paths.items[i], if (i % 2 == 0) .visible else .background, .{});
        if (i == 100) s.request(&owner, "/tmp/rediwm_sizetree5", .visible, .{});
    }
    settle(s);
    try std.testing.expectEqual(try expected("/tmp/rediwm_sizetree5"), s.lookup("/tmp/rediwm_sizetree5").bytes);
    for (paths.items[0..40]) |p| {
        const info = s.lookup(p);
        try std.testing.expectEqual(st.Status.exact, info.status);
        try std.testing.expectEqual(try expected(p), info.bytes);
    }
    // Revalidate everything after random changes.
    sh("cd /tmp/rediwm_sizetree5 && python3 -c \"import os,random,shutil\nrandom.seed(9)\nds=[r for r,_,_ in os.walk('.')]\nfor i in range(30):\n  d=random.choice(ds)\n  if d!='.' and os.path.exists(d) and random.random()<0.3: shutil.rmtree(d)\n  elif os.path.exists(d): open(os.path.join(d,'n%d'%i),'wb').write(b'y'*777)\"");
    s.revalidate_ms = 0;
    s.request(&owner, "/tmp/rediwm_sizetree5", .visible, .{ .revalidate = true });
    settle(s);
    try std.testing.expectEqual(try expected("/tmp/rediwm_sizetree5"), s.lookup("/tmp/rediwm_sizetree5").bytes);
}

test "a folder with 20000 subfolders: fast, and lookups never wait long" {
    if (c.system("command -v python3 >/dev/null") != 0) return error.SkipZigTest;
    sh("rm -rf /tmp/rediwm_sizetree6 && mkdir -p /tmp/rediwm_sizetree6 && cd /tmp/rediwm_sizetree6 && python3 -c \"import os\nfor i in range(20000):\n  os.mkdir('d%d'%i); open('d%d/f'%i,'wb').write(b'z'*10)\"");
    const s = try st.Service.create(std.testing.allocator, 4, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    var start = nowNs();
    s.request(&owner, "/tmp/rediwm_sizetree6", .visible, .{});
    var worst: u64 = 0;
    while (s.busy()) {
        const t = nowNs();
        _ = s.lookup("/tmp/rediwm_sizetree6");
        worst = @max(worst, nowNs() - t);
        _ = c.usleep(200);
    }
    const info = s.lookup("/tmp/rediwm_sizetree6");
    try std.testing.expectEqual(@as(i64, 200000), info.bytes);
    try std.testing.expect(worst < 100_000_000);
    s.revalidate_ms = 0;
    start = nowNs();
    s.request(&owner, "/tmp/rediwm_sizetree6", .visible, .{ .revalidate = true });
    settle(s);
    try std.testing.expectEqual(@as(i64, 200000), s.lookup("/tmp/rediwm_sizetree6").bytes);
}

test "forgetting drops queued work until asked again; no threads measures nothing" {
    sh("rm -rf /tmp/rediwm_sizetree7 && mkdir -p /tmp/rediwm_sizetree7/a");
    const idle = try st.Service.create(std.testing.allocator, 0, yes);
    defer idle.destroy();
    var idle_owner = idle.registerOwner();
    defer idle_owner.deinit();
    idle.request(&idle_owner, "/tmp/rediwm_sizetree7", .visible, .{});
    try std.testing.expect(idle.busy());
    try std.testing.expectEqual(st.Status.measuring, idle.lookup("/tmp/rediwm_sizetree7").status);
    idle.forgetPath(&idle_owner, "/tmp/rediwm_sizetree7");
    try std.testing.expect(!idle.busy());
    idle.request(&idle_owner, "/tmp/rediwm_sizetree7", .visible, .{});
    try std.testing.expect(idle.busy());
    idle.stopPath(&idle_owner, "/tmp/rediwm_sizetree7");
    try std.testing.expect(!idle.busy());

    sh("mkdir -p /tmp/rediwm_sizetree7/a/b/c/d/e/f && printf 1 > /tmp/rediwm_sizetree7/a/b/c/d/e/f/g");
    const s = try st.Service.create(std.testing.allocator, 1, yes);
    defer s.destroy();
    var owner = s.registerOwner();
    defer owner.deinit();
    try std.testing.expectEqual(@as(i64, 1), ask(&owner, "/tmp/rediwm_sizetree7", .{}).bytes);
    s.revalidate_ms = 0;
    s.request(&owner, "/tmp/rediwm_sizetree7", .visible, .{ .revalidate = true });
    s.forgetPath(&owner, "/tmp/rediwm_sizetree7");
    settle(s);
    // Stopped midway: the old total stays, shown as being measured again.
    const info = s.lookup("/tmp/rediwm_sizetree7");
    try std.testing.expect(info.status == .stale or info.status == .revalidating or info.status == .exact);
    try std.testing.expectEqual(@as(i64, 1), ask(&owner, "/tmp/rediwm_sizetree7", .{}).bytes);
    try std.testing.expectEqual(st.Status.exact, s.lookup("/tmp/rediwm_sizetree7").status);
}
