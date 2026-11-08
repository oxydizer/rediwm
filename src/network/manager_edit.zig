//! Changing saved connections: reading a profile for the editor, saving it,
//! forgetting it, and the quick actions (auto-connect, disconnect). Writes are
//! read-modify-write (see `manager_profile.zig`) and carry the interactive
//! authorization flag, so polkit may ask through the session's agent.

const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const secure = @import("secure_allocator.zig").allocator;
const eq = std.mem.eql;
const manager_mod = @import("manager.zig");
const Manager = manager_mod.Manager;
const nm = manager_mod.nm;
const root = manager_mod.root;
const device_iface = manager_mod.device_iface;
const settings_iface = manager_mod.settings_iface;
const Path = manager_mod.Path;
const Request = manager_mod.Request;
const profile_mod = @import("manager_profile.zig");
const Profile = profile_mod.Profile;

const Mode = enum { full, autoconnect };
const Save = struct { manager: *Manager, epoch: u64, profile: Profile, mode: Mode };

fn writable(self: *const Manager) bool {
    return self.available and self.conn != null and !self.edit_busy and (self.access == .open or self.access == .unknown);
}

fn fail(self: *Manager, message: []const u8) void {
    self.edit_busy = false;
    self.edit_message = message;
    self.refresh();
}

pub fn readProfile(self: *Manager, path: []const u8) void {
    if (!self.available or self.conn == null or path.len == 0) return;
    self.profile = null;
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = Path.init(path) };
    const b: wire.Writer = .{ .allocator = secure };
    _ = self.conn.?.call(self.owner.slice(), path, settings_iface, "GetSettings", "", &b, req, gotProfile, 5000) catch {
        gpa.destroy(req);
        return fail(self, i18n.tr("Could not read the connection settings."));
    };
    self.edit_message = "";
}

fn gotProfile(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    var msg = result catch return fail(self, i18n.tr("Could not read the connection settings."));
    if (!self.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{sa{sv}}")) return fail(self, i18n.tr("Could not read the connection settings."));
    self.profile = profile_mod.parse(&msg.body, req.path.slice()) catch return fail(self, i18n.tr("Could not read the connection settings."));
    self.refresh();
}

pub fn saveProfile(self: *Manager, profile: Profile) void {
    startSave(self, profile, .full);
}

pub fn setAutoconnect(self: *Manager, path: []const u8, on: bool) void {
    startSave(self, .{ .path = Path.init(path), .autoconnect = on }, .autoconnect);
}

fn startSave(self: *Manager, profile: Profile, mode: Mode) void {
    if (!writable(self) or profile.path.len == 0) return;
    const req = gpa.create(Save) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .profile = profile, .mode = mode };
    const b: wire.Writer = .{ .allocator = secure };
    _ = self.conn.?.call(self.owner.slice(), profile.path.slice(), settings_iface, "GetSettings", "", &b, req, saveSettings, 5000) catch {
        gpa.destroy(req);
        return fail(self, i18n.tr("Could not save the connection settings."));
    };
    self.edit_busy = true;
    self.edit_message = i18n.tr("Saving…");
    self.refresh();
}

fn saveSettings(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Save = @ptrCast(@alignCast(owner.?));
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return gpa.destroy(req);
    const msg = result catch return saveFailed(req);
    if (!self.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{sa{sv}}")) return saveFailed(req);
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    var settings = msg.body;
    if (req.mode == .autoconnect) {
        var reader = msg.body;
        var current = profile_mod.parse(&reader, req.profile.path.slice()) catch return saveFailed(req);
        current.autoconnect = req.profile.autoconnect;
        req.profile = current;
    }
    profile_mod.write(&settings, &b, &req.profile) catch return saveFailed(req);
    _ = conn.callWithFlags(self.owner.slice(), req.profile.path.slice(), settings_iface, "Update", "a{sa{sv}}", &b, req, saved, 15000, wire.flag_allow_interactive_authorization) catch return saveFailed(req);
}

fn saveFailed(req: *Save) void {
    const self = req.manager;
    const current = self.epoch == req.epoch and !self.closing;
    gpa.destroy(req);
    if (current) fail(self, i18n.tr("Could not save the connection settings."));
}

fn saved(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Save = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    const msg = result catch return fail(self, i18n.tr("Could not save the connection settings."));
    if (!self.fromOwner(msg) or msg.kind != .method_return) return fail(self, i18n.tr("Could not save the connection settings."));
    self.edit_busy = false;
    self.edit_message = if (req.mode == .full) i18n.tr("Saved.") else "";
    for (self.saved[0..self.saved_count]) |*s| if (eq(u8, s.path.slice(), req.profile.path.slice())) {
        s.loaded = false;
    };
    // New addresses only apply when the connection is made again.
    if (req.mode == .full) reactivate(self, req.profile.path.slice());
    self.fetch();
    self.refresh();
}

/// Brings up `profile` again on the adapter that is using it.
fn reactivate(self: *Manager, profile: []const u8) void {
    const device: Path = if (eq(u8, self.wifi.profile.slice(), profile)) self.device else blk: {
        for (self.ethernet[0..self.ethernet_count]) |eth| {
            for (self.actives[0..self.active_count]) |act| {
                if (eq(u8, act.path.slice(), eth.active_connection.slice()) and eq(u8, act.profile.slice(), profile)) break :blk eth.path;
            }
        }
        return;
    };
    if (device.len == 0) return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    b.objectPath(profile) catch return;
    b.objectPath(device.slice()) catch return;
    b.objectPath("/") catch return;
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = .{} };
    _ = self.conn.?.callWithFlags(self.owner.slice(), root, nm, "ActivateConnection", "ooo", &b, req, done, 15000, wire.flag_allow_interactive_authorization) catch gpa.destroy(req);
}

pub fn forget(self: *Manager, path: []const u8) void {
    if (!writable(self) or path.len == 0) return;
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = Path.init(path) };
    const b: wire.Writer = .{ .allocator = secure };
    _ = self.conn.?.callWithFlags(self.owner.slice(), path, settings_iface, "Delete", "", &b, req, forgotten, 15000, wire.flag_allow_interactive_authorization) catch {
        gpa.destroy(req);
        return fail(self, i18n.tr("Could not forget the connection."));
    };
    self.edit_busy = true;
    self.edit_message = i18n.tr("Forgetting…");
    self.refresh();
}

fn forgotten(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    const msg = result catch return fail(self, i18n.tr("Could not forget the connection."));
    if (!self.fromOwner(msg) or msg.kind != .method_return) return fail(self, i18n.tr("Could not forget the connection."));
    self.edit_busy = false;
    self.edit_message = i18n.tr("Connection forgotten.");
    if (self.profile) |p| if (eq(u8, p.path.slice(), req.path.slice())) {
        self.profile = null;
    };
    self.fetch();
    self.refresh();
}

pub fn disconnectWifi(self: *Manager) void {
    if (!self.available or self.conn == null or self.device.len == 0) return;
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = .{} };
    const b: wire.Writer = .{ .allocator = secure };
    _ = self.conn.?.callWithFlags(self.owner.slice(), self.device.slice(), device_iface, "Disconnect", "", &b, req, done, 15000, wire.flag_allow_interactive_authorization) catch gpa.destroy(req);
}

fn done(owner: ?*anyopaque, _: *dbus.Connection, _: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    self.fetch();
}

/// Brings up a profile that needs no adapter (a VPN).
pub fn activate(self: *Manager, profile: []const u8) void {
    if (!self.available or self.conn == null or profile.len == 0) return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    b.objectPath(profile) catch return;
    b.objectPath("/") catch return;
    b.objectPath("/") catch return;
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = .{} };
    _ = self.conn.?.callWithFlags(self.owner.slice(), root, nm, "ActivateConnection", "ooo", &b, req, vpnDone, 15000, wire.flag_allow_interactive_authorization) catch {
        gpa.destroy(req);
        return fail(self, i18n.tr("Could not start the connection."));
    };
    self.edit_message = "";
}

pub fn deactivate(self: *Manager, active: []const u8) void {
    if (!self.available or self.conn == null or active.len == 0) return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    b.objectPath(active) catch return;
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = .{} };
    _ = self.conn.?.callWithFlags(self.owner.slice(), root, nm, "DeactivateConnection", "o", &b, req, vpnDone, 15000, wire.flag_allow_interactive_authorization) catch {
        gpa.destroy(req);
        return fail(self, i18n.tr("Could not stop the connection."));
    };
    self.edit_message = "";
}

fn vpnDone(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    _ = result catch return fail(self, i18n.tr("The connection request was refused."));
    self.fetch();
}
