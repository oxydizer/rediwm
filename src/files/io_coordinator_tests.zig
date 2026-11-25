const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const io_operation_executor = @import("io_operation_executor.zig");
const support = @import("io_coordinator_test_support.zig");
const send = support.send;
const sendOwned = support.sendOwned;
const receive = support.receive;
const waitReadable = support.waitReadable;
const allocZ = support.allocZ;
const join = support.join;
const makeTempDir = support.makeTempDir;
const makeDirectory = support.makeDirectory;
const writeFile = support.writeFile;
const readFile = support.readFile;
const makeSymlink = support.makeSymlink;
const readLink = support.readLink;
const pathExists = support.pathExists;
const waitBriefly = support.waitBriefly;
const waitForContents = support.waitForContents;
const waitForPath = support.waitForPath;
const waitForRemoval = support.waitForRemoval;
const cleanup = support.cleanup;
const submitTransfer = support.submitTransfer;
const resolveConflict = support.resolveConflict;
const sendDiscoveryCommand = support.sendDiscoveryCommand;
const waitForRejection = support.waitForRejection;
const waitForJobState = support.waitForJobState;
const waitForRejection999 = support.waitForRejection999;

test "coordinator rejects transfer submissions without a payload" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(std.testing.allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try send(window, .{ .kind = .submit_job, .job_id = 73 });
    try std.testing.expect(waitReadable(service.updateWakeFd(), 2000));
    _ = service.drainUpdateWake();

    const update = (try receive(window)).?;
    try std.testing.expectEqual(io_service.UpdateKind.command_rejected, update.kind);
    try std.testing.expectEqual(@as(u64, 73), update.job_id);
    try std.testing.expectEqual(@as(u8, 5), update.state_code);
}

const c = @import("c.zig").api;

test "coordinator routes conflicts to their owning window and resolves them there" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "payload.txt");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "payload.txt");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try makeDirectory(destination_dir);
    try writeFile(source, "source contents");
    try writeFile(destination, "existing contents");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var owner_window = try service.registerWindow();
    defer owner_window.close();
    var other_window = try service.registerWindow();
    defer other_window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, owner_window, .copy, destination_dir, source);

    var conflict_id: ?io_manager.ConflictId = null;
    var other_window_saw_conflict = false;
    for (0..500) |_| {
        if (waitReadable(service.updateWakeFd(), 10))
            _ = service.drainUpdateWake();

        while (try receive(owner_window)) |update| {
            if (update.kind == .conflict)
                conflict_id = update.conflict_id;
        }
        while (try receive(other_window)) |update| {
            if (update.kind == .conflict)
                other_window_saw_conflict = true;
        }
        if (conflict_id != null) break;
    }

    const id = conflict_id orelse return error.ConflictNotificationTimedOut;
    try std.testing.expect(!other_window_saw_conflict);

    // A different window cannot resolve another window's conflict.
    try resolveConflict(allocator, other_window, id, .skip);
    var rejected: ?io_service.Update = null;
    for (0..500) |_| {
        if (waitReadable(service.updateWakeFd(), 10))
            _ = service.drainUpdateWake();
        rejected = receive(other_window) catch {
            waitBriefly();
            continue;
        };
        if (rejected != null) break;
        waitBriefly();
    }
    const rejection = rejected orelse
        return error.MissingConflictOwnershipRejection;
    try std.testing.expectEqual(io_service.UpdateKind.command_rejected, rejection.kind);

    try resolveConflict(allocator, owner_window, id, .skip);

    var saw_terminal_state = false;
    for (0..500) |_| {
        if (waitReadable(service.updateWakeFd(), 10))
            _ = service.drainUpdateWake();
        while (try receive(owner_window)) |update| {
            if (update.kind == .job_state) {
                const state: io_manager.JobState = @fromBackingInt(
                    @intCast(update.state_code),
                );
                if (state.isTerminal()) saw_terminal_state = true;
            }
        }
        if (saw_terminal_state) break;
    }
    try std.testing.expect(saw_terminal_state);
}

test "coordinator validates discovery payloads and routes rejections to the sender" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(std.testing.allocator, &service);

    var owner_window = try service.registerWindow();
    defer owner_window.close();
    var other_window = try service.registerWindow();
    defer other_window.close();
    defer coordinator.deinit();

    const job_id: io_service.JobId = 73;

    try send(owner_window, .{
        .kind = .start_discovery,
        .job_id = job_id,
    });
    const missing_payload = try waitForRejection(&service, owner_window, job_id);
    try std.testing.expectEqual(
        @as(u8, 5),
        missing_payload.state_code,
    );

    try sendDiscoveryCommand(
        std.testing.allocator,
        owner_window,
        .start_discovery,
        job_id,
        1,
        null,
    );
    const missing_path = try waitForRejection(&service, owner_window, job_id);
    try std.testing.expectEqual(
        @as(u8, 255),
        missing_path.state_code,
    );

    try sendDiscoveryCommand(
        std.testing.allocator,
        owner_window,
        .start_discovery,
        job_id,
        1,
        "/tmp/discovery-root",
    );
    const unknown_job = try waitForRejection(&service, owner_window, job_id);
    try std.testing.expectEqual(
        @as(u8, 2),
        unknown_job.state_code,
    );

    try std.testing.expect((try receive(other_window)) == null);
}

test "coordinator accepts discovery prioritization for a submitted directory job" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source_dir = try join(allocator, temp, "source");
    defer allocator.free(source_dir);
    defer cleanup(source_dir, true);
    const source_file = try join(allocator, source_dir, "payload.txt");
    defer allocator.free(source_file);
    defer cleanup(source_file, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination_file = try join(
        allocator,
        destination_dir,
        "source/payload.txt",
    );
    defer allocator.free(destination_file);
    defer cleanup(destination_file, false);

    try makeDirectory(source_dir);
    try makeDirectory(destination_dir);
    try writeFile(source_file, "discovery priority payload");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source_dir);

    var job_id: ?io_service.JobId = null;
    for (0..500) |_| {
        if (waitReadable(service.updateWakeFd(), 10))
            _ = service.drainUpdateWake();
        while (try receive(window)) |update| {
            if (update.kind == .job_state) {
                job_id = update.job_id;
                break;
            }
        }
        if (job_id != null) break;
    }
    const submitted_job_id = job_id orelse return error.JobStateUpdateTimedOut;

    try sendDiscoveryCommand(
        allocator,
        window,
        .prioritize_discovery,
        submitted_job_id,
        1,
        null,
    );

    try waitForContents(destination_file, "discovery priority payload");

    while (try receive(window)) |update| {
        if (update.kind == .command_rejected and update.job_id == submitted_job_id)
            return error.DiscoveryPrioritizationRejected;
    }
}

test "coordinator copies a regular-file transfer" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "payload.bin");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "payload.bin");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try writeFile(source, "coordinator regular-file copy");
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source);
    try waitForContents(destination, "coordinator regular-file copy");

    try std.testing.expect(pathExists(source));
}

test "coordinator publishes job state transitions and transfer progress" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "payload.bin");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    try makeDirectory(destination_dir);

    const contents = try allocator.alloc(u8, 16 * 1024 * 1024);
    defer allocator.free(contents);
    @memset(contents, 0x5a);
    try writeFile(source, contents);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source);

    var saw_progress = false;
    var saw_running_state = false;
    var saw_terminal_state = false;
    var job_id: ?io_service.JobId = null;

    for (0..500) |_| {
        if (waitReadable(service.updateWakeFd(), 10)) {
            _ = service.drainUpdateWake();
            for (0..100) |_| {
                const maybe_update = receive(window) catch {
                    continue;
                };
                const update = maybe_update orelse break;

                if (update.kind == .job_state or update.kind == .progress) {
                    if (job_id) |expected|
                        try std.testing.expectEqual(expected, update.job_id)
                    else
                        job_id = update.job_id;
                }

                if (update.kind == .progress) {
                    try std.testing.expect(update.total_bytes > 0);
                    if (update.completed_bytes > 0)
                        saw_progress = true;
                } else if (update.kind == .job_state) {
                    const state: io_manager.JobState = @fromBackingInt(@intCast(update.state_code));
                    if (state == .running)
                        saw_running_state = true;
                    if (state.isTerminal()) {
                        try std.testing.expectEqual(io_manager.JobState.completed, state);
                        saw_terminal_state = true;
                    }
                }
            }
        }
        if (saw_terminal_state) break;
    }

    try std.testing.expect(job_id != null);
    try std.testing.expect(saw_progress);
    try std.testing.expect(saw_running_state);
    try std.testing.expect(saw_terminal_state);
}

test "coordinator copies a symlink without dereferencing its target" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "relative-link");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "relative-link");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try makeSymlink("../missing/target", source);
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source);
    try waitForPath(destination);

    const target = try readLink(allocator, destination);
    defer allocator.free(target);
    try std.testing.expectEqualStrings("../missing/target", target);
    try std.testing.expect(pathExists(source));
}

test "coordinator moves a same-filesystem regular file" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "move-me.bin");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "move-me.bin");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try writeFile(source, "coordinator same-filesystem move");
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .move, destination_dir, source);
    try waitForContents(destination, "coordinator same-filesystem move");
    try waitForRemoval(source);
}

test "coordinator discovers and copies a directory tree" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const source_nested = try join(allocator, source, "nested");
    defer allocator.free(source_nested);
    const source_file = try join(allocator, source, "root.txt");
    defer allocator.free(source_file);
    const source_nested_file = try join(allocator, source_nested, "nested.txt");
    defer allocator.free(source_nested_file);

    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try join(allocator, destination_dir, "source");
    defer allocator.free(destination);
    const destination_nested = try join(allocator, destination, "nested");
    defer allocator.free(destination_nested);
    const destination_file = try join(allocator, destination, "root.txt");
    defer allocator.free(destination_file);
    const destination_nested_file = try join(allocator, destination_nested, "nested.txt");
    defer allocator.free(destination_nested_file);

    defer cleanup(destination_dir, true);
    defer cleanup(destination, true);
    defer cleanup(destination_nested, true);
    defer cleanup(destination_file, false);
    defer cleanup(destination_nested_file, false);
    defer cleanup(source, true);
    defer cleanup(source_nested, true);
    defer cleanup(source_file, false);
    defer cleanup(source_nested_file, false);

    try makeDirectory(source);
    try makeDirectory(source_nested);
    try makeDirectory(destination_dir);
    try writeFile(source_file, "directory root content");
    try writeFile(source_nested_file, "directory nested content");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source);
    try waitForContents(destination_file, "directory root content");
    try waitForContents(destination_nested_file, "directory nested content");

    try std.testing.expect(pathExists(source_file));
    try std.testing.expect(pathExists(source_nested_file));
}

test "coordinator moves a same-filesystem directory tree" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const source_nested = try join(allocator, source, "nested");
    defer allocator.free(source_nested);
    const source_file = try join(allocator, source_nested, "payload.txt");
    defer allocator.free(source_file);

    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try join(allocator, destination_dir, "source");
    defer allocator.free(destination);
    const destination_nested = try join(allocator, destination, "nested");
    defer allocator.free(destination_nested);
    const destination_file = try join(allocator, destination_nested, "payload.txt");
    defer allocator.free(destination_file);

    defer cleanup(destination_dir, true);
    defer cleanup(destination, true);
    defer cleanup(destination_nested, true);
    defer cleanup(destination_file, false);
    defer cleanup(source, true);
    defer cleanup(source_nested, true);
    defer cleanup(source_file, false);

    try makeDirectory(source);
    try makeDirectory(source_nested);
    try makeDirectory(destination_dir);
    try writeFile(source_file, "directory move content");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .move, destination_dir, source);
    try waitForContents(destination_file, "directory move content");
    try waitForRemoval(source);
}

test "coordinator rejects an invalid transfer source" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const missing_source = try join(allocator, temp, "does-not-exist");
    defer allocator.free(missing_source);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, missing_source);

    try std.testing.expect(waitReadable(service.updateWakeFd(), 2000));
    _ = service.drainUpdateWake();

    const update = (try receive(window)).?;
    try std.testing.expectEqual(io_service.UpdateKind.command_rejected, update.kind);
    try std.testing.expectEqual(
        @intFromEnum(io_coordinator.RejectionCode.invalid_source),
        update.state_code,
    );
    try std.testing.expectEqual(@as(usize, 0), blk: {
        var count: usize = 0;
        const zpath = try allocZ(allocator, destination_dir);
        defer allocator.free(zpath);
        const dir = c.opendir(zpath) orelse return error.OpenDirectoryFailed;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."))
                count += 1;
        }
        break :blk count;
    });
}

test "a hung worker does not stall the coordinator, other jobs or window calls" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const hung_source = try join(allocator, temp, "hung.bin");
    defer allocator.free(hung_source);
    defer cleanup(hung_source, false);
    const other_source = try join(allocator, temp, "other.bin");
    defer allocator.free(other_source);
    defer cleanup(other_source, false);
    const hung_dir = try join(allocator, temp, "hung-destination");
    defer allocator.free(hung_dir);
    defer cleanup(hung_dir, true);
    const hung_destination = try join(allocator, hung_dir, "hung.bin");
    defer allocator.free(hung_destination);
    defer cleanup(hung_destination, false);
    const other_dir = try join(allocator, temp, "other-destination");
    defer allocator.free(other_dir);
    defer cleanup(other_dir, true);
    const other_destination = try join(allocator, other_dir, "other.bin");
    defer allocator.free(other_destination);
    defer cleanup(other_destination, false);

    try writeFile(hung_source, "parked like a hung mount");
    try writeFile(other_source, "copied while the other worker is parked");
    try makeDirectory(hung_dir);
    try makeDirectory(other_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();
    // Runs before coordinator.deinit joins the workers, even on failure.
    const gate = io_operation_executor.test_gate;
    defer gate.release();

    // Job 1's copy unit parks on its worker, as on a hung mount.
    gate.arm();
    try submitTransfer(allocator, window, .copy, hung_dir, hung_source);
    for (0..1000) |_| {
        if (gate.parked.load(.acquire)) break;
        waitBriefly();
    } else return error.Timeout;

    // The coordinator keeps dispatching and reconciling: job 2 completes on
    // the other operation worker while job 1 is still parked.
    try submitTransfer(allocator, window, .copy, other_dir, other_source);
    try waitForContents(other_destination, "copied while the other worker is parked");
    try waitForJobState(window, &service, 2, .completed);

    // Window-side calls do not wait on the parked work.
    var second = try service.registerWindow();
    second.close();
    _ = try receive(window);

    // Cancellation is applied while the unit is still parked. Control
    // commands run in order, so the rejection of a cancel for an unknown job
    // queued right behind it proves the real one was applied.
    try send(window, .{ .kind = .cancel_job, .job_id = 1 });
    try send(window, .{ .kind = .cancel_job, .job_id = 999 });
    try waitForRejection999(window, &service);
    try std.testing.expect(gate.parked.load(.acquire));

    // The job reaches `cancelled` only once the parked unit has returned.
    gate.release();
    try waitForJobState(window, &service, 1, .cancelled);
}
