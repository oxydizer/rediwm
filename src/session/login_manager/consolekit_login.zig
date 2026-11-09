//! Own one ConsoleKit2 session for the supervisor's lifetime. Do not adopt a
//! session merely because environment variables claim it belongs to this login.
const std = @import("std");
const types = @import("types.zig");

fn string(bus: anytype, arena: std.mem.Allocator, path: []const u8, field: types.SessionField) ![]const u8 {
    var reply = try bus.loginCall(.{ .session_field = .{ .path = path, .field = field } });
    defer reply.deinit(bus.allocator);
    try reply.expect("s");
    var body = reply.reader();
    return arena.dupe(u8, try body.string());
}

fn user(bus: anytype, path: []const u8) !u32 {
    var reply = try bus.loginCall(.{ .session_field = .{ .path = path, .field = .uid } });
    defer reply.deinit(bus.allocator);
    try reply.expect("u");
    var body = reply.reader();
    return body.uint32();
}

pub fn login(bus: anytype, arena: std.mem.Allocator, context: types.Context) ![]const u8 {
    // This entry point is for a console login. A pty/SSH or nested compositor
    // must not create an apparently local login by asserting its own metadata.
    if (!std.mem.startsWith(u8, context.display_device, "/dev/ttyv")) return error.NotLocalWaylandLogin;
    if (bus.login_cookie != null) return error.SessionAlreadyOpen;
    var owner = try bus.loginCall(.owner);
    defer owner.deinit(bus.allocator);
    try owner.expect("s");
    var owner_body = owner.reader();
    bus.login_owner = try bus.allocator.dupe(u8, try owner_body.string());
    errdefer {
        bus.allocator.free(bus.login_owner.?);
        bus.login_owner = null;
    }

    var opened = try bus.loginCall(.{ .open_session = context });
    defer opened.deinit(bus.allocator);
    try opened.expect("s");
    var cookie_body = opened.reader();
    const cookie = try cookie_body.string();
    if (cookie.len == 0) return error.InvalidReply;
    bus.login_cookie = try bus.allocator.dupe(u8, cookie);
    errdefer release(bus);
    var located = try bus.loginCall(.{ .session_for_cookie = cookie });
    defer located.deinit(bus.allocator);
    try located.expect("o");
    var located_body = located.reader();
    const path = try arena.dupe(u8, try located_body.objectPath());

    var local_reply = try bus.loginCall(.{ .session_field = .{ .path = path, .field = .local } });
    defer local_reply.deinit(bus.allocator);
    try local_reply.expect("b");
    var local_body = local_reply.reader();
    if (!try local_body.boolean() or try user(bus, path) != std.posix.system.getuid() or
        !std.mem.eql(u8, try string(bus, arena, path, .kind), "wayland") or
        !std.mem.eql(u8, try string(bus, arena, path, .class), "user") or
        (try string(bus, arena, path, .remote)).len != 0) return error.NotLocalWaylandLogin;
    // Active is deliberately not required: CK2 sessions without a display
    // device cannot be active. There is no Desktop property to validate.
    return path;
}

pub fn release(bus: anytype) void {
    const cookie = bus.login_cookie orelse return;
    if (bus.loginCall(.{ .close_session = cookie })) |value| {
        var reply = value;
        reply.deinit(bus.allocator);
    } else |_| {}
    bus.allocator.free(cookie);
    bus.login_cookie = null;
}

pub fn conflict(bus: anytype, arena: std.mem.Allocator, ours: []const u8) !?[]const u8 {
    var reply = try bus.loginCall(.list_sessions);
    defer reply.deinit(bus.allocator);
    try reply.expect("ao");
    var body = reply.reader();
    var paths = try body.array(4);
    while (paths.offset < paths.bytes.len) {
        const path = try paths.objectPath();
        if (std.mem.eql(u8, path, ours) or try user(bus, path) != std.posix.system.getuid()) continue;
        const kind = try string(bus, arena, path, .kind);
        if (!std.mem.eql(u8, kind, "wayland") and !std.mem.eql(u8, kind, "x11")) continue;
        if (std.mem.eql(u8, try string(bus, arena, path, .state), "closing")) continue;
        return try arena.dupe(u8, path);
    }
    return null;
}
