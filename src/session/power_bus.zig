//! The logind connection: Hello, the signal owner, subscriptions, PrepareForSleep/PrepareForShutdown and API introspection.

const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const log = std.log.scoped(.power);
const power_mod = @import("power.zig");
const login = @import("login_manager.zig");
const Manager = power_mod.Manager;
const call_timeout_ms = power_mod.call_timeout_ms;
const onDisconnect = Manager.onDisconnect;

pub fn connection(self: *Manager) !*dbus.Connection {
    if (self.conn) |c| {
        if (!c.closed) return c;
        c.destroy();
        self.conn = null;
        self.resetSignalOwner();
        self.owner_changed = false;
        self.hello_done = false;
        self.introspect_done = false;
        self.has_with_flags = false;
        self.has_list_inhibitors = false;
    }
    const loop = self.server.wl_server.getEventLoop();
    const conn = try dbus.Connection.openSystemWithFds(self.allocator, loop, self.server.environ);
    errdefer conn.destroy();
    _ = try conn.hello(self, onHello);
    conn.on_disconnect = .{ .owner = self, .callback = onDisconnect };
    self.conn = conn;
    return conn;
}

pub fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    _ = result catch |err| {
        conn.close();
        const req = self.pending orelse return;
        if (login.usesCommand(req.kind.loginAction())) return;
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not reach the system's power service."), err);
        return;
    };
    self.hello_done = true;
    self.inspectApi(conn);
    self.watchSignalOwner(conn) catch return;
    _ = conn.addMatch(login.owner_match, null, null) catch return;
    _ = login.call(conn, .owner, null, self, onSignalOwner, call_timeout_ms) catch |err| {
        log.warn("could not resolve power signal sender: {}", .{err});
    };
}

pub fn onSignalOwner(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing or self.owner_changed) return;
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    const sender = msg.body.string() catch return;
    self.signal_sender = self.allocator.dupe(u8, sender) catch return;
    self.subscribeSignals(conn);
    self.syncInhibitors();
    self.watchSession(conn);
}

pub fn subscribeSignals(self: *Manager, conn: *dbus.Connection) void {
    _ = conn.subscribe(login.signal(.sleep, self.signal_sender orelse return, self, onPrepareForSleep), null, null) catch |err| {
        log.warn("could not subscribe to PrepareForSleep: {}", .{err});
    };
    _ = conn.subscribe(login.signal(.shutdown, self.signal_sender orelse return, self, onPrepareForShutdown), null, null) catch |err| {
        log.warn("could not subscribe to PrepareForShutdown: {}", .{err});
    };
}

pub fn onPrepareForSleep(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    var reader = msg.body;
    const sleep_starting = reader.boolean() catch {
        log.warn("PrepareForSleep: invalid body", .{});
        return;
    };
    if (sleep_starting) {
        log.info("PrepareForSleep(true): system is suspending; preparing session", .{});
        self.lockForSleep();
        self.server.deactivateSession();
    } else {
        log.info("PrepareForSleep(false): system resumed from sleep; restoring session", .{});
        if (self.sleep_waiting) self.finishSleepWait();
        self.server.reactivateSession();
        // Delay the next sleep too.
        self.syncInhibitors();
    }
}

pub fn onPrepareForShutdown(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    var reader = msg.body;
    const shutdown_starting = reader.boolean() catch {
        log.warn("PrepareForShutdown: invalid body", .{});
        return;
    };
    if (shutdown_starting) {
        // Preparation runs while delay inhibitors are still active. An
        // early logout can make the display manager start a new greeter
        // while those services are preparing devices for poweroff. Like
        // labwc/niri, leave session termination to systemd's SIGTERM.
        log.info("PrepareForShutdown(true): waiting for session termination", .{});
    } else {
        log.info("PrepareForShutdown(false): shutdown canceled", .{});
    }
}

pub fn inspectApi(self: *Manager, conn: *dbus.Connection) void {
    _ = login.call(conn, .inspect, null, self, onIntrospect, call_timeout_ms) catch {
        // If Introspect fails immediately, proceed with legacy methods
        self.introspect_done = true;
        self.maybeProbe();
        if (self.pending) |req| self.queryCapability(conn, req);
    };
}

pub fn onIntrospect(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    self.introspect_done = true;
    if (result) |msg| {
        const api = login.readApi(msg);
        self.has_with_flags = api.with_flags;
        self.has_list_inhibitors = api.list_inhibitors;
    } else |_| {}
    self.maybeProbe();
    const req = self.pending orelse return;
    self.queryCapability(conn, req);
}
