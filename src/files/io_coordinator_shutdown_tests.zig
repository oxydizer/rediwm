//! Draining shutdown and unanswerable conflicts (threading §10).
const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const io_operation_executor = @import("io_operation_executor.zig");
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");

const allocator = std.testing.allocator;

fn releaseLater(delay_ms: i32) void {
    _ = std.posix.system.poll(&.{}, 0, delay_ms);
    io_operation_executor.test_gate.release();
}

test "a copy accepted before shutdown finishes instead of being cancelled" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const source = try support.join(allocator, temp, "payload.txt");
    defer allocator.free(source);
    const destination_dir = try support.join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try support.join(allocator, destination_dir, "payload.txt");
    defer allocator.free(destination);
    try support.writeFile(source, "survives shutdown");
    try support.makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    var window = try service.registerWindow();

    // Park the copy so shutdown certainly begins while it is running.
    const gate = io_operation_executor.test_gate;
    gate.arm();
    defer gate.release();
    try support.submitTransfer(allocator, window, .copy, destination_dir, source);
    for (0..1000) |_| {
        if (gate.parked.load(.acquire)) break;
        support.waitBriefly();
    } else return error.Timeout;

    // The last window goes, then the owner drains. The parked unit resumes
    // later; the drain waits for it rather than cancelling the job.
    window.close();
    const releaser = try std.Thread.spawn(.{}, releaseLater, .{100});
    coordinator.deinit();
    releaser.join();

    try support.waitForContents(destination, "survives shutdown");
}

test "draining cancels a job waiting on a conflict, even with a window open" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const source = try support.join(allocator, temp, "payload.txt");
    defer allocator.free(source);
    const destination_dir = try support.join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try support.join(allocator, destination_dir, "payload.txt");
    defer allocator.free(destination);
    try support.writeFile(source, "new");
    try support.makeDirectory(destination_dir);
    try support.writeFile(destination, "existing");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    var window = try service.registerWindow();
    defer window.close();
    var view = support.View.init(window, &service);

    try support.submitTransfer(allocator, window, .copy, destination_dir, source);
    _ = try view.waitFor(support.PendingConflict{});

    // Returns: the conflict no one will answer is cancelled, not waited on.
    coordinator.deinit();
    try support.waitForContents(destination, "existing");
}

test "with no window open, a conflict cancels its job" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const source = try support.join(allocator, temp, "payload.txt");
    defer allocator.free(source);
    const destination_dir = try support.join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try support.join(allocator, destination_dir, "payload.txt");
    defer allocator.free(destination);
    try support.writeFile(source, "new");
    try support.makeDirectory(destination_dir);
    try support.writeFile(destination, "existing");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    defer coordinator.deinit();

    // An external subscriber watches; it cannot answer conflicts.
    var panel = try service.registerExternal();
    defer panel.close();

    var window = try service.registerWindow();
    try support.submitTransfer(allocator, window, .copy, destination_dir, source);
    window.close();

    var out: [16]io_service.JobRecord = undefined;
    for (0..1000) |_| {
        const result = panel.fetchChanges(&out);
        for (out[0..result.count]) |record| {
            if (record.id == 1 and record.state == .cancelled) {
                try support.waitForContents(destination, "existing");
                return;
            }
        }
        if (support.waitReadable(service.updateWakeFd(), 10)) _ = service.drainUpdateWake();
    }
    return error.Timeout;
}

test "an abort cancels ordinary jobs too" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const source = try support.join(allocator, temp, "payload.txt");
    defer allocator.free(source);
    const destination_dir = try support.join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    try support.writeFile(source, "aborted");
    try support.makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    var panel = try service.registerExternal();
    defer panel.close();
    var window = try service.registerWindow();

    const gate = io_operation_executor.test_gate;
    gate.arm();
    defer gate.release();
    try support.submitTransfer(allocator, window, .copy, destination_dir, source);
    for (0..1000) |_| {
        if (gate.parked.load(.acquire)) break;
        support.waitBriefly();
    } else return error.Timeout;
    window.close();

    // A second quit: unlike a drain, the running copy is cancelled.
    coordinator.requestAbort();
    const releaser = try std.Thread.spawn(.{}, releaseLater, .{50});
    coordinator.deinit();
    releaser.join();

    var out: [16]io_service.JobRecord = undefined;
    var final: ?io_service.JobRecord = null;
    while (true) {
        const result = panel.fetchChanges(&out);
        for (out[0..result.count]) |record| {
            if (record.id == 1) final = record;
        }
        if (!result.more) break;
    }
    try std.testing.expectEqual(io_service.JobState.cancelled, final.?.state);
}
