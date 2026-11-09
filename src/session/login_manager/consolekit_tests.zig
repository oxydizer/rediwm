const std = @import("std");
const dbus = @import("dbus");
const login = @import("../login_manager.zig").Service(@import("consolekit.zig"));
const Recording = @import("tests.zig").Recording;
const t = std.testing;

test "ConsoleKit uses legacy interactive booleans for all power actions" {
    var fake: Recording = .{};
    defer fake.deinit();
    const actions = [_]@import("types.zig").Action{ .poweroff, .reboot, .@"suspend" };
    for (actions, [_][]const u8{ "PowerOff", "Reboot", "Suspend" }) |action, method| {
        _ = try login.call(&fake, .{ .action = .{ .kind = action, .interactive = false, .with_flags = true } }, null, null, null, 5000);
        try t.expectEqualStrings("org.freedesktop.ConsoleKit", fake.target.?.destination);
        try t.expectEqualStrings("/org/freedesktop/ConsoleKit/Manager", fake.target.?.path);
        try t.expectEqualStrings(method, fake.target.?.member);
        try t.expectEqualStrings("b", fake.target.?.signature);
        try t.expectEqual(@as(u8, 0), fake.target.?.flags);
        var body = fake.reader();
        try t.expect(!try body.boolean());
        try body.done();
        try t.expect(!login.usesCommand(action));
    }
    try t.expectEqual(.inhibited, login.actionError("org.freedesktop.ConsoleKit.Manager.Error.Inhibited"));
    try t.expectEqual(.authorization_required, login.actionError("org.freedesktop.ConsoleKit.Manager.Error.AuthorizationRequired"));
    try t.expectEqual(.denied, login.actionError("org.freedesktop.ConsoleKit.Manager.Error.InsufficientPermission"));
}

test "ConsoleKit identity stays an object path for polkit, manager receives short id" {
    var fake: Recording = .{};
    defer fake.deinit();
    const path = "/org/freedesktop/ConsoleKit/Session9";
    _ = try login.call(&fake, .{ .session = path }, ":1.19", null, null, 5000);
    try t.expectEqualStrings(":1.19", fake.target.?.destination);
    var body = fake.reader();
    try t.expectEqualStrings("Session9", try body.string());
    try t.expectError(error.InvalidSession, login.call(&fake, .{ .session = "/other/Session9" }, null, null, null, 5000));
    _ = try login.call(&fake, .{ .session_field = .{ .path = path, .field = .id } }, null, null, null, 5000);
    try t.expectEqualStrings("GetId", fake.target.?.member);
    var reply: dbus.wire.Writer = .{ .allocator = t.allocator };
    defer reply.deinit();
    try reply.objectPath(path);
    const msg: dbus.wire.Message = .{ .kind = .method_return, .serial = 1, .headers = .{ .signature = "o" }, .body = .{ .bytes = reply.bytes.items } };
    try t.expectEqualStrings(path, try login.readSessionId(msg));
}
