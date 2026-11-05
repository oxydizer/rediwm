//! Child processes by identity, not by pid. A `Handle` addresses the process
//! it was opened for even after the pid is reused, and its `fd` turns readable
//! when the process exits, without reaping it: the owner still collects the
//! status with `reap`. Linux backs it with pidfds (`child_linux.zig`), FreeBSD
//! with kqueue (`child_freebsd.zig`). Callers poll `fd` from the Wayland loop,
//! `poll` or a `Set`; nothing here starts a thread or a timer.
const std = @import("std");
const builtin = @import("builtin");

pub const Pid = std.posix.pid_t;
pub const Signal = std.posix.SIG;

pub const Error = error{
    /// The process is gone (or was never there).
    NoSuchProcess,
    PermissionDenied,
    /// The system cannot give a handle on a process.
    Unsupported,
    Failed,
};

const impl = switch (builtin.os.tag) {
    .linux => @import("child_linux.zig"),
    .freebsd => @import("child_freebsd.zig"),
    else => @compileError("platform.child is not ported to this OS yet (docs/plans/freebsd.md, phase 1)"),
};

pub const Handle = impl.Handle;
pub const Set = impl.Set;
pub const reap = impl.reap;
pub const exists = impl.exists;
pub const signalGroup = impl.signalGroup;
pub const killAndReap = impl.killAndReap;

test {
    _ = impl;
}
