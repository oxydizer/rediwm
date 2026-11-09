const std = @import("std");
const publication = @import("publication.zig");
const Private = @import("private_publication.zig").Publication;
const t = std.testing;

const Bus = struct {
    owns_user_bus: bool = false,
    other_login: bool = false,
    writes: usize = 0,
    display: []const u8 = "other-display",
    pub fn conflict(self: *Bus, _: std.mem.Allocator, _: []const u8) !?[]const u8 {
        return if (self.other_login) "another-session" else null;
    }
    pub fn activation(self: *Bus, values: []const publication.Pair) !void {
        self.writes += 1;
        for (values) |pair| if (std.mem.eql(u8, pair.key, "WAYLAND_DISPLAY")) {
            self.display = pair.value;
        };
    }
};

test "borrowed bus publication refuses another graphical login and never clears its environment" {
    var bus: Bus = .{ .other_login = true };
    var lease = try Private(Bus).init(t.allocator, &bus, "", "ours");
    defer lease.deinit();
    try t.expectError(error.GraphicalSessionConflict, lease.acquire());
    try t.expectError(error.GraphicalSessionConflict, lease.publish(&.{.{ .key = "WAYLAND_DISPLAY", .value = "ours" }}));
    try lease.restore();
    try t.expectEqual(@as(usize, 0), bus.writes);
    try t.expectEqualStrings("other-display", bus.display);
    bus.other_login = false;
    try lease.publish(&.{.{ .key = "WAYLAND_DISPLAY", .value = "ours" }});
    bus.display = "new-desktop";
    try lease.restore();
    try t.expectEqualStrings("new-desktop", bus.display);
    try t.expectEqual(@as(usize, 1), bus.writes);
}

test "owned bus clears its dead display once and rejects non-activation state" {
    var bus: Bus = .{ .owns_user_bus = true, .other_login = true };
    var lease = try Private(Bus).init(t.allocator, &bus, "", "ours");
    defer lease.deinit();
    try lease.acquire();
    try t.expectError(error.InvalidActivationEnvironment, lease.publish(&.{.{ .key = "XDG_SESSION_COOKIE", .value = "secret" }}));
    try t.expectEqual(@as(usize, 0), bus.writes);
    try lease.publish(&.{.{ .key = "WAYLAND_DISPLAY", .value = "ours" }});
    try lease.restore();
    try lease.restore();
    try t.expectEqualStrings("", bus.display);
    try t.expectEqual(@as(usize, 2), bus.writes);
}
