//! Process attributes that differ between systems: dying with the parent, being
//! dumped or traced, gaining privileges through exec, adopting orphans. Linux
//! uses prctl, FreeBSD procctl. `process.h` is the same for C.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const child = @import("child.zig");

// std.os.linux issues Linux syscall numbers on any target, so a build for
// another OS must fail here and not ask its kernel something else.
comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .freebsd)
        @compileError("platform.process is not ported to this OS yet (docs/plans/freebsd.md, P.4)");
}

/// FreeBSD's procctl(2): the commands and values of `sys/procctl.h`.
const bsd = struct {
    extern "c" fn procctl(idtype: c_int, id: i64, cmd: c_int, data: ?*anyopaque) c_int;
    const P_PID: c_int = 0;
    const PROC_REAP_ACQUIRE = 2;
    const PROC_REAP_RELEASE = 3;
    const PROC_REAP_STATUS = 4;
    const PROC_TRACE_CTL = 7;
    const PROC_TRACE_STATUS = 8;
    const PROC_PDEATHSIG_CTL = 11;
    const PROC_PDEATHSIG_STATUS = 12;
    const PROC_NO_NEW_PRIVS_CTL = 19;
    const PROC_NO_NEW_PRIVS_STATUS = 20;
    const TRACE_CTL_ENABLE: c_int = 1;
    const TRACE_CTL_DISABLE: c_int = 2;
    const NO_NEW_PRIVS_ENABLE: c_int = 1;
    const REAPER_STATUS_OWNED = 1;

    const ReaperStatus = extern struct {
        rs_flags: c_uint,
        rs_children: c_uint,
        rs_descendants: c_uint,
        rs_reaper: i32,
        rs_pid: i32,
        rs_pad0: [15]c_uint,
    };

    /// procctl on this process.
    fn self(cmd: c_int, data: ?*anyopaque) Error!void {
        if (procctl(P_PID, std.c.getpid(), cmd, data) != 0) return error.Failed;
    }
};

pub const Error = error{Failed};

/// A write to a closed pipe or socket then fails with EPIPE instead of ending
/// the program with SIGPIPE. Not reversible by a caller that wants the default.
pub fn ignoreBrokenPipes() void {
    setHandler(.PIPE, std.posix.SIG.IGN);
}

/// Makes the calling thread nicer (`nice` 0..19, higher yields more) without
/// touching the others. Linux only: FreeBSD's `setpriority` takes a process,
/// so there the call changes nothing.
pub fn lowerThreadPriority(nice: c_int) void {
    if (builtin.os.tag != .linux) return;
    const libc = struct {
        extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
    };
    _ = libc.setpriority(0, @intCast(linux.gettid()), nice);
}

/// Puts `sig` back to its default action.
pub fn defaultSignal(sig: child.Signal) void {
    setHandler(sig, std.posix.SIG.DFL);
}

fn setHandler(sig: child.Signal, handler: anytype) void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &action, null);
}

fn check(rc: usize) Error!void {
    if (linux.errno(rc) != .SUCCESS) return error.Failed;
}

/// Delivers `sig` to this process when its parent dies. A failure leaves the
/// process as it was, and no caller can do better, so it is not reported.
pub fn dieWithParent(sig: child.Signal) void {
    switch (builtin.os.tag) {
        .linux => _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(sig), 0, 0, 0),
        .freebsd => {
            var number: c_int = @intCast(@intFromEnum(sig));
            bsd.self(bsd.PROC_PDEATHSIG_CTL, &number) catch {};
        },
        else => unreachable,
    }
}

/// Marks the process non-dumpable: no core dump, and other processes of the
/// same user cannot ptrace it or read its memory (a password sits in it).
/// Like Linux's dumpable flag it lasts for this program image: exec resets it.
pub fn denyDumps() Error!void {
    switch (builtin.os.tag) {
        .linux => try check(linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0)),
        .freebsd => {
            var mode = bsd.TRACE_CTL_DISABLE;
            try bsd.self(bsd.PROC_TRACE_CTL, &mode);
        },
        else => unreachable,
    }
}

/// From now on exec cannot give this process, or anything it starts, more
/// privilege (setuid, file capabilities). Irreversible.
pub fn noNewPrivileges() Error!void {
    switch (builtin.os.tag) {
        .linux => try check(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)),
        .freebsd => {
            var mode = bsd.NO_NEW_PRIVS_ENABLE;
            try bsd.self(bsd.PROC_NO_NEW_PRIVS_CTL, &mode);
        },
        else => unreachable,
    }
}

/// Whether this process adopts the orphans of its descendants.
pub fn childSubreaper() Error!bool {
    switch (builtin.os.tag) {
        .linux => {
            var on: c_int = 0;
            try check(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&on), 0, 0, 0));
            return on != 0;
        },
        .freebsd => {
            var status: bsd.ReaperStatus = std.mem.zeroes(bsd.ReaperStatus);
            try bsd.self(bsd.PROC_REAP_STATUS, &status);
            return status.rs_flags & bsd.REAPER_STATUS_OWNED != 0;
        },
        else => unreachable,
    }
}

pub fn setChildSubreaper(on: bool) Error!void {
    switch (builtin.os.tag) {
        .linux => try check(linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), @intFromBool(on), 0, 0, 0)),
        .freebsd => try bsd.self(if (on) bsd.PROC_REAP_ACQUIRE else bsd.PROC_REAP_RELEASE, null),
        else => unreachable,
    }
}

test "the subreaper setting is read, changed and restored" {
    const before = try childSubreaper();
    try setChildSubreaper(!before);
    try std.testing.expectEqual(!before, try childSubreaper());
    try setChildSubreaper(before);
    try std.testing.expectEqual(before, try childSubreaper());
}

test "dumps are denied and the death signal is set, then both restored" {
    if (builtin.os.tag == .freebsd) {
        var status: c_int = 0;
        try bsd.self(bsd.PROC_TRACE_STATUS, &status);
        try std.testing.expect(status >= 0); // tracing allowed before
        try denyDumps();
        try bsd.self(bsd.PROC_TRACE_STATUS, &status);
        try std.testing.expectEqual(@as(c_int, -1), status);
        var enable = bsd.TRACE_CTL_ENABLE;
        try bsd.self(bsd.PROC_TRACE_CTL, &enable);

        dieWithParent(.TERM);
        var signal: c_int = -1;
        try bsd.self(bsd.PROC_PDEATHSIG_STATUS, &signal);
        try std.testing.expectEqual(@as(c_int, @intCast(@intFromEnum(child.Signal.TERM))), signal);
        dieWithParent(@enumFromInt(0));
        return;
    }
    const dumpable = linux.prctl(@intFromEnum(linux.PR.GET_DUMPABLE), 0, 0, 0, 0);
    try std.testing.expect(linux.errno(dumpable) == .SUCCESS);
    try denyDumps();
    try std.testing.expectEqual(@as(usize, 0), linux.prctl(@intFromEnum(linux.PR.GET_DUMPABLE), 0, 0, 0, 0));
    _ = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), dumpable, 0, 0, 0);

    var signal: c_int = -1;
    dieWithParent(.TERM);
    _ = linux.prctl(@intFromEnum(linux.PR.GET_PDEATHSIG), @intFromPtr(&signal), 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(child.Signal.TERM)), signal);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), 0, 0, 0, 0);
}
