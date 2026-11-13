//! Linux backend of the process list: /proc. A `Process` holds the
//! `/proc/<pid>` directory open, so every file read belongs to the same task.
//! The parsers are pure functions; their tests run on every OS.
const std = @import("std");
const common = @import("proc_common.zig");
const c = common.c;
const Error = common.Error;
const Stat = common.Stat;
const Uids = common.Uids;
const Cpu = common.Cpu;
const Memory = common.Memory;
const readAt = common.readAt;
pub const descendants = @import("proc_linux_children.zig").descendants;
pub const systemStats = @import("proc_linux_system.zig").sample;

/// comm may contain spaces, newlines and closing parentheses. Field 3 starts
/// after the LAST closing parenthesis; fields 4/14/15/22/24 are PPID/CPU/start/RSS.
pub fn parseStat(bytes: []const u8) ?Stat {
    const begin = std.mem.indexOfScalar(u8, bytes, '(') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return null;
    if (end <= begin) return null;
    var fields = std.mem.tokenizeAny(u8, bytes[end + 1 ..], " \n");
    var out: Stat = .{ .name = bytes[begin + 1 .. end], .state = '?', .cpu = 0, .start = 0, .rss = 0 };
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) switch (index) {
        0 => {
            if (field.len != 1) return null;
            out.state = field[0];
        },
        1 => out.ppid = std.fmt.parseInt(i32, field, 10) catch return null,
        11, 12 => out.cpu +|= std.fmt.parseInt(u64, field, 10) catch return null,
        19 => out.start = std.fmt.parseInt(u64, field, 10) catch return null,
        21 => {
            const rss = std.fmt.parseInt(i64, field, 10) catch return null;
            out.rss = @intCast(@max(0, rss));
            return out;
        },
        else => {},
    };
    return null;
}

pub fn parseUids(bytes: []const u8) ?Uids {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var values = std.mem.tokenizeAny(u8, line[4..], " \t");
        var out: Uids = undefined;
        for (&out) |*uid| uid.* = std.fmt.parseInt(u32, values.next() orelse return null, 10) catch return null;
        return out;
    }
    return null;
}

pub fn parseCpu(bytes: []const u8) ?Cpu {
    var fields = std.mem.tokenizeAny(u8, bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len], " \t");
    if (!std.mem.eql(u8, fields.next() orelse return null, "cpu")) return null;
    return cpuFields(&fields);
}

/// The `cpuN` lines in order; offline CPUs have none, so `id` keeps N.
pub fn parseCores(bytes: []const u8, out: []common.Core) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (count == out.len) break;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, name, "cpu")) {
            // The per-CPU lines follow the total; anything else ends them.
            if (count > 0) break;
            continue;
        }
        if (name.len == 3) continue;
        const id = std.fmt.parseInt(u32, name[3..], 10) catch continue;
        out[count] = .{ .id = id, .cpu = cpuFields(&fields) orelse continue };
        count += 1;
    }
    return count;
}

fn cpuFields(fields: *std.mem.TokenIterator(u8, .any)) ?Cpu {
    var out: Cpu = .{ .total = 0, .idle = 0 };
    var count: usize = 0;
    // guest and guest_nice are already included in user/nice.
    while (fields.next()) |field| : (count += 1) {
        if (count == 8) break;
        const ticks = std.fmt.parseInt(u64, field, 10) catch return null;
        out.total +|= ticks;
        if (count == 3 or count == 4) out.idle +|= ticks;
    }
    return if (count >= 4) out else null;
}

pub fn parseMemory(bytes: []const u8) ?Memory {
    var total: ?u64 = null;
    var available: ?u64 = null;
    var swap_total: ?u64 = null;
    var swap_free: ?u64 = null;
    // Free, buff/cache (Buffers + Cached + SReclaimable) and Shmem.
    var extra: [5]?u64 = @splat(null);
    const extra_keys = [_][]const u8{ "MemFree:", "Buffers:", "Cached:", "SReclaimable:", "Shmem:" };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const key = fields.next() orelse continue;
        const slot = for (extra_keys, 0..) |name, i| {
            if (std.mem.eql(u8, key, name)) break i;
        } else null;
        const relevant = std.mem.eql(u8, key, "MemTotal:") or std.mem.eql(u8, key, "MemAvailable:") or std.mem.eql(u8, key, "SwapTotal:") or std.mem.eql(u8, key, "SwapFree:");
        if (slot) |i| {
            const kb = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
            extra[i] = std.math.mul(u64, kb, 1024) catch null;
            continue;
        }
        if (!relevant) continue;
        const kb = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        if (!std.mem.eql(u8, fields.next() orelse return null, "kB")) return null;
        const value = std.math.mul(u64, kb, 1024) catch return null;
        if (std.mem.eql(u8, key, "MemTotal:")) total = value;
        if (std.mem.eql(u8, key, "MemAvailable:")) available = value;
        if (std.mem.eql(u8, key, "SwapTotal:")) swap_total = value;
        if (std.mem.eql(u8, key, "SwapFree:")) swap_free = value;
    }
    const cached: ?u64 = if (extra[1] != null and extra[2] != null)
        extra[1].? +| extra[2].? +| (extra[3] orelse 0)
    else
        null;
    return .{
        .total = total orelse return null,
        .available = available orelse return null,
        .swap_total = swap_total,
        .swap_free = swap_free,
        .free = extra[0],
        .cached = cached,
        .shared = extra[4],
    };
}

pub const Process = struct {
    dir: c_int,

    pub fn open(pid: i32) Error!Process {
        if (pid <= 0) return error.ProcessExited;
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "/proc/{d}", .{pid}, 0) catch return error.ReadFailed;
        const fd = c.open(path, c.O_DIRECTORY | c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (fd < 0) return switch (std.posix.errno(fd)) {
            .ACCES, .PERM => error.PermissionDenied,
            .NOENT, .SRCH => error.ProcessExited,
            else => error.ReadFailed,
        };
        return .{ .dir = fd };
    }
    pub fn close(self: Process) void {
        _ = c.close(self.dir);
    }
    /// `name` points into `buf`.
    pub fn stat(self: Process, buf: []u8) Error!Stat {
        return parseStat(try readAt(self.dir, "stat", buf)) orelse error.IdentityUnavailable;
    }
    pub fn uids(self: Process, buf: []u8) Error!Uids {
        return parseUids(try readAt(self.dir, "status", buf)) orelse error.IdentityUnavailable;
    }
    /// The executable's path, possibly ending in " (deleted)".
    pub fn exePath(self: Process, buf: []u8) Error![]const u8 {
        const n = c.readlinkat(self.dir, "exe", buf.ptr, buf.len);
        if (n < 0 or n == buf.len) return error.IdentityUnavailable;
        return buf[0..@intCast(n)];
    }
};

/// The pids that exist now, in no particular order.
pub const List = struct {
    dir: *c.DIR,

    pub fn open() ?List {
        return .{ .dir = c.opendir("/proc") orelse return null };
    }
    pub fn next(self: *List) ?i32 {
        while (c.readdir(self.dir)) |entry| {
            const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
            const pid = std.fmt.parseInt(i32, name, 10) catch continue;
            if (pid > 0) return pid;
        }
        return null;
    }
    pub fn close(self: *List) void {
        _ = c.closedir(self.dir);
    }
};

pub fn cpuTotals(buf: []u8) ?Cpu {
    return parseCpu(readAt(c.AT_FDCWD, "/proc/stat", buf) catch return null);
}

pub fn cpuCores(buf: []u8, out: []common.Core) usize {
    return parseCores(readAt(c.AT_FDCWD, "/proc/stat", buf) catch return 0, out);
}

pub fn memoryTotals(buf: []u8) ?Memory {
    return parseMemory(readAt(c.AT_FDCWD, "/proc/meminfo", buf) catch return null);
}

/// The unit of `Stat.cpu`.
pub fn ticksPerSecond() u64 {
    return @intCast(@max(0, c.sysconf(c._SC_CLK_TCK)));
}
