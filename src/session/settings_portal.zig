//! Compositor-side `org.freedesktop.impl.portal.Settings` backend.
//!
//! Answers `org.freedesktop.appearance` `color-scheme` from `[compositor]
//! dark_mode`, and `org.gnome.desktop.interface` `enable-animations` when
//! `[animations] reduced_motion` is an explicit on/off (auto leaves the key
//! to gtk so we can follow the desktop preference). `data/rediwm-portals.conf`
//! lists this backend ahead of gtk, and xdg-desktop-portal takes the first
//! backend that knows a key, so fonts, cursor theme and everything else still
//! come from xdg-desktop-portal-gtk. With no backend reachable the portal
//! drops the Settings interface entirely, and Brave treats that as "prefer dark".
//!
//! Rides the notifications manager's session-bus connection, so it is up in
//! exactly the sessions that connection is (a real login, or
//! REDIWM_FORCE_DBUS=1).
const std = @import("std");

const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const anim = @import("ui").anim;

const log = std.log.scoped(.settings_portal);

/// Must match `DBusName` in `data/rediwm.portal`.
pub const bus_name = "org.freedesktop.impl.portal.desktop.rediwm";
pub const object_path = "/org/freedesktop/portal/desktop";
pub const interface = "org.freedesktop.impl.portal.Settings";

pub const appearance_namespace = "org.freedesktop.appearance";
pub const color_scheme_key = "color-scheme";
pub const gnome_interface_namespace = "org.gnome.desktop.interface";
pub const enable_animations_key = "enable-animations";
const portal_frontend_name = "org.freedesktop.portal.Desktop";
const portal_frontend_iface = "org.freedesktop.portal.Settings";
const not_found_error = "org.freedesktop.portal.Error.NotFound";

/// `org.freedesktop.appearance` `color-scheme` values.
pub const ColorScheme = enum(u32) {
    no_preference = 0,
    prefer_dark = 1,
    prefer_light = 2,
};

/// Off is an explicit light preference rather than "no preference": the
/// latter lets gtk's gsettings value through, and a desktop that exports no
/// preference at all is exactly what browsers read as dark.
pub fn colorScheme(dark_mode: bool) ColorScheme {
    return if (dark_mode) .prefer_dark else .prefer_light;
}

/// Handler registration only; call `requestName` once Hello has completed.
pub fn register(conn: *dbus.Connection, server: *Server) !void {
    try conn.register(.{ .path = object_path, .interface = interface, .member = "ReadAll", .owner = server, .callback = handleReadAll });
    try conn.register(.{ .path = object_path, .interface = interface, .member = "Read", .owner = server, .callback = handleRead });
}

pub fn requestName(conn: *dbus.Connection) void {
    // Same policy as org.freedesktop.Notifications: a restarted compositor
    // takes the name over from the instance it replaces.
    _ = conn.requestName(bus_name, 7, null, onRequestName) catch |err| {
        log.warn("RequestName {s} failed: {}", .{ bus_name, err });
    };
}

/// Follow `enable-animations` from the portal frontend when `reduced_motion = auto`.
/// Does not auto-start xdg-desktop-portal: a method call to its well-known
/// name would activate it on nested/test buses and steal the Settings name
/// from the test's own portal.
pub fn startWatching(conn: *dbus.Connection, server: *Server) void {
    _ = conn.subscribe(.{
        .interface = portal_frontend_iface,
        .member = "SettingChanged",
        .owner = server,
        .callback = onFrontendSettingChanged,
    }, null, null) catch {};
    var body: wire.Writer = .{ .allocator = conn.allocator };
    defer body.deinit();
    body.string(portal_frontend_name) catch return;
    _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", &body, server, onPortalNameHasOwner, 5000) catch {};
}

fn onPortalNameHasOwner(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const server: *Server = @ptrCast(@alignCast(owner orelse return));
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    const owned = msg.body.boolean() catch return;
    if (!owned) return;
    requestEnableAnimations(conn, server);
}

fn requestEnableAnimations(conn: *dbus.Connection, server: *Server) void {
    var body: wire.Writer = .{ .allocator = conn.allocator };
    defer body.deinit();
    body.string(gnome_interface_namespace) catch return;
    body.string(enable_animations_key) catch return;
    _ = conn.call(portal_frontend_name, object_path, portal_frontend_iface, "Read", "ss", &body, server, onReadEnableAnimations, 5000) catch {};
}

/// Emits SettingChanged so running apps restyle without a restart. Call when
/// `dark_mode` changes.
pub fn emitColorScheme(server: *Server) void {
    const mgr = server.notifications orelse return;
    const conn = mgr.conn orelse return;
    var body: wire.Writer = .{ .allocator = mgr.allocator };
    defer body.deinit();
    writeSettingChanged(&body, colorScheme(server.config.compositor.dark_mode)) catch return;
    conn.signal(object_path, interface, "SettingChanged", "ssv", &body) catch |err| {
        // NotRegistered: Hello has not completed; ReadAll will answer instead.
        if (err != error.NotRegistered) log.warn("SettingChanged failed: {}", .{err});
    };
}

/// Emits SettingChanged for `enable-animations` when we own the key
/// (`reduced_motion` is not auto). `null` means we handed it back to gtk.
pub fn emitEnableAnimations(server: *Server, served: ?bool) void {
    const enabled = served orelse return;
    const mgr = server.notifications orelse return;
    const conn = mgr.conn orelse return;
    var body: wire.Writer = .{ .allocator = mgr.allocator };
    defer body.deinit();
    writeEnableAnimationsChanged(&body, enabled) catch return;
    conn.signal(object_path, interface, "SettingChanged", "ssv", &body) catch |err| {
        if (err != error.NotRegistered) log.warn("SettingChanged failed: {}", .{err});
    };
}

/// Namespace patterns as xdg-desktop-portal documents them: an empty list or
/// an empty string matches everything, and a trailing `*` matches a prefix.
pub fn namespaceMatches(pattern: []const u8, namespace: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern[pattern.len - 1] == '*') return std.mem.startsWith(u8, namespace, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, namespace);
}

/// `a{sa{sv}}` for ReadAll. `patterns` is the request's `as` array reader.
fn writeReadAll(body: *wire.Writer, patterns: wire.Reader, scheme: ColorScheme, enable_animations: ?bool) !void {
    var reader = patterns;
    var match_appearance = reader.offset == reader.bytes.len;
    var match_gnome = match_appearance;
    while (reader.offset < reader.bytes.len) {
        const pattern = try reader.string();
        if (namespaceMatches(pattern, appearance_namespace)) match_appearance = true;
        if (namespaceMatches(pattern, gnome_interface_namespace)) match_gnome = true;
    }
    const namespaces = try body.beginArray(8);
    if (match_appearance) {
        try body.alignTo(8);
        try body.string(appearance_namespace);
        const values = try body.beginArray(8);
        try body.alignTo(8);
        try body.string(color_scheme_key);
        try body.variant("u");
        try body.uint32(@intFromEnum(scheme));
        try body.endArray(values);
    }
    if (enable_animations) |enabled| {
        if (match_gnome) {
            try body.alignTo(8);
            try body.string(gnome_interface_namespace);
            const values = try body.beginArray(8);
            try body.alignTo(8);
            try body.string(enable_animations_key);
            try body.variant("b");
            try body.boolean(enabled);
            try body.endArray(values);
        }
    }
    try body.endArray(namespaces);
}

fn writeSettingChanged(body: *wire.Writer, scheme: ColorScheme) !void {
    try body.string(appearance_namespace);
    try body.string(color_scheme_key);
    try body.variant("u");
    try body.uint32(@intFromEnum(scheme));
}

fn writeEnableAnimationsChanged(body: *wire.Writer, enabled: bool) !void {
    try body.string(gnome_interface_namespace);
    try body.string(enable_animations_key);
    try body.variant("b");
    try body.boolean(enabled);
}

fn handleReadAll(owner: ?*anyopaque, conn: *dbus.Connection, request: wire.Message) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(owner orelse return error.NoOwner));
    if (!std.mem.eql(u8, request.headers.signature, "as")) return error.BadSignature;
    var args = request.body;
    const patterns = try args.array(4);
    var body: wire.Writer = .{ .allocator = conn.allocator };
    defer body.deinit();
    try writeReadAll(
        &body,
        patterns,
        colorScheme(server.config.compositor.dark_mode),
        anim.servedEnableAnimations(server.config.animations),
    );
    try conn.reply(request, "a{sa{sv}}", &body);
}

fn handleRead(owner: ?*anyopaque, conn: *dbus.Connection, request: wire.Message) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(owner orelse return error.NoOwner));
    if (!std.mem.eql(u8, request.headers.signature, "ss")) return error.BadSignature;
    var args = request.body;
    const namespace = try args.string();
    const key = try args.string();
    var body: wire.Writer = .{ .allocator = conn.allocator };
    defer body.deinit();
    if (std.mem.eql(u8, namespace, appearance_namespace) and std.mem.eql(u8, key, color_scheme_key)) {
        try body.variant("u");
        try body.uint32(@intFromEnum(colorScheme(server.config.compositor.dark_mode)));
        try conn.reply(request, "v", &body);
        return;
    }
    if (std.mem.eql(u8, namespace, gnome_interface_namespace) and std.mem.eql(u8, key, enable_animations_key)) {
        if (anim.servedEnableAnimations(server.config.animations)) |enabled| {
            try body.variant("b");
            try body.boolean(enabled);
            try conn.reply(request, "v", &body);
            return;
        }
    }
    try conn.replyError(request, not_found_error, "Requested setting not found");
}

fn applyDesktopPreference(server: *Server, enabled: bool) void {
    if (anim.desktopEnableAnimations() == enabled) return;
    anim.setDesktopEnableAnimations(enabled);
    if (server.config.animations.reduced_motion != .auto) return;
    anim.applySettings(server.config.animations);
    server.scheduleFrames();
}

fn onFrontendSettingChanged(owner: ?*anyopaque, _: *dbus.Connection, request: wire.Message) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(owner orelse return error.NoOwner));
    var args = request.body;
    const namespace = try args.string();
    const key = try args.string();
    if (!std.mem.eql(u8, namespace, gnome_interface_namespace) or !std.mem.eql(u8, key, enable_animations_key)) return;
    const sig = try args.variant();
    if (!std.mem.eql(u8, sig, "b")) return;
    applyDesktopPreference(server, try args.boolean());
}

fn onReadEnableAnimations(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const server: *Server = @ptrCast(@alignCast(owner orelse return));
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    const sig = msg.body.variant() catch return;
    if (!std.mem.eql(u8, sig, "b")) return;
    const enabled = msg.body.boolean() catch return;
    applyDesktopPreference(server, enabled);
}

fn onRequestName(_: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    var msg = result catch |err| {
        log.warn("RequestName {s} reply failed: {}", .{ bus_name, err });
        return;
    };
    if (msg.kind != .method_return) {
        log.warn("RequestName {s} refused: {s}", .{ bus_name, msg.headers.error_name orelse "unknown error" });
        return;
    }
    const code = msg.body.uint32() catch 0;
    if (code == 1 or code == 4) {
        log.info("acquired {s}", .{bus_name});
    } else {
        log.warn("bus name {s} already owned (code {d})", .{ bus_name, code });
    }
}

test "settings portal namespace patterns" {
    try std.testing.expect(namespaceMatches("", appearance_namespace));
    try std.testing.expect(namespaceMatches("org.freedesktop.appearance", appearance_namespace));
    try std.testing.expect(namespaceMatches("org.freedesktop.*", appearance_namespace));
    try std.testing.expect(namespaceMatches("*", appearance_namespace));
    try std.testing.expect(!namespaceMatches("org.gnome.*", appearance_namespace));
    try std.testing.expect(!namespaceMatches("org.freedesktop.appearance.extra", appearance_namespace));
    try std.testing.expect(!namespaceMatches("org.freedesktop", appearance_namespace));
}

test "settings portal color scheme follows dark_mode, off is explicit light" {
    try std.testing.expectEqual(ColorScheme.prefer_dark, colorScheme(true));
    try std.testing.expectEqual(ColorScheme.prefer_light, colorScheme(false));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(colorScheme(true)));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(colorScheme(false)));
}

fn expectReadAll(patterns: []const []const u8, expect_appearance: bool) !void {
    const allocator = std.testing.allocator;
    var request: wire.Writer = .{ .allocator = allocator };
    defer request.deinit();
    const list = try request.beginArray(4);
    for (patterns) |pattern| try request.string(pattern);
    try request.endArray(list);
    var request_reader: wire.Reader = .{ .bytes = request.bytes.items };
    const pattern_reader = try request_reader.array(4);

    var body: wire.Writer = .{ .allocator = allocator };
    defer body.deinit();
    try writeReadAll(&body, pattern_reader, .prefer_dark, null);
    // encode validates the body against the signature.
    var msg = try wire.encode(allocator, .method_return, 0, 2, .{ .reply_serial = 1, .destination = ":1.1", .signature = "a{sa{sv}}" }, &body);
    defer msg.deinit();
    var reader = (try wire.decode(msg.bytes.items)).body;
    var namespaces = try reader.array(8);
    if (expect_appearance) {
        try namespaces.alignTo(8);
        try std.testing.expectEqualStrings(appearance_namespace, try namespaces.string());
        var values = try namespaces.array(8);
        try values.alignTo(8);
        try std.testing.expectEqualStrings(color_scheme_key, try values.string());
        try std.testing.expectEqualStrings("u", try values.variant());
        try std.testing.expectEqual(@as(u32, 1), try values.uint32());
        try values.done();
    }
    try namespaces.done();
    try reader.done();
}

test "settings portal ReadAll filters namespaces and encodes a{sa{sv}}" {
    try expectReadAll(&.{}, true);
    try expectReadAll(&.{"org.freedesktop.appearance"}, true);
    try expectReadAll(&.{ "org.gnome.desktop.interface", "org.freedesktop.*" }, true);
    try expectReadAll(&.{"org.gnome.*"}, false);
}

test "settings portal ReadAll includes enable-animations when we own it" {
    const allocator = std.testing.allocator;
    var request: wire.Writer = .{ .allocator = allocator };
    defer request.deinit();
    const list = try request.beginArray(4);
    try request.string("org.gnome.*");
    try request.endArray(list);
    var request_reader: wire.Reader = .{ .bytes = request.bytes.items };
    const pattern_reader = try request_reader.array(4);

    var body: wire.Writer = .{ .allocator = allocator };
    defer body.deinit();
    try writeReadAll(&body, pattern_reader, .prefer_light, false);
    var msg = try wire.encode(allocator, .method_return, 0, 2, .{ .reply_serial = 1, .destination = ":1.1", .signature = "a{sa{sv}}" }, &body);
    defer msg.deinit();
    var reader = (try wire.decode(msg.bytes.items)).body;
    var namespaces = try reader.array(8);
    try namespaces.alignTo(8);
    try std.testing.expectEqualStrings(gnome_interface_namespace, try namespaces.string());
    var values = try namespaces.array(8);
    try values.alignTo(8);
    try std.testing.expectEqualStrings(enable_animations_key, try values.string());
    try std.testing.expectEqualStrings("b", try values.variant());
    try std.testing.expectEqual(false, try values.boolean());
    try values.done();
    try namespaces.done();
    try reader.done();
}

test "settings portal SettingChanged encodes ssv" {
    var body: wire.Writer = .{ .allocator = std.testing.allocator };
    defer body.deinit();
    try writeSettingChanged(&body, .prefer_light);
    var msg = try wire.encode(std.testing.allocator, .signal, 0, 1, .{ .path = object_path, .interface = interface, .member = "SettingChanged", .signature = "ssv" }, &body);
    defer msg.deinit();
    var reader = (try wire.decode(msg.bytes.items)).body;
    try std.testing.expectEqualStrings(appearance_namespace, try reader.string());
    try std.testing.expectEqualStrings(color_scheme_key, try reader.string());
    try std.testing.expectEqualStrings("u", try reader.variant());
    try std.testing.expectEqual(@as(u32, 2), try reader.uint32());
    try reader.done();
}
