//! FreeBSD backend of the process list: `kern.proc` sysctls, since FreeBSD has
//! no procfs by default. One `Process` holds the `kinfo_proc` taken when it was
//! opened, so its three reads agree. CPU is in microseconds (`ki_runtime`, so
//! `ticksPerSecond` is 1e6) and RSS in pages. `start` is the start time in
//! microseconds, which with the pid names one process.
//!
//! Not read: swap (needs `vm.swap_info`), and a long command name (`ki_comm`
//! holds 19 characters).
const std = @import("std");
const common = @import("proc_common.zig");
const c = common.c;
const Error = common.Error;

const Info = c.struct_kinfo_proc;

const ctl_kern = 1;
const kern_proc = 14;
const kern_proc_all = 0;
const kern_proc_pid = 1;
const kern_proc_pathname = 12;

const allocator = std.heap.c_allocator;

fn classify(err: std.posix.E) Error {
    return switch (err) {
        .PERM, .ACCES => error.PermissionDenied,
        .SRCH => error.ProcessExited,
        .NOMEM => error.DataTooLarge,
        else => error.ReadFailed,
    };
}

fn lastError() Error {
    return classify(std.posix.errno(@as(c_int, -1)));
}

pub const Process = struct {
    info: Info,
    pid: i32,

    pub fn open(pid: i32) Error!Process {
        var mib = [_]c_int{ ctl_kern, kern_proc, kern_proc_pid, pid };
        var self: Process = .{ .info = undefined, .pid = pid };
        var len: usize = @sizeOf(Info);
        if (std.c.sysctl(&mib, mib.len, &self.info, &len, null, 0) != 0) return lastError();
        // An unknown pid is a success with nothing returned.
        if (len == 0) return error.ProcessExited;
        if (len != @sizeOf(Info) or self.info.ki_structsize != @sizeOf(Info)) return error.ReadFailed;
        if (self.info.ki_pid != pid) return error.ProcessExited;
        return self;
    }

    pub fn close(_: Process) void {}

    pub fn stat(self: Process, buf: []u8) Error!common.Stat {
        const comm: *const [@sizeOf(@TypeOf(self.info.ki_comm))]u8 = @ptrCast(&self.info.ki_comm);
        const name = std.mem.sliceTo(comm, 0);
        if (name.len > buf.len) return error.DataTooLarge;
        @memcpy(buf[0..name.len], name);
        const start = self.info.ki_start;
        return .{
            .name = buf[0..name.len],
            .state = stateLetter(@bitCast(self.info.ki_stat)),
            .cpu = self.info.ki_runtime,
            .start = @as(u64, @intCast(@max(start.tv_sec, 0))) * 1_000_000 + @as(u64, @intCast(@max(start.tv_usec, 0))),
            .rss = @intCast(@max(self.info.ki_rssize, 0)),
            .ppid = self.info.ki_ppid,
        };
    }

    /// Real, effective, saved and (FreeBSD has no such thing) file system uid.
    pub fn uids(self: Process, _: []u8) Error!common.Uids {
        return .{ self.info.ki_ruid, self.info.ki_uid, self.info.ki_svuid, self.info.ki_uid };
    }

    /// Read by pid when asked, so a number reused since `open` would answer for
    /// the new process; callers also compare `start` (see `actions.zig`).
    pub fn exePath(self: Process, buf: []u8) Error![]const u8 {
        var mib = [_]c_int{ ctl_kern, kern_proc, kern_proc_pathname, self.pid };
        var len: usize = buf.len;
        if (std.c.sysctl(&mib, mib.len, buf.ptr, &len, null, 0) != 0) return lastError();
        const path = std.mem.sliceTo(buf[0..len], 0);
        // Kernel threads have none.
        if (path.len == 0) return error.IdentityUnavailable;
        return path;
    }
};

/// The letters Linux's `/proc/<pid>/stat` uses, from `ki_stat` (`sys/proc.h`).
fn stateLetter(code: u8) u8 {
    return switch (code) {
        1 => 'I', // SIDL: being created
        2 => 'R', // SRUN
        3 => 'S', // SSLEEP
        4 => 'T', // SSTOP
        5 => 'Z', // SZOMB
        6, 7 => 'D', // SWAIT, SLOCK
        else => '?',
    };
}

pub const List = struct {
    entries: []Info,
    count: usize,
    index: usize = 0,

    pub fn open() ?List {
        var mib = [_]c_int{ ctl_kern, kern_proc, kern_proc_all };
        var size: usize = 0;
        if (std.c.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return null;
        // The table can grow between the size query and the read: leave room
        // and retry when the kernel still says it is too small.
        var attempt: usize = 0;
        while (attempt < 4) : (attempt += 1) {
            const capacity = size / @sizeOf(Info) + 32 + size / @sizeOf(Info) / 8;
            const entries = allocator.alloc(Info, capacity) catch return null;
            var len: usize = capacity * @sizeOf(Info);
            if (std.c.sysctl(&mib, mib.len, entries.ptr, &len, null, 0) == 0) {
                const count = len / @sizeOf(Info);
                if (len % @sizeOf(Info) == 0 and (count == 0 or entries[0].ki_structsize == @sizeOf(Info)))
                    return .{ .entries = entries, .count = count };
                allocator.free(entries);
                return null;
            }
            allocator.free(entries);
            if (std.posix.errno(@as(c_int, -1)) != .NOMEM) return null;
            size = capacity * @sizeOf(Info) * 2;
        }
        return null;
    }

    pub fn next(self: *List) ?i32 {
        while (self.index < self.count) {
            const pid = self.entries[self.index].ki_pid;
            self.index += 1;
            if (pid > 0) return pid;
        }
        return null;
    }

    pub fn close(self: *List) void {
        allocator.free(self.entries);
        self.entries = &.{};
        self.count = 0;
    }
};

fn sysctlValue(comptime T: type, name: [*:0]const u8) ?T {
    var value: T = undefined;
    var len: usize = @sizeOf(T);
    if (std.c.sysctlbyname(name, &value, &len, null, 0) != 0 or len != @sizeOf(T)) return null;
    return value;
}

/// `kern.cp_time`: user, nice, system, interrupt and idle ticks, all CPUs.
pub fn cpuTotals(_: []u8) ?common.Cpu {
    var times: [5]c_long = undefined;
    var len: usize = @sizeOf(@TypeOf(times));
    if (std.c.sysctlbyname("kern.cp_time", &times, &len, null, 0) != 0 or len != @sizeOf(@TypeOf(times))) return null;
    var total: u64 = 0;
    for (times) |ticks| total += @intCast(@max(ticks, 0));
    return .{ .total = total, .idle = @intCast(@max(times[4], 0)) };
}

/// Available is free plus inactive pages. Swap is not read.
pub fn memoryTotals(_: []u8) ?common.Memory {
    const page = common.pageSize();
    if (page == 0) return null;
    const total = sysctlValue(c_ulong, "hw.physmem") orelse return null;
    const free = sysctlValue(c_uint, "vm.stats.vm.v_free_count") orelse return null;
    const inactive = sysctlValue(c_uint, "vm.stats.vm.v_inactive_count") orelse return null;
    return .{
        .total = total,
        .available = @min(total, (@as(u64, free) + inactive) * page),
        .swap_total = null,
        .swap_free = null,
    };
}

pub fn ticksPerSecond() u64 {
    return 1_000_000;
}
