//! Who is on the other end of a connected unix socket. Linux reads
//! SO_PEERCRED, FreeBSD LOCAL_PEERCRED. `peer.h` is the same contract for C
//! and C++.
//!
//! The answer names whoever made the other end, as of `connect` or
//! `socketpair`; it says nothing about who writes later (see `AGENTS.md`).
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// std.os.linux issues Linux syscall numbers on any target, so a build for
// another OS must fail here and not ask its kernel something else.
comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .freebsd)
        @compileError("platform.peer is not ported to this OS yet (docs/plans/freebsd.md, P.9)");
}

pub const Credentials = struct {
    uid: std.posix.uid_t,
    pid: std.posix.pid_t,
};

/// The kernel's `struct ucred`.
const Ucred = extern struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

/// FreeBSD's `struct xucred` (`sys/ucred.h`): the first group is the effective
/// gid, and `cr_pid` shares its slot with an unused pointer.
const Xucred = extern struct {
    cr_version: c_uint,
    cr_uid: std.posix.uid_t,
    cr_ngroups: c_short,
    cr_groups: [16]std.posix.gid_t,
    cr_pid: extern union { unused: ?*anyopaque, pid: std.posix.pid_t },

    const version = 0;
    const sol_local = 0;
    const local_peercred = 1;
};

/// The user and process id of whoever made the other end of the connected unix
/// socket `fd`. Null when the kernel gives no answer (not a socket, not
/// connected, or no process id): callers refuse the peer.
pub fn of(fd: std.posix.fd_t) ?Credentials {
    switch (builtin.os.tag) {
        .linux => {
            var cred: Ucred = undefined;
            var len: linux.socklen_t = @sizeOf(Ucred);
            const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
            if (linux.errno(rc) != .SUCCESS or len != @sizeOf(Ucred)) return null;
            return .{ .uid = cred.uid, .pid = cred.pid };
        },
        .freebsd => {
            var cred: Xucred = undefined;
            var len: std.c.socklen_t = @sizeOf(Xucred);
            if (std.c.getsockopt(fd, Xucred.sol_local, Xucred.local_peercred, &cred, &len) != 0) return null;
            if (len != @sizeOf(Xucred) or cred.cr_version != Xucred.version) return null;
            // A kernel that does not fill cr_pid leaves it 0: no answer.
            if (cred.cr_pid.pid <= 0) return null;
            return .{ .uid = cred.cr_uid, .pid = cred.cr_pid.pid };
        },
        else => unreachable,
    }
}

test "both ends of a socketpair name this process" {
    const sys = std.posix.system;
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(sys.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0, &fds)));
    defer for (fds) |fd| {
        _ = sys.close(fd);
    };
    for (fds) |fd| {
        const peer = of(fd).?;
        try std.testing.expectEqual(sys.getuid(), peer.uid);
        try std.testing.expectEqual(sys.getpid(), peer.pid);
    }
}

test "a descriptor that is not a connected socket has no peer" {
    const sys = std.posix.system;
    try std.testing.expect(of(-1) == null);
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(sys.pipe(&fds)));
    defer for (fds) |fd| {
        _ = sys.close(fd);
    };
    try std.testing.expect(of(fds[0]) == null);
}
