//! Capabilities: availability, explanations and probing CanPowerOff/CanReboot/CanSuspend.

const i18n = @import("i18n");
const dbus = @import("dbus");
const wire = dbus.wire;
const power_mod = @import("power.zig");
const login = @import("login_manager.zig");
const Manager = power_mod.Manager;
const call_timeout_ms = power_mod.call_timeout_ms;
const Kind = power_mod.Kind;
const Capability = power_mod.Capability;

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
        .no => i18n.tr("Denied by policy"),
        .na => i18n.tr("Not supported"),
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

pub fn maybeProbe(self: *Manager) void {
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

pub fn queryProbe(self: *Manager, conn: *dbus.Connection, kind: Kind) void {
    const Context = struct { mgr: *Manager, kind: Kind };
    const ctx = self.allocator.create(Context) catch {
        self.finishProbeReply();
        return;
    };
    ctx.* = .{ .mgr = self, .kind = kind };
    _ = login.call(conn, .{ .capability = kind.loginAction() }, null, ctx, onProbeCapability, call_timeout_ms) catch {
        self.allocator.destroy(ctx);
        self.finishProbeReply();
    };
}

/// `probing` guards against starting a second probe batch while one of
/// the three Can* replies is still outstanding; it must only clear once
/// all three have been accounted for (reply received, or the call never
/// made it onto the bus), not after the first one back.
pub fn finishProbeReply(self: *Manager) void {
    self.probe_replies_pending -|= 1;
    if (self.probe_replies_pending == 0) self.probing = false;
}

pub fn onProbeCapability(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
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
