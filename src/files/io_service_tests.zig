const std = @import("std");
const service_mod = @import("io_service.zig");
const c = @import("c.zig").api;

fn normalCommand(job_id: u64) service_mod.Command {
    return .{ .kind = .submit_job, .job_id = job_id };
}

fn controlCommand(job_id: u64) service_mod.Command {
    return .{ .kind = .cancel_job, .job_id = job_id };
}

test "window IDs are centrally assigned, monotonic and not reused" {
    var service: service_mod.Service = .{};
    try service.init();
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
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var handles: [9]service_mod.Handle = undefined;
    var handle_count: usize = 0;
    defer {
        for (handles[0..handle_count]) |*handle| {
            handle.close();
        }
        while (service.tryReceiveCommand() != null) {}
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
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var handle = try service.registerWindow();
    defer {
        handle.close();
        while (service.tryReceiveCommand() != null) {}
    }

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
    var service: service_mod.Service = .{};
    try service.init();
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

test "shutdown rejects admission while handles can unregister cleanly" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var handle = try service.registerWindow();
    service.beginShutdown();
    try std.testing.expectError(error.ServiceStopping, handle.trySend(normalCommand(1)));
    try std.testing.expectError(error.ServiceStopping, service.registerWindow());
    handle.close();
}

test "shutdown wakes the process command consumer" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();

    try std.testing.expect(!isReadable(service.commandWakeFd()));
    service.beginShutdown();
    try std.testing.expect(service.isStopping());
    try std.testing.expect(isReadable(service.commandWakeFd()));
    try std.testing.expect(service.drainCommandWake() > 0);
    try std.testing.expect(!isReadable(service.commandWakeFd()));
}

test "window operations fail fast under mutex contention and remain retryable" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var handle = try service.registerWindow();

    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_lock(&service.mutex));
    // Send and receive never wait for the mutex: they fail fast and the
    // caller retries on a later event-loop iteration.
    try std.testing.expectError(
        error.ServiceBusy,
        handle.trySend(normalCommand(1)),
    );
    var records: [4]service_mod.JobRecord = undefined;
    try std.testing.expectError(
        error.ServiceBusy,
        handle.fetchChanges(&records),
    );
    // Registering and closing take no lock at all, so they succeed while
    // the mutex is held and cannot leave window teardown spinning.
    var second = try service.registerWindow();
    try std.testing.expect(second.window_id > handle.window_id);
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_unlock(&service.mutex));

    // Failed operations did not consume the handle or lose the command.
    try handle.trySend(normalCommand(2));

    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_lock(&service.mutex));
    handle.close();
    second.close();
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_unlock(&service.mutex));

    // A command queued before close is still delivered, and draining
    // recycles both closed slots.
    try std.testing.expectEqual(@as(u64, 2), service.tryReceiveCommand().?.command.job_id);
    try std.testing.expect(service.tryReceiveCommand() == null);
    var handles: [service_mod.max_windows]service_mod.Handle = undefined;
    for (&handles) |*h| h.* = try service.registerWindow();
    for (&handles) |*h| h.close();
}

test "closing a stale handle copy never closes a later window in the same slot" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();

    var first = try service.registerWindow();
    var stale = first;
    first.close();
    var later = try service.registerWindow();
    defer later.close();

    stale.close();
    try later.trySend(normalCommand(5));
    try std.testing.expectEqual(later.window_id, service.tryReceiveCommand().?.window_id);
}

test "command admission and record changes wake their process consumers" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();
    var handle = try service.registerWindow();
    defer handle.close();

    try std.testing.expect(!isReadable(service.commandWakeFd()));
    try handle.trySend(normalCommand(41));
    try std.testing.expect(isReadable(service.commandWakeFd()));
    try std.testing.expect(service.drainCommandWake() > 0);
    try std.testing.expect(!isReadable(service.commandWakeFd()));
    try std.testing.expectEqual(@as(u64, 41), service.tryReceiveCommand().?.command.job_id);

    // A record written after the consumer drained the wake leaves the
    // counter readable, and the read that follows sees the record.
    try std.testing.expect(!isReadable(service.updateWakeFd()));
    try service.createJobRecord(.{ .id = 41, .origin_window_id = handle.window_id, .state = .queued }, true);
    try std.testing.expect(isReadable(service.updateWakeFd()));
    try std.testing.expect(service.drainUpdateWake() > 0);
    try std.testing.expect(!isReadable(service.updateWakeFd()));
    var records: [4]service_mod.JobRecord = undefined;
    const result = try handle.fetchChanges(&records);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(u64, 41), records[0].id);
}

fn isReadable(fd: std.posix.fd_t) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return std.posix.errno(std.posix.system.poll(&fds, 1, 0)) == .SUCCESS and
        fds[0].revents != 0;
}

test "accepted commands survive window closure and retain their origin ID" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();

    var handle = try service.registerWindow();
    const stale = handle;
    const origin_id = handle.window_id;

    try handle.trySend(normalCommand(73));
    try handle.trySend(controlCommand(74));
    handle.close();

    try std.testing.expectError(
        error.WindowClosed,
        stale.trySend(normalCommand(75)),
    );

    const first = service.tryReceiveCommand().?;
    try std.testing.expectEqual(origin_id, first.window_id);
    try std.testing.expectEqual(service_mod.CommandKind.cancel_job, first.command.kind);
    try std.testing.expectEqual(@as(u64, 74), first.command.job_id);

    const second = service.tryReceiveCommand().?;
    try std.testing.expectEqual(origin_id, second.window_id);
    try std.testing.expectEqual(service_mod.CommandKind.submit_job, second.command.kind);
    try std.testing.expectEqual(@as(u64, 73), second.command.job_id);

    try std.testing.expect(service.tryReceiveCommand() == null);

    var replacement = try service.registerWindow();
    defer replacement.close();
    try std.testing.expect(replacement.window_id > origin_id);
}

test "owned command admission transfers payload only after successful enqueue" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();

    var handle = try service.registerWindow();
    defer handle.close();

    const source_paths = [_][]const u8{ "/source/one", "/source/two" };
    var command: service_mod.Command = .{
        .kind = .submit_job,
        .payload = try service_mod.OwnedPayload.createTransfer(
            std.testing.allocator,
            .copy,
            "/destination",
            &source_paths,
        ),
    };
    defer command.deinitPayload();

    // Ordinary value admission must not accidentally transfer an owner.
    try std.testing.expectError(
        error.OwnedPayloadRequiresTransfer,
        handle.trySend(command),
    );
    try std.testing.expect(command.payload != null);

    try handle.trySendOwned(&command);
    try std.testing.expect(command.payload == null);

    var routed = service.tryReceiveCommand().?;
    try std.testing.expectEqual(service_mod.CommandKind.submit_job, routed.command.kind);
    try std.testing.expect(routed.command.payload != null);

    const payload = routed.command.payload.?;
    switch (payload.data) {
        .transfer => |request| {
            try std.testing.expectEqual(service_mod.TransferMode.copy, request.mode);
            try std.testing.expectEqualStrings("/destination", request.destination_path);
            try std.testing.expectEqual(@as(usize, 2), request.sources.len);
            try std.testing.expectEqualStrings("/source/one", request.sources[0].path);
            try std.testing.expectEqualStrings("/source/two", request.sources[1].path);
        },
        else => return error.UnexpectedPayloadKind,
    }
    routed.command.deinitPayload();
}

test "failed owned command admission leaves payload with caller" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();

    var handle = try service.registerWindow();
    defer {
        handle.close();
        while (service.tryReceiveCommand()) |routed_value| {
            var routed = routed_value;
            routed.command.deinitPayload();
        }
    }

    for (0..service_mod.command_capacity_per_window) |i| {
        try handle.trySend(normalCommand(i));
    }

    const source_paths = [_][]const u8{"/source/file"};
    var command: service_mod.Command = .{
        .kind = .submit_job,
        .payload = try service_mod.OwnedPayload.createTransfer(
            std.testing.allocator,
            .move,
            "/destination",
            &source_paths,
        ),
    };
    defer command.deinitPayload();

    try std.testing.expectError(error.WindowQueueFull, handle.trySendOwned(&command));
    try std.testing.expect(command.payload != null);
}

test "owned commands remain valid after their originating window closes" {
    var service: service_mod.Service = .{};
    try service.init();
    defer service.deinit();

    var handle = try service.registerWindow();
    const origin_id = handle.window_id;
    const source_paths = [_][]const u8{"/source/file"};
    var command: service_mod.Command = .{
        .kind = .submit_job,
        .payload = try service_mod.OwnedPayload.createTransfer(
            std.testing.allocator,
            .copy,
            "/destination",
            &source_paths,
        ),
    };
    defer command.deinitPayload();

    try handle.trySendOwned(&command);
    handle.close();

    var routed = service.tryReceiveCommand().?;
    try std.testing.expectEqual(origin_id, routed.window_id);
    try std.testing.expect(routed.command.payload != null);
    routed.command.deinitPayload();
    try std.testing.expect(service.tryReceiveCommand() == null);
}

test "discovery payload owns its root path and entry identity" {
    var payload = try service_mod.OwnedPayload.createDiscovery(
        std.testing.allocator,
        42,
        "/source/tree",
    );
    defer payload.deinit();

    switch (payload.data) {
        .discovery => |request| {
            try std.testing.expectEqual(@as(u64, 42), request.root_entry_id);
            try std.testing.expectEqualStrings("/source/tree", request.root_path.?);
        },
        else => return error.UnexpectedPayloadKind,
    }
}

test "discovery priority payload can omit a root path" {
    var payload = try service_mod.OwnedPayload.createDiscovery(
        std.testing.allocator,
        73,
        null,
    );
    defer payload.deinit();

    switch (payload.data) {
        .discovery => |request| {
            try std.testing.expectEqual(@as(u64, 73), request.root_entry_id);
            try std.testing.expect(request.root_path == null);
        },
        else => return error.UnexpectedPayloadKind,
    }
}

test "conflict resolution payload owns rename destination" {
    var payload = try service_mod.OwnedPayload.createConflictResolution(
        std.testing.allocator,
        91,
        .rename,
        "/destination/renamed",
    );
    defer payload.deinit();

    switch (payload.data) {
        .conflict_resolution => |request| {
            try std.testing.expectEqual(@as(u64, 91), request.conflict_id);
            try std.testing.expectEqual(service_mod.ConflictAction.rename, request.action);
            try std.testing.expectEqualStrings(
                "/destination/renamed",
                request.destination_path.?,
            );
        },
        else => return error.UnexpectedPayloadKind,
    }
}

test "conflict resolution payload rejects inconsistent rename data" {
    try std.testing.expectError(
        error.InvalidConflictResolutionPayload,
        service_mod.OwnedPayload.createConflictResolution(
            std.testing.allocator,
            92,
            .rename,
            null,
        ),
    );
    try std.testing.expectError(
        error.InvalidConflictResolutionPayload,
        service_mod.OwnedPayload.createConflictResolution(
            std.testing.allocator,
            93,
            .skip,
            "/unexpected/path",
        ),
    );
}

test "command payload destruction consumes ownership" {
    var command: service_mod.Command = .{
        .kind = .start_discovery,
        .payload = try service_mod.OwnedPayload.createDiscovery(
            std.testing.allocator,
            101,
            "/source",
        ),
    };

    command.deinitPayload();
    try std.testing.expect(command.payload == null);
    command.deinitPayload();
    try std.testing.expect(command.payload == null);
}
