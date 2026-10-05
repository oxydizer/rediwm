const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("Server.zig");
const WaitManager = @import("ipc/wait.zig").WaitManager;

fn registrationFailures(allocator: std.mem.Allocator, condition: bool) !void {
    const display = try wl.Server.create();
    defer display.destroy();
    // Dispatch after manager cleanup: a failed registration must leave no
    // armed callback behind, including when appending to entries fails.
    defer display.getEventLoop().dispatch(5) catch unreachable;
    var server: Server = undefined;
    server.wl_server = display;
    server.outputs.init();
    server.world.toplevels.init();
    const manager = try WaitManager.create(&server, allocator);
    defer manager.deinit();
    if (condition) {
        _ = try manager.registerCondition(1, .{ .string = "request" }, .{
            .window_mapped = .{ .app_id = "absent", .title = "absent" },
        }, 1);
    } else {
        _ = try manager.registerFrame(1, .{ .string = "request" }, null, 1);
    }
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
    manager.cancelForClient(1);
    try std.testing.expectEqual(@as(usize, 0), manager.entries.items.len);
}

test "lifecycle wait registration releases strings and timers at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registrationFailures, .{true});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registrationFailures, .{false});
}
