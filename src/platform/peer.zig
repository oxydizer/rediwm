//! Who is on the other end of a connected unix socket. Linux reads
//! SO_PEERCRED. `peer.h` is the same contract for C and C++.
//!
//! The answer names whoever made the other end, as of `connect` or
//! `socketpair`; it says nothing about who writes later (see `AGENTS.md`).
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// std.os.linux issues Linux syscall numbers on any target, so a build for
// another OS must fail here and not ask its kernel something else.
comptime {
    if (builtin.os.tag != .linux)
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

/// The user and process id of whoever made the other end of the connected unix
/// socket `fd`. Null when the kernel gives no answer (not a socket, not
/// connected): callers refuse the peer.
pub fn of(fd: std.posix.fd_t) ?Credentials {
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
    if (linux.errno(rc) != .SUCCESS or len != @sizeOf(Ucred)) return null;
    return .{ .uid = cred.uid, .pid = cred.pid };
}

test "both ends of a socketpair name this process" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    for (fds) |fd| {
        const peer = of(fd).?;
        try std.testing.expectEqual(linux.getuid(), peer.uid);
        try std.testing.expectEqual(linux.getpid(), peer.pid);
    }
}

test "a descriptor that is not a connected socket has no peer" {
    try std.testing.expect(of(-1) == null);
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    try std.testing.expect(of(fds[0]) == null);
}
