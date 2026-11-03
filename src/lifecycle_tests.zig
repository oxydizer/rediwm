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

const wlr = @import("wlroots");

// Renderer wrappers attach listeners and addons without locking the producer.
// Both must be torn down while its pixels and embedded wlr.Buffer still exist.
fn bufferFinalization(base: *wlr.Buffer) !void {
    const Watch = struct {
        destroys: usize = 0,
        addons: usize = 0,
        listener: wl.Listener(void) = .init(notify),
        addon: wlr.Addon = undefined,

        const impl: wlr.Addon.Interface = .{ .name = "retention audit", .destroy = finishAddon };

        fn notify(listener: *wl.Listener(void)) void {
            const self: *@This() = @fieldParentPtr("listener", listener);
            self.destroys += 1;
            listener.link.remove();
        }

        fn finishAddon(addon: *wlr.Addon) callconv(.c) void {
            const self: *@This() = @fieldParentPtr("addon", addon);
            self.addons += 1;
            addon.deinit();
        }
    };
    var watch: Watch = .{};
    base.events.destroy.add(&watch.listener);
    watch.addon.init(&base.addons, &watch, &Watch.impl);
    _ = base.lock();
    base.drop();
    try std.testing.expectEqual(@as(usize, 0), watch.destroys);
    try std.testing.expectEqual(@as(usize, 0), watch.addons);
    base.unlock();
    try std.testing.expectEqual(@as(usize, 1), watch.destroys);
    try std.testing.expectEqual(@as(usize, 1), watch.addons);
}

test "lifecycle image buffer finalizes consumers after the last lock" {
    const image = try @import("ImageBuffer.zig").createSolid(16, 8, 0xff112233);
    try bufferFinalization(&image.base);
}

test "lifecycle chrome buffer finalizes consumers after the last lock" {
    const chrome = try @import("chrome.zig").ChromeBuffer.create(160, .{});
    try bufferFinalization(&chrome.base);
}

test "lifecycle taskbar buffer finalizes consumers after the last lock" {
    const bar = try @import("taskbar/types.zig").BarBuffer.create(16, 8, 1);
    try bufferFinalization(&bar.base);
}

test "lifecycle desktop tile finalizes consumers before freeing or reuse" {
    const TileBuffer = @import("desktop/TileBuffer.zig");
    const unpooled = try TileBuffer.create(16, 8, false);
    try bufferFinalization(&unpooled.base);
    for (0..3) |_| {
        const pooled = try TileBuffer.acquire(16, 8);
        try bufferFinalization(&pooled.base);
    }
}
