//! The process list the System Monitor and the IPC `processes` command read.
//! This file is the interface: the record types and arithmetic come from
//! `proc_common.zig`, the reading from one backend chosen at compile time
//! (`proc_linux.zig` reads `/proc`, `proc_freebsd.zig` the `kern.proc` sysctls). A
//! backend provides:
//!
//! * `Process`: `open(pid)`, `close`, `stat(buf)`, `uids(buf)`, `exePath(buf)`.
//!   One open `Process` describes one task, so its three reads agree.
//! * `List`: `open()`, `next()` (a pid), `close()`.
//! * `cpuTotals(buf)`, `memoryTotals(buf)`, `ticksPerSecond()`.
//!
//! No compositor, Wayland or UI dependencies.
const builtin = @import("builtin");
const common = @import("proc_common.zig");
const backend = switch (builtin.os.tag) {
    .linux => @import("proc_linux.zig"),
    .freebsd => @import("proc_freebsd.zig"),
    else => @compileError("the process list is not ported to this OS (docs/plans/freebsd.md)"),
};

pub const c = common.c;
pub const Error = common.Error;
pub const Identity = common.Identity;
pub const Stat = common.Stat;
pub const Uids = common.Uids;
pub const Cpu = common.Cpu;
pub const Memory = common.Memory;
pub const owned = common.owned;
pub const protectedName = common.protectedName;
pub const cpuPercent = common.cpuPercent;
pub const processPercent = common.processPercent;
pub const readAt = common.readAt;
pub const pageSize = common.pageSize;
pub const nowNs = common.nowNs;

pub const Process = backend.Process;
pub const List = backend.List;
pub const cpuTotals = backend.cpuTotals;
pub const memoryTotals = backend.memoryTotals;
pub const ticksPerSecond = backend.ticksPerSecond;

/// One process's stat, or null if it is gone or unreadable. `name` points into `buf`.
pub fn readStat(pid: i32, buf: []u8) ?Stat {
    const process = Process.open(pid) catch return null;
    defer process.close();
    return process.stat(buf) catch null;
}

/// Session processes and this one must never be signalled from the monitor.
/// An unreadable executable is an error, not "not protected".
pub fn isProtected(process: Process, pid: i32) Error!bool {
    if (pid <= 1 or pid == c.getpid()) return true;
    var buf: [4096]u8 = undefined;
    return protectedName(try process.exePath(&buf));
}
