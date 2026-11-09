//! Power requests: the systemctl fallback, capability checks, calling the action, inhibitor listings and failure reports.

const i18n = @import("i18n");
const std = @import("std");
const Child = @import("child.zig");
const dbus = @import("dbus");
const wire = dbus.wire;
const log = std.log.scoped(.power);
const power_mod = @import("power.zig");
const login = @import("login_manager.zig");
const Manager = power_mod.Manager;
const call_timeout_ms = power_mod.call_timeout_ms;
const Kind = power_mod.Kind;
const Capability = power_mod.Capability;
const Request = power_mod.Request;
const commandArgv = power_mod.commandArgv;

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

pub fn beginRequest(self: *Manager, req: Request) void {
    if (self.pending != null) {
        log.warn("{s}: rejected, {s} is already pending", .{ req.kind.label(), self.pending.?.kind.label() });
        self.report(req.kind, i18n.tr("Another power action is already in progress."));
        return;
    }
    self.pending = req;
    if (login.usesCommand(req.kind.loginAction())) {
        self.startCommand(req);
        return;
    }
    const conn = self.connection() catch |err| {
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not reach the system's power service."), err);
        return;
    };
    // A freshly opened connection queries once its Hello + Introspect
    // handshake completes (see onHello/onIntrospect); a reused one can query right away.
    if (self.hello_done and self.introspect_done) {
        self.queryCapability(conn, req);
    }
}

pub fn startCommand(self: *Manager, req: Request) void {
    var buf: [4][]const u8 = undefined;
    const argv = commandArgv(&buf, req.kind, req.interactive, false) orelse unreachable;
    var child = std.process.spawn(self.server.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        // Preserve the tool's detailed refusal/inhibitor reason in the
        // session log. Completion is delivered by the pidfd watcher.
    }) catch |err| {
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not start the power command."), err);
        return;
    };
    self.command_tool = argv[0];
    self.command_child = Child.watch(self.allocator, self.server.wl_server.getEventLoop(), child.id.?, self, commandExited) catch |err| {
        child.kill(self.server.io);
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not watch the power command."), err);
        return;
    };
}

pub fn commandExited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    self.command_child = null;
    const req = self.pending orelse return;
    self.pending = null;
    if (status != null and status.? == 0) {
        log.info("{s} requested via {s}", .{ req.kind.label(), self.command_tool });
    } else {
        log.warn("{s}: {s} failed (wait status {?d})", .{ req.kind.label(), self.command_tool, status });
        self.report(req.kind, i18n.tr("Power request failed. Check permissions and applications blocking shutdown."));
    }
}

pub fn queryCapability(self: *Manager, conn: *dbus.Connection, req: Request) void {
    if (login.usesCommand(req.kind.loginAction())) return;
    _ = login.call(conn, .{ .capability = req.kind.loginAction() }, null, self, onCapability, call_timeout_ms) catch |err| {
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not query logind."), err);
    };
}

pub fn onCapability(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    const req = self.pending orelse return;
    var msg = result catch |err| {
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not query logind."), err);
        return;
    };
    if (msg.kind != .method_return) {
        self.pending = null;
        self.failedMsg(req.kind, i18n.tr("Could not query logind."), msg);
        return;
    }
    const cap = msg.body.string() catch {
        self.pending = null;
        self.failed(req.kind, i18n.tr("Logind returned a malformed reply."), error.InvalidReply);
        return;
    };
    self.setCapability(req.kind, Capability.parse(cap));
    // "challenge" means interactive authorization may be required, not
    // that the action is unavailable; only "no"/"na" stop unconditionally.
    if (std.mem.eql(u8, cap, "no")) {
        self.pending = null;
        log.warn("{s}: denied by system policy", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Denied by system policy."));
        return;
    }
    if (std.mem.eql(u8, cap, "na")) {
        self.pending = null;
        log.warn("{s}: not available on this system", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Not available on this system."));
        return;
    }
    if (!std.mem.eql(u8, cap, "yes") and !std.mem.eql(u8, cap, "challenge")) {
        self.pending = null;
        log.warn("{s}: unrecognized logind capability '{s}'", .{ req.kind.label(), cap });
        self.report(req.kind, i18n.tr("Logind returned an unrecognized reply."));
        return;
    }

    // Automatic requests must never open an authentication prompt or silently override inhibitors.
    if (std.mem.eql(u8, cap, "challenge") and !req.interactive) {
        self.pending = null;
        log.warn("{s}: automatic request denied, interactive authorization required", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Interactive authorization required."));
        return;
    }

    self.callAction(conn, req);
}

pub fn callAction(self: *Manager, conn: *dbus.Connection, req: Request) void {
    _ = login.call(conn, .{ .action = .{ .kind = req.kind.loginAction(), .interactive = req.interactive, .with_flags = self.has_with_flags } }, null, self, onAction, call_timeout_ms) catch |err| {
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not reach logind."), err);
    };
}

pub fn onAction(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    const req = self.pending orelse return;
    const msg = result catch |err| {
        self.pending = null;
        self.failed(req.kind, i18n.tr("Logind request failed."), err);
        return;
    };
    if (msg.kind == .method_return) {
        self.pending = null;
        log.info("{s} requested via logind", .{req.kind.label()});
        return;
    }

    const err_name = msg.headers.error_name orelse "";
    const failure = login.actionError(err_name);

    // If WithFlags is not recognized by this logind instance, fall back to the legacy method.
    if (self.has_with_flags and failure == .unknown_method) {
        log.info("{s}: WithFlags method not found; falling back to legacy method", .{req.kind.label()});
        self.has_with_flags = false;
        self.callAction(conn, req);
        return;
    }

    if (failure == .inhibited) {
        if (self.has_list_inhibitors) {
            self.queryInhibitors(conn);
            return;
        }
        self.pending = null;
        log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Blocked by an active inhibitor lock."));
        return;
    }

    self.pending = null;

    if (failure == .authorization_required) {
        log.warn("{s}: interactive authorization required", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Interactive authorization required."));
        return;
    }

    if (failure == .denied) {
        log.warn("{s}: denied by system policy ({s})", .{ req.kind.label(), err_name });
        self.report(req.kind, i18n.tr("Denied by system policy."));
        return;
    }

    self.failedMsg(req.kind, i18n.tr("Logind refused the request."), msg);
}

pub fn queryInhibitors(self: *Manager, conn: *dbus.Connection) void {
    _ = login.call(conn, .list_inhibitors, null, self, onListInhibitors, call_timeout_ms) catch {
        const req = self.pending orelse return;
        self.pending = null;
        log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Blocked by an active inhibitor lock."));
    };
}

pub fn onListInhibitors(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    const req = self.pending orelse return;
    self.pending = null;

    var msg = result catch {
        log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Blocked by an active inhibitor lock."));
        return;
    };
    if (msg.kind != .method_return) {
        log.warn("{s}: blocked by an active inhibitor lock", .{req.kind.label()});
        self.report(req.kind, i18n.tr("Blocked by an active inhibitor lock."));
        return;
    }
    self.handleInhibitors(req.kind, &msg.body);
}

pub fn handleInhibitors(self: *Manager, kind: Kind, body: *wire.Reader) void {
    const target = kind.inhibitorType();
    var array = body.array(8) catch {
        log.warn("{s}: blocked by an active inhibitor lock", .{kind.label()});
        self.report(kind, i18n.tr("Blocked by an active inhibitor lock."));
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
                const text = i18n.fmt(&buf, i18n.tr("Blocked by {application}: {reason}"), .{ .application = who, .reason = why }) catch i18n.tr("Blocked by an application.");
                self.report(kind, text);
            } else if (who.len > 0) {
                var buf: [128]u8 = undefined;
                const text = i18n.fmt(&buf, i18n.tr("Blocked by {application}."), .{ .application = who }) catch i18n.tr("Blocked by an application.");
                self.report(kind, text);
            } else {
                self.report(kind, i18n.tr("Blocked by an application."));
            }
            return;
        }
    }
    log.warn("{s}: blocked by an active inhibitor lock", .{kind.label()});
    self.report(kind, i18n.tr("Blocked by an active inhibitor lock."));
}

pub fn failed(self: *Manager, kind: Kind, why: []const u8, err: anyerror) void {
    log.warn("{s}: {s} ({s})", .{ kind.label(), why, @errorName(err) });
    self.report(kind, why);
}

pub fn failedMsg(self: *Manager, kind: Kind, why: []const u8, msg: wire.Message) void {
    log.warn("{s}: {s} ({s})", .{ kind.label(), why, msg.headers.error_name orelse "unknown error" });
    self.report(kind, why);
}

pub fn report(self: *Manager, kind: Kind, why: []const u8) void {
    if (self.server.notifications) |nm| {
        var buf: [64]u8 = undefined;
        const title = i18n.fmt(&buf, i18n.tr("{action} failed"), .{ .action = kind.label() }) catch i18n.tr("Power action failed");
        _ = nm.postNotification(i18n.tr("Power"), 0, "", title, why, &.{}, 1, false, true, 4000, "", null) catch {};
    }
}
