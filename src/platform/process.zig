//! Process attributes that differ between systems: dying with the parent, being
//! dumped or traced, gaining privileges through exec, adopting orphans. Linux
//! uses prctl. `process.h` is the same for C.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const child = @import("child.zig");

// std.os.linux issues Linux syscall numbers on any target, so a build for
// another OS must fail here and not ask its kernel something else.
comptime {
    if (builtin.os.tag != .linux)
        @compileError("platform.process is not ported to this OS yet (docs/plans/freebsd.md, P.4)");
}

pub const Error = error{Failed};

fn check(rc: usize) Error!void {
    if (linux.errno(rc) != .SUCCESS) return error.Failed;
}

/// Delivers `sig` to this process when its parent dies. A failure leaves the
/// process as it was, and no caller can do better, so it is not reported.
pub fn dieWithParent(sig: child.Signal) void {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(sig), 0, 0, 0);
}

/// Marks the process non-dumpable: no core dump, and other processes of the
/// same user cannot ptrace it or read its memory (a password sits in it).
pub fn denyDumps() Error!void {
    try check(linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0));
}

/// From now on exec cannot give this process, or anything it starts, more
/// privilege (setuid, file capabilities). Irreversible.
pub fn noNewPrivileges() Error!void {
    try check(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
}

/// Whether this process adopts the orphans of its descendants.
pub fn childSubreaper() Error!bool {
    var on: c_int = 0;
    try check(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&on), 0, 0, 0));
    return on != 0;
}

pub fn setChildSubreaper(on: bool) Error!void {
    try check(linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), @intFromBool(on), 0, 0, 0));
}

test "the subreaper setting is read, changed and restored" {
    const before = try childSubreaper();
    try setChildSubreaper(!before);
    try std.testing.expectEqual(!before, try childSubreaper());
    try setChildSubreaper(before);
    try std.testing.expectEqual(before, try childSubreaper());
}

test "dumps are denied and the death signal is set, then both restored" {
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
