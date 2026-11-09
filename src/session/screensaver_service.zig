//! org.freedesktop.ScreenSaver: idle inhibition over the session bus.
//!
//! Chromium creates its idle-inhibit-v1 inhibitor only on a window that has
//! pointer or keyboard focus when playback starts, and never retries, so a
//! video that resumes while the pointer is elsewhere would let the display
//! blank. It also calls this interface when the name has an owner, as do SDL,
//! mpv, VLC and xdg-desktop-portal-gtk's Inhibit backend (Firefox, Flatpak).
//! Inhibitors live in the IdleManager and go when their sender leaves the bus.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const IdleManager = @import("idle.zig").IdleManager;
const gpa = @import("../main.zig").gpa;
const log = std.log.scoped(.screensaver_service);

const bus_name = "org.freedesktop.ScreenSaver";
/// KDE serves both; older clients use the short path.
const object_paths = .{ "/org/freedesktop/ScreenSaver", "/ScreenSaver" };
const dbus_name = "org.freedesktop.DBus";
const dbus_path = "/org/freedesktop/DBus";

pub fn register(conn: *dbus.Connection, server: *Server) !void {
    const im = server.idle orelse return;
    inline for (object_paths) |path| {
        inline for (.{
            .{ "Inhibit", inhibit },
            .{ "UnInhibit", uninhibit },
            .{ "SimulateUserActivity", simulateUserActivity },
            .{ "GetActive", getActive },
        }) |method| {
            try conn.register(.{ .path = path, .interface = bus_name, .member = method[0], .owner = im, .callback = method[1] });
        }
    }
}

/// After Hello: follow departing clients, then take the name.
pub fn start(conn: *dbus.Connection, server: *Server) void {
    const im = server.idle orelse return;
    _ = conn.subscribe(.{ .sender = dbus_name, .path = dbus_path, .interface = dbus_name, .member = "NameOwnerChanged", .owner = im, .callback = nameOwnerChanged }, null, null) catch |err| {
        // Without departures an inhibitor could outlive its client.
        log.warn("cannot follow bus clients ({}); not serving {s}", .{ err, bus_name });
        return;
    };
    // A restarted compositor takes the name over from the instance it replaces.
    _ = conn.requestName(bus_name, 7, null, onRequestName) catch |err| {
        log.warn("RequestName {s} failed: {}", .{ bus_name, err });
    };
}

fn onRequestName(_: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const msg = result catch |err| {
        log.warn("RequestName {s} reply failed: {}", .{ bus_name, err });
        return;
    };
    if (msg.headers.error_name) |name| {
        log.warn("RequestName {s} refused: {s}", .{ bus_name, name });
        return;
    }
    var body = msg.body;
    const code = body.uint32() catch return;
    // 1 primary owner, 4 already owner; 3 = exists (DO_NOT_QUEUE).
    if (code != 1 and code != 4) log.info("{s} is served by another process", .{bus_name});
}

fn manager(owner: ?*anyopaque) *IdleManager {
    return @ptrCast(@alignCast(owner.?));
}

fn inhibit(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    const im = manager(owner);
    if (!std.mem.eql(u8, msg.headers.signature, "ss")) return error.InvalidArguments;
    const sender = msg.headers.sender orelse return error.InvalidArguments;
    var reader = msg.body;
    const app = try reader.string();
    const reason = try reader.string();
    try reader.done();
    const cookie = im.addBusInhibitor(gpa, sender, app, reason) catch |err| switch (err) {
        error.TooManyInhibitors => {
            try conn.replyError(msg, "org.freedesktop.DBus.Error.LimitsExceeded", "Too many inhibitors");
            return;
        },
        else => return err,
    };
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    try body.uint32(cookie);
    try conn.reply(msg, "u", &body);
}

fn uninhibit(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    const im = manager(owner);
    if (!std.mem.eql(u8, msg.headers.signature, "u")) return error.InvalidArguments;
    const sender = msg.headers.sender orelse return error.InvalidArguments;
    var reader = msg.body;
    const cookie = try reader.uint32();
    try reader.done();
    // Unknown or foreign cookies succeed silently, as on KDE.
    _ = im.removeBusInhibitor(gpa, sender, cookie);
    const empty: wire.Writer = .{ .allocator = gpa };
    try conn.reply(msg, "", &empty);
}

fn simulateUserActivity(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    if (msg.headers.signature.len != 0) return error.InvalidArguments;
    manager(owner).notifyActivity(.virtual);
    const empty: wire.Writer = .{ .allocator = gpa };
    try conn.reply(msg, "", &empty);
}

fn getActive(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    if (msg.headers.signature.len != 0) return error.InvalidArguments;
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    try body.boolean(manager(owner).isBlanked());
    try conn.reply(msg, "b", &body);
}

fn nameOwnerChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    if (!std.mem.eql(u8, msg.headers.signature, "sss")) return;
    var reader = msg.body;
    const name = try reader.string();
    _ = try reader.string();
    const new_owner = try reader.string();
    if (new_owner.len == 0 and name.len > 0 and name[0] == ':') manager(owner).dropBusOwner(gpa, name);
}
