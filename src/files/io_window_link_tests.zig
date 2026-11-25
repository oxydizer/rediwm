//! Service job-table admission and reads, and the window-side helpers.
const std = @import("std");
const c = @import("c.zig").api;
const service_mod = @import("io_service.zig");
const link = @import("io_window_link.zig");

fn submit(tag: u64) service_mod.Command {
    return .{ .kind = .submit_job, .submit_tag = tag };
}

fn record(id: u64, origin: u64) service_mod.JobRecord {
    return .{ .id = id, .origin_window_id = origin, .state = .queued };
}

/// Stands in for the coordinator: takes queued submits and creates records.
fn admitQueued(service: *service_mod.Service, next_id: *u64) !void {
    while (service.tryReceiveCommand()) |routed| {
        if (routed.command.kind != .submit_job) continue;
        next_id.* += 1;
        var r = record(next_id.*, routed.window_id);
        r.submit_tag = routed.command.submit_tag;
        try service.createJobRecord(r, true);
    }
}

test "submit admission reserves a record and an outcome slot" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var window = try service.registerWindow();
    defer window.close();
    var next_id: u64 = 0;

    for (0..service_mod.outcome_slots_per_window) |i| {
        try window.trySend(submit(i));
        try admitQueued(&service, &next_id);
    }
    // Every outcome slot of this window is reserved by a live job.
    try std.testing.expectError(error.WindowOutcomesFull, window.trySend(submit(99)));

    // Another window is not affected.
    var other = try service.registerWindow();
    defer other.close();
    try other.trySend(submit(1));
    try admitQueued(&service, &next_id);

    // The submitting window recognises its jobs by submit_tag.
    var out: [32]service_mod.JobRecord = undefined;
    const result = try window.fetchChanges(&out);
    try std.testing.expectEqual(service_mod.outcome_slots_per_window + 1, result.count);
    try std.testing.expectEqual(@as(u64, 0), out[0].submit_tag);
    try std.testing.expectEqual(window.window_id, out[0].origin_window_id);
}

test "a refused submit leaks no reservation" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var window = try service.registerWindow();
    defer {
        window.close();
        while (service.tryReceiveCommand() != null) {}
    }
    for (0..service_mod.command_capacity_per_window) |i| try window.trySend(submit(i));
    try std.testing.expectError(error.WindowQueueFull, window.trySend(submit(99)));
    try std.testing.expectEqual(service_mod.command_capacity_per_window, service.table.reserved_live);
}

test "fetchChanges fails fast under contention and a late window sees live jobs" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var first = try service.registerWindow();
    defer first.close();
    var next_id: u64 = 0;
    try first.trySend(submit(7));
    try admitQueued(&service, &next_id);

    var late = try service.registerWindow();
    defer late.close();
    var out: [4]service_mod.JobRecord = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_lock(&service.mutex));
    try std.testing.expectError(error.ServiceBusy, late.fetchChanges(&out));
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_unlock(&service.mutex));

    const result = try late.fetchChanges(&out);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(u64, 7), out[0].submit_tag);
}

test "closing a window drops its view and outcomes, never the jobs" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var window = try service.registerWindow();
    var next_id: u64 = 0;
    try window.trySend(submit(1));
    try admitQueued(&service, &next_id);
    window.close();
    _ = service.tryReceiveCommand(); // recycles the slot

    var other = try service.registerWindow();
    defer other.close();
    var out: [4]service_mod.JobRecord = undefined;
    const result = try other.fetchChanges(&out);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try service.retireJobRecord(out[0].id);
}

test "external consumers read the table without outcome slots" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var window = try service.registerWindow();
    defer window.close();
    var panel = try service.registerExternal();
    defer panel.close();
    var next_id: u64 = 0;
    try window.trySend(submit(1));
    try admitQueued(&service, &next_id);

    var out: [4]service_mod.JobRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), panel.fetchChanges(&out).count);
}

test "the outbox retries busy commands in order and never waits" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var window = try service.registerWindow();
    defer window.close();
    var outbox: link.Outbox = .{};
    defer outbox.deinit();

    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_lock(&service.mutex));
    var first: service_mod.Command = .{ .kind = .cancel_job, .job_id = 1 };
    var second: service_mod.Command = .{ .kind = .prioritize_discovery, .job_id = 2 };
    try outbox.send(window, &first);
    try outbox.send(window, &second);
    try std.testing.expect(outbox.pending());
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_unlock(&service.mutex));

    // A later command queues behind the earlier ones, so order holds.
    var third: service_mod.Command = .{ .kind = .prioritize_discovery, .job_id = 3 };
    try outbox.send(window, &third);
    try std.testing.expect(!outbox.pending());
    try std.testing.expectEqual(@as(u64, 1), service.tryReceiveCommand().?.command.job_id);
    try std.testing.expectEqual(@as(u64, 2), service.tryReceiveCommand().?.command.job_id);
    try std.testing.expectEqual(@as(u64, 3), service.tryReceiveCommand().?.command.job_id);
}

test "the reader remembers a busy fetch so no wakeup is lost" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var window = try service.registerWindow();
    defer window.close();
    var reader: link.Reader = .{};
    var out: [4]service_mod.JobRecord = undefined;

    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_lock(&service.mutex));
    try std.testing.expect((try reader.fetch(window, &out)) == null);
    try std.testing.expectEqual(@as(?i32, 1), reader.pollTimeoutMs(null));
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_unlock(&service.mutex));

    const result = (try reader.fetch(window, &out)).?;
    try std.testing.expect(!result.more);
    try std.testing.expectEqual(@as(?i32, null), reader.pollTimeoutMs(result));
}
