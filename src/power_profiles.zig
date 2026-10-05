//! Power profiles through the freedesktop PowerProfiles D-Bus API, served by
//! power-profiles-daemon, tuned-ppd, or on ASUS laptops RediOS's
//! redi-powerprofiles shim over asusd. Never talks to asusd directly, so the
//! daemon behind the name stays the only writer of platform_profile.
//!
//! Event-driven: NameOwnerChanged tracks the service coming and going, and
//! PropertiesChanged tracks ActiveProfile, so an idle session makes no calls.
//! Every confirmed change shows the OSD, including ones nothing here asked
//! for: asus-wmi's Fn+F5 cycles platform_profile inside the kernel, and asusd
//! and the shim relay it here.
const std = @import("std");

const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("Server.zig");

const log = std.log.scoped(.power_profiles);

const bus_name = "org.freedesktop.UPower.PowerProfiles";
const object_path = "/org/freedesktop/UPower/PowerProfiles";
const properties_interface = "org.freedesktop.DBus.Properties";
const call_timeout_ms: u32 = 5000;

const owner_rule = "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',path='/org/freedesktop/DBus',arg0='" ++ bus_name ++ "'";
const changed_rule = "type='signal',sender='" ++ bus_name ++ "',interface='" ++ properties_interface ++ "',member='PropertiesChanged',path='" ++ object_path ++ "',arg0='" ++ bus_name ++ "'";

pub const Profile = enum {
    power_saver,
    balanced,
    performance,

    pub fn parse(text: []const u8) ?Profile {
        inline for (std.meta.fields(Profile)) |field| {
            if (std.mem.eql(u8, text, wireName(@enumFromInt(field.value)))) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn wireName(self: Profile) []const u8 {
        return switch (self) {
            .power_saver => "power-saver",
            .balanced => "balanced",
            .performance => "performance",
        };
    }

    pub fn label(self: Profile) []const u8 {
        return switch (self) {
            .power_saver => "Power Saver",
            .balanced => "Balanced",
            .performance => "Performance",
        };
    }
};

/// The profile after `active` among `available`, wrapping around. Every
/// daemon offers at least balanced and power-saver; an empty set means the
/// Profiles list has not arrived, so all three are assumed.
pub fn next(active: Profile, available: std.EnumSet(Profile)) Profile {
    const choices = if (available.count() == 0) std.EnumSet(Profile).initFull() else available;
    var candidate = active;
    for (0..std.meta.fields(Profile).len) |_| {
        candidate = @enumFromInt((@intFromEnum(candidate) + 1) % std.meta.fields(Profile).len);
        if (choices.contains(candidate)) return candidate;
    }
    return active;
}

/// Without a system bus or a PowerProfiles service the manager stays inert.
/// A lost bus connection is not retried automatically; the next explicit
/// cycle request reconnects.
pub const Manager = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    conn: ?*dbus.Connection = null,
    /// Unique name currently owning `bus_name`. Signals and replies from any
    /// other sender are ignored, so a stale reply from a previous owner or a
    /// forged PropertiesChanged cannot move the OSD.
    service_owner: ?[]u8 = null,
    active: ?Profile = null,
    available: std.EnumSet(Profile) = .initEmpty(),
    closing: bool = false,

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*Manager {
        const self = try allocator.create(Manager);
        self.* = .{ .server = server, .allocator = allocator };
        self.connect();
        return self;
    }

    pub fn deinit(self: *Manager) void {
        self.closing = true;
        if (self.conn) |conn| conn.destroy();
        self.setOwner(null);
        self.allocator.destroy(self);
    }

    pub fn isAvailable(self: *const Manager) bool {
        return self.service_owner != null and self.active != null;
    }

    pub fn supports(self: *const Manager, profile: Profile) bool {
        return self.isAvailable() and self.available.contains(profile);
    }

    /// Selection remains at the last confirmed value until the daemon replies.
    pub fn select(self: *Manager, profile: Profile) void {
        if (!self.supports(profile) or self.active == profile) return;
        const conn = self.conn orelse return;
        if (!conn.closed) self.request(conn, profile);
    }

    fn refreshPopup(self: *Manager) void {
        if (self.closing) return;
        if (self.server.input.open_battery) |popup| popup.refresh();
    }

    /// Asks the daemon for the next profile. The OSD appears only when the
    /// daemon confirms the change through PropertiesChanged.
    pub fn cycle(self: *Manager) void {
        const conn = self.conn orelse {
            self.connect();
            return;
        };
        if (conn.closed) {
            self.connect();
            return;
        }
        const active = self.active orelse {
            log.info("no power profile service to switch", .{});
            return;
        };
        self.request(conn, next(active, self.available));
    }

    fn request(self: *Manager, conn: *dbus.Connection, profile: Profile) void {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string(bus_name) catch return;
        body.string("ActiveProfile") catch return;
        body.variant("s") catch return;
        body.string(profile.wireName()) catch return;
        // power-profiles-daemon checks the switch-profile polkit action, which
        // active local sessions normally hold without a prompt.
        _ = conn.callWithFlags(bus_name, object_path, properties_interface, "Set", "ssv", &body, self, onSet, call_timeout_ms, wire.flag_allow_interactive_authorization) catch |err| {
            log.warn("could not request power profile {s}: {}", .{ profile.wireName(), err });
        };
    }

    fn onSet(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const msg = result catch |err| {
            log.warn("power profile change failed: {}", .{err});
            return;
        };
        if (msg.kind == .error_reply) log.warn("power profile change refused: {s}", .{msg.headers.error_name orelse "unknown error"});
    }

    fn connect(self: *Manager) void {
        if (self.conn) |old| {
            old.destroy();
            self.conn = null;
        }
        self.setOwner(null);
        const loop = self.server.wl_server.getEventLoop();
        const conn = dbus.Connection.openSystem(self.allocator, loop, self.server.environ) catch |err| {
            log.info("system bus unavailable, power profiles disabled: {}", .{err});
            return;
        };
        _ = conn.hello(self, onHello) catch |err| {
            log.warn("could not register on the system bus: {}", .{err});
            conn.destroy();
            return;
        };
        conn.on_disconnect = .{ .owner = self, .callback = onDisconnect };
        self.conn = conn;
    }

    fn onDisconnect(owner: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        self.setOwner(null);
    }

    fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const msg = result catch |err| {
            log.warn("system bus Hello failed: {}", .{err});
            conn.close();
            return;
        };
        if (msg.kind != .method_return) {
            conn.close();
            return;
        }
        self.subscribe(conn) catch |err| {
            log.warn("could not watch power profiles: {}", .{err});
            conn.close();
            return;
        };
        // Match rules are in place before the owner is asked for, so a
        // service starting in between is reported by NameOwnerChanged.
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string(bus_name) catch return;
        _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &body, self, onNameOwner, call_timeout_ms) catch |err| {
            log.warn("could not look up the power profile service: {}", .{err});
        };
    }

    fn subscribe(self: *Manager, conn: *dbus.Connection) !void {
        // arg0 keeps the bus from waking us for every other name on the
        // system bus, which the generic subscribe() rule cannot express.
        try conn.registerSignal(.{
            .sender = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "NameOwnerChanged",
            .owner = self,
            .callback = onNameOwnerChanged,
        });
        _ = try conn.addMatch(owner_rule, null, null);
        // Signals carry the owner's unique name, not the well-known one, so
        // the sender is checked against service_owner in the handler.
        try conn.registerSignal(.{
            .path = object_path,
            .interface = properties_interface,
            .member = "PropertiesChanged",
            .owner = self,
            .callback = onPropertiesChanged,
        });
        _ = try conn.addMatch(changed_rule, null, null);
    }

    fn onNameOwner(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        var msg = result catch return;
        if (msg.kind != .method_return) {
            log.info("no power profile service on the system bus", .{});
            return;
        }
        const unique = msg.body.string() catch return;
        // NameOwnerChanged may already have reported a newer owner.
        if (self.service_owner != null) return;
        self.setOwner(unique);
        self.fetchAll(conn);
    }

    fn onNameOwnerChanged(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        var body = msg.body;
        const name = try body.string();
        _ = try body.string();
        const new_owner = try body.string();
        if (!std.mem.eql(u8, name, bus_name)) return;
        if (new_owner.len == 0) {
            log.info("power profile service left the bus", .{});
            self.setOwner(null);
            return;
        }
        self.setOwner(new_owner);
        self.fetchAll(conn);
    }

    /// Drops everything learned from the previous owner; the next GetAll is
    /// a fresh baseline and shows no OSD.
    fn setOwner(self: *Manager, unique: ?[]const u8) void {
        defer self.refreshPopup();
        if (self.service_owner) |old| self.allocator.free(old);
        self.service_owner = null;
        self.active = null;
        self.available = .initEmpty();
        const name = unique orelse return;
        self.service_owner = self.allocator.dupe(u8, name) catch null;
    }

    fn fromOwner(self: *const Manager, msg: wire.Message) bool {
        const owner = self.service_owner orelse return false;
        const sender = msg.headers.sender orelse return false;
        return std.mem.eql(u8, owner, sender);
    }

    fn fetchAll(self: *Manager, conn: *dbus.Connection) void {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string(bus_name) catch return;
        _ = conn.call(bus_name, object_path, properties_interface, "GetAll", "s", &body, self, onGetAll, call_timeout_ms) catch |err| {
            log.warn("could not read power profiles: {}", .{err});
        };
    }

    fn onGetAll(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        var msg = result catch |err| {
            log.warn("reading power profiles failed: {}", .{err});
            return;
        };
        if (msg.kind != .method_return or !self.fromOwner(msg) or !std.mem.eql(u8, msg.headers.signature, "a{sv}")) return;
        const update = parseProperties(&msg.body) catch |err| {
            log.warn("invalid power profile properties: {}", .{err});
            return;
        };
        if (update.available) |set| self.available = set;
        if (update.active) |profile| {
            self.active = profile;
            log.info("power profile service ready, active profile {s}", .{profile.wireName()});
        }
        self.refreshPopup();
    }

    fn onPropertiesChanged(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing or !self.fromOwner(msg)) return;
        if (!std.mem.eql(u8, msg.headers.signature, "sa{sv}as")) return;
        var body = msg.body;
        if (!std.mem.eql(u8, try body.string(), bus_name)) return;
        const update = try parseProperties(&body);
        if (update.available) |set| self.available = set;
        if (update.active) |profile| self.apply(profile);
        if (update.active == null and update.available != null) self.refreshPopup();
        var invalidated = try body.array(4);
        while (invalidated.offset < invalidated.bytes.len) {
            const name = try invalidated.string();
            if (std.mem.eql(u8, name, "ActiveProfile") or std.mem.eql(u8, name, "Profiles")) {
                // Values that are only invalidated must be read back; a
                // GetAll reply is a baseline, so announce the result here.
                self.fetchActive(conn);
                return;
            }
        }
    }

    fn fetchActive(self: *Manager, conn: *dbus.Connection) void {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string(bus_name) catch return;
        body.string("ActiveProfile") catch return;
        _ = conn.call(bus_name, object_path, properties_interface, "Get", "ss", &body, self, onGetActive, call_timeout_ms) catch |err| {
            log.warn("could not read the active power profile: {}", .{err});
        };
    }

    fn onGetActive(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        var msg = result catch return;
        if (msg.kind != .method_return or !self.fromOwner(msg) or !std.mem.eql(u8, msg.headers.signature, "v")) return;
        const sig = msg.body.variant() catch return;
        if (!std.mem.eql(u8, sig, "s")) return;
        const profile = Profile.parse(msg.body.string() catch return) orelse return;
        self.apply(profile);
    }

    /// A change from a known profile is announced; the first value after a
    /// (re)connect only establishes the baseline.
    fn apply(self: *Manager, profile: Profile) void {
        const previous = self.active;
        self.active = profile;
        self.refreshPopup();
        if (previous == null or previous.? == profile) return;
        log.info("power profile changed to {s}", .{profile.wireName()});
        @import("osd.zig").show(self.server, .{ .kind = .power_profile, .profile = profile });
    }
};

const Update = struct {
    active: ?Profile = null,
    available: ?std.EnumSet(Profile) = null,
};

/// Reads the ActiveProfile and Profiles entries of an a{sv}. Unknown
/// profile names (a daemon newer than this code) are skipped.
fn parseProperties(reader: *wire.Reader) !Update {
    var update: Update = .{};
    var entries = try reader.array(8);
    while (entries.offset < entries.bytes.len) {
        try entries.alignTo(8);
        const name = try entries.string();
        const sig = try entries.variant();
        if (std.mem.eql(u8, name, "ActiveProfile") and std.mem.eql(u8, sig, "s")) {
            update.active = Profile.parse(try entries.string());
        } else if (std.mem.eql(u8, name, "Profiles") and std.mem.eql(u8, sig, "aa{sv}")) {
            var set: std.EnumSet(Profile) = .initEmpty();
            var profiles = try entries.array(4);
            while (profiles.offset < profiles.bytes.len) {
                var fields = try profiles.array(8);
                while (fields.offset < fields.bytes.len) {
                    try fields.alignTo(8);
                    const key = try fields.string();
                    const value_sig = try fields.variant();
                    if (std.mem.eql(u8, key, "Profile") and std.mem.eql(u8, value_sig, "s")) {
                        if (Profile.parse(try fields.string())) |profile| set.insert(profile);
                    } else try fields.skip(value_sig);
                }
            }
            update.available = set;
        } else try entries.skip(sig);
    }
    return update;
}

test "profiles round-trip their wire names" {
    for (std.enums.values(Profile)) |profile| {
        try std.testing.expectEqual(profile, Profile.parse(profile.wireName()).?);
    }
    try std.testing.expectEqual(@as(?Profile, null), Profile.parse("quiet"));
}

test "cycling wraps and skips profiles the daemon lacks" {
    var all: std.EnumSet(Profile) = .initFull();
    try std.testing.expectEqual(Profile.balanced, next(.power_saver, all));
    try std.testing.expectEqual(Profile.performance, next(.balanced, all));
    try std.testing.expectEqual(Profile.power_saver, next(.performance, all));
    all.remove(.performance);
    try std.testing.expectEqual(Profile.power_saver, next(.balanced, all));
    try std.testing.expectEqual(Profile.performance, next(.balanced, .initEmpty()));
}

test "properties parse the active profile and the offered set" {
    const gpa = std.testing.allocator;
    var w: wire.Writer = .{ .allocator = gpa };
    defer w.deinit();
    const outer = try w.beginArray(8);
    try w.alignTo(8);
    try w.string("PerformanceDegraded");
    try w.variant("s");
    try w.string("");
    try w.alignTo(8);
    try w.string("ActiveProfile");
    try w.variant("s");
    try w.string("performance");
    try w.alignTo(8);
    try w.string("Profiles");
    try w.variant("aa{sv}");
    const list = try w.beginArray(4);
    for ([_][]const u8{ "power-saver", "turbo", "performance" }) |name| {
        const dict = try w.beginArray(8);
        try w.alignTo(8);
        try w.string("Driver");
        try w.variant("s");
        try w.string("asusd");
        try w.alignTo(8);
        try w.string("Profile");
        try w.variant("s");
        try w.string(name);
        try w.endArray(dict);
    }
    try w.endArray(list);
    try w.endArray(outer);

    var reader: wire.Reader = .{ .bytes = w.bytes.items };
    const update = try parseProperties(&reader);
    try reader.done();
    try std.testing.expectEqual(Profile.performance, update.active.?);
    const set = update.available.?;
    try std.testing.expect(set.contains(.power_saver) and set.contains(.performance) and !set.contains(.balanced));
}
