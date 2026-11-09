const std = @import("std");
const dbus = @import("dbus");
const login = @import("../login_manager.zig").Service(@import("logind.zig"));
const types = @import("types.zig");
const wire = dbus.wire;
const testing = std.testing;

/// Records the actual transport boundary, including borrowed body bytes. No
/// real bus or power command can be reached by these checks.
pub const Recording = struct {
    allocator: std.mem.Allocator = testing.allocator,
    target: ?types.Target = null,
    body: std.ArrayList(u8) = .empty,
    calls: u32 = 0,
    timeout: u32 = 0,

    pub fn callWithFlags(self: *Recording, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer, _: ?*anyopaque, _: ?dbus.Connection.Callback, timeout: u32, flags: u8) !u32 {
        self.target = .{ .destination = destination, .path = path, .interface = interface, .member = member, .signature = signature, .flags = flags };
        self.body.clearRetainingCapacity();
        try self.body.appendSlice(self.allocator, body.bytes.items);
        self.timeout = timeout;
        self.calls += 1;
        return self.calls;
    }

    pub fn reader(self: *const Recording) wire.Reader {
        return .{ .bytes = self.body.items };
    }

    pub fn deinit(self: *Recording) void {
        self.body.deinit(self.allocator);
    }
};

test "automatic suspend never prompts or overrides inhibitors in either API" {
    var fake: Recording = .{};
    defer fake.deinit();
    for ([_]bool{ false, true }) |with_flags| {
        _ = try login.call(&fake, .{ .action = .{ .kind = .@"suspend", .interactive = false, .with_flags = with_flags } }, null, null, null, 5000);
        const target = fake.target.?;
        try testing.expectEqualStrings("org.freedesktop.login1", target.destination);
        try testing.expectEqualStrings("/org/freedesktop/login1", target.path);
        try testing.expectEqualStrings("org.freedesktop.login1.Manager", target.interface);
        try testing.expectEqual(@as(u8, 0), target.flags);
        var body = fake.reader();
        if (with_flags) {
            try testing.expectEqualStrings("SuspendWithFlags", target.member);
            try testing.expectEqualStrings("t", target.signature);
            try testing.expectEqual(@as(u64, 1), try body.uint64());
        } else {
            try testing.expectEqualStrings("Suspend", target.member);
            try testing.expectEqualStrings("b", target.signature);
            try testing.expect(!try body.boolean());
        }
        try body.done();
    }
    _ = try login.call(&fake, .{ .action = .{ .kind = .@"suspend", .interactive = true, .with_flags = false } }, null, null, null, 5000);
    try testing.expectEqual(wire.flag_allow_interactive_authorization, fake.target.?.flags);
    var body = fake.reader();
    try testing.expect(try body.boolean());
}

test "session and inhibitor calls remain pinned to the selected service owner" {
    var fake: Recording = .{};
    defer fake.deinit();
    _ = try login.call(&fake, .{ .inhibit = .sleep }, ":1.42", null, null, 5000);
    try testing.expectEqualStrings(":1.42", fake.target.?.destination);
    try testing.expectEqualStrings("Inhibit", fake.target.?.member);
    var body = fake.reader();
    for ([_][]const u8{ "sleep", "RediWM", "Lock the screen before sleep", "delay" }) |arg| try testing.expectEqualStrings(arg, try body.string());
    try body.done();
    _ = try login.call(&fake, .{ .session = "c7" }, ":1.42", null, null, 3000);
    try testing.expectEqualStrings(":1.42", fake.target.?.destination);
    try testing.expectEqualStrings("GetSession", fake.target.?.member);
    try testing.expectEqual(@as(u32, 3000), fake.timeout);
    body = fake.reader();
    try testing.expectEqualStrings("c7", try body.string());
    _ = try login.call(&fake, .{ .locked_hint = .{ .path = "/session/ours", .locked = true } }, ":1.42", null, null, 5000);
    try testing.expectEqualStrings(":1.42", fake.target.?.destination);
    try testing.expectEqualStrings("/session/ours", fake.target.?.path);
    try testing.expectEqualStrings("SetLockedHint", fake.target.?.member);
    body = fake.reader();
    try testing.expect(try body.boolean());
}

test "session identity rejects error replies and wrong property types" {
    var body: wire.Writer = .{ .allocator = testing.allocator };
    defer body.deinit();
    try body.variant("s");
    try body.string("c7");
    var msg: wire.Message = .{ .kind = .method_return, .serial = 1, .headers = .{ .signature = "v" }, .body = .{ .bytes = body.bytes.items } };
    try testing.expectEqualStrings("c7", try login.readSessionId(msg));
    msg.kind = .error_reply;
    try testing.expectError(error.Refused, login.readSessionId(msg));
    msg.kind = .method_return;
    msg.headers.signature = "s";
    try testing.expectError(error.InvalidReply, login.readSessionId(msg));
    body.bytes.clearRetainingCapacity();
    try body.variant("u");
    try body.uint32(7);
    msg.headers.signature = "v";
    msg.body = .{ .bytes = body.bytes.items };
    try testing.expectError(error.InvalidReply, login.readSessionId(msg));
}
