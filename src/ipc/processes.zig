//! A bounded, request-driven /proc sample. The worker owns copied identities;
//! no compositor objects or Wayland calls are accessed off the event loop.
const std = @import("std");
const wl = @import("wayland").server.wl;
const protocol = @import("protocol.zig");
const Client = @import("server.zig").Client;
const Server = @import("../Server.zig");
const gpa = @import("../main.zig").gpa;
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("sys/eventfd.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
});

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    client: *Client, // event-loop access only
    id: ?protocol.RequestId,
    source: ?*wl.EventSource = null,
    fd: c_int,
    refs: std.atomic.Value(u32) = .init(1),
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    rows: []protocol.ProcessData,
    sample_ms: u32 = 200,

    fn unref(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = c.close(job.fd);
        job.arena.deinit();
        gpa.destroy(job);
    }
    pub fn cancel(job: *Job) void {
        job.cancelled.store(true, .release);
        if (job.source) |source| source.remove();
        job.source = null;
        job.unref();
    }
    fn run(job: *Job) void {
        defer job.unref();
        const ticks = c.sysconf(c._SC_CLK_TCK);
        const page = c.sysconf(c._SC_PAGESIZE);
        const a = job.arena.allocator();
        const first = a.alloc(?Sample, job.rows.len) catch {
            job.complete();
            return;
        };
        const start_ns = nowNs();
        for (job.rows, first) |row, *sample| sample.* = readSample(row.pid);
        if (job.rows.len > 0) {
            var delay: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 200_000_000 };
            while (c.nanosleep(&delay, &delay) != 0) {
                if (std.posix.errno(-1) != .INTR) break;
            }
        }
        const elapsed = nowNs() -| start_ns;
        job.sample_ms = @intCast(@min(elapsed / 1_000_000, std.math.maxInt(u32)));
        for (job.rows, first) |*row, before| {
            if (job.cancelled.load(.acquire)) return;
            const after = readSample(row.pid) orelse continue;
            const prev = before orelse continue;
            if (prev.start != after.start) continue;
            row.running = true;
            row.start_ticks = after.start;
            if (page > 0) row.rss_bytes = std.math.mul(u64, after.rss, @intCast(page)) catch null;
            if (ticks > 0 and elapsed > 0 and after.cpu >= prev.cpu)
                row.cpu_percent = @as(f64, @floatFromInt(after.cpu - prev.cpu)) * 100 * 1_000_000_000 /
                    (@as(f64, @floatFromInt(ticks)) * @as(f64, @floatFromInt(elapsed)));
        }
        job.complete();
    }
    fn complete(job: *Job) void {
        job.done.store(true, .release);
        const one: u64 = 1;
        _ = c.write(job.fd, &one, @sizeOf(u64));
    }
};

const Sample = struct { cpu: u64, start: u64, rss: u64 };
fn readSample(pid: i32) ?Sample {
    var path: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return null;
    const fd = c.open(name, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const bytes = buf[0..@intCast(n)];
    const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, bytes[end + 1 ..], ' ');
    var utime: u64 = 0;
    var stime: u64 = 0;
    var start_ticks: u64 = 0;
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        switch (index) {
            11 => utime = std.fmt.parseInt(u64, field, 10) catch return null,
            12 => stime = std.fmt.parseInt(u64, field, 10) catch return null,
            19 => start_ticks = std.fmt.parseInt(u64, field, 10) catch return null,
            21 => return .{ .cpu = utime +| stime, .start = start_ticks, .rss = std.fmt.parseInt(u64, field, 10) catch return null },
            else => {},
        }
    }
    return null;
}
fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

pub fn start(server: *Server, id: ?protocol.RequestId, maybe_client: ?*Client) !protocol.Response {
    const client = maybe_client orelse return .{ .err = "ClientRequired" };
    if (client.process_job != null) return .{ .err = "ProcessSampleBusy" };
    var pending: usize = 0;
    for (client.ipc.clients.items) |peer| if (peer.process_job != null) {
        pending += 1;
    };
    if (pending >= 4) return .{ .err = "ProcessSampleBusy" };
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(protocol.ProcessData) = .empty;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |t| {
        const pid = t.clientPid() orelse continue;
        if (pid <= 0 or !t.in_world) continue;
        var found = false;
        for (rows.items) |*row| if (row.pid == pid) {
            const ids = try a.alloc(u64, row.window_ids.len + 1);
            @memcpy(ids[0..row.window_ids.len], row.window_ids);
            ids[ids.len - 1] = t.id;
            row.window_ids = ids;
            found = true;
            break;
        };
        if (found) continue;
        if (rows.items.len >= 4096) return error.TooManyProcesses;
        const ids = try a.alloc(u64, 1);
        ids[0] = t.id;
        try rows.append(a, .{ .pid = pid, .app_id = try a.dupe(u8, t.appId()), .window_ids = ids });
    }
    const owned_id: ?protocol.RequestId = if (id) |rid| switch (rid) {
        .integer => rid,
        .string => |value| .{ .string = try a.dupe(u8, value) },
    } else null;
    const fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (fd < 0) return error.EventFdFailed;
    errdefer _ = c.close(fd);
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{ .arena = arena, .client = client, .id = owned_id, .rows = rows.items, .fd = fd };
    job.source = try server.wl_server.getEventLoop().addFd(*Job, fd, .{ .readable = true }, ready, job);
    errdefer job.source.?.remove();
    job.refs.store(2, .release);
    const thread = try std.Thread.spawn(.{}, Job.run, .{job});
    thread.detach();
    client.process_job = job;
    return .{ .ok = .async_pending };
}

fn ready(_: c_int, _: wl.EventMask, job: *Job) c_int {
    if (!job.done.load(.acquire)) return 0;
    const client = job.client;
    const server = client.ipc.compositor;
    var response: protocol.Response = .{ .ok = .{ .processes = .{ .processes = job.rows, .sample_ms = job.sample_ms } } };
    // Authorization may have changed while the worker sampled.
    if (server.locker != null) response = .{ .err = "SessionLocked" } else if (server.polkit_dialog != null) response = .{ .err = "AuthenticationActive" };
    if (client.sandbox) |sb| {
        if (!server.config.sandboxAllowGroups(sb.app_id, sb.engine).contains(.ipc)) response = .{ .err = "PermissionDenied" };
    }
    const writer = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
    protocol.stringifyResponseWithId(job.id, response, writer) catch {};
    client.updateFdInterest() catch {};
    client.process_job = null;
    job.cancel();
    return 0;
}
