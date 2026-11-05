//! Event-loop-owned child lifetime. Owners may disappear before their child;
//! detach the callback, leaving the pidfd watched until exit. No waiter thread
//! or timer is needed, and signals always address the original process.
const std = @import("std");
const wl = @import("wayland").server.wl;
const platform = @import("platform");
const Child = @This();

allocator: std.mem.Allocator,
pid: platform.child.Pid,
handle: platform.child.Handle,
source: *wl.EventSource,
loop_destroy: wl.Listener(*wl.EventLoop) = .init(loopDestroyed),
owner: ?*anyopaque,
callback: ?*const fn (?*anyopaque, *Child, ?u32) void,
/// A session helper owns its process group. Kill descendants before reaping
/// its leader, while the PID is still reserved.
kill_group: bool = false,
/// False for `observe`: another owner collects the exit status.
reaps: bool = true,

pub fn watch(allocator: std.mem.Allocator, loop: *wl.EventLoop, pid: platform.child.Pid, owner: ?*anyopaque, callback: @FieldType(Child, "callback")) !*Child {
    const self = try allocator.create(Child);
    errdefer allocator.destroy(self);
    const handle = try platform.child.Handle.open(pid);
    errdefer handle.close();
    self.* = .{ .allocator = allocator, .pid = pid, .handle = handle, .source = undefined, .owner = owner, .callback = callback };
    self.source = try loop.addFd(*Child, handle.fd, .{ .readable = true }, ready, self);
    loop.addDestroyListener(&self.loop_destroy);
    return self;
}

/// `watch` for a child whose status someone else collects: the callback gets
/// no status, and the process is never reaped here.
pub fn observe(allocator: std.mem.Allocator, loop: *wl.EventLoop, pid: platform.child.Pid, owner: ?*anyopaque, callback: @FieldType(Child, "callback")) !*Child {
    const self = try watch(allocator, loop, pid, owner, callback);
    self.reaps = false;
    return self;
}

pub fn signal(self: *Child, sig: platform.child.Signal) void {
    self.handle.signal(sig) catch {};
}

pub fn detach(self: *Child) void {
    self.owner = null;
    self.callback = null;
}

/// Stops watching without a callback; the process runs on.
pub fn cancel(self: *Child) void {
    self.destroy();
}

/// Explicit nonblocking drain for bounded shutdown, never an exit poll timer.
/// Returns true if this call destroyed the watch.
pub fn dispatch(self: *Child) bool {
    if (!self.handle.exited()) return false;
    if (self.kill_group) platform.child.signalGroup(self.pid, .KILL);
    const status = self.reap();
    if (self.callback) |callback| callback(self.owner, self, status);
    self.destroy();
    return true;
}

fn reap(self: *Child) ?u32 {
    return if (self.reaps) platform.child.reap(self.pid) else null;
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
    self.handle.close();
    self.allocator.destroy(self);
}

test "an observed child is reported without being reaped, and a cancelled watch stays silent" {
    const loop = try wl.EventLoop.create();
    defer loop.destroy();
    const Seen = struct {
        calls: u32 = 0,
        status: ?u32 = 0,
        fn exited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
            const self: *@This() = @ptrCast(@alignCast(owner.?));
            self.calls += 1;
            self.status = status;
        }
    };
    var seen: Seen = .{};

    var quick = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "exit 5" } });
    defer quick.kill(std.testing.io);
    const quick_pid = quick.id.?;
    _ = try observe(std.testing.allocator, loop, quick_pid, &seen, Seen.exited);
    try loop.dispatch(2000);
    try std.testing.expectEqual(@as(u32, 1), seen.calls);
    // The exit was observed, not collected: the real owner still gets the status.
    try std.testing.expectEqual(@as(?u32, null), seen.status);
    const status = platform.child.reap(quick_pid).?;
    try std.testing.expectEqual(@as(u8, 5), std.posix.W.EXITSTATUS(status));
    quick.id = null;

    var slow = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/bin/sleep", "30" } });
    defer slow.kill(std.testing.io);
    const cancelled = try observe(std.testing.allocator, loop, slow.id.?, &seen, Seen.exited);
    cancelled.cancel();
    try loop.dispatch(0);
    try std.testing.expectEqual(@as(u32, 1), seen.calls);
    try std.testing.expect(platform.child.exists(slow.id.?));
}
