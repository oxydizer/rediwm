//! What the process list means on every OS: the record types and the pure
//! arithmetic over them. The OS-specific reading is in `proc_linux.zig` and
//! `proc_freebsd.zig`, chosen by `proc.zig`.
const std = @import("std");
pub const c = @import("c");

/// What a backend may report. `IdentityUnavailable` means the record exists but
/// is unreadable or malformed; `Unsupported` means this OS has no backend yet.
pub const Error = error{ ProcessExited, PermissionDenied, ReadFailed, DataTooLarge, IdentityUnavailable, Unsupported };

/// Owned descendants; FreeBSD includes start stamps for handle validation.
pub const Tree = std.AutoArrayHashMapUnmanaged(i32, u64);

pub const Identity = struct {
    pid: i32,
    /// An opaque start stamp: with the pid it names one process for ever.
    start: u64,
    pub fn eql(a: Identity, b: Identity) bool {
        return a.pid == b.pid and a.start == b.start;
    }
};
/// CPU is in `ticksPerSecond()` units and RSS in `pageSize()` units.
pub const Stat = struct { name: []const u8, state: u8, cpu: u64, start: u64, rss: u64, ppid: i32 = 0 };

pub const Uids = [4]u32;

pub fn owned(uids: Uids, uid: u32) bool {
    for (uids) |value| if (value != uid) return false;
    return true;
}

pub fn protectedName(name: []const u8) bool {
    const clean = if (std.mem.endsWith(u8, name, " (deleted)")) name[0 .. name.len - " (deleted)".len] else name;
    const base = std.fs.path.basename(clean);
    inline for (.{ "rediwm", "rediwm-session", "rediwm-dm", "rediwm-accounts-helper", "rediwm-polkit-agent" }) |protected| {
        if (std.mem.eql(u8, base, protected)) return true;
    }
    return false;
}

pub const Cpu = struct { total: u64, idle: u64 };
/// One online logical CPU's counters; `id` survives offline CPUs in between.
pub const Core = struct { id: u32, cpu: Cpu };
/// The expanded CPU card shows at most this many cores.
pub const max_cores = 1024;
pub const System = struct {
    logical_cpus: ?u32 = null,
    frequency_ghz: ?f64 = null,
    uptime_seconds: ?u64 = null,
    temperature_c: ?f64 = null,
    gpu_temperature_c: ?f64 = null,
    network: ?Network = null,
    /// 1, 5 and 15 minute load averages.
    load: ?[3]f64 = null,
    /// Every thread on the system (Linux reports it beside the load).
    threads: ?u64 = null,
};
pub const Network = struct { received: u64 = 0, sent: u64 = 0, interfaces: u64 = 0 };
pub const NetworkRate = struct { received: f64, sent: f64 };

/// Interface changes and reset counters need a fresh baseline, as does resume.
pub fn networkRate(before: Network, after: Network, elapsed_ns: u64) ?NetworkRate {
    if (elapsed_ns == 0 or before.interfaces != after.interfaces or
        after.received < before.received or after.sent < before.sent) return null;
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000;
    return .{
        .received = @as(f64, @floatFromInt(after.received - before.received)) / seconds,
        .sent = @as(f64, @floatFromInt(after.sent - before.sent)) / seconds,
    };
}

pub fn cpuPercent(before: Cpu, after: Cpu) ?f64 {
    if (after.total <= before.total or after.idle < before.idle) return null;
    const total = after.total - before.total;
    return @as(f64, @floatFromInt(total -| (after.idle - before.idle))) * 100 / @as(f64, @floatFromInt(total));
}
/// Process CPU uses one core = 100%, and may exceed 100% for threaded apps.
pub fn processPercent(before: Stat, after: Stat, hz: u64, elapsed_ns: u64) ?f64 {
    if (before.start != after.start or after.cpu < before.cpu or hz == 0 or elapsed_ns == 0) return null;
    return @as(f64, @floatFromInt(after.cpu - before.cpu)) * 100 * 1_000_000_000 /
        (@as(f64, @floatFromInt(hz)) * @as(f64, @floatFromInt(elapsed_ns)));
}

pub const Memory = struct {
    total: u64,
    available: u64,
    swap_total: ?u64,
    swap_free: ?u64,
    /// Never used, not even as cache.
    free: ?u64 = null,
    /// Buffers and page cache the kernel can reclaim (free(1)'s buff/cache).
    cached: ?u64 = null,
    /// tmpfs and shared memory, counted inside `cached`.
    shared: ?u64 = null,
    pub fn used(self: Memory) u64 {
        return self.total -| self.available;
    }
};

pub fn readAt(dir: c_int, path: [*:0]const u8, buf: []u8) ![]const u8 {
    const fd = c.openat(dir, path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return switch (std.posix.errno(fd)) {
        .ACCES, .PERM => error.PermissionDenied,
        .NOENT, .SRCH => error.ProcessExited,
        else => error.ReadFailed,
    };
    defer _ = c.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(fd, buf.ptr + len, buf.len - len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) return error.ReadFailed;
        if (n == 0) return buf[0..len];
        len += @intCast(n);
    }
    return error.DataTooLarge;
}

pub fn pageSize() u64 {
    const value = c.sysconf(c._SC_PAGESIZE);
    return if (value > 0) @intCast(value) else 0;
}

pub fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
