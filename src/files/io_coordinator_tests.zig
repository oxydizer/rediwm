const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");

test "coordinator owns its Runtime thread and reports unsupported commands" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(std.testing.allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try window.trySend(.{ .kind = .submit_job, .job_id = 73 });
    try std.testing.expect(waitReadable(service.updateWakeFd(), 2000));
    _ = service.drainUpdateWake();

    const update = (try window.tryReceiveUpdate()).?;
    try std.testing.expectEqual(io_service.UpdateKind.command_rejected, update.kind);
    try std.testing.expectEqual(@as(u64, 73), update.job_id);
    try std.testing.expectEqual(@as(u8, 1), update.state_code);
}

fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const rc = std.posix.system.poll(&fds, 1, timeout_ms);
    return std.posix.errno(rc) == .SUCCESS and fds[0].revents != 0;
}
