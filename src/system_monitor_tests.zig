const std = @import("std");
const platform = @import("platform");
const proc = @import("system_monitor/proc.zig");
const linux = @import("system_monitor/proc_linux.zig");
const model = @import("system_monitor/model.zig");
const collector = @import("system_monitor/collector.zig");
const actions = @import("system_monitor/actions.zig");

test {
    _ = @import("system_monitor/proc_system_tests.zig");
    _ = @import("system_monitor/proc_gpu.zig");
    _ = @import("system_monitor/proc_temperature_tests.zig");
}

test "monitor backend lists and describes this process and the machine" {
    const pid = proc.c.getpid();
    var list = proc.List.open().?;
    defer list.close();
    var listed = false;
    while (list.next()) |other| {
        if (other == pid) listed = true;
    }
    try std.testing.expect(listed);

    const process = try proc.Process.open(pid);
    defer process.close();
    var buf: [65536]u8 = undefined;
    const stat = try process.stat(&buf);
    try std.testing.expect(stat.name.len > 0);
    try std.testing.expect(stat.state == 'R' or stat.state == 'S');
    try std.testing.expectEqual(proc.c.getppid(), stat.ppid);
    try std.testing.expect(stat.start != 0 and stat.rss > 0);
    try std.testing.expect(proc.owned(try process.uids(&buf), proc.c.getuid()));
    try std.testing.expect(std.fs.path.isAbsolute(try process.exePath(&buf)));
    try std.testing.expectError(error.ProcessExited, proc.Process.open(std.math.maxInt(i32)));

    const cpu = proc.cpuTotals(&buf).?;
    try std.testing.expect(cpu.total > 0 and cpu.idle <= cpu.total);
    var cores: [proc.max_cores]proc.Core = undefined;
    try std.testing.expect(proc.cpuCores(&buf, &cores) > 0);
    const memory = proc.memoryTotals(&buf).?;
    try std.testing.expect(memory.total > 0 and memory.available <= memory.total);
    try std.testing.expect(proc.ticksPerSecond() > 0 and proc.pageSize() > 0);
}

test "monitor stat parsing preserves tricky names and rejects partial data" {
    const stat = linux.parseStat("123 (a ) strange\nname) S 1 2 3 4 5 6 7 8 9 10 100 50 0 0 20 0 1 0 987654 10000 42\n").?;
    try std.testing.expectEqual(@as(i32, 1), stat.ppid);
    try std.testing.expectEqualStrings("a ) strange\nname", stat.name);
    try std.testing.expectEqual(@as(u64, 150), stat.cpu);
    try std.testing.expectEqual(@as(u64, 987654), stat.start);
    try std.testing.expectEqual(@as(u64, 42), stat.rss);
    try std.testing.expect(linux.parseStat("123 (gone) S 1 2") == null);
    try std.testing.expect(linux.parseStat("garbage") == null);
}
test "monitor CPU excludes guest accounting and rejects reset counters and PID reuse" {
    const before = linux.parseCpu("cpu 100 20 30 400 50 10 20 10 90 10\ncpu0 1").?;
    const after = linux.parseCpu("cpu 120 20 40 440 60 10 30 20 100 10\n").?;
    try std.testing.expectEqual(@as(u64, 640), before.total);
    try std.testing.expectApproxEqAbs(@as(f64, 50), proc.cpuPercent(before, after).?, 0.001);
    try std.testing.expect(proc.cpuPercent(after, before) == null);
    // Per-CPU lines keep their numbers across an offline CPU and stop at intr.
    var cores: [4]proc.Core = undefined;
    const listed = linux.parseCores("cpu 9 9 9 9\ncpu0 10 0 0 30\ncpu2 1 2 3 4 5\nintr 5 6\ncpu3 1 1 1 1\n", &cores);
    try std.testing.expectEqual(@as(usize, 2), listed);
    try std.testing.expectEqual(@as(u32, 2), cores[1].id);
    try std.testing.expectEqual(proc.Cpu{ .total = 40, .idle = 30 }, cores[0].cpu);
    try std.testing.expectEqual(@as(usize, 1), linux.parseCores("cpu0 1 1 1 1\ncpu1 1 1 1 1\n", cores[0..1]));
    var snap: collector.Snapshot = .{ .arena = .init(std.testing.allocator), .processes = &.{}, .at_ns = 0, .cpu = null, .memory = null };
    defer snap.arena.deinit();
    var now = [_]proc.Core{ .{ .id = 0, .cpu = .{ .total = 200, .idle = 50 } }, .{ .id = 3, .cpu = .{ .total = 200, .idle = 200 } } };
    var percent = [_]?f64{ null, null };
    snap.cores = &now;
    snap.core_percent = &percent;
    collector.corePercents(&snap, &.{ .{ .id = 3, .cpu = .{ .total = 100, .idle = 100 } }, .{ .id = 0, .cpu = .{ .total = 100, .idle = 50 } } });
    try std.testing.expectApproxEqAbs(@as(f64, 100), percent[0].?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), percent[1].?, 0.001);
    var first: proc.Stat = .{ .name = "", .state = 'R', .cpu = 100, .start = 10, .rss = 0 };
    var second = first;
    second.cpu = 350;
    try std.testing.expectApproxEqAbs(@as(f64, 250), proc.processPercent(first, second, 100, 1_000_000_000).?, 0.001);
    first.start = 11;
    try std.testing.expect(proc.processPercent(first, second, 100, 1_000_000_000) == null);
}
test "monitor memory uses available rather than free and bounds missing values" {
    const mem = linux.parseMemory("MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\nSwapTotal: 500 kB\nSwapFree: 250 kB\n").?;
    try std.testing.expectEqual(@as(u64, 600 * 1024), mem.used());
    try std.testing.expectEqual(@as(u64, 500 * 1024), mem.swap_total.?);
    try std.testing.expectEqual(@as(u64, 100 * 1024), mem.free.?);
    try std.testing.expect(mem.cached == null);
    const detail = linux.parseMemory("MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\nBuffers: 10 kB\nCached: 200 kB\nShmem: 30 kB\nSReclaimable: 20 kB\n").?;
    try std.testing.expectEqual(@as(u64, 230 * 1024), detail.cached.?);
    try std.testing.expectEqual(@as(u64, 30 * 1024), detail.shared.?);
    try std.testing.expect(linux.parseMemory("MemTotal: 1000 kB\nMemFree: 100 kB\n") == null);
    try std.testing.expect(linux.parseMemory("MemTotal: 18446744073709551615 kB\nMemAvailable: 1 kB") == null);
}
fn fixture(pid: i32, start: u64, name: []const u8, uid: u32, cpu: f64) collector.Process {
    return .{ .identity = .{ .pid = pid, .start = start }, .name = name, .user = "alex", .uids = .{ uid, uid, uid, uid }, .state = 'S', .cpu_ticks = 0, .cpu_percent = cpu, .resident_bytes = 4096, .protected = false };
}
test "monitor sort search selection and scroll survive updates without following reused PIDs" {
    var snap: collector.Snapshot = .{ .arena = .init(std.testing.allocator), .processes = &.{}, .at_ns = 0, .cpu = null, .memory = null };
    defer snap.arena.deinit();
    var rows = [_]collector.Process{ fixture(21, 1, "alpha", 1000, 1), fixture(22, 2, "beta", 1000, 10), fixture(23, 3, "root", 0, 20) };
    snap.processes = &rows;
    var m: model.Model = .{ .allocator = std.testing.allocator, .snapshot = &snap, .uid = 1000, .scroll = 36 };
    defer m.rows.deinit(std.testing.allocator);
    try m.filter();
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, m.rows.items);
    m.selected = rows[0].identity;
    rows[0].cpu_percent = 50;
    try m.filter();
    try std.testing.expectEqual(@as(usize, 0), m.selectedIndex().?);
    try std.testing.expectEqual(@as(f64, 36), m.scroll);
    m.setSort(.name);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, m.rows.items);
    m.setSort(.name);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, m.rows.items);
    try std.testing.expectEqual(@as(usize, 1), m.selectedIndex().?);
    m.query = "BETA";
    try m.filter();
    try std.testing.expectEqualSlices(usize, &.{1}, m.rows.items);
    try std.testing.expect(m.selected == null);
    m.query = "";
    m.mine = false;
    try m.filter();
    try std.testing.expectEqual(@as(usize, 3), m.rows.items.len);
    m.selected = rows[0].identity;
    rows[0].identity.start = 99;
    try m.filter();
    try std.testing.expect(m.selected == null);
}
test "monitor history holds only the last 60 seconds including pause gaps" {
    var history: model.History = .{};
    var snap: collector.Snapshot = .{ .arena = .init(std.testing.allocator), .processes = &.{}, .at_ns = 0, .cpu = null, .memory = null };
    defer snap.arena.deinit();
    for (0..100) |i| {
        snap.at_ns = i * 1_000_000_000;
        history.append(&snap);
    }
    try std.testing.expectEqual(@as(usize, 60), history.count);
    snap.at_ns += 61_000_000_000;
    history.append(&snap);
    try std.testing.expectEqual(@as(usize, 1), history.count);
}
test "monitor action authority rejects changed identities and protects session executables" {
    try std.testing.expect(proc.protectedName("/usr/bin/rediwm-session"));
    try std.testing.expect(proc.protectedName("/usr/bin/rediwm (deleted)"));
    try std.testing.expect(!proc.protectedName("/usr/bin/rediwm-files"));
    try std.testing.expect(!proc.owned(.{ 1000, 0, 0, 1000 }, 1000));
    var buf: [4096]u8 = undefined;
    const own = proc.readStat(proc.c.getpid(), &buf).?;
    try std.testing.expectError(error.ProcessExited, actions.execute(.{ .pid = proc.c.getpid(), .start = own.start + 1 }, .end));
    try std.testing.expectError(error.ProtectedProcess, actions.execute(.{ .pid = proc.c.getpid(), .start = own.start }, .force));
}
test "monitor real collection includes its background worker owner and cancels" {
    var generation = std.atomic.Value(u64).init(0);
    const snap = try collector.sample(&generation, 0);
    defer snap.deinit();
    var found = false;
    for (snap.processes) |row| if (row.identity.pid == proc.c.getpid()) {
        found = true;
    };
    try std.testing.expect(found);
    generation.store(1, .release);
    try std.testing.expectError(error.Cancelled, collector.sample(&generation, 0));
}

test "monitor pidfd actions terminate only disposable fixtures and force a TERM-ignoring fixture" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" } });
    defer child.kill(io);
    var buf: [4096]u8 = undefined;
    const stat = proc.readStat(child.id.?, &buf).?;
    try actions.execute(.{ .pid = child.id.?, .start = stat.start }, .end);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.posix.SIG.TERM, term.signal);

    var stubborn = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "trap '' TERM; echo ready; exec sleep 30" }, .stdout = .pipe });
    defer stubborn.kill(io);
    var ready: [16]u8 = undefined;
    try std.testing.expect(proc.c.read(stubborn.stdout.?.handle, &ready, ready.len) > 0);
    const identity = proc.Identity{ .pid = stubborn.id.?, .start = proc.readStat(stubborn.id.?, &buf).?.start };
    const process = try platform.child.Handle.open(identity.pid);
    defer process.close();
    try actions.execute(identity, .end);
    var pollfd = proc.c.struct_pollfd{ .fd = process.fd, .events = proc.c.POLLIN, .revents = 0 };
    try std.testing.expectEqual(@as(c_int, 0), proc.c.poll(&pollfd, 1, 100));
    try actions.execute(identity, .force);
    const killed = try stubborn.wait(io);
    try std.testing.expectEqual(std.posix.SIG.KILL, killed.signal);
    try std.testing.expectError(error.ProcessExited, actions.execute(identity, .force));
}

test "monitor worker pause cancels publication and resume starts a fresh CPU interval" {
    const worker = try collector.Worker.init(std.testing.io);
    defer worker.deinit();
    var fd = proc.c.struct_pollfd{ .fd = worker.notify_fd, .events = proc.c.POLLIN, .revents = 0 };
    try std.testing.expectEqual(@as(c_int, 0), proc.c.poll(&fd, 1, 100));
    worker.setActive(true);
    try std.testing.expect(proc.c.poll(&fd, 1, 3000) > 0);
    const first = worker.take().?;
    try std.testing.expect(first.cpu_percent == null);
    try std.testing.expect(first.network_rate == null);
    first.deinit();
    worker.setActive(false);
    if (worker.take()) |unexpected| {
        unexpected.deinit();
        return error.PublishedWhilePaused;
    }
    try std.testing.expectEqual(@as(c_int, 0), proc.c.poll(&fd, 1, 1200));
    worker.setActive(true);
    try std.testing.expect(proc.c.poll(&fd, 1, 3000) > 0);
    const resumed = worker.take().?;
    defer resumed.deinit();
    try std.testing.expect(resumed.cpu_percent == null);
    try std.testing.expect(resumed.network_rate == null);
    for (resumed.processes) |row| try std.testing.expect(row.cpu_percent == null);
    // Exercise cancellation while enumeration may already be in progress.
    worker.setActive(false);
    worker.setActive(true);
    worker.setActive(false);
}

test "supervisor tree includes an owned child with its native identity" {
    var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" } });
    defer child.kill(std.testing.io);
    var tree = try proc.descendants(std.testing.allocator, std.posix.system.getpid());
    defer tree.deinit(std.testing.allocator);
    const stamp = tree.get(child.id.?) orelse return error.ChildMissing;
    try std.testing.expect(proc.treeIdentityMatches(child.id.?, stamp));
    if (stamp != 0) try std.testing.expect(!proc.treeIdentityMatches(child.id.?, stamp + 1));
}
