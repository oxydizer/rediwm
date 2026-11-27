const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const io_operation_executor = @import("io_operation_executor.zig");
const support = @import("io_coordinator_test_support.zig");
const send = support.send;
const sendOwned = support.sendOwned;
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

test "coordinator rejects transfer submissions without a payload" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(std.testing.allocator, std.testing.io, &service);

    var window = try service.registerWindow();
    var window_view = support.View.init(window, &service);
    defer window.close();
    defer coordinator.deinit();

    try send(window, .{ .kind = .submit_job, .submit_tag = 73 });

    // The failed submit is the window's own outcome, recognisable by its tag.
    const record = try window_view.waitFor(support.FailedSubmit{});
    try std.testing.expectEqual(@as(u64, 73), record.submit_tag);
    try std.testing.expectEqual(
        @intFromEnum(io_coordinator.RejectionCode.missing_payload),
        record.error_code,
    );
}

const c = @import("c.zig").api;

test "coordinator shows conflicts to every window, and any window resolves them" {
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
    try coordinator.init(allocator, std.testing.io, &service);

    var owner_window = try service.registerWindow();
    var owner_window_view = support.View.init(owner_window, &service);
    var owner_closed = false;
    defer if (!owner_closed) owner_window.close();
    var other_window = try service.registerWindow();
    var other_window_view = support.View.init(other_window, &service);
    defer other_window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, owner_window, .copy, destination_dir, source);

    // The pending conflict is part of the job's record, so every window
    // sees it, including one that did not submit the job.
    const owner_view = try owner_window_view.waitFor(support.PendingConflict{});
    const other_view = try other_window_view.waitFor(support.PendingConflict{});
    try std.testing.expectEqual(owner_view.pending_conflict, other_view.pending_conflict);
    const id = owner_view.pending_conflict;

    // Any window may resolve it, also after the window that submitted the
    // job has closed: jobs belong to the service, not to a window.
    owner_window.close();
    owner_closed = true;
    try resolveConflict(allocator, other_window, id, .skip);
    try other_window_view.waitState(owner_view.id, .completed);
    try std.testing.expectEqual(@as(u64, 0), other_window_view.find(owner_view.id).?.pending_conflict);
}

test "coordinator ignores invalid discovery commands without disturbing anything" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(std.testing.allocator, std.testing.io, &service);

    var window = try service.registerWindow();
    var window_view = support.View.init(window, &service);
    defer window.close();
    defer coordinator.deinit();

    const job_id: io_service.JobId = 73;
    // Missing payload, missing root path, unknown job. There is no reply
    // channel: a command that cannot apply changes nothing and is logged.
    try send(window, .{ .kind = .start_discovery, .job_id = job_id });
    try sendDiscoveryCommand(std.testing.allocator, window, .start_discovery, job_id, 1, null);
    try sendDiscoveryCommand(std.testing.allocator, window, .start_discovery, job_id, 1, "/tmp/discovery-root");

    // A failed submit queued behind them, in the same normal queue, proves
    // they were processed; the table holds nothing but that marker.
    try send(window, .{ .kind = .submit_job, .submit_tag = 9 });
    _ = try window_view.failedSubmit();
    try std.testing.expectEqual(@as(usize, 0), window_view.len);
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
    try coordinator.init(allocator, std.testing.io, &service);

    var window = try service.registerWindow();
    var window_view = support.View.init(window, &service);
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source_dir);

    const submitted_job_id = (try window_view.waitFor(support.AnyLiveJob{})).id;

    try sendDiscoveryCommand(
        allocator,
        window,
        .prioritize_discovery,
        submitted_job_id,
        1,
        null,
    );

    try waitForContents(destination_file, "discovery priority payload");
    try window_view.waitState(submitted_job_id, .completed);
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
    try coordinator.init(allocator, std.testing.io, &service);

    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source);
    try waitForContents(destination, "coordinator regular-file copy");

    try std.testing.expect(pathExists(source));
    // Once the job is gone the coordinator reports itself idle: a process
    // with no window left may then end (S6).
    var waited: usize = 0;
    while (!service.isWorkIdle()) : (waited += 1) {
        if (waited == 200) return error.CoordinatorNeverIdle;
        waitBriefly();
    }
}

test "coordinator publishes a job record with planned totals and final progress" {
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

    const size = 16 * 1024 * 1024;
    const contents = try allocator.alloc(u8, size);
    defer allocator.free(contents);
    @memset(contents, 0x5a);
    try writeFile(source, contents);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, std.testing.io, &service);

    var window = try service.registerWindow();
    var window_view = support.View.init(window, &service);
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, source);

    // The record exists from accept, in `planning`; once the worker's plan
    // is applied it knows the planned total, before any copying.
    const first = try window_view.waitFor(support.PlannedJob{});
    try std.testing.expectEqual(@as(u64, size), first.total_bytes);
    try std.testing.expectEqual(@as(u64, 1), first.total_items);
    try std.testing.expectEqualStrings("payload.bin", first.label());
    try std.testing.expectEqual(io_service.JobKind.copy, first.kind);
    try std.testing.expect(first.started_at_ms > 0);

    // Progress is coalesced; the terminal record carries the final values.
    try window_view.waitState(first.id, .completed);
    const final = window_view.find(first.id).?;
    try std.testing.expectEqual(@as(u64, size), final.completed_bytes);
    try std.testing.expectEqual(@as(u64, 1), final.completed_items);
    try std.testing.expect(final.finished_at_ms >= final.started_at_ms);
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
    try coordinator.init(allocator, std.testing.io, &service);

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
    try coordinator.init(allocator, std.testing.io, &service);

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
    try coordinator.init(allocator, std.testing.io, &service);

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
    try coordinator.init(allocator, std.testing.io, &service);

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
    try coordinator.init(allocator, std.testing.io, &service);

    var window = try service.registerWindow();
    var window_view = support.View.init(window, &service);
    defer window.close();
    defer coordinator.deinit();

    try submitTransfer(allocator, window, .copy, destination_dir, missing_source);

    try std.testing.expectEqual(
        @intFromEnum(io_coordinator.RejectionCode.invalid_source),
        try window_view.failedSubmit(),
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
    try coordinator.init(allocator, std.testing.io, &service);

    var window = try service.registerWindow();
    var window_view = support.View.init(window, &service);
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
    try window_view.waitState(2, .completed);

    // Window-side calls do not wait on the parked work.
    var second = try service.registerWindow();
    second.close();
    try window_view.sync();

    // Cancellation is applied while the unit is still parked: the record
    // shows cancel_requested before the job can reach `cancelled`.
    try send(window, .{ .kind = .cancel_job, .job_id = 1 });
    _ = try window_view.waitFor(support.CancelRequested{ .id = 1 });
    try std.testing.expect(gate.parked.load(.acquire));

    // The job reaches `cancelled` only once the parked unit has returned.
    gate.release();
    try window_view.waitState(1, .cancelled);
}

test "group move refuses existing destination and moves a mixed selection into a fresh one" {
    if (!@import("platform").fs.hasAtomicRenameNoReplace()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);
    const file = try join(allocator, temp, "Trip 1.jpg");
    defer allocator.free(file);
    defer cleanup(file, false);
    const dir = try join(allocator, temp, "Trip 2");
    defer allocator.free(dir);
    defer cleanup(dir, true);
    const child = try join(allocator, dir, "readme");
    defer allocator.free(child);
    defer cleanup(child, false);
    const destination = try join(allocator, temp, "Trip");
    defer allocator.free(destination);
    defer cleanup(destination, true);
    const moved_file = try join(allocator, destination, "Trip 1.jpg");
    defer allocator.free(moved_file);
    defer cleanup(moved_file, false);
    const moved_dir = try join(allocator, destination, "Trip 2");
    defer allocator.free(moved_dir);
    defer cleanup(moved_dir, true);
    const moved_child = try join(allocator, moved_dir, "readme");
    defer allocator.free(moved_child);
    defer cleanup(moved_child, false);

    try writeFile(file, "photo");
    try makeDirectory(dir);
    try writeFile(child, "notes");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, std.testing.io, &service);
    var window = try service.registerWindow();
    defer window.close();
    defer coordinator.deinit();
    var view = support.View.init(window, &service);

    const Terminal = struct {
        tag: u64,
        pub fn matches(self: @This(), record: io_service.JobRecord) bool {
            return record.submit_tag == self.tag and record.state.isTerminal();
        }
    };
    try makeDirectory(destination);
    for ([_]u64{ 1, 2 }) |tag| {
        var command: io_service.Command = .{
            .kind = .submit_job,
            .submit_tag = tag,
            .payload = try io_service.OwnedPayload.createTransfer(allocator, .move, destination, &.{ file, dir }),
        };
        defer command.deinitPayload();
        command.payload.?.data.transfer.create_destination = true;
        try sendOwned(window, &command);
        const record = try view.waitFor(Terminal{ .tag = tag });
        if (tag == 1) {
            try std.testing.expectEqual(io_service.JobState.failed, record.state);
            try std.testing.expectEqual(@backingInt(io_coordinator.RejectionCode.folder_exists), record.error_code);
            try std.testing.expect(pathExists(file) and pathExists(child));
            cleanup(destination, true);
        } else {
            try std.testing.expectEqual(io_service.JobState.completed, record.state);
            try std.testing.expect(!pathExists(file) and !pathExists(dir));
            try waitForContents(moved_file, "photo");
            try waitForContents(moved_child, "notes");
        }
    }
}

test "group move collision preserves both entries and any already moved sibling" {
    if (!@import("platform").fs.hasAtomicRenameNoReplace()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);
    const destination = try join(allocator, temp, "group");
    defer allocator.free(destination);
    try makeDirectory(destination);
    defer cleanup(destination, true);
    const first_target = try join(allocator, destination, "first");
    defer allocator.free(first_target);
    defer cleanup(first_target, false);
    const move = @import("io_move.zig");
    for ([_][]const u8{ "first", "second" }, 0..) |name, index| {
        const source = try join(allocator, temp, name);
        defer allocator.free(source);
        defer cleanup(source, false);
        const target = try join(allocator, destination, name);
        defer allocator.free(target);
        defer if (index == 1) cleanup(target, false);
        try writeFile(source, "original");
        if (index == 1) try writeFile(target, "arrived first");

        var completion = move.execute(allocator, .{
            .token = .{ .job_id = 1, .operation_id = @intCast(index + 1), .generation = 1 },
            .operation_kind = .move_entry,
            .input = try move.makeInputWithPolicy(allocator, source, target, true),
        });
        defer completion.deinit();
        if (index == 0) {
            try std.testing.expectEqual(io_manager.WorkResult.completed, completion.outcome);
            try std.testing.expect(!pathExists(source));
            try waitForContents(target, "original");
        } else {
            try std.testing.expectEqual(io_manager.WorkResult.failed, completion.outcome);
            try waitForContents(source, "original");
            try waitForContents(target, "arrived first");
            try waitForContents(first_target, "original");
        }
    }
}
