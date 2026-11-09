//! Signal delivery and child setup for the login supervisor. All waits are
//! event-driven; a FreeBSD kqueue replaces Linux's signalfd.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const io = @import("login_io.zig");
const linux = std.os.linux;

pub const Signals = struct {
    fd: i32,
    old_mask: std.posix.sigset_t,

    pub fn init() !Signals {
        var mask = std.posix.sigemptyset();
        for ([_]std.posix.SIG{ .TERM, .INT, .CHLD }) |sig| std.posix.sigaddset(&mask, sig);
        var old_mask = std.posix.sigemptyset();
        _ = try io.check(c.sigprocmask(std.posix.SIG.BLOCK, &mask, &old_mask));
        errdefer _ = c.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);
        const fd: i32 = switch (builtin.os.tag) {
            .linux => blk: {
                // libc reserves 1024 bits; the kernel consumes its first 64.
                const rc = linux.signalfd(-1, @ptrCast(&mask), linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
                if (linux.errno(rc) != .SUCCESS) return error.SignalWatchFailed;
                break :blk @intCast(rc);
            },
            .freebsd => blk: {
                const fd: i32 = @intCast(try io.check(c.kqueue()));
                errdefer io.close(fd);
                _ = try io.check(c.fcntl(fd, c.F.SETFD, @as(c_int, 1)));
                var changes: [3]c.Kevent = undefined;
                for ([_]std.posix.SIG{ .TERM, .INT, .CHLD }, &changes) |sig, *event| {
                    event.* = .{ .ident = @backingInt(sig), .filter = c.EVFILT.SIGNAL, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 };
                }
                var unused: [1]c.Kevent = undefined;
                _ = try io.check(c.kevent(fd, &changes, changes.len, &unused, 0, null));
                break :blk fd;
            },
            else => @compileError("login signal delivery is not ported to this OS"),
        };
        return .{ .fd = fd, .old_mask = old_mask };
    }

    pub fn deinit(self: *Signals) void {
        if (builtin.os.tag == .freebsd) while (self.next() != null) {};
        io.close(self.fd);
        _ = c.sigprocmask(std.posix.SIG.SETMASK, &self.old_mask, null);
    }

    pub fn next(self: *Signals) ?std.posix.SIG {
        switch (builtin.os.tag) {
            .linux => {
                var info: linux.signalfd_siginfo = undefined;
                if (c.read(self.fd, @ptrCast(&info), @sizeOf(@TypeOf(info))) != @sizeOf(@TypeOf(info))) return null;
                return @fromBackingInt(@intCast(info.signo));
            },
            .freebsd => {
                var events: [1]c.Kevent = undefined;
                const now: c.timespec = .{ .sec = 0, .nsec = 0 };
                if (c.kevent(self.fd, &events, 0, &events, 1, &now) <= 0) return null;
                const sig: std.posix.SIG = @fromBackingInt(@intCast(events[0].ident));
                // A kqueue notification does not consume a blocked POSIX
                // signal. Clear it before restoring the old mask at shutdown.
                const bsd = struct {
                    extern "c" fn sigtimedwait(*const std.posix.sigset_t, ?*c.siginfo_t, *const c.timespec) c_int;
                };
                var mask = std.posix.sigemptyset();
                std.posix.sigaddset(&mask, sig);
                _ = bsd.sigtimedwait(&mask, null, &now);
                return sig;
            },
            else => unreachable,
        }
    }
};

/// Only async-signal-safe libc calls run between fork and exec.
pub fn spawn(compositor: [:0]const u8, envp: [*:null]const ?[*:0]const u8, session_fd: i32, log_fd: i32, old_mask: *const std.posix.sigset_t) !std.posix.pid_t {
    const pid: std.posix.pid_t = @intCast(try io.check(c.fork()));
    if (pid == 0) {
        _ = c.setsid();
        _ = c.dup2(log_fd, 1);
        _ = c.dup2(log_fd, 2);
        _ = c.fcntl(session_fd, c.F.SETFD, @as(c_int, 0));
        @import("process.zig").defaultSignal(.PIPE);
        _ = c.sigprocmask(std.posix.SIG.SETMASK, old_mask, null);
        const argv = [_:null]?[*:0]const u8{compositor.ptr};
        _ = c.execve(compositor.ptr, &argv, envp);
        c._exit(127);
    }
    return pid;
}

/// Peek before reaping: the main loop owns the compositor's exit status.
pub fn reapAdopted(compositor: std.posix.pid_t) void {
    while (true) {
        var info = std.mem.zeroes(c.siginfo_t);
        switch (builtin.os.tag) {
            .linux => {
                if (linux.errno(linux.waitid(.ALL, 0, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null)) != .SUCCESS) return;
                const pid = info.fields.common.first.piduid.pid;
                if (pid == 0 or pid == compositor) return;
                if (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG, null)) != .SUCCESS) return;
            },
            .freebsd => {
                const bsd = struct {
                    extern "c" fn waitid(c_int, i64, *c.siginfo_t, c_int) c_int;
                };
                // sys/wait.h: P_ALL = 7, P_PID = 0; id_t is int64_t.
                if (bsd.waitid(7, 0, &info, c.W.EXITED | c.W.NOHANG | c.W.NOWAIT) != 0) return;
                if (info.pid == 0 or info.pid == compositor) return;
                if (bsd.waitid(0, info.pid, &info, c.W.EXITED | c.W.NOHANG) != 0) return;
            },
            else => unreachable,
        }
    }
}

/// Kernel-reported controlling terminal; the backend decides which seats it accepts.
pub fn consoleDevice(allocator: std.mem.Allocator) ![]const u8 {
    const libc = struct {
        extern "c" fn ttyname_r(c_int, [*]u8, usize) c_int;
    };
    var buf: [1024]u8 = undefined;
    if (libc.ttyname_r(0, &buf, buf.len) != 0) return error.NotConsoleLogin;
    return allocator.dupe(u8, std.mem.sliceTo(&buf, 0));
}

test "login signal queue consumes a blocked signal before restoring the mask" {
    var signals = try Signals.init();
    defer signals.deinit();
    // Target this thread so other threads in the test runner cannot receive it.
    try std.testing.expectEqual(@as(c_int, 0), c.raise(.TERM));
    var fds = [_]c.pollfd{.{ .fd = signals.fd, .events = c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&fds, 1, 5000));
    try std.testing.expectEqual(std.posix.SIG.TERM, signals.next().?);
    try std.testing.expect(signals.next() == null);
}
