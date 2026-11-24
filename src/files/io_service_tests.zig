const std = @import("std");
const service_mod = @import("io_service.zig");

fn normalCommand(job_id: u64) service_mod.Command {
    return .{ .kind = .submit_job, .job_id = job_id };
}

fn controlCommand(job_id: u64) service_mod.Command {
    return .{ .kind = .cancel_job, .job_id = job_id };
}

test "window IDs are centrally assigned, monotonic and not reused" {
    var service = service_mod.Service.init();
    defer service.deinit();
    var first = try service.registerWindow();
    const stale = first;
    const first_id = first.window_id;
    first.close();

    var second = try service.registerWindow();
    defer second.close();
    try std.testing.expect(second.window_id > first_id);
    try std.testing.expectError(error.WindowClosed, stale.trySend(normalCommand(1)));
}

test "normal command admission enforces per-window and aggregate bounds" {
    var service = service_mod.Service.init();
    defer service.deinit();
    var handles: [9]service_mod.Handle = undefined;
    var handle_count: usize = 0;
    defer {
        for (handles[0..handle_count]) |*handle| handle.close();
    }
    for (&handles) |*handle| {
        handle.* = try service.registerWindow();
        handle_count += 1;
    }

    for (0..service_mod.command_capacity_per_window) |i| {
        try handles[0].trySend(normalCommand(i));
    }
    try std.testing.expectError(
        error.WindowQueueFull,
        handles[0].trySend(normalCommand(99)),
    );

    for (1..8) |window_index| {
        for (0..service_mod.command_capacity_per_window) |i| {
            try handles[window_index].trySend(normalCommand(i));
        }
    }
    try std.testing.expectEqual(
        service_mod.aggregate_command_capacity,
        service.pending_normal_commands,
    );
    try std.testing.expectError(
        error.AggregateQueueFull,
        handles[8].trySend(normalCommand(100)),
    );
}

test "reserved control admission remains available when normal capacity is full" {
    var service = service_mod.Service.init();
    defer service.deinit();
    var handle = try service.registerWindow();
    defer handle.close();

    for (0..service_mod.command_capacity_per_window) |i| {
        try handle.trySend(normalCommand(i));
    }
    try handle.trySend(controlCommand(1));
    try handle.trySend(controlCommand(2));
    try std.testing.expectError(
        error.ControlQueueFull,
        handle.trySend(controlCommand(3)),
    );

    const first = service.tryReceiveCommand().?;
    try std.testing.expectEqual(service_mod.CommandKind.cancel_job, first.command.kind);
    const second = service.tryReceiveCommand().?;
    try std.testing.expectEqual(service_mod.CommandKind.cancel_job, second.command.kind);
}

test "command draining is round-robin across windows" {
    var service = service_mod.Service.init();
    defer service.deinit();
    var first = try service.registerWindow();
    var second = try service.registerWindow();
    defer first.close();
    defer second.close();

    try first.trySend(normalCommand(1));
    try first.trySend(normalCommand(2));
    try second.trySend(normalCommand(3));
    try second.trySend(normalCommand(4));

    try std.testing.expectEqual(first.window_id, service.tryReceiveCommand().?.window_id);
    try std.testing.expectEqual(second.window_id, service.tryReceiveCommand().?.window_id);
    try std.testing.expectEqual(first.window_id, service.tryReceiveCommand().?.window_id);
    try std.testing.expectEqual(second.window_id, service.tryReceiveCommand().?.window_id);
}

test "progress coalescing preserves ordering around lifecycle updates" {
    var service = service_mod.Service.init();
    defer service.deinit();
    var handle = try service.registerWindow();
    defer handle.close();

    const first_sequence = try service.publishUpdate(handle.window_id, .{
        .job_id = 7,
        .kind = .progress,
        .completed_bytes = 10,
    });
    const second_sequence = try service.publishUpdate(handle.window_id, .{
        .job_id = 7,
        .kind = .progress,
        .completed_bytes = 20,
    });
    try std.testing.expect(second_sequence > first_sequence);

    _ = try service.publishUpdate(handle.window_id, .{
        .job_id = 7,
        .kind = .job_state,
        .state_code = 2,
    });
    _ = try service.publishUpdate(handle.window_id, .{
        .job_id = 7,
        .kind = .progress,
        .completed_bytes = 30,
    });

    const coalesced = handle.tryReceiveUpdate().?;
    try std.testing.expectEqual(service_mod.UpdateKind.progress, coalesced.kind);
    try std.testing.expectEqual(@as(u64, 20), coalesced.completed_bytes);
    const state = handle.tryReceiveUpdate().?;
    try std.testing.expectEqual(service_mod.UpdateKind.job_state, state.kind);
    const latest = handle.tryReceiveUpdate().?;
    try std.testing.expectEqual(service_mod.UpdateKind.progress, latest.kind);
    try std.testing.expectEqual(@as(u64, 30), latest.completed_bytes);
}

test "update overflow is surfaced as an explicit resync marker" {
    var service = service_mod.Service.init();
    defer service.deinit();
    var handle = try service.registerWindow();
    defer handle.close();

    var last_sequence: u64 = 0;
    for (0..service_mod.update_capacity_per_window + 1) |i| {
        last_sequence = try service.publishUpdate(handle.window_id, .{
            .job_id = i + 1,
            .kind = .job_state,
            .state_code = 1,
        });
    }

    const marker = handle.tryReceiveUpdate().?;
    try std.testing.expectEqual(service_mod.UpdateKind.resync_required, marker.kind);
    try std.testing.expectEqual(last_sequence, marker.sequence);
    try std.testing.expect(handle.tryReceiveUpdate() == null);
}

test "shutdown rejects admission while handles can unregister cleanly" {
    var service = service_mod.Service.init();
    defer service.deinit();
    var handle = try service.registerWindow();
    service.beginShutdown();
    try std.testing.expectError(error.ServiceStopping, handle.trySend(normalCommand(1)));
    try std.testing.expectError(error.ServiceStopping, service.registerWindow());
    handle.close();
}
