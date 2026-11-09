//! Blocking login verification and graphical-session contention for logind.
const std = @import("std");
const types = @import("types.zig");

fn sessionString(self: anytype, arena: std.mem.Allocator, path: []const u8, field: types.SessionField) ![]const u8 {
    var reply = try self.loginCall(.{ .session_field = .{ .path = path, .field = field } });
    defer reply.deinit(self.allocator);
    try reply.expect("v");
    var r = reply.reader();
    if (!std.mem.eql(u8, try r.variant(), "s")) return error.InvalidReply;
    return arena.dupe(u8, try r.string());
}

/// Only a verified local Wayland user login of this desktop may publish.
/// Returns the logind session id.
pub fn login(self: anytype, arena: std.mem.Allocator, _: types.Context) ![]const u8 {
    var reply = try self.loginCall(.{ .session_for_pid = @intCast(std.posix.system.getpid()) });
    defer reply.deinit(self.allocator);
    try reply.expect("o");
    var r = reply.reader();
    const path = try arena.dupe(u8, try r.objectPath());

    const uid = blk: {
        var user = try self.loginCall(.{ .session_field = .{ .path = path, .field = .uid } });
        defer user.deinit(self.allocator);
        try user.expect("v");
        var ur = user.reader();
        if (!std.mem.eql(u8, try ur.variant(), "(uo)")) return error.InvalidReply;
        try ur.alignTo(8);
        break :blk try ur.uint32();
    };
    const remote = blk: {
        var value = try self.loginCall(.{ .session_field = .{ .path = path, .field = .remote } });
        defer value.deinit(self.allocator);
        try value.expect("v");
        var vr = value.reader();
        if (!std.mem.eql(u8, try vr.variant(), "b")) return error.InvalidReply;
        break :blk try vr.boolean();
    };
    const desktop = try sessionString(self, arena, path, .desktop);
    const desktop_ok = std.ascii.eqlIgnoreCase(desktop, "rediwm") or std.ascii.eqlIgnoreCase(desktop, "rediwm-release-safe");
    if (uid != std.posix.system.getuid() or
        !std.mem.eql(u8, try sessionString(self, arena, path, .kind), "wayland") or
        !std.mem.eql(u8, try sessionString(self, arena, path, .class), "user") or
        !desktop_ok or remote)
    {
        return error.NotLocalWaylandLogin;
    }
    return sessionString(self, arena, path, .id);
}

/// Another live graphical login of this uid shares the user bus.
pub fn conflict(self: anytype, arena: std.mem.Allocator, session: []const u8) !?[]const u8 {
    var reply = try self.loginCall(.list_sessions);
    defer reply.deinit(self.allocator);
    try reply.expect("a(susso)");
    var r = reply.reader();
    var rows = try r.array(8);
    const Row = struct { sid: []const u8, path: []const u8 };
    var candidates: std.ArrayList(Row) = .empty;
    while (rows.offset < rows.bytes.len) {
        try rows.alignTo(8);
        const sid = try rows.string();
        const uid = try rows.uint32();
        _ = try rows.string();
        _ = try rows.string();
        const path = try rows.objectPath();
        if (uid == std.posix.system.getuid() and !std.mem.eql(u8, sid, session)) {
            try candidates.append(arena, .{ .sid = try arena.dupe(u8, sid), .path = try arena.dupe(u8, path) });
        }
    }
    for (candidates.items) |row| {
        const kind = try sessionString(self, arena, row.path, .kind);
        if (!std.mem.eql(u8, kind, "wayland") and !std.mem.eql(u8, kind, "x11")) continue;
        if (std.mem.eql(u8, try sessionString(self, arena, row.path, .state), "closing")) continue;
        return row.sid;
    }
    return null;
}
