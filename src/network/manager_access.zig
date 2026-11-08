//! Whether changing saved connections is allowed. Like Services' unlock, this
//! asks polkit for the action NetworkManager checks for `Update`/`Delete`
//! (`settings.modify.system`). It is asked once without interaction when the
//! page loads: where policy already allows it (an active local session, the
//! usual default) there is nothing to unlock and no button shows. Otherwise the
//! page offers Unlock, which asks again with interaction. polkit still decides
//! every request; this only keeps the page honest about what will work.

const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const eq = std.mem.eql;
const manager_mod = @import("manager.zig");
const Manager = manager_mod.Manager;

pub const Access = enum { unknown, open, locked, denied };

pub const action_id = "org.freedesktop.NetworkManager.settings.modify.system";
const cancellation = "rediwm-settings-network-unlock";
const polkit_name = "org.freedesktop.PolicyKit1";
const polkit_path = "/org/freedesktop/PolicyKit1/Authority";
const polkit_authority = polkit_name ++ ".Authority";

const Check = struct { manager: *Manager, epoch: u64, interactive: bool };

pub fn check(self: *Manager, interactive: bool) void {
    const conn = self.conn orelse return;
    const unique = conn.unique_name orelse return;
    if (interactive and self.unlocking) return;
    if (!interactive and self.access_pending) return;
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    body.alignTo(8) catch return;
    body.string("system-bus-name") catch return;
    const subject = body.beginArray(8) catch return;
    body.string("name") catch return;
    body.variant("s") catch return;
    body.string(unique) catch return;
    body.endArray(subject) catch return;
    body.string(action_id) catch return;
    const details = body.beginArray(8) catch return;
    body.endArray(details) catch return;
    body.uint32(@intFromBool(interactive)) catch return;
    body.string(cancellation) catch return;
    const req = gpa.create(Check) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .interactive = interactive };
    _ = conn.callWithFlags(polkit_name, polkit_path, polkit_authority, "CheckAuthorization", "(sa{sv})sa{ss}us", &body, req, checked, if (interactive) 120000 else 5000, 0) catch {
        gpa.destroy(req);
        return;
    };
    if (interactive) {
        self.unlocking = true;
        self.edit_message = "";
        self.refresh();
    } else self.access_pending = true;
}

pub fn unlock(self: *Manager) void {
    if (self.access == .open) return;
    check(self, true);
}

/// Withdraws a pending prompt so no dialog outlives its Settings window.
pub fn cancelUnlock(self: *Manager) void {
    if (!self.unlocking) return;
    self.unlocking = false;
    const conn = self.conn orelse return;
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    body.string(cancellation) catch return;
    _ = conn.call(polkit_name, polkit_path, polkit_authority, "CancelCheckAuthorization", "s", &body, null, null, 1000) catch return;
    conn.flush() catch {};
}

fn checked(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Check = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    if (req.interactive) self.unlocking = false else self.access_pending = false;
    defer self.refresh();
    var msg = result catch return unavailable(self, req.interactive);
    if (msg.kind != .method_return or !eq(u8, msg.headers.signature, "(bba{ss})")) return unavailable(self, req.interactive);
    msg.body.alignTo(8) catch return unavailable(self, req.interactive);
    const authorized = msg.body.boolean() catch return unavailable(self, req.interactive);
    const challenge = msg.body.boolean() catch return unavailable(self, req.interactive);
    if (authorized) {
        self.access = .open;
    } else if (req.interactive) {
        self.access = .locked;
        self.edit_message = i18n.tr("Authentication was cancelled or denied.");
    } else self.access = if (challenge) .locked else .denied;
}

/// No polkit, or no answer: do not block. NetworkManager still decides every call.
fn unavailable(self: *Manager, interactive: bool) void {
    if (interactive) self.edit_message = i18n.tr("Could not request authentication. Check that polkit is running.") else self.access = .open;
}
