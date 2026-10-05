//! Poweroff/reboot through systemctl (like DMS); suspend through logind.
//! Capability probes and preparation signals still use the system bus.
//! Requests run as the logged-in user, with normal authorization and inhibitor
//! checks. Automatic power commands use --no-ask-password. Suspend uses
//! SuspendWithFlags with inhibitor checks, falling back to legacy Suspend.
//! Preparation does not log out: the session manager sends SIGTERM when ready.
//!
//! With `lock_on_suspend` a "sleep" delay inhibitor is held, so logind waits
//! until the lock covers every output before the system sleeps. A verified
//! login (REDIWM_LOGIN_SESSION) also follows logind's Lock request and keeps
//! the session's LockedHint current. logind's Unlock is deliberately ignored:
//! only the lock screen's own authentication ends a lock.
const std = @import("std");
const Child = @import("child.zig");
const wl = @import("wayland").server.wl;

const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const Lock = @import("lock.zig").Lock;

const log = std.log.scoped(.power);

const bus_name = "org.freedesktop.login1";
const bus_path = "/org/freedesktop/login1";
const bus_interface = "org.freedesktop.login1.Manager";
const session_interface = "org.freedesktop.login1.Session";
const introspect_interface = "org.freedesktop.DBus.Introspectable";
const call_timeout_ms: u32 = 5000;
/// How long PrepareForSleep waits for the lock to reach the screen. logind
/// itself gives up on delay inhibitors after InhibitDelayMaxSec (5 s default).
const sleep_lock_timeout_ms: i32 = 2000;

/// Enforce active inhibitors even for privileged callers, ensuring we never
/// bypass sleep/shutdown locks taken by package managers, backup tools, etc.
const SD_LOGIND_ROOT_CHECK_INHIBITORS: u64 = 1 << 0;

pub const Kind = enum {
    poweroff,
    reboot,
    @"suspend",

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .poweroff => "Power off",
            .reboot => "Restart",
            .@"suspend" => "Suspend",
        };
    }
    fn canMethod(self: Kind) []const u8 {
        return switch (self) {
            .poweroff => "CanPowerOff",
            .reboot => "CanReboot",
            .@"suspend" => "CanSuspend",
        };
    }
    fn actionMethod(self: Kind) []const u8 {
        return switch (self) {
            .poweroff => "PowerOff",
            .reboot => "Reboot",
            .@"suspend" => "Suspend",
        };
    }
    fn withFlagsMethod(self: Kind) []const u8 {
        return switch (self) {
            .poweroff => "PowerOffWithFlags",
            .reboot => "RebootWithFlags",
            .@"suspend" => "SuspendWithFlags",
        };
    }
    fn inhibitorType(self: Kind) []const u8 {
        return switch (self) {
            .poweroff, .reboot => "shutdown",
            .@"suspend" => "sleep",
        };
    }
};

pub const Capability = enum {
    unknown,
    yes,
    challenge,
    no,
    na,

    pub fn isAvailable(self: Capability) bool {
        return switch (self) {
            .no, .na => false,
            .unknown, .yes, .challenge => true,
        };
    }

    pub fn parse(text: []const u8) Capability {
        return std.meta.stringToEnum(Capability, text) orelse .unknown;
    }
};

pub const Request = struct {
    kind: Kind,
    interactive: bool,
};

/// Only one request may be in flight; a second action while one is
/// pending is reported and dropped rather than queued. There is no automatic
/// retry after a lost connection — the next explicit user action reconnects.
pub const Manager = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    conn: ?*dbus.Connection = null,
    signal_sender: ?[]const u8 = null,
    hello_done: bool = false,
    introspect_done: bool = false,
    has_with_flags: bool = false,
    has_list_inhibitors: bool = false,
    can_poweroff: Capability = .unknown,
    can_reboot: Capability = .unknown,
    can_suspend: Capability = .unknown,
    probing: bool = false,
    probe_replies_pending: u8 = 0,
    want_probe: bool = false,
    pending: ?Request = null,
    command_child: ?*Child = null,
    closing: bool = false,
    lid_fd: ?std.posix.fd_t = null,
    lid_pending: bool = false,
    /// The "sleep" delay inhibitor held while `lock_on_suspend` is on.
    sleep_fd: ?std.posix.fd_t = null,
    sleep_pending: bool = false,
    /// PrepareForSleep(true) until the lock covers every output.
    sleep_waiting: bool = false,
    sleep_timer: ?*wl.EventSource = null,
    /// This login's logind session object, for Lock and LockedHint.
    session_path: ?[]u8 = null,
    session_pending: bool = false,
    /// What the lock last announced, and what logind was last told.
    locked: bool = false,
    locked_hint: ?bool = null,
    owner_generation: u64 = 0,
    owner_changed: bool = false,

    const Inhibitor = enum { lid, sleep };
    const OwnerRequest = struct { manager: *Manager, generation: u64, inhibitor: Inhibitor = .lid };

    fn wantsInhibitor(self: *Manager, which: Inhibitor) bool {
        if (self.server.greeter_mode) return false;
        return switch (which) {
            .lid => self.server.config.compositor.lid_close == .ignore,
            .sleep => self.server.config.compositor.lock_on_suspend,
        };
    }

    fn inhibitorFd(self: *Manager, which: Inhibitor) *?std.posix.fd_t {
        return switch (which) {
            .lid => &self.lid_fd,
            .sleep => &self.sleep_fd,
        };
    }

    fn inhibitorPending(self: *Manager, which: Inhibitor) *bool {
        return switch (which) {
            .lid => &self.lid_pending,
            .sleep => &self.sleep_pending,
        };
    }

    fn releaseInhibitor(self: *Manager, which: Inhibitor) void {
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

    fn acquireInhibitor(self: *Manager, conn: *dbus.Connection, which: Inhibitor) !void {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        const args: [4][]const u8 = switch (which) {
            .lid => .{ "handle-lid-switch", "RediWM", "Lid close is set to Do nothing", "block" },
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

    fn onInhibit(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
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
        switch (which) {
            .lid => log.info("logind lid handling inhibited (Do nothing)", .{}),
            .sleep => log.info("logind sleep delayed until the screen is locked", .{}),
        }
    }

    fn resetSignalOwner(self: *Manager) void {
        self.releaseInhibitor(.lid);
        self.releaseInhibitor(.sleep);
        self.owner_generation +%= 1;
        self.lid_pending = false;
        self.sleep_pending = false;
        self.forgetSession();
        if (self.signal_sender) |sender| self.allocator.free(sender);
        self.signal_sender = null;
    }

    // ---- lock before sleep, logind Lock and LockedHint --------------------

    /// Locks before logind lets the system sleep, holding the delay inhibitor
    /// until the lock has reached every screen.
    fn lockForSleep(self: *Manager) void {
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

    fn finishSleepWait(self: *Manager) void {
        self.sleep_waiting = false;
        if (self.sleep_timer) |timer| timer.timerUpdate(0) catch {};
        self.releaseInhibitor(.sleep);
    }

    fn onSleepTimeout(self: *Manager) c_int {
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

    /// Resolves REDIWM_LOGIN_SESSION, set only for a login rediwm-session
    /// verified with logind; nested and test sessions have none.
    fn watchSession(self: *Manager, conn: *dbus.Connection) void {
        if (self.server.greeter_mode or self.session_path != null or self.session_pending) return;
        const id = self.server.environ.getPosix("REDIWM_LOGIN_SESSION") orelse return;
        if (id.len == 0) return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string(id) catch return;
        const sender = self.signal_sender orelse return;
        const ctx = self.allocator.create(OwnerRequest) catch return;
        ctx.* = .{ .manager = self, .generation = self.owner_generation };
        _ = conn.call(sender, bus_path, bus_interface, "GetSession", "s", &body, ctx, onSession, call_timeout_ms) catch |err| {
            self.allocator.destroy(ctx);
            log.warn("could not look up the logind session: {}", .{err});
            return;
        };
        self.session_pending = true;
    }

    fn onSession(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const ctx: *OwnerRequest = @ptrCast(@alignCast(owner orelse return));
        const self = ctx.manager;
        defer self.allocator.destroy(ctx);
        if (ctx.generation != self.owner_generation) return;
        self.session_pending = false;
        if (self.closing) return;
        var msg = result catch |err| {
            log.warn("could not look up the logind session: {}", .{err});
            return;
        };
        if (msg.kind != .method_return or !std.mem.eql(u8, msg.headers.signature, "o")) {
            log.warn("logind has no session for this login: {s}", .{msg.headers.error_name orelse "invalid reply"});
            return;
        }
        const path = msg.body.objectPath() catch return;
        self.session_path = self.allocator.dupe(u8, path) catch return;
        // Every session's Lock comes from the same sender; ours is picked out
        // by path in the handler, so the registration owns no strings.
        _ = conn.subscribe(.{
            .sender = self.signal_sender orelse return,
            .interface = session_interface,
            .member = "Lock",
            .owner = self,
            .callback = onSessionLock,
        }, null, null) catch |err| log.warn("could not follow logind lock requests: {}", .{err});
        self.syncLockedHint();
    }

    fn forgetSession(self: *Manager) void {
        if (self.session_path) |path| self.allocator.free(path);
        self.session_path = null;
        self.session_pending = false;
        self.locked_hint = null;
    }

    fn onSessionLock(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const ours = self.session_path orelse return;
        if (!std.mem.eql(u8, msg.headers.path orelse return, ours)) return;
        log.info("logind asked to lock the session", .{});
        Lock.start(self.server);
    }

    fn syncLockedHint(self: *Manager) void {
        const path = self.session_path orelse return;
        const conn = self.conn orelse return;
        const sender = self.signal_sender orelse return;
        if (conn.closed or self.locked_hint == self.locked) return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.boolean(self.locked) catch return;
        _ = conn.call(sender, path, session_interface, "SetLockedHint", "b", &body, null, null, call_timeout_ms) catch |err| {
            log.warn("could not update the session's LockedHint: {}", .{err});
            return;
        };
        self.locked_hint = self.locked;
    }

    fn onDisconnect(owner: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        self.resetSignalOwner();
        self.hello_done = false;
    }

    fn onOwnerChanged(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        var body = msg.body;
        if (!std.mem.eql(u8, try body.string(), bus_name)) return;
        _ = try body.string();
        const next = try body.string();
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

    fn watchSignalOwner(self: *Manager, conn: *dbus.Connection) !void {
        try conn.registerSignal(.{
            .sender = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "NameOwnerChanged",
            .owner = self,
            .callback = onOwnerChanged,
        });
    }

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*Manager {
        const mgr = try allocator.create(Manager);
        mgr.* = .{ .server = server, .allocator = allocator };
        mgr.ensureConnected();
        return mgr;
    }

    pub fn isAvailable(self: *Manager, kind: Kind) bool {
        const cap = switch (kind) {
            .poweroff => self.can_poweroff,
            .reboot => self.can_reboot,
            .@"suspend" => self.can_suspend,
        };
        return cap.isAvailable();
    }

    pub fn unavailableExplanation(self: *Manager, kind: Kind) ?[]const u8 {
        const cap = switch (kind) {
            .poweroff => self.can_poweroff,
            .reboot => self.can_reboot,
            .@"suspend" => self.can_suspend,
        };
        return switch (cap) {
            .no => "Denied by policy",
            .na => "Not supported",
            else => null,
        };
    }

    pub fn setCapability(self: *Manager, kind: Kind, cap: Capability) void {
        switch (kind) {
            .poweroff => self.can_poweroff = cap,
            .reboot => self.can_reboot = cap,
            .@"suspend" => self.can_suspend = cap,
        }
    }

    /// Called whenever something wants to know CanPowerOff/CanReboot/
    /// CanSuspend without making a request (currently: the power menu, on
    /// every open). The connection may still be mid-handshake at this point
    /// (e.g. the menu opened moments after compositor startup, before Hello/
    /// Introspect round-tripped) — in that case this just records the intent
    /// and `onIntrospect` fires the actual probe once the handshake lands, so
    /// the request is never silently dropped.
    pub fn probeCapabilities(self: *Manager) void {
        self.want_probe = true;
        self.maybeProbe();
    }

    fn maybeProbe(self: *Manager) void {
        if (!self.want_probe) return;
        const conn = self.conn orelse return;
        if (!self.hello_done or !self.introspect_done) return;
        if (self.probing) return;
        self.want_probe = false;
        self.probing = true;
        self.probe_replies_pending = 3;
        self.queryProbe(conn, .poweroff);
        self.queryProbe(conn, .reboot);
        self.queryProbe(conn, .@"suspend");
    }

    fn queryProbe(self: *Manager, conn: *dbus.Connection, kind: Kind) void {
        var empty: wire.Writer = .{ .allocator = self.allocator };
        defer empty.deinit();
        const Context = struct { mgr: *Manager, kind: Kind };
        const ctx = self.allocator.create(Context) catch {
            self.finishProbeReply();
            return;
        };
        ctx.* = .{ .mgr = self, .kind = kind };
        _ = conn.call(bus_name, bus_path, bus_interface, kind.canMethod(), "", &empty, ctx, onProbeCapability, call_timeout_ms) catch {
            self.allocator.destroy(ctx);
            self.finishProbeReply();
        };
    }

    /// `probing` guards against starting a second probe batch while one of
    /// the three Can* replies is still outstanding; it must only clear once
    /// all three have been accounted for (reply received, or the call never
    /// made it onto the bus), not after the first one back.
    fn finishProbeReply(self: *Manager) void {
        self.probe_replies_pending -|= 1;
        if (self.probe_replies_pending == 0) self.probing = false;
    }

    fn onProbeCapability(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const Context = struct { mgr: *Manager, kind: Kind };
        const ctx: *Context = @ptrCast(@alignCast(owner orelse return));
        defer ctx.mgr.allocator.destroy(ctx);
        if (ctx.mgr.closing) return;
        ctx.mgr.finishProbeReply();
        var msg = result catch return;
        if (msg.kind != .method_return) return;
        const cap = msg.body.string() catch return;
        ctx.mgr.setCapability(ctx.kind, Capability.parse(cap));

        var it = ctx.mgr.server.outputs.iterator(.forward);
        while (it.next()) |out| {
            if (out.power_menu) |pm| {
                pm.refreshCapabilities();
            }
        }
    }

    pub fn ensureConnected(self: *Manager) void {
        _ = self.connection() catch {};
    }

    pub fn deinit(self: *Manager) void {
        self.closing = true;
        self.releaseInhibitor(.lid);
        self.releaseInhibitor(.sleep);
        if (self.sleep_timer) |timer| timer.remove();
        if (self.command_child) |child| child.detach();
        if (self.conn) |c| c.destroy();
        if (self.signal_sender) |sender| self.allocator.free(sender);
        if (self.session_path) |path| self.allocator.free(path);
        self.allocator.destroy(self);
    }

    pub fn requestPowerOff(self: *Manager) void {
        self.request(.poweroff, true);
    }
    pub fn requestReboot(self: *Manager) void {
        self.request(.reboot, true);
    }
    pub fn requestSuspend(self: *Manager) void {
        self.request(.@"suspend", true);
    }
    pub fn requestPowerOffAuto(self: *Manager) void {
        self.request(.poweroff, false);
    }
    pub fn requestRebootAuto(self: *Manager) void {
        self.request(.reboot, false);
    }
    pub fn requestSuspendAuto(self: *Manager) void {
        self.request(.@"suspend", false);
    }

    pub fn request(self: *Manager, kind: Kind, interactive: bool) void {
        self.beginRequest(.{ .kind = kind, .interactive = interactive });
    }

    fn beginRequest(self: *Manager, req: Request) void {
        if (self.pending != null) {
            log.warn("{s}: rejected, {s} is already pending", .{ req.kind.label(), self.pending.?.kind.label() });
            self.report(req.kind, "Another power action is already in progress.");
            return;
        }
        self.pending = req;
        if (req.kind != .@"suspend") {
            self.startCommand(req);
            return;
        }
        const conn = self.connection() catch |err| {
            self.pending = null;
            self.failed(req.kind, "Could not reach the system's power service.", err);
            return;
        };
        // A freshly opened connection queries once its Hello + Introspect
        // handshake completes (see onHello/onIntrospect); a reused one can query right away.
        if (self.hello_done and self.introspect_done) {
            self.queryCapability(conn, req);
        }
    }

    fn startCommand(self: *Manager, req: Request) void {
        const action = if (req.kind == .reboot) "reboot" else "poweroff";
        const argv: []const []const u8 = if (req.interactive)
            &.{ "systemctl", action }
        else
            &.{ "systemctl", action, "--no-ask-password" };
        var child = std.process.spawn(self.server.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            // Preserve systemctl's detailed refusal/inhibitor reason in the
            // session log. Completion is delivered by the pidfd watcher.
        }) catch |err| {
            self.pending = null;
            self.failed(req.kind, "Could not start the power command.", err);
            return;
        };
        self.command_child = Child.watch(self.allocator, self.server.wl_server.getEventLoop(), child.id.?, self, commandExited) catch |err| {
            child.kill(self.server.io);
            self.pending = null;
            self.failed(req.kind, "Could not watch the power command.", err);
            return;
        };
    }

    fn commandExited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        self.command_child = null;
        const req = self.pending orelse return;
        self.pending = null;
        if (status != null and status.? == 0) {
            log.info("{s} requested via systemctl", .{req.kind.label()});
        } else {
            log.warn("{s}: systemctl failed (wait status {?d})", .{ req.kind.label(), status });
            self.report(req.kind, "Power request failed. Check permissions and applications blocking shutdown.");
        }
    }

    fn connection(self: *Manager) !*dbus.Connection {
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

    fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        _ = result catch |err| {
            conn.close();
            const req = self.pending orelse return;
            if (req.kind != .@"suspend") return;
            self.pending = null;
            self.failed(req.kind, "Could not reach the system's power service.", err);
            return;
        };
        self.hello_done = true;
        self.inspectApi(conn);
        self.watchSignalOwner(conn) catch return;
        _ = conn.addMatch("type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.login1'", null, null) catch return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string(bus_name) catch return;
        _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &body, self, onSignalOwner, call_timeout_ms) catch |err| {
            log.warn("could not resolve power signal sender: {}", .{err});
        };
    }

    fn onSignalOwner(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
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

    fn subscribeSignals(self: *Manager, conn: *dbus.Connection) void {
        _ = conn.subscribe(.{
            .sender = self.signal_sender orelse return,
            .path = bus_path,
            .interface = bus_interface,
            .member = "PrepareForSleep",
            .owner = self,
            .callback = onPrepareForSleep,
        }, null, null) catch |err| {
            log.warn("could not subscribe to PrepareForSleep: {}", .{err});
        };
        _ = conn.subscribe(.{
            .sender = self.signal_sender orelse return,
            .path = bus_path,
            .interface = bus_interface,
            .member = "PrepareForShutdown",
            .owner = self,
            .callback = onPrepareForShutdown,
        }, null, null) catch |err| {
            log.warn("could not subscribe to PrepareForShutdown: {}", .{err});
        };
    }

    fn onPrepareForSleep(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
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

    fn onPrepareForShutdown(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
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

    fn inspectApi(self: *Manager, conn: *dbus.Connection) void {
        const body: wire.Writer = .{ .allocator = self.allocator };
        _ = conn.call(bus_name, bus_path, introspect_interface, "Introspect", "", &body, self, onIntrospect, call_timeout_ms) catch {
            // If Introspect fails immediately, proceed with legacy methods
            self.introspect_done = true;
            self.maybeProbe();
            if (self.pending) |req| self.queryCapability(conn, req);
        };
    }

    fn onIntrospect(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        self.introspect_done = true;
        if (result) |*msg| {
            if (msg.kind == .method_return) {
                var reader = msg.body;
                if (reader.string()) |xml| {
                    self.has_with_flags = std.mem.indexOf(u8, xml, "SuspendWithFlags") != null;
                    self.has_list_inhibitors = std.mem.indexOf(u8, xml, "ListInhibitors") != null;
                } else |_| {}
            }
        } else |_| {}
        self.maybeProbe();
        const req = self.pending orelse return;
        self.queryCapability(conn, req);
    }

    fn queryCapability(self: *Manager, conn: *dbus.Connection, req: Request) void {
        if (req.kind != .@"suspend") return;
        const body: wire.Writer = .{ .allocator = self.allocator };
        _ = conn.call(bus_name, bus_path, bus_interface, req.kind.canMethod(), "", &body, self, onCapability, call_timeout_ms) catch |err| {
            self.pending = null;
            self.failed(req.kind, "Could not query logind.", err);
        };
    }

    fn onCapability(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const req = self.pending orelse return;
        var msg = result catch |err| {
            self.pending = null;
            self.failed(req.kind, "Could not query logind.", err);
            return;
        };
        if (msg.kind != .method_return) {
            self.pending = null;
            self.failedMsg(req.kind, "Could not query logind.", msg);
            return;
        }
        const cap = msg.body.string() catch {
            self.pending = null;
            self.failed(req.kind, "Logind returned a malformed reply.", error.InvalidReply);
            return;
        };
        self.setCapability(req.kind, Capability.parse(cap));
        // "challenge" means interactive authorization may be required, not
        // that the action is unavailable; only "no"/"na" stop unconditionally.
        if (std.mem.eql(u8, cap, "no")) {
            self.pending = null;
            log.warn("{s}: denied by system policy", .{req.kind.label()});
            self.report(req.kind, "Denied by system policy.");
            return;
        }
        if (std.mem.eql(u8, cap, "na")) {
            self.pending = null;
            log.warn("{s}: not available on this system", .{req.kind.label()});
            self.report(req.kind, "Not available on this system.");
            return;
        }
        if (!std.mem.eql(u8, cap, "yes") and !std.mem.eql(u8, cap, "challenge")) {
            self.pending = null;
            log.warn("{s}: unrecognized logind capability '{s}'", .{ req.kind.label(), cap });
            self.report(req.kind, "Logind returned an unrecognized reply.");
            return;
        }

        // Automatic requests must never open an authentication prompt or silently override inhibitors.
        if (std.mem.eql(u8, cap, "challenge") and !req.interactive) {
            self.pending = null;
            log.warn("{s}: automatic request denied, interactive authorization required", .{req.kind.label()});
            self.report(req.kind, "Interactive authorization required.");
            return;
        }

        self.callAction(conn, req);
    }

    fn callAction(self: *Manager, conn: *dbus.Connection, req: Request) void {
        const msg_flags: u8 = if (req.interactive) wire.flag_allow_interactive_authorization else 0;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();

        if (self.has_with_flags) {
            body.uint64(SD_LOGIND_ROOT_CHECK_INHIBITORS) catch |err| {
                self.pending = null;
                self.failed(req.kind, "Could not build the request.", err);
                return;
            };
            _ = conn.callWithFlags(bus_name, bus_path, bus_interface, req.kind.withFlagsMethod(), "t", &body, self, onAction, call_timeout_ms, msg_flags) catch |err| {
                self.pending = null;
                self.failed(req.kind, "Could not reach logind.", err);
            };
        } else {
            body.boolean(req.interactive) catch |err| {
                self.pending = null;
                self.failed(req.kind, "Could not build the request.", err);
                return;
            };
            _ = conn.callWithFlags(bus_name, bus_path, bus_interface, req.kind.actionMethod(), "b", &body, self, onAction, call_timeout_ms, msg_flags) catch |err| {
                self.pending = null;
                self.failed(req.kind, "Could not reach logind.", err);
            };
        }
    }

    fn onAction(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const req = self.pending orelse return;
        const msg = result catch |err| {
            self.pending = null;
            self.failed(req.kind, "Logind request failed.", err);
            return;
        };
        if (msg.kind == .method_return) {
            self.pending = null;
            log.info("{s} requested via logind", .{req.kind.label()});
            return;
        }

        const err_name = msg.headers.error_name orelse "";

        // If WithFlags is not recognized by this logind instance, fall back to the legacy method.
        if (self.has_with_flags and std.mem.eql(u8, err_name, "org.freedesktop.DBus.Error.UnknownMethod")) {
            log.info("{s}: WithFlags method not found; falling back to legacy method", .{req.kind.label()});
            self.has_with_flags = false;
            self.callAction(conn, req);
            return;
        }

        if (std.mem.eql(u8, err_name, "org.freedesktop.login1.OperationInhibited") or
            std.mem.eql(u8, err_name, "org.freedesktop.login1.BlockedByInhibitorLock"))
        {
            if (self.has_list_inhibitors) {
                self.queryInhibitors(conn);
                return;
            }
            self.pending = null;
            log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
            self.report(req.kind, "Blocked by an active inhibitor lock.");
            return;
        }

        self.pending = null;

        if (std.mem.eql(u8, err_name, "org.freedesktop.DBus.Error.InteractiveAuthorizationRequired")) {
            log.warn("{s}: interactive authorization required", .{req.kind.label()});
            self.report(req.kind, "Interactive authorization required.");
            return;
        }

        if (std.mem.eql(u8, err_name, "org.freedesktop.DBus.Error.AccessDenied") or
            std.mem.eql(u8, err_name, "org.freedesktop.login1.NotEnoughPrivileges"))
        {
            log.warn("{s}: denied by system policy ({s})", .{ req.kind.label(), err_name });
            self.report(req.kind, "Denied by system policy.");
            return;
        }

        self.failedMsg(req.kind, "Logind refused the request.", msg);
    }

    fn queryInhibitors(self: *Manager, conn: *dbus.Connection) void {
        const body: wire.Writer = .{ .allocator = self.allocator };
        _ = conn.call(bus_name, bus_path, bus_interface, "ListInhibitors", "", &body, self, onListInhibitors, call_timeout_ms) catch {
            const req = self.pending orelse return;
            self.pending = null;
            log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
            self.report(req.kind, "Blocked by an active inhibitor lock.");
        };
    }

    fn onListInhibitors(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const req = self.pending orelse return;
        self.pending = null;

        var msg = result catch {
            log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
            self.report(req.kind, "Blocked by an active inhibitor lock.");
            return;
        };
        if (msg.kind != .method_return) {
            log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
            self.report(req.kind, "Blocked by an active inhibitor lock.");
            return;
        }
        self.handleInhibitors(req.kind, &msg.body);
    }

    fn handleInhibitors(self: *Manager, kind: Kind, body: *wire.Reader) void {
        const target = kind.inhibitorType();
        var array = body.array(8) catch {
            log.warn("{s}: blocked by an active inhibitor lock", .{kind.label()});
            self.report(kind, "Blocked by an active inhibitor lock.");
            return;
        };
        while (array.offset < array.bytes.len) {
            array.alignTo(8) catch break;
            const what = array.string() catch break;
            const who = array.string() catch break;
            const why = array.string() catch break;
            const mode = array.string() catch break;
            const uid = array.uint32() catch break;
            const pid = array.uint32() catch break;
            if (std.mem.eql(u8, mode, "block") and std.mem.indexOf(u8, what, target) != null) {
                log.warn("{s}: blocked by inhibitor from '{s}' (pid {d}, uid {d}): {s}", .{ kind.label(), who, pid, uid, why });
                if (who.len > 0 and why.len > 0) {
                    var buf: [128]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "Blocked by {s}: {s}", .{ who, why }) catch "Blocked by an application.";
                    self.report(kind, text);
                } else if (who.len > 0) {
                    var buf: [128]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "Blocked by {s}.", .{who}) catch "Blocked by an application.";
                    self.report(kind, text);
                } else {
                    self.report(kind, "Blocked by an application.");
                }
                return;
            }
        }
        log.warn("{s}: blocked by an active inhibitor lock", .{kind.label()});
        self.report(kind, "Blocked by an active inhibitor lock.");
    }

    fn failed(self: *Manager, kind: Kind, why: []const u8, err: anyerror) void {
        log.warn("{s}: {s} ({s})", .{ kind.label(), why, @errorName(err) });
        self.report(kind, why);
    }

    fn failedMsg(self: *Manager, kind: Kind, why: []const u8, msg: wire.Message) void {
        log.warn("{s}: {s} ({s})", .{ kind.label(), why, msg.headers.error_name orelse "unknown error" });
        self.report(kind, why);
    }

    fn report(self: *Manager, kind: Kind, why: []const u8) void {
        if (self.server.notifications) |nm| {
            var buf: [64]u8 = undefined;
            const title = std.fmt.bufPrint(&buf, "{s} failed", .{kind.label()}) catch "Power action failed";
            _ = nm.postNotification("Power", 0, "", title, why, &.{}, 1, false, true, 4000, "", null) catch {};
        }
    }
};
