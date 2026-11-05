//! Child processes by identity, not by pid. A `Handle` addresses the process
//! it was opened for even after the pid is reused, and its `fd` turns readable
//! when the process exits, without reaping it: the owner still collects the
//! status with `reap`. Linux backs it with pidfds. Callers poll `fd` from the
//! Wayland loop, `poll` or a `Set`; nothing here starts a thread or a timer.
const std = @import("std");
const linux = std.os.linux;

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

fn classify(err: linux.E) Error {
    return switch (err) {
        .SRCH, .NOENT => error.NoSuchProcess,
        .PERM, .ACCES => error.PermissionDenied,
        .NOSYS, .INVAL => error.Unsupported,
        else => error.Failed,
    };
}

pub const Handle = struct {
    /// Readable once the process has exited; never carries data.
    fd: i32,

    /// Opens a handle on a running process. The caller closes it.
    pub fn open(process: Pid) Error!Handle {
        const rc = linux.pidfd_open(process, 0);
        if (linux.errno(rc) != .SUCCESS) return classify(linux.errno(rc));
        return .{ .fd = @intCast(rc) };
    }

    /// The handle of the process at the other end of a connected Unix socket,
    /// when the system can name it race-free. Null otherwise: fall back to
    /// `open` on the credentials' pid.
    pub fn peer(socket: i32) ?Handle {
        const so_peerpidfd = 77;
        var fd: i32 = -1;
        var len: u32 = @sizeOf(i32);
        const rc = linux.getsockopt(socket, linux.SOL.SOCKET, so_peerpidfd, @ptrCast(&fd), &len);
        if (linux.errno(rc) != .SUCCESS or fd < 0) return null;
        return .{ .fd = fd };
    }

    pub fn close(self: Handle) void {
        _ = linux.close(self.fd);
    }

    /// Signals the process this handle was opened for, never a pid reused
    /// since. Signal 0 only checks that it is still there.
    pub fn signal(self: Handle, sig: Signal) Error!void {
        const rc = linux.pidfd_send_signal(self.fd, sig, null, 0);
        if (linux.errno(rc) != .SUCCESS) return classify(linux.errno(rc));
    }

    pub fn alive(self: Handle) bool {
        self.signal(@enumFromInt(0)) catch return false;
        return true;
    }

    /// A nonblocking check of `fd`: has the process exited.
    pub fn exited(self: Handle) bool {
        var fds = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        return linux.errno(linux.poll(&fds, 1, 0)) == .SUCCESS and fds[0].revents != 0;
    }

    /// The pid of the process this handle is on: null once it has exited and
    /// been reaped, even if the number was reused since. An unreaped zombie
    /// still has its pid (see `exited`). Unavailable when the system cannot say.
    pub fn pid(self: Handle) error{Unavailable}!?Pid {
        var path: [64]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&path, "/proc/self/fdinfo/{d}", .{self.fd}, 0) catch unreachable;
        const opened = linux.openat(linux.AT.FDCWD, name.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return error.Unavailable;
        const info_fd: i32 = @intCast(opened);
        defer _ = linux.close(info_fd);
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const rc = linux.read(info_fd, buf[len..].ptr, buf.len - len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.Unavailable,
            }
            if (rc == 0) break;
            len += rc;
        } else return error.Unavailable;
        var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "Pid:")) continue;
            const value = std.fmt.parseInt(Pid, std.mem.trim(u8, line["Pid:".len..], " \t"), 10) catch return error.Unavailable;
            return if (value < 0) null else value;
        }
        return null;
    }
};

/// Collects the wait status of a child that has exited (or null: still
/// running, or somebody else reaped it). Never blocks.
pub fn reap(pid: Pid) ?u32 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.wait4(pid, @ptrCast(&status), linux.W.NOHANG, null);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => return if (rc == pid) status else null,
            else => return null,
        }
    }
}

/// Whether a process with this pid exists right now. Racy by nature: the pid
/// may be another process's by the time it matters; prefer a `Handle`.
pub fn exists(pid: Pid) bool {
    return linux.errno(linux.kill(pid, @enumFromInt(0))) == .SUCCESS;
}

/// Signals every member of the process group `pgid`, a leader's own pid.
pub fn signalGroup(pgid: Pid, sig: Signal) void {
    _ = linux.kill(-pgid, sig);
}

/// Kills a child nobody is going to wait for and collects it, so it leaves no
/// zombie. Blocks until the kernel has taken it; SIGKILL cannot be caught.
pub fn killAndReap(pid: Pid) void {
    _ = linux.kill(pid, .KILL);
    var status: u32 = 0;
    while (linux.errno(linux.wait4(pid, @ptrCast(&status), 0, null)) == .INTR) {}
}

test "a child nobody watches is killed and collected" {
    var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/bin/sleep", "30" } });
    const pid = child.id.?;
    killAndReap(pid);
    child.id = null;
    // Collected: no zombie, and no child left to wait for.
    try std.testing.expect(!exists(pid));
    try std.testing.expectEqual(@as(?u32, null), reap(pid));
}

/// Handles for poll-based clients. One fd joins the application's normal
/// event loop and turns readable when any member exits; a long-lived child
/// requires no thread and causes no wakeups.
pub const Set = struct {
    const Entry = struct { pid: Pid, handle: Handle };
    pub const Exit = struct { pid: Pid, status: ?u32 };

    /// Readable while `next` has an exit to report; -1 until the first `add`.
    fd: i32 = -1,
    entries: std.ArrayList(Entry) = .empty,

    pub fn add(self: *Set, allocator: std.mem.Allocator, pid: Pid) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
        if (self.fd < 0) {
            const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return error.Failed;
            self.fd = @intCast(rc);
        }
        const handle = try Handle.open(pid);
        errdefer handle.close();
        var event: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = handle.fd } };
        if (linux.errno(linux.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, handle.fd, &event)) != .SUCCESS) return error.Failed;
        self.entries.appendAssumeCapacity(.{ .pid = pid, .handle = handle });
    }

    /// The next child that exited, reaped, or null when none has.
    pub fn next(self: *Set) ?Exit {
        if (self.fd < 0) return null;
        var events: [1]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(self.fd, &events, 1, 0);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
        for (self.entries.items, 0..) |entry, i| {
            if (entry.handle.fd != events[0].data.fd) continue;
            _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, entry.handle.fd, null);
            entry.handle.close();
            _ = self.entries.swapRemove(i);
            return .{ .pid = entry.pid, .status = reap(entry.pid) };
        }
        unreachable;
    }

    pub fn signalAll(self: *Set, sig: Signal) void {
        for (self.entries.items) |entry| entry.handle.signal(sig) catch {};
    }

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        while (self.next() != null) {}
        for (self.entries.items) |entry| entry.handle.close();
        self.entries.deinit(allocator);
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.* = .{};
    }
};

fn waitReadable(fd: i32, timeout_ms: i32) bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.errno(linux.poll(&fds, 1, timeout_ms)) == .SUCCESS and fds[0].revents != 0;
}

test "a handle follows one process through signal, exit and reap" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" } });
    const pid = child.id.?;
    const handle = try Handle.open(pid);
    defer handle.close();
    try std.testing.expect(handle.alive());
    try std.testing.expect(!handle.exited());
    try std.testing.expectEqual(@as(?Pid, pid), try handle.pid());
    try std.testing.expectEqual(@as(?u32, null), reap(pid));

    try handle.signal(.TERM);
    try std.testing.expect(waitReadable(handle.fd, 5000));
    try std.testing.expect(handle.exited());
    // The zombie keeps its pid until it is reaped; then the handle names nobody.
    try std.testing.expectEqual(@as(?Pid, pid), try handle.pid());
    const status = reap(pid).?;
    try std.testing.expect(linux.W.IFSIGNALED(status) and linux.W.TERMSIG(status) == .TERM);
    try std.testing.expectEqual(@as(?u32, null), reap(pid));
    try std.testing.expectEqual(@as(?Pid, null), try handle.pid());
    try std.testing.expectError(error.NoSuchProcess, handle.signal(.TERM));
    child.id = null;
}

test "a handle cannot be opened on a process that does not exist" {
    try std.testing.expectError(error.NoSuchProcess, Handle.open(std.math.maxInt(Pid)));
}

test "a set reports each exit once with its status and signals the rest" {
    const io = std.testing.io;
    var quick = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 3" } });
    var slow = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" } });
    var set: Set = .{};
    defer set.deinit(std.testing.allocator);
    try set.add(std.testing.allocator, quick.id.?);
    try set.add(std.testing.allocator, slow.id.?);
    try std.testing.expect(waitReadable(set.fd, 5000));
    const first = set.next().?;
    try std.testing.expectEqual(quick.id.?, first.pid);
    try std.testing.expectEqual(@as(u8, 3), linux.W.EXITSTATUS(first.status.?));
    try std.testing.expect(set.next() == null);
    set.signalAll(.KILL);
    try std.testing.expect(waitReadable(set.fd, 5000));
    const second = set.next().?;
    try std.testing.expectEqual(slow.id.?, second.pid);
    try std.testing.expect(linux.W.IFSIGNALED(second.status.?));
    try std.testing.expectEqual(@as(usize, 0), set.entries.items.len);
    quick.id = null;
    slow.id = null;
}
