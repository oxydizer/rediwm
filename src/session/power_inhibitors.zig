//! Inhibitors and lock-before-sleep: lid and sleep delay inhibitors, the sleep wait and lock coverage.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Lock = @import("lock.zig").Lock;
const log = std.log.scoped(.power);
const power_mod = @import("power.zig");
const Manager = power_mod.Manager;
const bus_path = power_mod.bus_path;
const bus_interface = power_mod.bus_interface;
const call_timeout_ms = power_mod.call_timeout_ms;
const sleep_lock_timeout_ms = power_mod.sleep_lock_timeout_ms;
const Inhibitor = Manager.Inhibitor;
const OwnerRequest = Manager.OwnerRequest;

pub fn wantsInhibitor(self: *Manager, which: Inhibitor) bool {
    if (self.server.greeter_mode) return false;
    // Let logind (or the new active desktop) own lid events after a VT switch.
    if (which == .lid) if (self.server.session) |session| if (!session.active) return false;
    return switch (which) {
        .lid => self.server.power_policy.enabled() or self.server.config.compositor.lid_close == .ignore,
        .sleep => self.server.power_policy.lockOnSuspend(self.server),
    };
}

pub fn inhibitorFd(self: *Manager, which: Inhibitor) *?std.posix.fd_t {
    return switch (which) {
        .lid => &self.lid_fd,
        .sleep => &self.sleep_fd,
    };
}

pub fn inhibitorPending(self: *Manager, which: Inhibitor) *bool {
    return switch (which) {
        .lid => &self.lid_pending,
        .sleep => &self.sleep_pending,
    };
}

pub fn releaseInhibitor(self: *Manager, which: Inhibitor) void {
    const fd = self.inhibitorFd(which);
    if (fd.*) |held| _ = std.posix.system.close(held);
    fd.* = null;
}

/// The lid inhibitor holds only logind's lid switch policy, never explicit
/// or idle suspend; the sleep inhibitor only delays sleep for the lock.
pub fn syncInhibitors(self: *Manager) void {
    for ([_]Inhibitor{ .lid, .sleep }) |which| {
        if (self.closing or !self.wantsInhibitor(which)) {
            self.releaseInhibitor(which);
            continue;
        }
        const conn = self.connection() catch return;
        if (!self.hello_done or self.signal_sender == null or self.inhibitorFd(which).* != null or self.inhibitorPending(which).*) continue;
        self.acquireInhibitor(conn, which) catch |err| {
            log.warn("could not take logind {t} inhibitor: {}", .{ which, err });
        };
    }
}

pub fn acquireInhibitor(self: *Manager, conn: *dbus.Connection, which: Inhibitor) !void {
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    const args: [4][]const u8 = switch (which) {
        .lid => .{ "handle-lid-switch", "RediWM", "RediWM manages lid actions", "block" },
        .sleep => .{ "sleep", "RediWM", "Lock the screen before sleep", "delay" },
    };
    for (args) |arg| try body.string(arg);
    const ctx = try self.allocator.create(OwnerRequest);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{ .manager = self, .generation = self.owner_generation, .inhibitor = which };
    // Address this owner, so a restart cannot give us a stale inhibitor.
    _ = try conn.call(self.signal_sender.?, bus_path, bus_interface, "Inhibit", "ssss", &body, ctx, onInhibit, call_timeout_ms);
    self.inhibitorPending(which).* = true;
}

pub fn onInhibit(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const ctx: *OwnerRequest = @ptrCast(@alignCast(owner orelse return));
    const self = ctx.manager;
    const which = ctx.inhibitor;
    defer self.allocator.destroy(ctx);
    if (ctx.generation != self.owner_generation) return;
    self.inhibitorPending(which).* = false;
    if (self.closing or !self.wantsInhibitor(which)) return;
    var msg = result catch |err| {
        log.warn("could not take logind {t} inhibitor: {}", .{ which, err });
        return;
    };
    if (msg.kind != .method_return or !std.mem.eql(u8, msg.headers.signature, "h")) {
        log.warn("logind refused {t} inhibitor: {s}", .{ which, msg.headers.error_name orelse "invalid reply" });
        return;
    }
    const fd = msg.body.unixFd() catch return;
    const owned = std.posix.system.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (owned < 0) {
        log.warn("could not retain logind {t} inhibitor", .{which});
        return;
    }
    self.inhibitorFd(which).* = owned;
    if (which == .lid) self.server.power_policy.reconcileLid();
    switch (which) {
        .lid => log.info("logind lid handling inhibited (RediWM policy)", .{}),
        .sleep => log.info("logind sleep delayed until the screen is locked", .{}),
    }
}

pub fn resetSignalOwner(self: *Manager) void {
    self.releaseInhibitor(.lid);
    self.releaseInhibitor(.sleep);
    self.owner_generation +%= 1;
    self.lid_pending = false;
    self.sleep_pending = false;
    self.forgetSession();
    if (self.signal_sender) |sender| self.allocator.free(sender);
    self.signal_sender = null;
}

/// Locks before logind lets the system sleep, holding the delay inhibitor
/// until the lock has reached every screen.
pub fn lockForSleep(self: *Manager) void {
    const server = self.server;
    if (!self.wantsInhibitor(.sleep)) return self.releaseInhibitor(.sleep);
    if (server.locker == null) {
        log.info("locking the session before sleep", .{});
        Lock.start(server);
    }
    const lock = server.locker orelse return self.releaseInhibitor(.sleep);
    if (self.sleep_fd == null) return;
    if (lock.covered()) return self.releaseInhibitor(.sleep);
    self.sleep_waiting = true;
    server.scheduleFrames();
    const timer = self.sleep_timer orelse blk: {
        const created = server.wl_server.getEventLoop().addTimer(*Manager, onSleepTimeout, self) catch return self.finishSleepWait();
        self.sleep_timer = created;
        break :blk created;
    };
    timer.timerUpdate(sleep_lock_timeout_ms) catch self.finishSleepWait();
}

/// Every output has committed a frame with the lock covering it.
pub fn lockCovered(self: *Manager) void {
    if (!self.sleep_waiting) return;
    log.info("the lock is on screen; the system may sleep", .{});
    self.finishSleepWait();
}

pub fn finishSleepWait(self: *Manager) void {
    self.sleep_waiting = false;
    if (self.sleep_timer) |timer| timer.timerUpdate(0) catch {};
    self.releaseInhibitor(.sleep);
}

pub fn onSleepTimeout(self: *Manager) c_int {
    if (self.sleep_waiting) {
        log.warn("the lock did not reach every screen in time; letting the system sleep", .{});
        self.finishSleepWait();
    }
    return 0;
}

/// The lock engaged or released (`Lock.announce`).
pub fn lockChanged(self: *Manager, locked: bool) void {
    self.locked = locked;
    self.syncLockedHint();
}
