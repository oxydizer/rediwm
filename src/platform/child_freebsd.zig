//! FreeBSD backing of `child.zig`. FreeBSD has no pidfd, so a handle is a
//! kqueue holding one `EVFILT_PROC`/`NOTE_EXIT` registration for the process:
//! its descriptor turns readable when the process exits and stays readable,
//! because nobody ever dequeues the event, and polls like any descriptor
//! (the Wayland loop's epoll emulation included).
//!
//! The handle also keeps the pid, and signals go by pid. The guard against a
//! reused pid is the exit event: once it is pending the handle refuses to
//! signal. Before that the process still exists, and an unreaped child's pid
//! cannot be reused. For a process that is not our child the window between
//! its exit and our `signal` call is the only gap, and a pid takes a full
//! wrap of the pid space to come back.
const std = @import("std");
const c = std.c;
const child = @import("child.zig");

const Pid = child.Pid;
const Signal = child.Signal;
const Error = child.Error;

const Kevent = c.Kevent;

fn classify(err: std.posix.E) Error {
    return switch (err) {
        .SRCH => error.NoSuchProcess,
        .PERM, .ACCES => error.PermissionDenied,
        .NOSYS, .INVAL => error.Unsupported,
        else => error.Failed,
    };
}

fn exitRegistration(process: Pid) Kevent {
    return .{
        .ident = @intCast(process),
        .filter = c.EVFILT.PROC,
        .flags = c.EV.ADD | c.EV.ENABLE,
        .fflags = c.NOTE.EXIT,
        .data = 0,
        .udata = 0,
    };
}

/// A new close-on-exec kqueue.
fn newQueue() Error!i32 {
    const kq = c.kqueue();
    if (kq < 0) return classify(std.posix.errno(kq));
    // FD_CLOEXEC is 1 (sys/fcntl.h).
    _ = c.fcntl(kq, c.F.SETFD, @as(c_int, 1));
    return kq;
}

/// Registers `process` for exit on `kq`. A process that exited but is not yet
/// reaped (a zombie) registers fine and fires at once; a gone one is ESRCH.
fn watchExit(kq: i32, process: Pid) Error!void {
    const change = exitRegistration(process);
    var none: [1]Kevent = undefined;
    // With room for no events, a failed registration is the call's error.
    if (c.kevent(kq, @ptrCast(&change), 1, &none, 0, null) < 0) return classify(std.posix.errno(@as(c_int, -1)));
}

fn pollIn(fd: i32, timeout_ms: i32) bool {
    var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    return c.poll(&fds, 1, timeout_ms) > 0 and fds[0].revents != 0;
}

pub const Handle = struct {
    /// Readable once the process has exited; never carries data.
    fd: i32,
    /// The process this handle was opened for.
    process: Pid,

    /// Opens a handle on a running process. The caller closes it.
    pub fn open(process: Pid) Error!Handle {
        const kq = try newQueue();
        errdefer _ = c.close(kq);
        try watchExit(kq, process);
        return .{ .fd = kq, .process = process };
    }

    /// FreeBSD cannot name the peer of a socket race-free: callers fall back
    /// to `open` on the credentials' pid.
    pub fn peer(socket: i32) ?Handle {
        _ = socket;
        return null;
    }

    pub fn close(self: Handle) void {
        _ = c.close(self.fd);
    }

    /// Signals the process this handle was opened for, never a pid reused
    /// since (see the file comment). Signal 0 only checks that it is still
    /// there. A process that has exited is gone for this purpose, even while
    /// its unreaped zombie still answers `kill`.
    pub fn signal(self: Handle, sig: Signal) Error!void {
        if (self.exited()) return error.NoSuchProcess;
        if (c.kill(self.process, sig) != 0) return classify(std.posix.errno(@as(c_int, -1)));
    }

    pub fn alive(self: Handle) bool {
        self.signal(@enumFromInt(0)) catch return false;
        return true;
    }

    /// A nonblocking check of `fd`: has the process exited.
    pub fn exited(self: Handle) bool {
        return pollIn(self.fd, 0);
    }

    /// The pid of the process this handle is on: null once it has exited and
    /// been reaped. An unreaped zombie still has its pid (see `exited`). The
    /// kernel does not say whether a number was reused after the reap, so a
    /// reaped child whose number a new process took reads as that pid.
    pub fn pid(self: Handle) error{Unavailable}!?Pid {
        if (!self.exited()) return self.process;
        return if (c.kill(self.process, @enumFromInt(0)) == 0) self.process else null;
    }
};

/// Collects the wait status of a child that has exited (or null: still
/// running, or somebody else reaped it). Never blocks.
pub fn reap(pid: Pid) ?u32 {
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, c.W.NOHANG);
        if (rc == pid) return @bitCast(status);
        if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
        return null;
    }
}

/// Whether a process with this pid exists right now. Racy by nature: the pid
/// may be another process's by the time it matters; prefer a `Handle`.
pub fn exists(pid: Pid) bool {
    return c.kill(pid, @enumFromInt(0)) == 0;
}

/// Signals every member of the process group `pgid`, a leader's own pid.
pub fn signalGroup(pgid: Pid, sig: Signal) void {
    _ = c.kill(-pgid, sig);
}

/// Kills a child nobody is going to wait for and collects it, so it leaves no
/// zombie. Blocks until the kernel has taken it; SIGKILL cannot be caught.
pub fn killAndReap(pid: Pid) void {
    _ = c.kill(pid, .KILL);
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
}

/// Handles for poll-based clients. One fd joins the application's normal
/// event loop and turns readable when any member exits; a long-lived child
/// requires no thread and causes no wakeups. The members are children of this
/// process, so their pids stay reserved until `next` reaps them.
pub const Set = struct {
    pub const Exit = struct { pid: Pid, status: ?u32 };

    /// Readable while `next` has an exit to report; -1 until the first `add`.
    fd: i32 = -1,
    pids: std.ArrayList(Pid) = .empty,

    pub fn add(self: *Set, allocator: std.mem.Allocator, pid: Pid) !void {
        try self.pids.ensureUnusedCapacity(allocator, 1);
        if (self.fd < 0) self.fd = try newQueue();
        try watchExit(self.fd, pid);
        self.pids.appendAssumeCapacity(pid);
    }

    /// The next child that exited, reaped, or null when none has.
    pub fn next(self: *Set) ?Exit {
        if (self.fd < 0) return null;
        var events: [1]Kevent = undefined;
        const now: c.timespec = .{ .sec = 0, .nsec = 0 };
        // A NOTE_EXIT registration is one-shot: delivering it removes it.
        if (c.kevent(self.fd, @ptrCast(&events), 0, &events, 1, &now) <= 0) return null;
        const pid: Pid = @intCast(events[0].ident);
        for (self.pids.items, 0..) |member, i| {
            if (member != pid) continue;
            _ = self.pids.swapRemove(i);
            return .{ .pid = pid, .status = reap(pid) };
        }
        return null;
    }

    pub fn signalAll(self: *Set, sig: Signal) void {
        for (self.pids.items) |pid| _ = c.kill(pid, sig);
    }

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        while (self.next() != null) {}
        self.pids.deinit(allocator);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.* = .{};
    }
};

test "a child nobody watches is killed and collected" {
    var child_process = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/bin/sleep", "30" } });
    const pid = child_process.id.?;
    killAndReap(pid);
    child_process.id = null;
    // Collected: no zombie, and no child left to wait for.
    try std.testing.expect(!exists(pid));
    try std.testing.expectEqual(@as(?u32, null), reap(pid));
}

test "a handle follows one process through signal, exit and reap" {
    const io = std.testing.io;
    var child_process = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" } });
    const pid = child_process.id.?;
    const handle = try Handle.open(pid);
    defer handle.close();
    try std.testing.expect(handle.alive());
    try std.testing.expect(!handle.exited());
    try std.testing.expectEqual(@as(?Pid, pid), try handle.pid());
    try std.testing.expectEqual(@as(?u32, null), reap(pid));

    try handle.signal(.TERM);
    try std.testing.expect(pollIn(handle.fd, 5000));
    try std.testing.expect(handle.exited());
    // The zombie keeps its pid until it is reaped; then the handle names nobody.
    try std.testing.expectEqual(@as(?Pid, pid), try handle.pid());
    const status = reap(pid).?;
    try std.testing.expect(std.posix.W.IFSIGNALED(status) and std.posix.W.TERMSIG(status) == Signal.TERM);
    try std.testing.expectEqual(@as(?u32, null), reap(pid));
    try std.testing.expectEqual(@as(?Pid, null), try handle.pid());
    try std.testing.expectError(error.NoSuchProcess, handle.signal(.TERM));
    child_process.id = null;
}

test "a handle cannot be opened on a process that does not exist" {
    try std.testing.expectError(error.NoSuchProcess, Handle.open(std.math.maxInt(Pid)));
}

test "a handle sees an exit whether or not it happened before the handle opened" {
    const io = std.testing.io;
    var quick = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" } });
    const pid = quick.id.?;
    // Not reaped yet: the pid is still there, as a zombie once it has run.
    const handle = try Handle.open(pid);
    defer handle.close();
    try std.testing.expect(pollIn(handle.fd, 5000));
    try std.testing.expect(handle.exited());
    const late = try Handle.open(pid);
    defer late.close();
    try std.testing.expect(late.exited());
    try std.testing.expect(reap(pid) != null);
    quick.id = null;
}

test "a set reports each exit once with its status and signals the rest" {
    const io = std.testing.io;
    var quick = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 3" } });
    var slow = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" } });
    var set: Set = .{};
    defer set.deinit(std.testing.allocator);
    try set.add(std.testing.allocator, quick.id.?);
    try set.add(std.testing.allocator, slow.id.?);
    try std.testing.expect(pollIn(set.fd, 5000));
    const first = set.next().?;
    try std.testing.expectEqual(quick.id.?, first.pid);
    try std.testing.expectEqual(@as(u8, 3), std.posix.W.EXITSTATUS(first.status.?));
    try std.testing.expect(set.next() == null);
    set.signalAll(.KILL);
    try std.testing.expect(pollIn(set.fd, 5000));
    const second = set.next().?;
    try std.testing.expectEqual(slow.id.?, second.pid);
    try std.testing.expect(std.posix.W.IFSIGNALED(second.status.?));
    try std.testing.expectEqual(@as(usize, 0), set.pids.items.len);
    quick.id = null;
    slow.id = null;
}
