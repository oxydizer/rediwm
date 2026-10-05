//! Session service tracking and bounded shutdown handling.
//!
//! Tracks processes spawned by the session (autostart items, initial commands),
//! reaps them asynchronously via event-loop pidfds, handles clean termination on
//! SIGTERM/SIGINT, and performs bounded shutdown of owned helpers on logout.
//! Does not touch unrelated user services or the systemd user manager.

const std = @import("std");
const wl = @import("wayland").server.wl;

const Child = @import("child.zig");
const Server = @import("../Server.zig");

const log = std.log.scoped(.services);

var global_signal_fd: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(-1);
var pending_signals: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

const SIGNAL_BIT_TERM: u32 = 1 << 1;
const SIGNAL_BIT_INT: u32 = 1 << 2;

fn handlePosixSignal(sig: std.posix.SIG) callconv(.c) void {
    const bit: u32 = switch (sig) {
        .TERM => SIGNAL_BIT_TERM,
        .INT => SIGNAL_BIT_INT,
        else => 0,
    };
    if (bit == 0) return;
    _ = pending_signals.fetchOr(bit, .monotonic);
    const fd = global_signal_fd.load(.monotonic);
    if (fd >= 0) {
        const increment: u64 = 1;
        _ = std.posix.system.write(fd, @ptrCast(&increment), @sizeOf(u64));
    }
}

pub const Manager = struct {
    server: ?*Server,
    allocator: std.mem.Allocator,
    children: std.ArrayList(*Child) = .empty,
    loop: *wl.EventLoop,
    owns_loop: bool = false,
    helpers: std.ArrayList(Helper) = .empty,
    signal_fd: std.posix.fd_t = -1,
    signal_source: ?*wl.EventSource = null,
    prev_sigterm: ?std.posix.Sigaction = null,
    prev_sigint: ?std.posix.Sigaction = null,

    const Helper = struct { pid: std.posix.pid_t, command: []u8 };

    fn nowMs() i64 {
        var ts: std.posix.timespec = undefined;
        switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
            .SUCCESS => return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000),
            else => return 0,
        }
    }

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*Manager {
        const mgr = try allocator.create(Manager);
        errdefer allocator.destroy(mgr);
        mgr.* = .{
            .server = server,
            .allocator = allocator,
            .loop = server.wl_server.getEventLoop(),
        };

        const efd_rc = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
        if (std.os.linux.errno(efd_rc) != .SUCCESS) return error.EventFdFailed;
        const signal_fd: std.posix.fd_t = @intCast(efd_rc);
        mgr.signal_fd = signal_fd;

        global_signal_fd.store(signal_fd, .release);

        const sa: std.posix.Sigaction = .{
            .handler = .{ .handler = handlePosixSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        var old_term: std.posix.Sigaction = undefined;
        var old_int: std.posix.Sigaction = undefined;
        std.posix.sigaction(.TERM, &sa, &old_term);
        std.posix.sigaction(.INT, &sa, &old_int);

        mgr.prev_sigterm = old_term;
        mgr.prev_sigint = old_int;

        const loop = server.wl_server.getEventLoop();
        mgr.signal_source = loop.addFd(*Manager, signal_fd, .{ .readable = true }, handleSignalWake, mgr) catch |err| blk: {
            log.warn("could not register signal wake fd: {}", .{err});
            break :blk null;
        };

        return mgr;
    }

    pub fn createForTest(allocator: std.mem.Allocator) !*Manager {
        const mgr = try allocator.create(Manager);
        errdefer allocator.destroy(mgr);
        mgr.* = .{
            .server = null,
            .allocator = allocator,
            .loop = try wl.EventLoop.create(),
            .owns_loop = true,
        };
        return mgr;
    }

    pub fn deinit(self: *Manager) void {
        self.server = null;
        self.stopOwnedHelpers(1000);
        if (self.signal_source) |s| s.remove();
        if (self.signal_fd >= 0) {
            global_signal_fd.store(-1, .release);
            _ = std.posix.system.close(self.signal_fd);
            self.signal_fd = -1;
        }
        if (self.prev_sigterm) |*old| std.posix.sigaction(.TERM, old, null);
        if (self.prev_sigint) |*old| std.posix.sigaction(.INT, old, null);
        self.helpers.deinit(self.allocator);
        for (self.children.items) |child| child.detach();
        self.children.deinit(self.allocator);
        if (self.owns_loop) self.loop.destroy();
        self.allocator.destroy(self);
    }

    pub fn trackChild(self: *Manager, pid: std.posix.pid_t) !void {
        if (pid <= 0) return;
        if (self.isTracked(pid)) return;
        try self.children.ensureUnusedCapacity(self.allocator, 1);
        const child = try Child.watch(self.allocator, self.loop, pid, self, childExited);
        self.children.appendAssumeCapacity(child);
        log.debug("tracking child pid {d}", .{pid});
    }

    pub fn helperRunning(self: *Manager, command: []const u8) bool {
        self.reapChildren();
        for (self.helpers.items) |helper| {
            if (std.mem.eql(u8, helper.command, command)) return true;
        }
        return false;
    }

    pub fn trackHelper(self: *Manager, pid: std.posix.pid_t, command: []const u8) !void {
        const owned = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned);
        try self.helpers.ensureUnusedCapacity(self.allocator, 1);
        try self.trackChild(pid);
        for (self.children.items) |child| if (child.pid == pid) {
            child.kill_group = true;
        };
        self.helpers.appendAssumeCapacity(.{ .pid = pid, .command = owned });
    }

    fn forgetHelper(self: *Manager, pid: std.posix.pid_t) void {
        for (self.helpers.items, 0..) |helper, i| {
            if (helper.pid == pid) {
                self.allocator.free(helper.command);
                _ = self.helpers.swapRemove(i);
                return;
            }
        }
    }

    pub fn untrackChild(self: *Manager, pid: std.posix.pid_t) void {
        self.forgetHelper(pid);
        for (self.children.items, 0..) |p, i| {
            if (p.pid == pid) {
                p.detach();
                _ = self.children.swapRemove(i);
                log.debug("untracked session helper pid {d}", .{pid});
                return;
            }
        }
    }

    pub fn isTracked(self: *Manager, pid: std.posix.pid_t) bool {
        for (self.children.items) |p| {
            if (p.pid == pid) return true;
        }
        return false;
    }

    pub fn countTracked(self: *Manager) usize {
        return self.children.items.len;
    }

    fn childExited(owner: ?*anyopaque, child: *Child, status: ?u32) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.server) |server| server.launch_feedback.processExited(child.pid, status != null and status.? == 0);
        for (self.helpers.items) |helper| if (helper.pid == child.pid) {
            log.warn("session helper exited: {s} (wait status {?d}); not restarting", .{ helper.command, status });
        };
        self.untrackChild(child.pid);
    }

    pub fn reapChildren(self: *Manager) void {
        var i: usize = 0;
        while (i < self.children.items.len) {
            if (!self.children.items[i].dispatch()) i += 1;
        }
    }

    pub fn stopOwnedHelpers(self: *Manager, timeout_ms: u32) void {
        self.reapChildren();
        if (self.helpers.items.len == 0) return;
        log.info("stopping {d} session-owned helpers", .{self.helpers.items.len});
        for (self.helpers.items) |helper| std.posix.kill(-helper.pid, std.posix.SIG.TERM) catch {};
        const deadline = nowMs() + timeout_ms;
        while (self.helpers.items.len > 0 and nowMs() < deadline) {
            // Keep group leaders unreaped until the final group signal, so
            // their PIDs cannot be reused during the grace period.
            const left = deadline - nowMs();
            if (left <= 0) break;
            const delay = std.posix.timespec{ .sec = @intCast(@divTrunc(left, 1000)), .nsec = @intCast(@mod(left, 1000) * 1_000_000) };
            _ = std.posix.system.nanosleep(&delay, null);
        }
        for (self.helpers.items) |helper| {
            std.posix.kill(-helper.pid, std.posix.SIG.KILL) catch {};
            self.allocator.free(helper.command);
        }
        self.helpers.clearRetainingCapacity();
        self.reapChildren();
    }

    fn handleSignalWake(fd: c_int, mask: wl.EventMask, self: *Manager) c_int {
        _ = mask;
        var val: u64 = 0;
        _ = std.posix.system.read(fd, @ptrCast(&val), @sizeOf(u64));

        const pending = pending_signals.swap(0, .seq_cst);
        if ((pending & SIGNAL_BIT_TERM) != 0) {
            log.info("received SIGTERM; requesting clean termination", .{});
            if (self.server) |srv| srv.terminate();
        }
        if ((pending & SIGNAL_BIT_INT) != 0) {
            log.info("received SIGINT; requesting clean termination", .{});
            if (self.server) |srv| srv.terminate();
        }
        return 0;
    }
};

test "session helper tracking and bounded shutdown" {
    const allocator = std.testing.allocator;
    const mgr = try Manager.createForTest(allocator);
    defer mgr.deinit();

    var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/bin/sleep", "30" } });
    defer child.kill(std.testing.io);
    const pid = child.id.?;
    try mgr.trackChild(pid);
    try std.testing.expect(mgr.isTracked(pid));
    try std.testing.expectEqual(@as(usize, 1), mgr.countTracked());

    // Duplicate tracking is ignored
    try mgr.trackChild(pid);
    try std.testing.expectEqual(@as(usize, 1), mgr.countTracked());

    const watch = mgr.children.items[0];
    mgr.untrackChild(pid);
    try std.testing.expect(!mgr.isTracked(pid));
    try std.testing.expectEqual(@as(usize, 0), mgr.countTracked());

    // Cancellation removes the owner, not the reaper. A later exit must not
    // call it or leave a zombie behind.
    watch.signal(.KILL);
    child.id = null; // ownership was transferred to the watcher
    try mgr.loop.dispatch(1000);
    var status: u32 = 0;
    try std.testing.expectEqual(std.os.linux.E.CHILD, std.os.linux.errno(std.os.linux.wait4(pid, &status, std.os.linux.W.NOHANG, null)));

    // Immediate exits are readable even if they occur before registration.
    var quick = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" } });
    defer quick.kill(std.testing.io);
    const quick_pid = quick.id.?;
    try mgr.trackChild(quick_pid);
    quick.id = null;
    try mgr.loop.dispatch(1000);
    try std.testing.expectEqual(@as(usize, 0), mgr.countTracked());
    try std.testing.expectEqual(std.os.linux.E.CHILD, std.os.linux.errno(std.os.linux.wait4(quick_pid, &status, std.os.linux.W.NOHANG, null)));
}
