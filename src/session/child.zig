//! Event-loop-owned child lifetime. Owners may disappear before their child;
//! detach the callback, leaving the pidfd watched until exit. No waiter thread
//! or timer is needed, and signals always address the original process.
const std = @import("std");
const wl = @import("wayland").server.wl;
const linux = std.os.linux;
const Child = @This();

allocator: std.mem.Allocator,
pid: linux.pid_t,
fd: i32,
source: *wl.EventSource,
loop_destroy: wl.Listener(*wl.EventLoop) = .init(loopDestroyed),
owner: ?*anyopaque,
callback: ?*const fn (?*anyopaque, *Child, ?u32) void,
/// A session helper owns its process group. Kill descendants before reaping
/// its leader, while the PID is still reserved.
kill_group: bool = false,

pub fn watch(allocator: std.mem.Allocator, loop: *wl.EventLoop, pid: linux.pid_t, owner: ?*anyopaque, callback: @FieldType(Child, "callback")) !*Child {
    const self = try allocator.create(Child);
    errdefer allocator.destroy(self);
    const rc = linux.pidfd_open(pid, 0);
    if (linux.errno(rc) != .SUCCESS) return error.PidfdFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    self.* = .{ .allocator = allocator, .pid = pid, .fd = fd, .source = undefined, .owner = owner, .callback = callback };
    self.source = try loop.addFd(*Child, fd, .{ .readable = true }, ready, self);
    loop.addDestroyListener(&self.loop_destroy);
    return self;
}

pub fn signal(self: *Child, sig: linux.SIG) void {
    _ = linux.pidfd_send_signal(self.fd, sig, null, 0);
}

pub fn detach(self: *Child) void {
    self.owner = null;
    self.callback = null;
}

/// Explicit nonblocking drain for bounded shutdown, never an exit poll timer.
/// Returns true if this call destroyed the watch.
pub fn dispatch(self: *Child) bool {
    var fds = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.errno(linux.poll(&fds, 1, 0)) != .SUCCESS or fds[0].revents == 0) return false;
    if (self.kill_group) _ = linux.kill(-self.pid, .KILL);
    const status = self.reap();
    if (self.callback) |callback| callback(self.owner, self, status);
    self.destroy();
    return true;
}

fn reap(self: *Child) ?u32 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.wait4(self.pid, &status, linux.W.NOHANG, null);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => return if (rc == self.pid) status else null,
            else => return null,
        }
    }
}

fn ready(_: c_int, _: wl.EventMask, self: *Child) c_int {
    _ = self.dispatch();
    return 0;
}

fn loopDestroyed(listener: *wl.Listener(*wl.EventLoop), _: *wl.EventLoop) void {
    const self: *Child = @fieldParentPtr("loop_destroy", listener);
    // The process is shutting down. Live applications pass to the supervisor;
    // never call an owner that may already have been destroyed.
    _ = self.reap();
    self.destroy();
}

fn destroy(self: *Child) void {
    self.source.remove();
    self.loop_destroy.link.remove();
    _ = linux.close(self.fd);
    self.allocator.destroy(self);
}
