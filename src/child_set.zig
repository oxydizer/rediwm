//! Pidfds for poll-based clients. The epoll fd joins the application's normal
//! event loop; a long-lived child requires no thread and causes no wakeups.
const std = @import("std");
const linux = std.os.linux;
const Set = @This();
const Entry = struct { pid: linux.pid_t, fd: i32 };
pub const Exit = struct { pid: linux.pid_t, status: ?u32 };
fd: i32 = -1,
entries: std.ArrayList(Entry) = .empty,

pub fn add(self: *Set, allocator: std.mem.Allocator, pid: linux.pid_t) !void {
    try self.entries.ensureUnusedCapacity(allocator, 1);
    if (self.fd < 0) {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.EpollFailed;
        self.fd = @intCast(rc);
    }
    const rc = linux.pidfd_open(pid, 0);
    if (linux.errno(rc) != .SUCCESS) return error.PidfdFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    var event: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
    if (linux.errno(linux.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, fd, &event)) != .SUCCESS) return error.EpollFailed;
    self.entries.appendAssumeCapacity(.{ .pid = pid, .fd = fd });
}

pub fn next(self: *Set) ?Exit {
    if (self.fd < 0) return null;
    var events: [1]linux.epoll_event = undefined;
    const rc = linux.epoll_wait(self.fd, &events, 1, 0);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
    for (self.entries.items, 0..) |entry, i| {
        if (entry.fd != events[0].data.fd) continue;
        _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, entry.fd, null);
        _ = linux.close(entry.fd);
        _ = self.entries.swapRemove(i);
        var status: u32 = 0;
        while (true) {
            const result = linux.wait4(entry.pid, &status, linux.W.NOHANG, null);
            switch (linux.errno(result)) {
                .INTR => continue,
                .SUCCESS => return .{ .pid = entry.pid, .status = if (result == entry.pid) status else null },
                else => return .{ .pid = entry.pid, .status = null },
            }
        }
    }
    unreachable;
}

pub fn signalAll(self: *Set, sig: linux.SIG) void {
    for (self.entries.items) |entry| _ = linux.pidfd_send_signal(entry.fd, sig, null, 0);
}

pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
    while (self.next() != null) {}
    for (self.entries.items) |entry| _ = linux.close(entry.fd);
    self.entries.deinit(allocator);
    if (self.fd >= 0) _ = linux.close(self.fd);
    self.* = .{};
}
