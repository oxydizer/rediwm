//! Following the login session: its Lock signal, LockedHint, disconnects and the logind name owner.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Lock = @import("lock.zig").Lock;
const log = std.log.scoped(.power);
const power_mod = @import("power.zig");
const login = @import("login_manager.zig");
const Manager = power_mod.Manager;
const call_timeout_ms = power_mod.call_timeout_ms;
const OwnerRequest = Manager.OwnerRequest;

/// Resolves REDIWM_LOGIN_SESSION, set only for a login rediwm-session
/// verified with logind; nested and test sessions have none.
pub fn watchSession(self: *Manager, conn: *dbus.Connection) void {
    if (self.server.greeter_mode or self.session_path != null or self.session_pending) return;
    const id = self.server.environ.getPosix("REDIWM_LOGIN_SESSION") orelse return;
    if (id.len == 0) return;
    const sender = self.signal_sender orelse return;
    const ctx = self.allocator.create(OwnerRequest) catch return;
    ctx.* = .{ .manager = self, .generation = self.owner_generation };
    _ = login.call(conn, .{ .session = id }, sender, ctx, onSession, call_timeout_ms) catch |err| {
        self.allocator.destroy(ctx);
        log.warn("could not look up the logind session: {}", .{err});
        return;
    };
    self.session_pending = true;
}

pub fn onSession(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const ctx: *OwnerRequest = @ptrCast(@alignCast(owner orelse return));
    const self = ctx.manager;
    defer self.allocator.destroy(ctx);
    if (ctx.generation != self.owner_generation) return;
    self.session_pending = false;
    if (self.closing) return;
    const msg = result catch |err| {
        log.warn("could not look up the logind session: {}", .{err});
        return;
    };
    const path = login.readSessionPath(msg) catch {
        log.warn("logind has no session for this login: {s}", .{msg.headers.error_name orelse "invalid reply"});
        return;
    };
    self.session_path = self.allocator.dupe(u8, path) catch return;
    // Every session's Lock comes from the same sender; ours is picked out
    // by path in the handler, so the registration owns no strings.
    _ = conn.subscribe(login.signal(.lock, self.signal_sender orelse return, self, onSessionLock), null, null) catch |err| log.warn("could not follow logind lock requests: {}", .{err});
    self.syncLockedHint();
}

pub fn forgetSession(self: *Manager) void {
    if (self.session_path) |path| self.allocator.free(path);
    self.session_path = null;
    self.session_pending = false;
    self.locked_hint = null;
}

pub fn onSessionLock(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    const ours = self.session_path orelse return;
    if (!std.mem.eql(u8, msg.headers.path orelse return, ours)) return;
    log.info("logind asked to lock the session", .{});
    Lock.start(self.server);
}

pub fn syncLockedHint(self: *Manager) void {
    const path = self.session_path orelse return;
    const conn = self.conn orelse return;
    const sender = self.signal_sender orelse return;
    if (conn.closed or self.locked_hint == self.locked) return;
    _ = login.call(conn, .{ .locked_hint = .{ .path = path, .locked = self.locked } }, sender, null, null, call_timeout_ms) catch |err| {
        log.warn("could not update the session's LockedHint: {}", .{err});
        return;
    };
    self.locked_hint = self.locked;
}

pub fn onDisconnect(owner: ?*anyopaque) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    self.resetSignalOwner();
    self.hello_done = false;
}

pub fn onOwnerChanged(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    const next = try login.changedOwner(msg) orelse return;
    self.owner_changed = true;
    conn.unregisterSignalsByOwner(self);
    try self.watchSignalOwner(conn);
    self.resetSignalOwner();
    if (next.len == 0) return;
    self.signal_sender = try self.allocator.dupe(u8, next);
    self.subscribeSignals(conn);
    self.syncInhibitors();
    self.watchSession(conn);
}

pub fn watchSignalOwner(self: *Manager, conn: *dbus.Connection) !void {
    try conn.registerSignal(login.signal(.owner_changed, null, self, onOwnerChanged));
}
