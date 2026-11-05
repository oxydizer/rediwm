//! FreeBSD backend of the process list: not written yet (docs/plans/freebsd.md,
//! phase 3: `kern.proc` sysctls or libprocstat; FreeBSD has no procfs by
//! default). Everything reports "unavailable", so the System Monitor shows its
//! status line instead of rows and the IPC `processes` command finds no samples.
const common = @import("proc_common.zig");
const Error = common.Error;

pub const Process = struct {
    pub fn open(_: i32) Error!Process {
        return error.Unsupported;
    }
    pub fn close(_: Process) void {}
    pub fn stat(_: Process, _: []u8) Error!common.Stat {
        return error.Unsupported;
    }
    pub fn uids(_: Process, _: []u8) Error!common.Uids {
        return error.Unsupported;
    }
    pub fn exePath(_: Process, _: []u8) Error![]const u8 {
        return error.Unsupported;
    }
};

pub const List = struct {
    pub fn open() ?List {
        return null;
    }
    pub fn next(_: *List) ?i32 {
        return null;
    }
    pub fn close(_: *List) void {}
};

pub fn cpuTotals(_: []u8) ?common.Cpu {
    return null;
}

pub fn memoryTotals(_: []u8) ?common.Memory {
    return null;
}

pub fn ticksPerSecond() u64 {
    return 0;
}
