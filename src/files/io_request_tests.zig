//! Requests through a running coordinator: a reply reaches the window's
//! reserved slot, and the slots are bounded.
const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");

const allocator = std.testing.allocator;

fn sendRequest(window: io_service.Handle, tag: u64, request: io_service.Request) !void {
    var command: io_service.Command = .{
        .kind = .request,
        .submit_tag = tag,
        .payload = try io_service.OwnedPayload.createRequest(allocator, request),
    };
    defer command.deinitPayload();
    try support.sendOwned(window, &command);
}

fn waitReply(service: *io_service.Service, window: io_service.Handle) !*io_service.Reply {
    for (0..2000) |_| {
        const taken = window.takeReply() catch |err| switch (err) {
            error.ServiceBusy => null,
            else => return err,
        };
        if (taken) |reply| return reply;
        if (support.waitReadable(service.updateWakeFd(), 5)) _ = service.drainUpdateWake();
    }
    return error.Timeout;
}

test "a request's reply reaches the window that sent it" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    var service: io_service.Service = .{};
    try service.init();
    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, std.testing.io, &service);
    var window = try service.registerWindow();

    try sendRequest(window, 5, .{ .create_folder = .{ .dir = temp, .name = "made" } });
    const reply = try waitReply(&service, window);
    defer reply.destroy();
    try std.testing.expectEqual(@as(u64, 5), reply.tag);
    try std.testing.expectEqual(@as(?anyerror, null), reply.data.done);
    const made = try support.join(allocator, temp, "made");
    defer allocator.free(made);
    try std.testing.expect(support.pathExists(made));

    try sendRequest(window, 6, .{ .create_folder = .{ .dir = temp, .name = "made" } });
    const again = try waitReply(&service, window);
    defer again.destroy();
    try std.testing.expect(again.data.done != null);

    coordinator.deinit();
    window.close();
    service.deinit();
}

test "a window has at most four requests without a taken reply" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var window = try service.registerWindow();
    defer window.close();
    // No coordinator: nothing is answered, so the slots stay reserved.
    var sent: usize = 0;
    while (sent < io_service.reply_slots_per_window) : (sent += 1) {
        try sendRequest(window, sent, .{ .path_kinds = .{ .paths = &.{"/"} } });
    }
    try std.testing.expectError(error.RepliesFull, sendRequest(window, 99, .{ .path_kinds = .{ .paths = &.{"/"} } }));
    // Drain the queue as the coordinator would, so the Service can end.
    while (service.tryReceiveCommand()) |routed_value| {
        var routed = routed_value;
        routed.command.deinitPayload();
    }
}
