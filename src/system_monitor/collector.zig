//! A single cancellable worker. Snapshots own their arena; only copied data
//! crosses the mutex. Paused/hidden workers block indefinitely on an eventfd.
const std = @import("std");
const proc = @import("proc.zig");
const c = proc.c;
const a = std.heap.c_allocator;
const GpuReader = @import("proc_gpu.zig").Reader;

pub const Process = struct {
    identity: proc.Identity,
    name: []const u8,
    user: []const u8,
    uids: ?proc.Uids,
    state: u8,
    cpu_ticks: u64,
    cpu_percent: ?f64 = null,
    resident_bytes: ?u64,
    protected: bool,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    processes: []Process,
    at_ns: u64,
    cpu: ?proc.Cpu,
    cpu_percent: ?f64 = null,
    /// Online logical CPUs' counters and, from the second sample, their load.
    cores: []proc.Core = &.{},
    core_percent: []?f64 = &.{},
    memory: ?proc.Memory,
    system: proc.System = .{},
    network_rate: ?proc.NetworkRate = null,
    unavailable: usize = 0,
    truncated: bool = false,
    failed: bool = false,
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        a.destroy(self);
    }
};

pub fn sample(cancelled: *const std.atomic.Value(u64), generation: u64) !*Snapshot {
    const snapshot = try a.create(Snapshot);
    snapshot.* = .{ .arena = .init(a), .processes = &.{}, .at_ns = proc.nowNs(), .cpu = null, .memory = null };
    errdefer snapshot.deinit();
    const arena = snapshot.arena.allocator();
    var buf: [65536]u8 = undefined;
    snapshot.cpu = proc.cpuTotals(&buf);
    var cores: [proc.max_cores]proc.Core = undefined;
    const core_count = proc.cpuCores(&buf, &cores);
    snapshot.cores = try arena.dupe(proc.Core, cores[0..core_count]);
    snapshot.core_percent = try arena.alloc(?f64, core_count);
    @memset(snapshot.core_percent, null);
    snapshot.memory = proc.memoryTotals(&buf);
    snapshot.system = proc.systemStats(&buf);
    var list = proc.List.open() orelse {
        snapshot.failed = true;
        return snapshot;
    };
    defer list.close();
    const page_size = proc.pageSize();
    var rows: std.ArrayList(Process) = .empty;
    var users: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    // Avoid NSS here: a directory service outage must never prevent stopping
    // or joining the collector. Nonlocal accounts are displayed by UID.
    if (proc.readAt(c.AT_FDCWD, "/etc/passwd", &buf)) |bytes| {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ':');
            const user = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            const uid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            try users.put(arena, uid, try safeName(arena, user));
        }
    } else |_| {}
    while (list.next()) |pid| {
        if (cancelled.load(.acquire) != generation) return error.Cancelled;
        if (rows.items.len >= 131072) {
            snapshot.truncated = true;
            break;
        }
        const process = proc.Process.open(pid) catch {
            snapshot.unavailable += 1;
            continue;
        };
        defer process.close();
        const stat = process.stat(&buf) catch |err| {
            // Gone or unreadable counts as unavailable; a malformed record is skipped.
            if (err != error.IdentityUnavailable) snapshot.unavailable += 1;
            continue;
        };
        const process_name = try safeName(arena, stat.name);
        const uids = process.uids(&buf) catch null;
        const user = if (uids) |ids| blk: {
            if (users.get(ids[0])) |value| break :blk value;
            const value = try std.fmt.allocPrint(arena, "{d}", .{ids[0]});
            try users.put(arena, ids[0], value);
            break :blk value;
        } else "Unavailable";
        const protected = proc.isProtected(process, pid) catch true;
        try rows.append(arena, .{
            .identity = .{ .pid = pid, .start = stat.start },
            .name = process_name,
            .user = user,
            .uids = uids,
            .state = stat.state,
            .cpu_ticks = stat.cpu,
            .resident_bytes = if (page_size > 0) std.math.mul(u64, stat.rss, page_size) catch null else null,
            .protected = protected,
        });
    }
    snapshot.processes = rows.items;
    return snapshot;
}

fn safeName(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const value = try allocator.dupe(u8, if (std.unicode.utf8ValidateSlice(bytes)) bytes else "Unknown process");
    for (value) |*byte| if (byte.* < 32 or byte.* == 127) {
        byte.* = ' ';
    };
    return value;
}

const Baseline = struct { start: u64, cpu: u64 };
pub const Worker = struct {
    wake_fd: c_int,
    notify_fd: c_int,
    thread: ?std.Thread = null,
    generation: std.atomic.Value(u64) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    pending: ?*Snapshot = null,

    pub fn init(io: std.Io) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (wake_fd < 0) return error.EventFdFailed;
        errdefer _ = c.close(wake_fd);
        const notify = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (notify < 0) return error.EventFdFailed;
        errdefer _ = c.close(notify);
        self.* = .{ .wake_fd = wake_fd, .notify_fd = notify, .io = io };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn deinit(self: *Worker) void {
        self.stopping.store(true, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
        wake(self.wake_fd);
        self.thread.?.join();
        if (self.pending) |old| old.deinit();
        _ = c.close(self.wake_fd);
        _ = c.close(self.notify_fd);
        a.destroy(self);
    }
    pub fn setActive(self: *Worker, active: bool) void {
        if (self.active.swap(active, .acq_rel) == active) return;
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.mutex.lockUncancelable(self.io);
        if (self.pending) |old| old.deinit();
        self.pending = null;
        self.mutex.unlock(self.io);
        wake(self.wake_fd);
    }
    pub fn take(self: *Worker) ?*Snapshot {
        drain(self.notify_fd);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.pending;
        self.pending = null;
        return result;
    }
    fn run(self: *Worker) void {
        var gpu: ?GpuReader = null;
        defer if (gpu) |*reader| reader.deinit();
        var gpu_attempted = false;
        var previous: std.AutoHashMapUnmanaged(i32, Baseline) = .empty;
        defer previous.deinit(a);
        var last_at: u64 = 0;
        var last_cpu: ?proc.Cpu = null;
        var last_cores: [proc.max_cores]proc.Core = undefined;
        var last_core_count: usize = 0;
        var last_network: ?proc.Network = null;
        var observed: u64 = std.math.maxInt(u64);
        var deadline: u64 = 0;
        const hz = proc.ticksPerSecond();
        while (!self.stopping.load(.acquire)) {
            const generation = self.generation.load(.acquire);
            if (generation != observed) {
                observed = generation;
                previous.clearRetainingCapacity();
                last_at = 0;
                last_cpu = null;
                last_core_count = 0;
                last_network = null;
                deadline = 0;
            }
            if (self.active.load(.acquire) and proc.nowNs() >= deadline) {
                if (!gpu_attempted) {
                    gpu = GpuReader.init();
                    gpu_attempted = true;
                }
                const snap = sample(&self.generation, generation) catch {
                    deadline = proc.nowNs() + 1_000_000_000;
                    continue;
                };
                if (gpu) |*reader| if (reader.sample()) |temperature| {
                    snap.system.gpu_temperature_c = @max(snap.system.gpu_temperature_c orelse temperature, temperature);
                };
                if (self.generation.load(.acquire) != generation) {
                    snap.deinit();
                    continue;
                }
                if (last_cpu) |before| if (snap.cpu) |after| {
                    snap.cpu_percent = proc.cpuPercent(before, after);
                };
                corePercents(snap, last_cores[0..last_core_count]);
                last_core_count = snap.cores.len;
                @memcpy(last_cores[0..last_core_count], snap.cores);
                if (last_network) |before| if (snap.system.network) |after| {
                    snap.network_rate = proc.networkRate(before, after, snap.at_ns -| last_at);
                };
                for (snap.processes) |*row| {
                    if (previous.get(row.identity.pid)) |before| {
                        row.cpu_percent = proc.processPercent(.{ .name = "", .state = 0, .cpu = before.cpu, .start = before.start, .rss = 0 }, .{ .name = "", .state = 0, .cpu = row.cpu_ticks, .start = row.identity.start, .rss = 0 }, hz, snap.at_ns -| last_at);
                    }
                }
                previous.clearRetainingCapacity();
                for (snap.processes) |row| previous.put(a, row.identity.pid, .{ .start = row.identity.start, .cpu = row.cpu_ticks }) catch {};
                last_at = snap.at_ns;
                last_cpu = snap.cpu;
                last_network = snap.system.network;
                deadline = snap.at_ns + 1_000_000_000;
                self.mutex.lockUncancelable(self.io);
                if (self.generation.load(.acquire) == generation and self.active.load(.acquire)) {
                    if (self.pending) |old| old.deinit();
                    self.pending = snap;
                    wake(self.notify_fd);
                } else snap.deinit();
                self.mutex.unlock(self.io);
            }
            if (!self.active.load(.acquire)) {
                if (gpu) |*reader| reader.deinit();
                gpu = null;
                gpu_attempted = false;
            }
            var fd = c.struct_pollfd{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 };
            const timeout: c_int = if (!self.active.load(.acquire)) -1 else @intCast(@min(1000, (deadline -| proc.nowNs() + 999_999) / 1_000_000));
            _ = c.poll(&fd, 1, timeout);
            drain(self.wake_fd);
        }
    }
};

/// Pairs cores by id: one going offline shifts the rest of the list.
pub fn corePercents(snap: *Snapshot, before: []const proc.Core) void {
    for (snap.cores, snap.core_percent, 0..) |core, *percent, i| {
        const previous = if (i < before.len and before[i].id == core.id) before[i] else for (before) |other| {
            if (other.id == core.id) break other;
        } else continue;
        percent.* = proc.cpuPercent(previous.cpu, core.cpu);
    }
}

pub fn wake(fd: c_int) void {
    const one: u64 = 1;
    _ = c.write(fd, &one, @sizeOf(u64));
}
pub fn drain(fd: c_int) void {
    var value: u64 = undefined;
    _ = c.read(fd, &value, @sizeOf(u64));
}
