const std = @import("std");
const io_manager = @import("io_manager.zig");
const io_discovery = @import("io_discovery.zig");
const io_tree = @import("io_tree.zig");

test "discovery metadata retains device identity and Jobs retain destination device" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.setDestinationDirectory(job, "/destination");
    try manager.setDestinationDeviceId(job, 73);
    try std.testing.expectEqual(@as(?u64, 73), manager.destinationDeviceId(job));

    try manager.startDiscovery(job, "/source");
    const token = manager.dispatchDiscovery().?;

    var batch: io_discovery.Batch = .{
        .allocator = allocator,
        .complete = true,
    };
    errdefer batch.deinit();

    const name = try allocator.dupe(u8, "payload.bin");
    try batch.records.append(allocator, .{
        .name = name,
        .kind = .regular_file,
        .metadata = .{ .size = 19, .device_id = 91 },
    });

    try std.testing.expect(try manager.completeDiscovery(token, &batch));

    const tree = manager.treeIndex(job).?;
    const child_id = tree.getConst(root).?.children.items[0];
    try std.testing.expectEqual(
        @as(?u64, 91),
        tree.getConst(child_id).?.metadata.device_id,
    );
}

fn makeDiscoveryBatch(
    allocator: std.mem.Allocator,
    records: []const struct {
        name: []const u8,
        kind: io_tree.EntryKind,
        device_id: ?u64 = 1,
        symlink_target: ?[]const u8 = null,
    },
    complete: bool,
) !io_discovery.Batch {
    var batch: io_discovery.Batch = .{
        .allocator = allocator,
        .complete = complete,
    };
    errdefer batch.deinit();

    for (records) |record| {
        const name = try allocator.dupe(u8, record.name);
        errdefer allocator.free(name);
        const symlink_target = if (record.symlink_target) |target|
            try allocator.dupe(u8, target)
        else
            null;
        errdefer if (symlink_target) |target| allocator.free(target);
        try batch.records.append(allocator, .{
            .name = name,
            .kind = record.kind,
            .metadata = .{ .device_id = record.device_id },
            .symlink_target = symlink_target,
        });
    }

    return batch;
}

test "scheduler rotates fairly across Jobs and preserves per-Job FIFO" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_a = try manager.createJob(1);
    const a1 = try manager.addOperation(job_a, .copy_file);
    const a2 = try manager.addOperation(job_a, .publish);
    const job_b = try manager.createJob(2);
    const b1 = try manager.addOperation(job_b, .copy_file);
    try manager.queueJob(job_a);
    try manager.queueJob(job_b);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, first.job_id);
    try std.testing.expectEqual(a1, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .yielded));

    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(job_b, second.job_id);
    try std.testing.expectEqual(b1, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));

    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(a1, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    const fourth = manager.dispatchNext().?;
    try std.testing.expectEqual(a2, fourth.operation_id);
    try std.testing.expect(manager.completeWork(fourth, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_a).?);
}

test "one Job never runs more than its limit, even alone" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.max_running_per_job = 2;

    // A lone Job with three independent copies starts two of them.
    const job_a = try manager.createJob(1);
    for (0..3) |_| _ = try manager.addOperation(job_a, .copy_file);
    try manager.queueJob(job_a);
    const a1 = manager.dispatchNext().?;
    const a2 = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, a2.job_id);
    try std.testing.expectEqual(@as(?io_manager.WorkToken, null), manager.dispatchNext());

    // A Job that arrives while those two hang gets the free worker.
    const job_b = try manager.createJob(2);
    _ = try manager.addOperation(job_b, .copy_file);
    try manager.queueJob(job_b);
    const b1 = manager.dispatchNext().?;
    try std.testing.expectEqual(job_b, b1.job_id);
    try std.testing.expect(manager.completeWork(b1, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_b).?);

    // Once one of the two returns, the Job's third copy may start.
    try std.testing.expect(manager.completeWork(a1, .completed));
    const a3 = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, a3.job_id);
    try std.testing.expect(manager.completeWork(a2, .completed));
    try std.testing.expect(manager.completeWork(a3, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_a).?);
}

test "a serial disk runs one operation at a time across jobs, a stuck one aside" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.setDiskLimit(7, 1);

    const job_a = try manager.createJob(1);
    for (0..2) |_| _ = try manager.addOperation(job_a, .copy_file);
    const job_b = try manager.createJob(2);
    _ = try manager.addOperation(job_b, .copy_file);
    const job_c = try manager.createJob(3);
    _ = try manager.addOperation(job_c, .copy_file);
    try std.testing.expect(manager.setJobDisks(job_a, &.{7}));
    try std.testing.expect(manager.setJobDisks(job_b, &.{ 9, 7 }));
    try manager.queueJob(job_a);
    try manager.queueJob(job_b);
    try manager.queueJob(job_c);

    // One operation on disk 7; job C touches no limited disk and runs.
    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, first.job_id);
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(job_c, second.job_id);
    try std.testing.expectEqual(@as(?io_manager.WorkToken, null), manager.dispatchNext());

    // A's operation is stuck: it no longer holds the disk, so B goes. A
    // itself is held meanwhile, as its suspect mount makes it.
    try std.testing.expect(manager.setJobStalled(job_a, true));
    try std.testing.expect(manager.setJobHeld(job_a, true));
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(job_b, third.job_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    try std.testing.expect(manager.setJobStalled(job_a, false));
    try std.testing.expect(manager.setJobHeld(job_a, false));
    try std.testing.expect(manager.completeWork(first, .completed));
    try std.testing.expect(manager.completeWork(second, .completed));
    const fourth = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, fourth.job_id);
    try std.testing.expect(manager.completeWork(fourth, .completed));
}

test "hovered copy operation gets one-shot priority over normal scheduling" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_a = try manager.createJob(1);
    const current_entry = try manager.addTreeRoot(
        job_a,
        "current.bin",
        .regular_file,
        .{ .size = 4096 },
        null,
    );
    const current_operation = try manager.addEntryOperation(
        job_a,
        current_entry,
        .copy_file,
    );
    const entry_a = try manager.addTreeRoot(
        job_a,
        "urgent.docx",
        .regular_file,
        .{ .size = 4096 },
        null,
    );
    const operation_a = try manager.addEntryOperation(
        job_a,
        entry_a,
        .copy_file,
    );

    try manager.queueJob(job_a);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, first.job_id);
    try std.testing.expectEqual(current_operation, first.operation_id);

    // A newly planned Job can introduce higher-kind-priority work while the
    // current bounded work unit is running.
    const job_b = try manager.createJob(2);
    const directory_operation = try manager.addOperation(
        job_b,
        .create_directory,
    );
    const operation_b = try manager.addOperation(job_b, .copy_file);
    try manager.queueJob(job_b);

    // The target is still pending and has never had a work unit dispatched.
    try std.testing.expect(manager.prioritizeEntryOperation(job_a, entry_a));
    try std.testing.expect(manager.completeWork(first, .yielded));

    // The preference overrides both Job rotation and operation-kind priority.
    const boosted = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, boosted.job_id);
    try std.testing.expectEqual(operation_a, boosted.operation_id);
    try std.testing.expect(manager.completeWork(boosted, .completed));

    // Normal operation-kind priority resumes after the one-shot boost.
    const normal_kind = manager.dispatchNext().?;
    try std.testing.expectEqual(job_b, normal_kind.job_id);
    try std.testing.expectEqual(directory_operation, normal_kind.operation_id);
    try std.testing.expect(manager.completeWork(normal_kind, .completed));

    // The yielded copy resumes after higher-priority directory creation.
    const resumed = manager.dispatchNext().?;
    try std.testing.expectEqual(job_a, resumed.job_id);
    try std.testing.expectEqual(current_operation, resumed.operation_id);
    try std.testing.expect(manager.completeWork(resumed, .completed));

    const normal_job = manager.dispatchNext().?;
    try std.testing.expectEqual(job_b, normal_job.job_id);
    try std.testing.expectEqual(operation_b, normal_job.operation_id);
    try std.testing.expect(manager.completeWork(normal_job, .completed));
}

test "independent operations run concurrently while dependencies remain blocked" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const parent = try manager.addOperation(job, .create_directory);
    const independent = try manager.addOperation(job, .copy_file);
    const child = try manager.addOperation(job, .copy_file);
    try manager.addDependency(job, child, parent);
    try manager.queueJob(job);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(parent, first.operation_id);
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(independent, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));
    // The child is still blocked by its prerequisite, even though the
    // independent operation has completed and the parent is still running.
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expect(manager.completeWork(first, .completed));
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(child, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "stale and duplicate worker results are rejected" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const operation = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);
    const old_token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(old_token, .yielded));
    const new_token = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, new_token.operation_id);
    try std.testing.expect(new_token.generation > old_token.generation);
    try std.testing.expect(!manager.completeWork(old_token, .completed));
    try std.testing.expect(manager.completeWork(new_token, .completed));
    try std.testing.expect(!manager.completeWork(new_token, .completed));
}

test "archive operations own request paths and expose current job-level details" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    try std.testing.expectError(
        error.ArchiveRequestRequired,
        manager.addOperation(job, .archive_extract),
    );

    const source = try allocator.dupe(u8, "/tmp/source.zip");
    defer allocator.free(source);
    const staging_parent = try allocator.dupe(u8, "/tmp/destination");
    defer allocator.free(staging_parent);
    const member = try allocator.dupe(u8, "nested/./item.txt");
    defer allocator.free(member);

    const operation = try manager.addArchiveOperation(
        job,
        .archive_member_extract,
        .{
            .source_path = source,
            .staging_parent = staging_parent,
            .member_path = member,
        },
    );

    @memset(source, 'x');
    @memset(staging_parent, 'y');
    @memset(member, 'z');

    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, token.operation_id);
    try std.testing.expect(manager.operationDetails(token) == null);

    const details = manager.archiveOperationDetails(token).?;
    try std.testing.expectEqual(
        io_manager.OperationKind.archive_member_extract,
        details.kind,
    );
    try std.testing.expectEqualStrings("/tmp/source.zip", details.source_path);
    try std.testing.expectEqualStrings("/tmp/destination", details.staging_parent);
    try std.testing.expectEqualStrings("nested/item.txt", details.member_path.?);

    var stale = token;
    stale.generation += 1;
    try std.testing.expect(manager.archiveOperationDetails(stale) == null);
    try std.testing.expect(manager.completeWork(token, .completed));
    try std.testing.expect(manager.archiveOperationDetails(token) == null);
}

test "archive operations own and normalize selected member paths" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const source = try allocator.dupe(u8, "/tmp/source.zip");
    defer allocator.free(source);
    const staging_parent = try allocator.dupe(u8, "/tmp/destination");
    defer allocator.free(staging_parent);
    const first = try allocator.dupe(u8, "nested/./one.txt");
    defer allocator.free(first);
    const second = try allocator.dupe(u8, "two.txt");
    defer allocator.free(second);
    const members = [_][]const u8{ first, second };

    const operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = source,
            .staging_parent = staging_parent,
            .member_paths = &members,
        },
    );

    @memset(source, 'x');
    @memset(staging_parent, 'y');
    @memset(first, 'z');
    @memset(second, 'w');

    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, token.operation_id);

    const details = manager.archiveOperationDetails(token).?;
    try std.testing.expectEqualStrings("/tmp/source.zip", details.source_path);
    try std.testing.expectEqualStrings("/tmp/destination", details.staging_parent);
    try std.testing.expect(details.member_path == null);
    try std.testing.expectEqual(@as(usize, 2), details.member_paths.len);
    try std.testing.expectEqualStrings("nested/one.txt", details.member_paths[0]);
    try std.testing.expectEqualStrings("two.txt", details.member_paths[1]);
}

test "archive operation registration validates kind and member selection" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    try std.testing.expectError(
        error.InvalidOperationKind,
        manager.addArchiveOperation(
            job,
            .copy_file,
            .{
                .source_path = "/tmp/source.zip",
                .staging_parent = "/tmp/destination",
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidArchiveMemberPath,
        manager.addArchiveOperation(
            job,
            .archive_member_extract,
            .{
                .source_path = "/tmp/source.zip",
                .staging_parent = "/tmp/destination",
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidArchiveMemberPath,
        manager.addArchiveOperation(
            job,
            .archive_extract,
            .{
                .source_path = "/tmp/source.zip",
                .staging_parent = "/tmp/destination",
                .member_path = "item.txt",
            },
        ),
    );
    try std.testing.expectError(
        error.UnsafeArchivePath,
        manager.addArchiveOperation(
            job,
            .archive_member_extract,
            .{
                .source_path = "/tmp/source.zip",
                .staging_parent = "/tmp/destination",
                .member_path = "../outside.txt",
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidArchiveMemberPath,
        manager.addArchiveOperation(
            job,
            .archive_extract,
            .{
                .source_path = "/tmp/source.zip",
                .staging_parent = "/tmp/destination",
                .member_paths = &.{ "nested/item.txt", "nested/./item.txt" },
            },
        ),
    );
    try std.testing.expectError(
        error.UnsafeArchivePath,
        manager.addArchiveOperation(
            job,
            .archive_extract,
            .{
                .source_path = "/tmp/source.zip",
                .staging_parent = "/tmp/destination",
                .member_paths = &.{"../outside.txt"},
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidArchiveSourcePath,
        manager.addArchiveOperation(
            job,
            .archive_extract,
            .{
                .source_path = "relative.zip",
                .staging_parent = "/tmp/destination",
            },
        ),
    );
}

test "a job accepts at most one archive operation" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const request = io_manager.ArchiveOperationRequest{
        .source_path = "/tmp/source.zip",
        .staging_parent = "/tmp/staging",
    };

    _ = try manager.addArchiveOperation(job, .archive_extract, request);

    try std.testing.expectError(
        error.ArchiveOperationAlreadyRegistered,
        manager.addArchiveOperation(job, .archive_extract, request),
    );
    try std.testing.expectError(
        error.ArchiveOperationAlreadyRegistered,
        manager.addArchiveOperation(job, .archive_member_extract, .{
            .source_path = "/tmp/other.zip",
            .staging_parent = "/tmp/staging",
            .member_path = "item.txt",
        }),
    );
}

test "archive operations reject jobs already configured for incremental moves" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 1 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 1);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    _ = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);

    try std.testing.expectError(
        error.DiscoveryOperationModeAlreadySet,
        manager.addArchiveOperation(
            job,
            .archive_extract,
            .{
                .source_path = "/tmp/source.zip",
                .staging_parent = "/tmp/staging",
            },
        ),
    );
}

test "archive publication roots register multiple owned roots and schedule discovery" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const archive_operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = "/tmp/source.zip",
            .staging_parent = "/tmp/staging",
        },
    );

    // Archive jobs can establish their destination before extraction
    // reveals the publication roots.
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.queueJob(job);

    const archive_token = manager.dispatchNext().?;
    try std.testing.expectEqual(archive_operation, archive_token.operation_id);
    try std.testing.expect(manager.completeWork(archive_token, .waiting));

    const directory_source = try allocator.dupe(u8, "/tmp/staging/folder");
    defer allocator.free(directory_source);
    const directory_root = try manager.addArchivePublicationRoot(
        archive_token,
        .{
            .name = "folder",
            .source_path = directory_source,
            .kind = .directory,
        },
    );
    @memset(directory_source, 'x');

    const file_source = try allocator.dupe(u8, "/tmp/staging/readme.txt");
    defer allocator.free(file_source);
    const file_root = try manager.addArchivePublicationRoot(
        archive_token,
        .{
            .name = "readme.txt",
            .source_path = file_source,
            .kind = .regular_file,
            .metadata = .{ .size = 42 },
        },
    );
    @memset(file_source, 'y');

    const tree = manager.treeIndex(job).?;
    try std.testing.expectEqual(@as(usize, 2), tree.roots().len);
    try std.testing.expectEqualStrings(
        "folder",
        tree.getConst(directory_root).?.name,
    );
    try std.testing.expectEqual(
        io_tree.DiscoveryState.queued,
        tree.getConst(directory_root).?.discovery,
    );
    try std.testing.expectEqualStrings(
        "readme.txt",
        tree.getConst(file_root).?.name,
    );

    try std.testing.expectEqualStrings(
        "/tmp/staging/folder",
        manager.discoveryRootPath(job, directory_root).?,
    );
    const file_path = try manager.sourcePath(allocator, job, file_root);
    defer allocator.free(file_path);
    try std.testing.expectEqualStrings("/tmp/staging/readme.txt", file_path);

    const directory_operation = manager.dispatchNext().?;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(directory_operation).?.kind,
    );
    try std.testing.expect(manager.completeWork(directory_operation, .completed));

    const file_operation = manager.dispatchNext().?;
    try std.testing.expectEqual(
        io_manager.OperationKind.copy_file,
        manager.operationDetails(file_operation).?.kind,
    );
    try std.testing.expect(manager.completeWork(file_operation, .completed));

    const discovery = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(directory_root, discovery.entry_id);

    var batch = try makeDiscoveryBatch(
        allocator,
        &.{
            .{
                .name = "nested.txt",
                .kind = .regular_file,
                .device_id = 7,
            },
        },
        true,
    );
    var batch_owned = true;
    defer if (batch_owned) batch.deinit();

    const discovery_completed = try manager.completeDiscovery(discovery, &batch);
    if (discovery_completed) batch_owned = false;
    try std.testing.expect(discovery_completed);
    const discovered_tree = manager.treeIndex(job).?;
    const child_id = discovered_tree.getConst(directory_root).?.children.items[0];
    try std.testing.expectEqualStrings(
        "nested.txt",
        discovered_tree.getConst(child_id).?.name,
    );

    const child_operation = manager.dispatchNext().?;
    try std.testing.expectEqual(
        io_manager.OperationKind.copy_file,
        manager.operationDetails(child_operation).?.kind,
    );
    try std.testing.expectEqual(child_id, manager.operationDetails(child_operation).?.entry_id);
    try std.testing.expect(manager.completeWork(child_operation, .completed));
}

test "archive publication roots reject stale and closed barriers" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const archive_operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = "/tmp/source.zip",
            .staging_parent = "/tmp/staging",
        },
    );
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(archive_operation, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .waiting));

    var stale_token = token;
    stale_token.generation += 1;
    try std.testing.expectError(
        error.StaleWorkToken,
        manager.addArchivePublicationRoot(stale_token, .{
            .name = "payload.bin",
            .source_path = "/tmp/staging/payload.bin",
            .kind = .regular_file,
        }),
    );

    try manager.closeArchivePublication(token);
    try std.testing.expectError(
        error.ArchivePublicationAlreadyClosed,
        manager.addArchivePublicationRoot(token, .{
            .name = "payload.bin",
            .source_path = "/tmp/staging/payload.bin",
            .kind = .regular_file,
        }),
    );
}

test "archive publication roots validate source paths and entry kinds" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = "/tmp/source.zip",
            .staging_parent = "/tmp/staging",
        },
    );
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(token, .waiting));

    try std.testing.expectError(
        error.InvalidSourceRootPath,
        manager.addArchivePublicationRoot(token, .{
            .name = "payload.bin",
            .source_path = "relative/payload.bin",
            .kind = .regular_file,
        }),
    );
    try std.testing.expectError(
        error.UnsupportedEntryKind,
        manager.addArchivePublicationRoot(token, .{
            .name = "special",
            .source_path = "/tmp/staging/special",
            .kind = .other,
        }),
    );
}

test "archive publication barrier waits for dynamically registered operations" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{ .size = 64 },
        null,
    );
    const archive_operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = "/tmp/source.zip",
            .staging_parent = "/tmp/staging",
        },
    );
    try manager.queueJob(job);

    const archive_token = manager.dispatchNext().?;
    try std.testing.expectEqual(archive_operation, archive_token.operation_id);
    try std.testing.expect(manager.completeWork(archive_token, .waiting));
    try std.testing.expectEqual(
        io_manager.JobState.waiting,
        manager.jobState(job).?,
    );

    const publication_operation = try manager.addEntryOperation(
        job,
        root,
        .copy_file,
    );
    try manager.closeArchivePublication(archive_token);
    try std.testing.expectEqual(
        @as(?bool, false),
        manager.archivePublicationReady(archive_token),
    );

    const publication_token = manager.dispatchNext().?;
    try std.testing.expectEqual(
        publication_operation,
        publication_token.operation_id,
    );
    try std.testing.expect(manager.completeWork(publication_token, .completed));
    const detach_operation = try manager.addEntryOperation(
        job,
        root,
        .detach_source,
    );
    try std.testing.expectEqual(
        @as(?bool, false),
        manager.archivePublicationReady(archive_token),
    );
    const detach_token = manager.dispatchNext().?;
    try std.testing.expectEqual(detach_operation, detach_token.operation_id);
    try std.testing.expect(manager.completeWork(detach_token, .completed));
    try std.testing.expectEqual(
        @as(?bool, true),
        manager.archivePublicationReady(archive_token),
    );

    try std.testing.expect(manager.completeArchivePublication(archive_token));
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, archive_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.JobState.completed,
        manager.jobState(job).?,
    );
    try std.testing.expect(!manager.completeArchivePublication(archive_token));
}

test "archive publication barrier completes before directory finalization" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const archive_operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = "/tmp/source.zip",
            .staging_parent = "/tmp/staging",
        },
    );
    const root = try manager.addTreeRoot(job, "Photos", .directory, .{}, null);
    try manager.queueJob(job);

    const archive_token = manager.dispatchNext().?;
    try std.testing.expectEqual(archive_operation, archive_token.operation_id);
    try std.testing.expect(manager.completeWork(archive_token, .waiting));

    _ = try manager.addEntryOperation(job, root, .create_directory);
    const create_token = manager.dispatchNext().?;
    try manager.registerDirectoryPermission(create_token, .{
        .entry_id = root,
        .device_id = 12,
        .inode_id = 34,
        .mode = 0o750,
        .origin = .created,
    });
    try std.testing.expect(manager.completeWork(create_token, .completed));

    try manager.closeArchivePublication(archive_token);
    try std.testing.expectEqual(
        @as(?bool, true),
        manager.archivePublicationReady(archive_token),
    );
    try std.testing.expect(manager.completeArchivePublication(archive_token));

    try std.testing.expectEqual(io_manager.JobState.finalizing, manager.jobState(job).?);
    const finalizer_token = manager.dispatchNext().?;
    try std.testing.expectEqual(
        io_manager.OperationKind.finalize_directories,
        manager.operationKind(finalizer_token).?,
    );
    try std.testing.expect(manager.completeWork(finalizer_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "failed archive publication waits for registered operations before failing" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const archive_operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = "/tmp/source.zip",
            .staging_parent = "/tmp/staging",
        },
    );
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.queueJob(job);

    const archive_token = manager.dispatchNext().?;
    try std.testing.expectEqual(archive_operation, archive_token.operation_id);
    try std.testing.expect(manager.completeWork(archive_token, .waiting));

    const root = try manager.addArchivePublicationRoot(
        archive_token,
        .{
            .name = "payload.bin",
            .source_path = "/tmp/staging/payload.bin",
            .kind = .regular_file,
        },
    );
    try std.testing.expectEqual(
        @as(?bool, false),
        manager.populationComplete(job),
    );
    const publication_operation = manager.entryOperationView(job, root).?;
    try std.testing.expectEqual(io_manager.OperationState.pending, publication_operation.state);

    try manager.failArchivePublication(archive_token);
    try std.testing.expectEqual(
        @as(?bool, false),
        manager.archivePublicationReady(archive_token),
    );

    const publication_token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(publication_token, .completed));
    try std.testing.expectEqual(
        @as(?bool, true),
        manager.populationComplete(job),
    );
    try std.testing.expectEqual(
        @as(?bool, true),
        manager.archivePublicationReady(archive_token),
    );

    try std.testing.expect(manager.completeArchivePublication(archive_token));
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, archive_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );
}

test "copy progress exposes the storage-flush phase" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{ .size = 128 },
        null,
    );
    _ = try manager.addEntryOperation(job, root, .copy_file);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(token, .yielded));
    try std.testing.expect(manager.recordOperationProgress(
        token,
        128,
        128,
        .flushing,
    ));

    const view = manager.entryOperationView(job, root).?;
    try std.testing.expectEqual(io_manager.CopyPhase.flushing, view.copy_phase);
    try std.testing.expectEqual(@as(u64, 128), view.progress_bytes);
    try std.testing.expectEqual(@as(u64, 128), view.progress_total_bytes);
}

test "source detach stays blocked until the copy flush completes" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const copy_operation = try manager.addOperation(job, .copy_file);
    const detach_operation = try manager.addOperation(job, .detach_source);
    try manager.addDependency(job, detach_operation, copy_operation);
    try manager.queueJob(job);

    const transfer_token = manager.dispatchNext().?;
    try std.testing.expectEqual(copy_operation, transfer_token.operation_id);
    try std.testing.expect(manager.completeWork(transfer_token, .yielded));
    try std.testing.expect(manager.recordOperationProgress(
        transfer_token,
        4096,
        4096,
        .flushing,
    ));

    const flush_token = manager.dispatchNext().?;
    try std.testing.expectEqual(copy_operation, flush_token.operation_id);
    try std.testing.expect(manager.completeWork(flush_token, .completed));

    const detach_token = manager.dispatchNext().?;
    try std.testing.expectEqual(detach_operation, detach_token.operation_id);
}

fn expectMoveFallback(
    entry_kind: io_tree.EntryKind,
    symlink_target: ?[]const u8,
    expected_copy_kind: io_manager.OperationKind,
) !void {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "payload",
        entry_kind,
        .{},
        symlink_target,
    );
    try manager.setRootSourcePath(job, root, "/source/payload");
    try manager.setDestinationDirectory(job, "/destination");
    const move_operation = try manager.addEntryOperation(job, root, .move_entry);
    try manager.queueJob(job);

    const move_token = manager.dispatchNext().?;
    try std.testing.expectEqual(move_operation, move_token.operation_id);
    try std.testing.expect(manager.completeWork(move_token, .waiting));

    var stale_token = move_token;
    stale_token.generation += 1;
    try std.testing.expectError(
        error.StaleWorkToken,
        manager.fallbackMoveToCopy(stale_token),
    );

    const detach_operation = try manager.fallbackMoveToCopy(move_token);
    const copy_token = manager.dispatchNext().?;
    try std.testing.expectEqual(move_operation, copy_token.operation_id);
    try std.testing.expectEqual(
        expected_copy_kind,
        manager.operationDetails(copy_token).?.kind,
    );

    // Park the copy. With no active worker, detach must still remain blocked.
    try std.testing.expect(manager.completeWork(copy_token, .waiting));
    try std.testing.expect(manager.dispatchNext() == null);

    try manager.resolveWaiting(job, move_operation);
    const copy_retry = manager.dispatchNext().?;
    try std.testing.expectEqual(move_operation, copy_retry.operation_id);
    try std.testing.expect(copy_retry.generation > copy_token.generation);
    try std.testing.expect(manager.completeWork(copy_retry, .completed));

    const detach_token = manager.dispatchNext().?;
    try std.testing.expectEqual(detach_operation, detach_token.operation_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.detach_source,
        manager.operationDetails(detach_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(detach_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "EXDEV fallback converts regular-file moves into copy-and-detach" {
    try expectMoveFallback(.regular_file, null, .copy_file);
}

test "EXDEV fallback converts symlink moves into copy-and-detach" {
    try expectMoveFallback(.symlink, "../literal-target", .copy_symlink);
}

test "waiting Operations release the worker and can be resolved" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const waiting_op = try manager.addOperation(job, .copy_file);
    const independent = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);
    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(waiting_op, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .waiting));
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(independent, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));
    try std.testing.expectEqual(io_manager.JobState.waiting, manager.jobState(job).?);

    try manager.resolveWaiting(job, waiting_op);
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(waiting_op, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "conflicts are Manager-owned and presented in one global FIFO" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(
        first_job,
        "first.txt",
        .regular_file,
        .{},
        null,
    );
    const first_operation = try manager.addEntryOperation(
        first_job,
        first_root,
        .copy_file,
    );
    try manager.queueJob(first_job);
    const first_token = manager.dispatchNext().?;

    const second_job = try manager.createJob(null);
    const second_root = try manager.addTreeRoot(
        second_job,
        "second.txt",
        .regular_file,
        .{},
        null,
    );
    const second_operation = try manager.addEntryOperation(
        second_job,
        second_root,
        .copy_file,
    );
    try manager.queueJob(second_job);
    const second_token = manager.dispatchNext().?;

    const first_source = try std.testing.allocator.dupe(u8, "/source/first.txt");
    defer std.testing.allocator.free(first_source);
    const first_id = try manager.registerConflict(
        first_token,
        first_root,
        first_source,
        "/destination/first.txt",
        .regular_file,
        .regular_file,
    );
    try std.testing.expectError(
        error.ConflictAlreadyRegistered,
        manager.registerConflict(
            first_token,
            first_root,
            first_source,
            "/destination/first.txt",
            .regular_file,
            .regular_file,
        ),
    );
    const second_id = try manager.registerConflict(
        second_token,
        second_root,
        "/source/second.txt",
        "/destination/second.txt",
        .regular_file,
        .regular_file,
    );

    try std.testing.expectEqual(io_manager.OperationState.waiting, manager.operationState(
        first_job,
        first_operation,
    ).?);
    try std.testing.expectEqual(io_manager.OperationState.waiting, manager.operationState(
        second_job,
        second_operation,
    ).?);

    const head = manager.nextConflict().?;
    try std.testing.expectEqual(first_id, head.id);
    try std.testing.expectEqual(first_job, head.job_id);
    try std.testing.expectEqualStrings("/source/first.txt", head.source_path);
    try std.testing.expectError(
        error.ConflictNotAtQueueHead,
        manager.resolveConflict(second_id),
    );

    try manager.resolveConflict(first_id);
    const next = manager.nextConflict().?;
    try std.testing.expectEqual(second_id, next.id);
    try std.testing.expectEqual(second_job, next.job_id);
    try std.testing.expectEqual(io_manager.OperationState.pending, manager.operationState(
        first_job,
        first_operation,
    ).?);
}

test "resolving a conflict allows unrelated operations to continue" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "blocked.txt", .regular_file, .{}, null);
    const blocked = try manager.addEntryOperation(job, root, .copy_file);
    const independent = try manager.addOperation(job, .publish);
    try manager.queueJob(job);

    const blocked_token = manager.dispatchNext().?;
    const conflict_id = try manager.registerConflict(
        blocked_token,
        root,
        "/source/blocked.txt",
        "/destination/blocked.txt",
        .regular_file,
        .regular_file,
    );

    const independent_token = manager.dispatchNext().?;
    try std.testing.expectEqual(independent, independent_token.operation_id);
    try std.testing.expect(manager.completeWork(independent_token, .completed));

    try manager.resolveConflict(conflict_id);
    const retry_token = manager.dispatchNext().?;
    try std.testing.expectEqual(blocked, retry_token.operation_id);
    try std.testing.expect(retry_token.generation > blocked_token.generation);
    try std.testing.expect(manager.completeWork(retry_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "merging a directory conflict authorizes only its retried directory operation" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "Photos", .directory, .{}, null);
    const operation = try manager.addEntryOperation(job, root, .create_directory);
    try manager.queueJob(job);
    const first_token = manager.dispatchNext().?;
    const conflict_id = try manager.registerConflict(
        first_token,
        root,
        "/source/Photos",
        "/destination/Photos",
        .directory,
        .directory,
    );

    try manager.mergeConflict(conflict_id);
    try std.testing.expect(manager.nextConflict() == null);
    const retry_token = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, retry_token.operation_id);
    try std.testing.expect(retry_token.generation > first_token.generation);
    const details = manager.operationDetails(retry_token).?;
    try std.testing.expectEqual(io_manager.OperationKind.create_directory, details.kind);
    try std.testing.expect(details.merge_existing_directory);
    try std.testing.expect(manager.completeWork(retry_token, .completed));
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, operation).?,
    );
}

test "directory permission registration validates ownership and records once" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "Photos", .directory, .{}, null);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    const record = io_manager.DirectoryPermissionRecord{
        .entry_id = root,
        .device_id = 12,
        .inode_id = 34,
        .mode = 0o751,
        .origin = .created,
    };

    try manager.registerDirectoryPermission(token, record);
    try std.testing.expectError(
        error.DuplicateDirectoryPermissionRecord,
        manager.registerDirectoryPermission(token, record),
    );
    var invalid = record;
    invalid.origin = .merged;
    try std.testing.expectError(
        error.InvalidDirectoryPermissionRecord,
        manager.registerDirectoryPermission(token, invalid),
    );
    invalid = record;
    invalid.mode = 0o1000;
    try std.testing.expectError(
        error.InvalidDirectoryPermissionRecord,
        manager.registerDirectoryPermission(token, invalid),
    );
    var stale_token = token;
    stale_token.generation += 1;
    try std.testing.expectError(
        error.StaleWork,
        manager.registerDirectoryPermission(stale_token, record),
    );

    const records = manager.directoryPermissionRecords(job).?;
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(root, records[0].entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(token).?.kind,
    );
    try std.testing.expect(manager.completeWork(token, .completed));
}

test "directory finalization waits for publication and discovery to drain" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "Photos", .directory, .{}, null);
    try manager.setRootSourcePath(job, root, "/tmp/Photos");
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const publication = try manager.addOperation(job, .publish);
    const second_publication = try manager.addOperation(job, .publish);
    try manager.startDiscovery(job, "/tmp/Photos");
    try manager.queueJob(job);

    const create_token = manager.dispatchNext().?;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationKind(create_token).?,
    );
    try manager.registerDirectoryPermission(create_token, .{
        .entry_id = root,
        .device_id = 12,
        .inode_id = 34,
        .mode = 0o750,
        .origin = .created,
    });
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const publication_token = manager.dispatchNext().?;
    try std.testing.expectEqual(publication, publication_token.operation_id);
    const second_publication_token = manager.dispatchNext().?;
    try std.testing.expectEqual(second_publication, second_publication_token.operation_id);
    try std.testing.expect(manager.completeWork(publication_token, .completed));

    const scan = manager.dispatchDiscovery().?;
    var batch: io_discovery.Batch = .{
        .allocator = std.testing.allocator,
        .complete = true,
    };
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));
    try std.testing.expectEqual(io_manager.JobState.running, manager.jobState(job).?);
    // The finalizer must wait for the other active operation as well as
    // discovery and publication registration.
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expect(manager.completeWork(second_publication_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.finalizing, manager.jobState(job).?);

    const finalizer_token = manager.dispatchNext().?;
    try std.testing.expectEqual(
        io_manager.OperationKind.finalize_directories,
        manager.operationKind(finalizer_token).?,
    );
    try std.testing.expect(manager.completeWork(finalizer_token, .failed));
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );
}

test "cancellation preserves directory permission records and cancels finalization" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "Photos", .directory, .{}, null);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try manager.registerDirectoryPermission(token, .{
        .entry_id = root,
        .device_id = 12,
        .inode_id = 34,
        .mode = 0o700,
        .origin = .created,
    });
    try std.testing.expect(manager.completeWork(token, .completed));
    try std.testing.expectEqual(io_manager.JobState.finalizing, manager.jobState(job).?);

    try manager.cancelJob(job);
    try std.testing.expectEqual(io_manager.JobState.cancelled, manager.jobState(job).?);
    try std.testing.expectEqual(
        @as(usize, 1),
        manager.directoryPermissionRecords(job).?.len,
    );
    try std.testing.expect(manager.dispatchNext() == null);
}

test "directory merge rejects non-directory conflicts without consuming the FIFO" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "Photos", .directory, .{}, null);
    const operation = try manager.addEntryOperation(job, root, .create_directory);
    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    const conflict_id = try manager.registerConflict(
        token,
        root,
        "/source/Photos",
        "/destination/Photos",
        .directory,
        .regular_file,
    );

    try std.testing.expectError(
        error.MergeRequiresDirectoryConflict,
        manager.mergeConflict(conflict_id),
    );
    try std.testing.expectEqual(conflict_id, manager.nextConflict().?.id);
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );
}

test "directory merge rejects a conflict not backed by directory creation" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "payload.txt", .regular_file, .{}, null);
    const operation = try manager.addEntryOperation(job, root, .move_entry);
    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    const conflict_id = try manager.registerConflict(
        token,
        root,
        "/source/payload.txt",
        "/destination/payload.txt",
        .directory,
        .directory,
    );

    try std.testing.expectError(
        error.MergeRequiresDirectoryOperation,
        manager.mergeConflict(conflict_id),
    );
    try std.testing.expectEqual(conflict_id, manager.nextConflict().?.id);
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );
}

test "replacing a regular-file conflict authorizes only its retried copy operation" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "payload.txt", .regular_file, .{}, null);
    const operation = try manager.addEntryOperation(job, root, .copy_file);
    try manager.queueJob(job);
    const first_token = manager.dispatchNext().?;
    const conflict_id = try manager.registerConflict(
        first_token,
        root,
        "/source/payload.txt",
        "/destination/payload.txt",
        .regular_file,
        .regular_file,
    );

    try manager.replaceConflict(conflict_id);
    try std.testing.expect(manager.nextConflict() == null);
    const retry_token = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, retry_token.operation_id);
    try std.testing.expect(retry_token.generation > first_token.generation);
    const details = manager.operationDetails(retry_token).?;
    try std.testing.expectEqual(io_manager.OperationKind.copy_file, details.kind);
    try std.testing.expect(details.replace_existing_file);
    try std.testing.expect(!details.merge_existing_directory);
    try std.testing.expect(manager.completeWork(retry_token, .completed));
}

test "file replacement accepts directory and rejects symlink destinations" {
    for ([_]io_tree.EntryKind{ .directory, .symlink }) |destination_kind| {
        var manager = io_manager.Manager.init(std.testing.allocator);
        defer manager.deinit();

        const job = try manager.createJob(null);
        const root = try manager.addTreeRoot(job, "payload.txt", .regular_file, .{}, null);
        const operation = try manager.addEntryOperation(job, root, .copy_file);
        try manager.queueJob(job);
        const token = manager.dispatchNext().?;
        const conflict_id = try manager.registerConflict(
            token,
            root,
            "/source/payload.txt",
            "/destination/payload.txt",
            .regular_file,
            destination_kind,
        );

        if (destination_kind == .directory) {
            try manager.replaceConflict(conflict_id);
            try std.testing.expect(manager.nextConflict() == null);
            const retry_token = manager.dispatchNext().?;
            try std.testing.expectEqual(operation, retry_token.operation_id);
            try std.testing.expect(manager.operationDetails(retry_token).?.replace_existing_file);
            try std.testing.expect(manager.completeWork(retry_token, .completed));
        } else {
            try std.testing.expectError(
                error.ReplaceRequiresRegularFileConflict,
                manager.replaceConflict(conflict_id),
            );
            try std.testing.expectEqual(conflict_id, manager.nextConflict().?.id);
            try std.testing.expectEqual(
                io_manager.OperationState.waiting,
                manager.operationState(job, operation).?,
            );
        }
    }
}

test "file replacement rejects conflicts not backed by a regular-file copy" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "payload.txt", .regular_file, .{}, null);
    const operation = try manager.addEntryOperation(job, root, .move_entry);
    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    const conflict_id = try manager.registerConflict(
        token,
        root,
        "/source/payload.txt",
        "/destination/payload.txt",
        .regular_file,
        .regular_file,
    );

    try std.testing.expectError(
        error.ReplaceRequiresFileCopyOperation,
        manager.replaceConflict(conflict_id),
    );
    try std.testing.expectEqual(conflict_id, manager.nextConflict().?.id);
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );
}

test "skipping a conflict advances the FIFO and skips its Operation" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(
        first_job,
        "first.txt",
        .regular_file,
        .{},
        null,
    );
    const first_operation = try manager.addEntryOperation(
        first_job,
        first_root,
        .copy_file,
    );
    try manager.queueJob(first_job);
    const first_token = manager.dispatchNext().?;
    const first_conflict = try manager.registerConflict(
        first_token,
        first_root,
        "/source/first.txt",
        "/destination/first.txt",
        .regular_file,
        .regular_file,
    );

    const second_job = try manager.createJob(null);
    const second_root = try manager.addTreeRoot(
        second_job,
        "second.txt",
        .regular_file,
        .{},
        null,
    );
    const second_operation = try manager.addEntryOperation(
        second_job,
        second_root,
        .copy_file,
    );
    try manager.queueJob(second_job);
    const second_token = manager.dispatchNext().?;
    const second_conflict = try manager.registerConflict(
        second_token,
        second_root,
        "/source/second.txt",
        "/destination/second.txt",
        .regular_file,
        .regular_file,
    );

    try manager.skipConflict(first_conflict);
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(first_job, first_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.JobState.completed,
        manager.jobState(first_job).?,
    );
    try std.testing.expect(manager.jobHasSkippedOperations(first_job));
    try std.testing.expectEqual(second_conflict, manager.nextConflict().?.id);
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(second_job, second_operation).?,
    );
}

test "skipping a directory conflict retires queued descendant discovery" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 1 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/source");
    try manager.setDestinationDirectory(job, "/destination");
    try manager.setDestinationDeviceId(job, 1);
    const root_create = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/source");
    try manager.queueJob(job);

    const root_scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var root_batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "nested", .kind = .directory, .device_id = 1 }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(root_scan, &root_batch));

    const tree = manager.treeIndex(job).?;
    const nested = tree.getConst(root).?.children.items[0];
    const nested_create = manager.entryOperationView(job, nested) orelse
        return error.MissingNestedCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationState.pending,
        nested_create.state,
    );

    const root_token = manager.dispatchNext() orelse return error.MissingRootOperation;
    try std.testing.expectEqual(root_create, root_token.operation_id);
    const conflict_id = try manager.registerConflict(
        root_token,
        root,
        "/source",
        "/destination/source",
        .directory,
        .directory,
    );

    try manager.skipConflict(conflict_id);

    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, root_create).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.entryOperationView(job, nested).?.state,
    );
    try std.testing.expectEqual(
        io_tree.DiscoveryState.skipped,
        tree.getConst(nested).?.discovery,
    );
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "skipping a directory conflict discards its in-flight discovery batch" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 1 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/source");
    try manager.setDestinationDirectory(job, "/destination");
    try manager.setDestinationDeviceId(job, 1);
    const root_create = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/source");
    try manager.queueJob(job);

    const root_scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    const root_token = manager.dispatchNext() orelse return error.MissingRootOperation;
    try std.testing.expectEqual(root_create, root_token.operation_id);
    const conflict_id = try manager.registerConflict(
        root_token,
        root,
        "/source",
        "/destination/source",
        .directory,
        .directory,
    );

    try manager.skipConflict(conflict_id);

    var late_batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{
            .{ .name = "late.txt", .kind = .regular_file, .device_id = 1 },
            .{ .name = "nested", .kind = .directory, .device_id = 1 },
        },
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(root_scan, &late_batch));

    try std.testing.expectEqual(@as(usize, 1), manager.treeIndex(job).?.count());
    try std.testing.expectEqual(
        io_tree.DiscoveryState.skipped,
        manager.treeIndex(job).?.getConst(root).?.discovery,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "skipping a directory conflict absorbs an in-flight discovery failure" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 1 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/source");
    try manager.setDestinationDirectory(job, "/destination");
    try manager.setDestinationDeviceId(job, 1);
    const root_create = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/source");
    try manager.queueJob(job);

    const root_scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    const root_token = manager.dispatchNext() orelse return error.MissingRootOperation;
    try std.testing.expectEqual(root_create, root_token.operation_id);
    const conflict_id = try manager.registerConflict(
        root_token,
        root,
        "/source",
        "/destination/source",
        .directory,
        .directory,
    );

    try manager.skipConflict(conflict_id);

    try std.testing.expect(manager.failDiscovery(root_scan));
    try std.testing.expectEqual(
        io_tree.DiscoveryState.skipped,
        manager.treeIndex(job).?.getConst(root).?.discovery,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "renaming a directory conflict redirects descendant destinations" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "Photos",
        .directory,
        .{},
        null,
    );
    const child = try manager.addTreeEntry(
        job,
        root,
        "2024",
        .directory,
        .{},
        null,
    );
    const root_operation = try manager.addEntryOperation(
        job,
        root,
        .create_directory,
    );
    _ = try manager.addEntryOperation(job, child, .create_directory);

    try manager.setSourceRootPath(job, "/source/Photos");
    try manager.setDestinationDirectory(job, "/destination");
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root_operation, token.operation_id);
    const conflict_id = try manager.registerConflict(
        token,
        root,
        "/source/Photos",
        "/destination/Photos",
        .directory,
        .directory,
    );

    try manager.renameConflict(conflict_id, "/destination/Photos (1)");

    const retry = manager.dispatchNext().?;
    try std.testing.expectEqual(root_operation, retry.operation_id);
    try std.testing.expect(retry.generation > token.generation);
    try std.testing.expect(manager.completeWork(retry, .completed));

    const child_source = try manager.sourcePath(allocator, job, child);
    defer allocator.free(child_source);
    const child_destination = try manager.destinationPath(allocator, job, child);
    defer allocator.free(child_destination);

    try std.testing.expectEqualStrings(
        "/source/Photos/2024",
        child_source,
    );
    try std.testing.expectEqualStrings(
        "/destination/Photos (1)/2024",
        child_destination,
    );
}

test "cancelling a Job prunes all its conflicts and preserves unrelated FIFO entries" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(
        first_job,
        "source",
        .directory,
        .{},
        null,
    );
    const first_entry = try manager.addTreeEntry(
        first_job,
        first_root,
        "first.txt",
        .regular_file,
        .{},
        null,
    );
    const third_entry = try manager.addTreeEntry(
        first_job,
        first_root,
        "third.txt",
        .regular_file,
        .{},
        null,
    );
    const fourth_entry = try manager.addTreeEntry(
        first_job,
        first_root,
        "fourth.txt",
        .regular_file,
        .{},
        null,
    );
    const root_operation = try manager.addEntryOperation(
        first_job,
        first_root,
        .create_directory,
    );
    const first_operation = try manager.addEntryOperation(
        first_job,
        first_entry,
        .copy_file,
    );
    const third_operation = try manager.addEntryOperation(
        first_job,
        third_entry,
        .copy_file,
    );
    const fourth_operation = try manager.addEntryOperation(
        first_job,
        fourth_entry,
        .copy_file,
    );
    try manager.queueJob(first_job);

    const root_token = manager.dispatchNext().?;
    try std.testing.expectEqual(root_operation, root_token.operation_id);
    try std.testing.expect(manager.completeWork(root_token, .completed));

    const second_job = try manager.createJob(null);
    const second_root = try manager.addTreeRoot(
        second_job,
        "second.txt",
        .regular_file,
        .{},
        null,
    );
    const second_operation = try manager.addEntryOperation(
        second_job,
        second_root,
        .copy_file,
    );
    try manager.queueJob(second_job);

    const first_token = manager.dispatchNext().?;
    try std.testing.expectEqual(first_operation, first_token.operation_id);
    const first_conflict = try manager.registerConflict(
        first_token,
        first_entry,
        "/source/first.txt",
        "/destination/first.txt",
        .regular_file,
        .regular_file,
    );

    const unrelated_token = manager.dispatchNext().?;
    try std.testing.expectEqual(second_operation, unrelated_token.operation_id);
    const unrelated_conflict = try manager.registerConflict(
        unrelated_token,
        second_root,
        "/source/second.txt",
        "/destination/second.txt",
        .regular_file,
        .regular_file,
    );

    const third_token = manager.dispatchNext().?;
    try std.testing.expectEqual(third_operation, third_token.operation_id);
    _ = try manager.registerConflict(
        third_token,
        third_entry,
        "/source/third.txt",
        "/destination/third.txt",
        .regular_file,
        .regular_file,
    );

    try std.testing.expectEqual(first_conflict, manager.nextConflict().?.id);

    try manager.cancelConflict(first_conflict);

    try std.testing.expectEqual(
        io_manager.JobState.cancelled,
        manager.jobState(first_job).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.cancelled,
        manager.operationState(first_job, first_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.cancelled,
        manager.operationState(first_job, third_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.cancelled,
        manager.operationState(first_job, fourth_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(first_job, root_operation).?,
    );
    try std.testing.expectEqual(unrelated_conflict, manager.nextConflict().?.id);
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(second_job, second_operation).?,
    );
    try manager.resolveConflict(unrelated_conflict);
    try std.testing.expect(manager.nextConflict() == null);
    try std.testing.expectEqual(
        io_manager.OperationState.pending,
        manager.operationState(second_job, second_operation).?,
    );
}

test "failed dependencies skip descendants" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const parent = try manager.addOperation(job, .copy_file);
    const child = try manager.addOperation(job, .publish);
    try manager.addDependency(job, child, parent);
    try manager.queueJob(job);
    const token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(token, .failed));
    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, child).?);
    try std.testing.expectEqual(io_manager.JobState.failed, manager.jobState(job).?);
}

test "dependency cycles are rejected before queueing" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const first = try manager.addOperation(job, .copy_file);
    const second = try manager.addOperation(job, .publish);
    try manager.addDependency(job, first, second);
    try manager.addDependency(job, second, first);
    try std.testing.expectError(error.DependencyCycle, manager.queueJob(job));
    try std.testing.expectEqual(io_manager.JobState.planning, manager.jobState(job).?);
}

test "pause prevents dispatch and resume restores eligible work" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);
    try manager.pauseJob(job);
    try std.testing.expect(manager.dispatchNext() == null);
    try manager.resumeJob(job);
    try std.testing.expect(manager.dispatchNext() != null);
}

test "pause stops dispatch and waits for every active operation to return" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const first = try manager.addOperation(job, .copy_file);
    const second = try manager.addOperation(job, .copy_file);
    const third = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);

    const first_token = manager.dispatchNext().?;
    const second_token = manager.dispatchNext().?;
    try manager.pauseJob(job);
    try std.testing.expectEqual(io_manager.JobState.running, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expect(manager.completeWork(first_token, .yielded));
    try std.testing.expectEqual(io_manager.JobState.running, manager.jobState(job).?);
    try std.testing.expectEqual(io_manager.OperationState.pending, manager.operationState(job, first).?);
    try std.testing.expect(manager.operationState(job, second).? == .running);
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expect(manager.completeWork(second_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.paused, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);

    try manager.resumeJob(job);
    const resumed = manager.dispatchNext().?;
    try std.testing.expectEqual(first, resumed.operation_id);
    try std.testing.expect(manager.completeWork(resumed, .completed));
    const next = manager.dispatchNext().?;
    try std.testing.expectEqual(third, next.operation_id);
}

test "cancellation waits for every active operation to return" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const active = try manager.addOperation(job, .copy_file);
    const second_active = try manager.addOperation(job, .copy_file);
    const pending = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    const second_token = manager.dispatchNext().?;
    try manager.cancelJob(job);
    try std.testing.expectEqual(io_manager.JobState.running, manager.jobState(job).?);
    try std.testing.expectEqual(io_manager.OperationState.cancelled, manager.operationState(job, pending).?);
    try std.testing.expect(manager.completeWork(token, .yielded));
    try std.testing.expectEqual(io_manager.JobState.running, manager.jobState(job).?);
    try std.testing.expectEqual(io_manager.OperationState.cancelled, manager.operationState(job, active).?);
    try std.testing.expectEqual(io_manager.OperationState.running, manager.operationState(job, second_active).?);
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expect(manager.completeWork(second_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.cancelled, manager.jobState(job).?);
    try std.testing.expectEqual(io_manager.OperationState.completed, manager.operationState(job, second_active).?);
    try std.testing.expect(manager.dispatchNext() == null);
}

test "cancelling a cross-filesystem directory move before source detach preserves the source" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 30);

    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "payload.bin", .kind = .regular_file, .device_id = 10 }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const child = manager.treeIndex(job).?.getConst(root).?.children.items[0];
    const child_detach = manager.sourceDetachOperationState(job, child) orelse
        return error.MissingChildDetachOperation;
    try std.testing.expectEqual(io_manager.OperationState.pending, child_detach);

    const create_token = manager.dispatchNext() orelse
        return error.MissingRootCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const copy_token = manager.dispatchNext() orelse
        return error.MissingChildCopyOperation;
    try std.testing.expectEqual(child, manager.operationDetails(copy_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.copy_file,
        manager.operationDetails(copy_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(copy_token, .completed));
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.entryOperationView(job, child).?.state,
    );

    // Publication has completed, but cancellation wins before the dependent
    // source detach can be dispatched.
    try manager.cancelJob(job);

    try std.testing.expectEqual(io_manager.JobState.cancelled, manager.jobState(job).?);
    try std.testing.expectEqual(
        io_manager.OperationState.cancelled,
        manager.sourceDetachOperationState(job, child).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.cancelled,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "cancelling during cross-filesystem source detach finishes only that bounded operation" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 30);

    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "payload.bin", .kind = .regular_file, .device_id = 10 }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const child = manager.treeIndex(job).?.getConst(root).?.children.items[0];

    const create_token = manager.dispatchNext() orelse
        return error.MissingRootCreateOperation;
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const copy_token = manager.dispatchNext() orelse
        return error.MissingChildCopyOperation;
    try std.testing.expectEqual(child, manager.operationDetails(copy_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.copy_file,
        manager.operationDetails(copy_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(copy_token, .completed));

    const detach_token = manager.dispatchNext() orelse
        return error.MissingChildDetachOperation;
    try std.testing.expectEqual(child, manager.operationDetails(detach_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.detach_source,
        manager.operationDetails(detach_token).?.kind,
    );

    // unlinkat is atomic and cannot be interrupted halfway through. The
    // active detach may finish, but cancellation must prevent parent removal.
    try manager.cancelJob(job);
    try std.testing.expectEqual(io_manager.JobState.running, manager.jobState(job).?);
    try std.testing.expect(manager.completeWork(detach_token, .completed));

    try std.testing.expectEqual(io_manager.JobState.cancelled, manager.jobState(job).?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.sourceDetachOperationState(job, child).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.cancelled,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expect(manager.dispatchNext() == null);
}

test "failed cross-filesystem source detach preserves the parent directory" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 30);

    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "payload.bin", .kind = .regular_file, .device_id = 10 }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const child = manager.treeIndex(job).?.getConst(root).?.children.items[0];
    const child_detach = manager.sourceDetachOperationState(job, child) orelse
        return error.MissingChildDetachOperation;

    try std.testing.expectEqual(io_manager.OperationState.pending, child_detach);

    const create_token = manager.dispatchNext() orelse
        return error.MissingRootCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const copy_token = manager.dispatchNext() orelse
        return error.MissingChildCopyOperation;
    try std.testing.expectEqual(child, manager.operationDetails(copy_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.copy_file,
        manager.operationDetails(copy_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(copy_token, .completed));

    const detach_token = manager.dispatchNext() orelse
        return error.MissingChildDetachOperation;
    try std.testing.expectEqual(child, manager.operationDetails(detach_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.detach_source,
        manager.operationDetails(detach_token).?.kind,
    );

    // The destination copy is published, but removing the source fails.
    try std.testing.expect(manager.completeWork(detach_token, .failed));

    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.entryOperationView(job, child).?.state,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.sourceDetachOperationState(job, child).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "entry operation progress is accepted only for its current yielded generation" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const entry = try manager.addTreeRoot(
        job,
        "large.bin",
        .regular_file,
        .{ .size = 100_000 },
        null,
    );
    _ = try manager.addEntryOperation(job, entry, .copy_file);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(token, .yielded));
    try std.testing.expect(manager.recordOperationProgress(
        token,
        65_536,
        100_000,
        .transferring,
    ));
    const view = manager.entryOperationView(job, entry).?;
    try std.testing.expectEqual(@as(u64, 65_536), view.progress_bytes);
    try std.testing.expectEqual(@as(u64, 100_000), view.progress_total_bytes);

    const next = manager.dispatchNext().?;
    try std.testing.expect(!manager.recordOperationProgress(
        token,
        90_000,
        100_000,
        .transferring,
    ));
    try std.testing.expect(manager.completeWork(next, .completed));
    const completed = manager.entryOperationView(job, entry).?;
    try std.testing.expectEqual(@as(u64, 100_000), completed.progress_bytes);
}

test "snapshots own dependency data and planning closes at queue time" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(42);
    const first = try manager.addOperation(job, .create_directory);
    const second = try manager.addOperation(job, .copy_file);
    try manager.addDependency(job, second, first);
    try manager.queueJob(job);

    var snapshot = try manager.snapshotJob(std.testing.allocator, job);
    defer snapshot.deinit();
    try std.testing.expectEqual(job, snapshot.id);
    try std.testing.expectEqual(@as(?io_manager.WindowId, 42), snapshot.origin_window_id);
    try std.testing.expectEqual(@as(usize, 2), snapshot.operations.len);
    try std.testing.expectEqual(first, snapshot.operations[1].dependencies[0]);
    try std.testing.expectError(error.InvalidJobState, manager.addOperation(job, .publish));
}

test "job snapshots expose progress and snapshotJobs lists independent live jobs" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(17);
    const entry = try manager.addTreeRoot(
        first_job,
        "large.bin",
        .regular_file,
        .{ .size = 100_000 },
        null,
    );
    _ = try manager.addEntryOperation(first_job, entry, .copy_file);
    try manager.queueJob(first_job);

    const token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(token, .yielded));
    try std.testing.expect(manager.recordOperationProgress(
        token,
        65_536,
        100_000,
        .transferring,
    ));

    const second_job = try manager.createJob(29);

    const snapshots = try manager.snapshotJobs(allocator);
    defer {
        for (snapshots) |*snapshot| snapshot.deinit();
        allocator.free(snapshots);
    }

    try std.testing.expectEqual(@as(usize, 2), snapshots.len);
    try std.testing.expectEqual(first_job, snapshots[0].id);
    try std.testing.expectEqual(@as(?io_manager.WindowId, 17), snapshots[0].origin_window_id);
    try std.testing.expectEqual(second_job, snapshots[1].id);
    try std.testing.expectEqual(@as(?io_manager.WindowId, 29), snapshots[1].origin_window_id);

    try std.testing.expectEqual(@as(usize, 1), snapshots[0].operations.len);
    const operation = snapshots[0].operations[0];
    try std.testing.expectEqual(@as(u64, 65_536), operation.progress_bytes);
    try std.testing.expectEqual(@as(u64, 100_000), operation.progress_total_bytes);
    try std.testing.expectEqual(io_manager.CopyPhase.transferring, operation.copy_phase);

    // Snapshot storage remains valid after the live Manager changes.
    const resumed_token = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(resumed_token, .completed));
    try std.testing.expectEqual(@as(u64, 65_536), snapshots[0].operations[0].progress_bytes);
}

test "queued Jobs accept operations as discovery progresses" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job).?);
    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    try std.testing.expectEqual(io_manager.OperationState.pending, manager.operationState(job, root_op).?);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .completed));
}

test "directory move detach waits for discovery and every descendant move" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{ .device_id = 1 }, null);
    try manager.setSourceRootPath(job, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 1);
    const root_create = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const root_scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var root_batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{
            .{ .name = "top.txt", .kind = .regular_file, .device_id = 1 },
            .{ .name = "nested", .kind = .directory, .device_id = 1 },
        },
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(root_scan, &root_batch));

    const nested_scan = manager.dispatchDiscovery() orelse return error.MissingNestedScan;
    const tree = manager.treeIndex(job).?;
    var nested_id: ?io_tree.EntryId = null;
    for (tree.getConst(root).?.children.items) |child_id| {
        if (std.mem.eql(u8, tree.getConst(child_id).?.name, "nested"))
            nested_id = child_id;
    }
    const nested = nested_id orelse return error.MissingNestedEntry;
    try std.testing.expectEqual(nested, nested_scan.entry_id);

    var nested_batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "deep.txt", .kind = .regular_file, .device_id = 1 }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(nested_scan, &nested_batch));
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);

    var dispatched: [6]io_manager.OperationDetails = undefined;
    var dispatched_count: usize = 0;
    while (manager.dispatchNext()) |token| {
        dispatched[dispatched_count] = manager.operationDetails(token).?;
        dispatched_count += 1;
        try std.testing.expect(manager.completeWork(token, .completed));
    }

    try std.testing.expectEqual(@as(usize, 6), dispatched_count);
    try std.testing.expectEqual(io_manager.OperationKind.create_directory, dispatched[0].kind);
    try std.testing.expectEqual(root, dispatched[0].entry_id);

    var top_move_position: ?usize = null;
    var nested_move_position: ?usize = null;
    var nested_detach_position: ?usize = null;
    var root_detach_position: ?usize = null;
    for (dispatched[0..dispatched_count], 0..) |details, index| {
        switch (details.kind) {
            .move_entry => {
                const entry = tree.getConst(details.entry_id).?;
                if (std.mem.eql(u8, entry.name, "top.txt"))
                    top_move_position = index;
                if (std.mem.eql(u8, entry.name, "deep.txt"))
                    nested_move_position = index;
            },
            .detach_source => {
                if (details.entry_id == nested)
                    nested_detach_position = index;
                if (details.entry_id == root)
                    root_detach_position = index;
            },
            else => {},
        }
    }

    try std.testing.expect(top_move_position != null);
    try std.testing.expect(nested_move_position != null);
    try std.testing.expect(nested_detach_position != null);
    try std.testing.expect(root_detach_position != null);
    try std.testing.expect(nested_detach_position.? > nested_move_position.?);
    try std.testing.expect(root_detach_position.? > top_move_position.?);
    try std.testing.expect(root_detach_position.? > nested_detach_position.?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expect(root_create != root_detach);
}

test "failed descendant move prevents source directory detach" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{ .device_id = 1 }, null);
    try manager.setSourceRootPath(job, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 1);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "blocked.txt", .kind = .regular_file, .device_id = 1 }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const move_token = manager.dispatchNext() orelse return error.MissingMoveOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.move_entry,
        manager.operationDetails(move_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(move_token, .failed));

    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(io_manager.JobState.completed_with_errors, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
}

test "failed directory discovery prevents source directory detach" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 1);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    try std.testing.expect(manager.failDiscovery(scan));
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, root_detach).?,
    );
    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed_with_errors, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
}

test "empty source directory releases its detach discovery gate" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{ .device_id = 1 }, null);
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(std.testing.allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const detach_token = manager.dispatchNext() orelse return error.MissingDetachOperation;
    try std.testing.expectEqual(root_detach, detach_token.operation_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.detach_source,
        manager.operationDetails(detach_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(detach_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "partial discovery batch keeps source directory detach gated" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{ .device_id = 1 }, null);
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 1);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const first_scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var first_batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "early.txt", .kind = .regular_file, .device_id = 1 }},
        false,
    );
    try std.testing.expect(try manager.completeDiscovery(first_scan, &first_batch));

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const move_token = manager.dispatchNext() orelse return error.MissingMoveOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.move_entry,
        manager.operationDetails(move_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(move_token, .completed));

    try std.testing.expectEqual(
        io_manager.OperationState.pending,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expect(manager.dispatchNext() == null);

    const final_scan = manager.dispatchDiscovery() orelse return error.MissingFinalScan;
    try std.testing.expectEqual(root, final_scan.entry_id);
    var final_batch = try makeDiscoveryBatch(std.testing.allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(final_scan, &final_batch));

    const detach_token = manager.dispatchNext() orelse return error.MissingDetachOperation;
    try std.testing.expectEqual(root_detach, detach_token.operation_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.detach_source,
        manager.operationDetails(detach_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(detach_token, .completed));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "directory move routes regular files by destination filesystem" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 20);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{
            .{ .name = "same-device.txt", .kind = .regular_file, .device_id = 20 },
            .{ .name = "cross-device.txt", .kind = .regular_file, .device_id = 10 },
        },
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    var same_move_seen = false;
    var cross_copy_seen = false;
    var cross_detach_seen = false;
    while (manager.dispatchNext()) |token| {
        const details = manager.operationDetails(token).?;
        if (details.entry_id == root) {
            try std.testing.expectEqual(io_manager.OperationKind.detach_source, details.kind);
            try std.testing.expect(cross_detach_seen);
            try std.testing.expect(manager.completeWork(token, .completed));
            break;
        }

        const entry = manager.treeIndex(job).?.getConst(details.entry_id).?;
        if (std.mem.eql(u8, entry.name, "same-device.txt")) {
            try std.testing.expectEqual(io_manager.OperationKind.move_entry, details.kind);
            same_move_seen = true;
        } else if (std.mem.eql(u8, entry.name, "cross-device.txt")) {
            switch (details.kind) {
                .copy_file => cross_copy_seen = true,
                .detach_source => {
                    try std.testing.expect(cross_copy_seen);
                    cross_detach_seen = true;
                },
                else => return error.UnexpectedCrossDeviceOperation,
            }
        } else {
            return error.UnexpectedOperation;
        }
        try std.testing.expect(manager.completeWork(token, .completed));
    }

    try std.testing.expect(same_move_seen);
    try std.testing.expect(cross_copy_seen);
    try std.testing.expect(cross_detach_seen);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "directory move routes symlinks by destination filesystem" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 20);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{
            .{
                .name = "same-device-link",
                .kind = .symlink,
                .device_id = 20,
                .symlink_target = "../same-target",
            },
            .{
                .name = "cross-device-link",
                .kind = .symlink,
                .device_id = 10,
                .symlink_target = "../cross-target",
            },
        },
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const tree = manager.treeIndex(job).?;
    const children = tree.getConst(root).?.children.items;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings(
        "../same-target",
        tree.getConst(children[0]).?.symlink_target.?,
    );
    try std.testing.expectEqualStrings(
        "../cross-target",
        tree.getConst(children[1]).?.symlink_target.?,
    );

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    var same_move_seen = false;
    var cross_copy_seen = false;
    var cross_detach_seen = false;
    while (manager.dispatchNext()) |token| {
        const details = manager.operationDetails(token).?;
        if (details.entry_id == root) {
            try std.testing.expectEqual(io_manager.OperationKind.detach_source, details.kind);
            try std.testing.expect(cross_detach_seen);
            try std.testing.expect(manager.completeWork(token, .completed));
            break;
        }

        const entry = tree.getConst(details.entry_id).?;
        if (std.mem.eql(u8, entry.name, "same-device-link")) {
            try std.testing.expectEqual(io_manager.OperationKind.move_entry, details.kind);
            same_move_seen = true;
        } else if (std.mem.eql(u8, entry.name, "cross-device-link")) {
            switch (details.kind) {
                .copy_symlink => cross_copy_seen = true,
                .detach_source => {
                    try std.testing.expect(cross_copy_seen);
                    cross_detach_seen = true;
                },
                else => return error.UnexpectedCrossDeviceOperation,
            }
        } else {
            return error.UnexpectedOperation;
        }
        try std.testing.expect(manager.completeWork(token, .completed));
    }

    try std.testing.expect(same_move_seen);
    try std.testing.expect(cross_copy_seen);
    try std.testing.expect(cross_detach_seen);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "directory move fails closed when symlink device identity is missing" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 20);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{
            .name = "unknown-device-link",
            .kind = .symlink,
            .device_id = null,
            .symlink_target = "literal-target",
        }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, root_detach).?,
    );

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );
}

test "directory move fails closed when regular-file device identity is missing" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 20);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "unknown-device.txt", .kind = .regular_file, .device_id = null }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, root_detach).?,
    );

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );
}

test "directory move preserves nested filesystem boundaries and continues siblings" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 10);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{
            .{ .name = "mounted", .kind = .directory, .device_id = 20 },
            .{ .name = "sibling.txt", .kind = .regular_file, .device_id = 10 },
        },
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const tree = manager.treeIndex(job).?;
    const children = tree.getConst(root).?.children.items;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqual(
        io_tree.DiscoveryState.skipped,
        tree.getConst(children[0]).?.discovery,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expect(manager.dispatchDiscovery() == null);

    const create_token = manager.dispatchNext() orelse return error.MissingCreateOperation;
    try std.testing.expectEqual(root, manager.operationDetails(create_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(create_token, .completed));

    const sibling_token = manager.dispatchNext() orelse return error.MissingSiblingMove;
    try std.testing.expectEqual(children[1], manager.operationDetails(sibling_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.move_entry,
        manager.operationDetails(sibling_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(sibling_token, .completed));
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expectEqual(io_manager.JobState.completed_with_errors, manager.jobState(job).?);
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, root_detach).?,
    );
}

test "cross-filesystem directory move propagates nested mount boundary failures" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    try manager.setDestinationDeviceId(job, 30);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    _ = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const root_scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var root_batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{
            .{ .name = "nested", .kind = .directory, .device_id = 10 },
            .{ .name = "root-sibling.txt", .kind = .regular_file, .device_id = 10 },
        },
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(root_scan, &root_batch));

    const tree = manager.treeIndex(job).?;
    const root_children = tree.getConst(root).?.children.items;
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    const nested = root_children[0];
    const root_sibling = root_children[1];
    const nested_create = manager.entryOperationView(job, nested) orelse
        return error.MissingNestedDirectoryOperation;
    try std.testing.expectEqual(io_manager.OperationState.pending, nested_create.state);

    const root_create_token = manager.dispatchNext() orelse
        return error.MissingRootCreateOperation;
    try std.testing.expectEqual(root, manager.operationDetails(root_create_token).?.entry_id);
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(root_create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(root_create_token, .completed));

    const nested_create_token = manager.dispatchNext() orelse
        return error.MissingNestedCreateOperation;
    try std.testing.expectEqual(
        nested,
        manager.operationDetails(nested_create_token).?.entry_id,
    );
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(nested_create_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(nested_create_token, .completed));

    const root_copy_token = manager.dispatchNext() orelse
        return error.MissingRootSiblingCopy;
    try std.testing.expectEqual(
        root_sibling,
        manager.operationDetails(root_copy_token).?.entry_id,
    );
    try std.testing.expectEqual(
        io_manager.OperationKind.copy_file,
        manager.operationDetails(root_copy_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(root_copy_token, .completed));

    const root_sibling_detach = manager.sourceDetachOperationState(job, root_sibling) orelse
        return error.MissingRootSiblingDetach;
    try std.testing.expectEqual(io_manager.OperationState.pending, root_sibling_detach);
    const root_detach_token = manager.dispatchNext() orelse
        return error.MissingRootSiblingDetachOperation;
    try std.testing.expectEqual(
        root_sibling,
        manager.operationDetails(root_detach_token).?.entry_id,
    );
    try std.testing.expectEqual(
        io_manager.OperationKind.detach_source,
        manager.operationDetails(root_detach_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(root_detach_token, .completed));
    try std.testing.expect(manager.dispatchNext() == null);

    const nested_scan = manager.dispatchDiscovery() orelse
        return error.MissingNestedScan;
    try std.testing.expectEqual(nested, nested_scan.entry_id);
    var nested_batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{
            .{ .name = "mounted", .kind = .directory, .device_id = 20 },
            .{ .name = "nested-sibling.txt", .kind = .regular_file, .device_id = 10 },
        },
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(nested_scan, &nested_batch));

    const nested_children = tree.getConst(nested).?.children.items;
    try std.testing.expectEqual(@as(usize, 2), nested_children.len);
    const mounted = nested_children[0];
    const nested_sibling = nested_children[1];
    try std.testing.expectEqual(
        io_tree.DiscoveryState.skipped,
        tree.getConst(mounted).?.discovery,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.sourceDetachOperationState(job, nested).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.sourceDetachOperationState(job, root).?,
    );
    try std.testing.expect(manager.dispatchDiscovery() == null);

    const nested_copy_token = manager.dispatchNext() orelse
        return error.MissingNestedSiblingCopy;
    try std.testing.expectEqual(
        nested_sibling,
        manager.operationDetails(nested_copy_token).?.entry_id,
    );
    try std.testing.expectEqual(
        io_manager.OperationKind.copy_file,
        manager.operationDetails(nested_copy_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(nested_copy_token, .completed));

    const nested_detach_token = manager.dispatchNext() orelse
        return error.MissingNestedSiblingDetach;
    try std.testing.expectEqual(
        nested_sibling,
        manager.operationDetails(nested_detach_token).?.entry_id,
    );
    try std.testing.expectEqual(
        io_manager.OperationKind.detach_source,
        manager.operationDetails(nested_detach_token).?.kind,
    );
    try std.testing.expect(manager.completeWork(nested_detach_token, .completed));

    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.sourceDetachOperationState(job, root_sibling).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.sourceDetachOperationState(job, nested_sibling).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.sourceDetachOperationState(job, nested).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.sourceDetachOperationState(job, root).?,
    );
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );
}

test "directory move fails closed when child device identity is missing" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .device_id = 10 },
        null,
    );
    try manager.setRootSourcePath(job, root, "/tmp/source");
    try manager.setDestinationDirectory(job, "/tmp/destination");
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch = try makeDiscoveryBatch(
        std.testing.allocator,
        &.{.{ .name = "unknown-device", .kind = .directory, .device_id = null }},
        true,
    );
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    const tree = manager.treeIndex(job).?;
    const child = tree.getConst(root).?.children.items[0];
    try std.testing.expectEqual(
        io_tree.DiscoveryState.skipped,
        tree.getConst(child).?.discovery,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, root_detach).?,
    );
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "file and symlink source detach waits for successful copy publication" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const file = try manager.addTreeRoot(job, "file", .regular_file, .{}, null);
    const link = try manager.addTreeRoot(job, "link", .symlink, .{}, "../target");
    try manager.setRootSourcePath(job, file, "/tmp/source/file");
    try manager.setRootSourcePath(job, link, "/tmp/source/link");
    try manager.setDestinationDirectory(job, "/tmp/destination");

    const file_copy = try manager.addEntryOperation(job, file, .copy_file);
    const file_detach = try manager.addEntryOperation(job, file, .detach_source);
    const link_copy = try manager.addEntryOperation(job, link, .copy_symlink);
    const link_detach = try manager.addEntryOperation(job, link, .detach_source);
    try manager.queueJob(job);

    var positions = [_]?usize{ null, null, null, null };
    var dispatch_index: usize = 0;
    while (manager.dispatchNext()) |token| {
        const details = manager.operationDetails(token).?;
        var position: usize = undefined;
        if (token.operation_id == file_copy) {
            position = 0;
        } else if (token.operation_id == file_detach) {
            position = 1;
        } else if (token.operation_id == link_copy) {
            position = 2;
        } else if (token.operation_id == link_detach) {
            position = 3;
        } else {
            return error.UnexpectedOperation;
        }

        positions[position] = dispatch_index;
        dispatch_index += 1;
        try std.testing.expectEqual(
            if (position < 2) file else link,
            details.entry_id,
        );
        try std.testing.expect(manager.completeWork(token, .completed));
    }

    try std.testing.expectEqual(@as(usize, 4), dispatch_index);
    try std.testing.expect(positions[0].? < positions[1].?);
    try std.testing.expect(positions[2].? < positions[3].?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, file_detach).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, link_detach).?,
    );
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "failed or skipped cross-filesystem copies prevent source detach" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const file = try manager.addTreeRoot(job, "file", .regular_file, .{}, null);
    const link = try manager.addTreeRoot(job, "link", .symlink, .{}, "../target");
    try manager.setRootSourcePath(job, file, "/tmp/source/file");
    try manager.setRootSourcePath(job, link, "/tmp/source/link");
    try manager.setDestinationDirectory(job, "/tmp/destination");

    const file_copy = try manager.addEntryOperation(job, file, .copy_file);
    const file_detach = try manager.addEntryOperation(job, file, .detach_source);
    const link_copy = try manager.addEntryOperation(job, link, .copy_symlink);
    const link_detach = try manager.addEntryOperation(job, link, .detach_source);
    try manager.queueJob(job);

    var file_seen = false;
    var link_seen = false;
    while (manager.dispatchNext()) |token| {
        if (token.operation_id == file_copy) {
            file_seen = true;
            try std.testing.expect(manager.completeWork(token, .failed));
        } else if (token.operation_id == link_copy) {
            link_seen = true;
            try std.testing.expect(manager.completeWork(token, .skipped));
        } else {
            return error.UnexpectedOperation;
        }
    }
    try std.testing.expect(file_seen);
    try std.testing.expect(link_seen);
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, file_detach).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, link_detach).?,
    );
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expectEqual(io_manager.JobState.failed, manager.jobState(job).?);
}

test "population accounting survives yields and waiting retries" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "file", .regular_file, .{}, null);
    const operation = try manager.addEntryOperation(job, root, .copy_file);

    try std.testing.expectEqual(
        @as(?bool, false),
        manager.populationComplete(job),
    );
    try manager.queueJob(job);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .yielded));
    try std.testing.expectEqual(
        @as(?bool, false),
        manager.populationComplete(job),
    );

    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .waiting));
    try std.testing.expectEqual(
        @as(?bool, false),
        manager.populationComplete(job),
    );

    try manager.resolveWaiting(job, operation);
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(operation, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    try std.testing.expectEqual(
        @as(?bool, true),
        manager.populationComplete(job),
    );
}

test "population accounting retires failed and dependency-skipped entries" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    const child = try manager.addTreeEntry(
        job,
        root,
        "child",
        .regular_file,
        .{},
        null,
    );
    const root_operation = try manager.addEntryOperation(
        job,
        root,
        .create_directory,
    );
    const child_operation = try manager.addEntryOperation(
        job,
        child,
        .copy_file,
    );

    try std.testing.expectEqual(
        @as(?bool, false),
        manager.populationComplete(job),
    );
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root_operation, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .failed));

    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, child_operation).?,
    );
    try std.testing.expectEqual(
        @as(?bool, true),
        manager.populationComplete(job),
    );
    try std.testing.expectEqual(
        io_manager.JobState.failed,
        manager.jobState(job).?,
    );
}

test "entry operations depend on their destination parent directory" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    const child = try manager.addTreeEntry(job, root, "child", .directory, .{}, null);
    const file = try manager.addTreeEntry(job, child, "file", .regular_file, .{}, null);

    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    const child_op = try manager.addEntryOperation(job, child, .create_directory);
    const file_op = try manager.addEntryOperation(job, file, .copy_file);
    try manager.queueJob(job);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .completed));

    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(child_op, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));

    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(file_op, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
}

test "late entries inherit skipped state from failed destination parents" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    const child = try manager.addTreeEntry(job, root, "child", .directory, .{}, null);
    const file = try manager.addTreeEntry(job, child, "file", .regular_file, .{}, null);

    _ = try manager.startDiscovery(job, "/tmp/source");
    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .failed));

    const child_op = try manager.addEntryOperation(job, child, .create_directory);
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, child_op).?,
    );

    const file_op = try manager.addEntryOperation(job, file, .copy_file);
    try std.testing.expectEqual(
        io_manager.OperationState.skipped,
        manager.operationState(job, file_op).?,
    );
}

test "multi-root Jobs retain independent source and destination paths" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(
        job,
        "first",
        .directory,
        .{},
        null,
    );
    const first_child = try manager.addTreeEntry(
        job,
        first_root,
        "nested.txt",
        .regular_file,
        .{},
        null,
    );
    const second_root = try manager.addTreeRoot(
        job,
        "second",
        .directory,
        .{},
        null,
    );

    try manager.startRootDiscovery(job, first_root, "/tmp/first-source");
    try manager.startRootDiscovery(job, second_root, "/tmp/second-source");
    try manager.setDestinationDirectory(job, "/tmp/destination");

    const first_source = try manager.sourcePath(
        allocator,
        job,
        first_child,
    );
    defer allocator.free(first_source);
    const second_source = try manager.sourcePath(
        allocator,
        job,
        second_root,
    );
    defer allocator.free(second_source);
    const first_destination = try manager.destinationPath(
        allocator,
        job,
        first_child,
    );
    defer allocator.free(first_destination);
    const second_destination = try manager.destinationPath(
        allocator,
        job,
        second_root,
    );
    defer allocator.free(second_destination);

    try std.testing.expectEqualStrings(
        "/tmp/first-source/nested.txt",
        first_source,
    );
    try std.testing.expectEqualStrings(
        "/tmp/second-source",
        second_source,
    );
    try std.testing.expectEqualStrings(
        "/tmp/destination/first/nested.txt",
        first_destination,
    );
    try std.testing.expectEqualStrings(
        "/tmp/destination/second",
        second_destination,
    );
    try std.testing.expectEqualStrings(
        "/tmp/first-source",
        manager.discoveryRootPath(job, first_root).?,
    );
    try std.testing.expectEqualStrings(
        "/tmp/second-source",
        manager.discoveryRootPath(job, second_root).?,
    );
    try std.testing.expectEqual(@as(?bool, false), manager.discoveryComplete(job));
}

test "directory creation outranks symlinks and regular files" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    const file = try manager.addTreeEntry(job, root, "file", .regular_file, .{}, null);
    const link = try manager.addTreeEntry(job, root, "link", .symlink, .{}, "target");
    const directory = try manager.addTreeEntry(job, root, "directory", .directory, .{}, null);

    const root_op = try manager.addEntryOperation(job, root, .create_directory);
    const file_op = try manager.addEntryOperation(job, file, .copy_file);
    const link_op = try manager.addEntryOperation(job, link, .copy_symlink);
    const directory_op = try manager.addEntryOperation(job, directory, .create_directory);
    try manager.queueJob(job);

    const first = manager.dispatchNext().?;
    try std.testing.expectEqual(root_op, first.operation_id);
    try std.testing.expect(manager.completeWork(first, .completed));
    const second = manager.dispatchNext().?;
    try std.testing.expectEqual(directory_op, second.operation_id);
    try std.testing.expect(manager.completeWork(second, .completed));
    const third = manager.dispatchNext().?;
    try std.testing.expectEqual(link_op, third.operation_id);
    try std.testing.expect(manager.completeWork(third, .completed));
    const fourth = manager.dispatchNext().?;
    try std.testing.expectEqual(file_op, fourth.operation_id);
    try std.testing.expect(manager.completeWork(fourth, .completed));
}

test "Job remains active while discovery has pending work and no operations" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job).?);
}

test "Manager owns an independent TreeIndex for each Job" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(null);
    const second_job = try manager.createJob(null);
    const root_id = try manager.addTreeRoot(first_job, "source", .directory, .{}, null);
    const child_id = try manager.addTreeEntry(first_job, root_id, "child", .regular_file, .{ .size = 42 }, null);
    const second_root = try manager.addTreeRoot(second_job, "other", .directory, .{}, null);

    const first_tree = manager.treeIndex(first_job).?;
    const second_tree = manager.treeIndex(second_job).?;
    try std.testing.expectEqual(@as(usize, 2), first_tree.count());
    try std.testing.expectEqual(@as(usize, 1), second_tree.count());
    try std.testing.expectEqual(child_id, first_tree.getConst(child_id).?.id);
    try std.testing.expectEqual(second_root, second_tree.root().?);
    try std.testing.expectEqualStrings("source", first_tree.getConst(root_id).?.name);
    try std.testing.expectEqualStrings("other", second_tree.getConst(second_root).?.name);

    _ = try manager.addTreeEntry(first_job, root_id, "another-child", .regular_file, .{}, null);
    try std.testing.expectEqual(@as(usize, 3), first_tree.count());
    try std.testing.expectEqual(@as(usize, 1), second_tree.count());
}

test "destination paths are built from Job-owned directories and EntryIds" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const first_job = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(first_job, "source", .directory, .{}, null);
    const nested = try manager.addTreeEntry(first_job, first_root, "nested", .directory, .{}, null);
    const file = try manager.addTreeEntry(first_job, nested, "file.bin", .regular_file, .{}, null);

    const first_destination = try allocator.dupe(u8, "/tmp/first-target");
    try manager.setDestinationDirectory(first_job, first_destination);
    allocator.free(first_destination);

    const root_path = try manager.destinationPath(allocator, first_job, first_root);
    defer allocator.free(root_path);
    const file_path = try manager.destinationPath(allocator, first_job, file);
    defer allocator.free(file_path);

    try std.testing.expectEqualStrings("/tmp/first-target/source", root_path);
    try std.testing.expectEqualStrings("/tmp/first-target/source/nested/file.bin", file_path);

    const second_job = try manager.createJob(null);
    const second_root = try manager.addTreeRoot(second_job, "other", .directory, .{}, null);
    try manager.setDestinationDirectory(second_job, "/tmp/second-target");

    const second_path = try manager.destinationPath(allocator, second_job, second_root);
    defer allocator.free(second_path);
    try std.testing.expectEqualStrings("/tmp/second-target/other", second_path);

    try std.testing.expectError(
        error.UnknownEntry,
        manager.destinationPath(allocator, first_job, 999),
    );
}

test "destination directory requires a root and an absolute path" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    try std.testing.expectError(
        error.MissingTreeRoot,
        manager.setDestinationDirectory(job, "/tmp/target"),
    );

    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try std.testing.expectError(
        error.InvalidDestinationDirectory,
        manager.setDestinationDirectory(job, "relative-target"),
    );
    const nul_path = [_]u8{ '/', 't', 'm', 'p', 0, 'x' };
    try std.testing.expectError(
        error.InvalidDestinationDirectory,
        manager.setDestinationDirectory(job, &nul_path),
    );

    try std.testing.expectError(
        error.MissingDestinationDirectory,
        manager.destinationPath(std.testing.allocator, job, 1),
    );

    try manager.setDestinationDirectory(job, "/tmp/target");
    try std.testing.expectError(
        error.DestinationDirectoryAlreadySet,
        manager.setDestinationDirectory(job, "/tmp/other"),
    );
}

test "standalone file roots have source paths without directory discovery" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{ .size = 123 },
        null,
    );

    try std.testing.expectError(
        error.InvalidSourceRootPath,
        manager.setSourceRootPath(job, "relative/payload.bin"),
    );
    try manager.setSourceRootPath(job, "/tmp/source/payload.bin");
    try manager.setDestinationDirectory(job, "/tmp/destination");

    const source = try manager.sourcePath(allocator, job, root);
    defer allocator.free(source);
    const destination = try manager.destinationPath(allocator, job, root);
    defer allocator.free(destination);

    try std.testing.expectEqualStrings("/tmp/source/payload.bin", source);
    try std.testing.expectEqualStrings("/tmp/destination/payload.bin", destination);
    try std.testing.expect(manager.discoveryRootPath(job, root) == null);
    try std.testing.expect(manager.discoveryComplete(job) == null);
}

test "discardPlanningJob removes an uncommitted Job without disturbing others" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createJob(null);
    const discarded = try manager.createJob(null);
    const retained = try manager.createJob(null);
    const last = try manager.createJob(null);

    try std.testing.expect(manager.discardPlanningJob(discarded));
    try std.testing.expect(manager.jobState(discarded) == null);
    try std.testing.expect(manager.jobState(first) != null);
    try std.testing.expect(manager.jobState(retained) != null);
    try std.testing.expect(manager.jobState(last) != null);

    const first_operation = try manager.addOperation(first, .copy_file);
    const retained_operation = try manager.addOperation(retained, .copy_file);
    const last_operation = try manager.addOperation(last, .copy_file);

    try manager.queueJob(first);
    try manager.queueJob(retained);
    try manager.queueJob(last);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(first, token.job_id);
    try std.testing.expectEqual(first_operation, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .completed));

    const next = manager.dispatchNext().?;
    try std.testing.expectEqual(retained, next.job_id);
    try std.testing.expectEqual(retained_operation, next.operation_id);
    try std.testing.expect(manager.completeWork(next, .completed));

    const final = manager.dispatchNext().?;
    try std.testing.expectEqual(last, final.job_id);
    try std.testing.expectEqual(last_operation, final.operation_id);
    try std.testing.expect(manager.completeWork(final, .completed));
}

test "discovery adopts batches and visits directories breadth first" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    try std.testing.expectEqualStrings(
        "/tmp/source",
        manager.discoveryRootPath(job, root).?,
    );

    const root_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, root_token.entry_id);

    var root_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "a", .kind = .directory },
        .{ .name = "root.txt", .kind = .regular_file },
        .{ .name = "b", .kind = .directory },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(root_token, &root_batch));

    const tree = manager.treeIndex(job).?;
    try std.testing.expectEqual(@as(usize, 4), tree.count());
    const a_id = tree.getConst(root).?.children.items[0];
    const b_id = tree.getConst(root).?.children.items[2];

    const a_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(a_id, a_token.entry_id);
    var a_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "inside-a", .kind = .regular_file },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(a_token, &a_batch));

    const b_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(b_id, b_token.entry_id);
    var b_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(b_token, &b_batch));

    try std.testing.expect(manager.discoveryComplete(job).?);
    try std.testing.expectEqual(@as(usize, 5), tree.count());
}

test "discovery resumes a partial directory after promoted work" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const first_token = manager.dispatchDiscovery().?;
    var first_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "child", .kind = .directory },
    }, false);
    try std.testing.expect(try manager.completeDiscovery(first_token, &first_batch));

    const child_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(
        manager.treeIndex(job).?.getConst(root).?.children.items[0],
        child_token.entry_id,
    );
    var child_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(child_token, &child_batch));

    const resumed_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, resumed_token.entry_id);
    try std.testing.expect(resumed_token.generation > first_token.generation);

    var final_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(resumed_token, &final_batch));
    try std.testing.expect(manager.discoveryComplete(job).?);
}

test "discovery rejects stale completion and failure tokens" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const token = manager.dispatchDiscovery().?;
    try std.testing.expect(manager.failDiscovery(token));
    try std.testing.expect(!manager.failDiscovery(token));

    var stale_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    defer stale_batch.deinit();
    try std.testing.expect(!try manager.completeDiscovery(token, &stale_batch));
    try std.testing.expect(manager.discoveryComplete(job).?);
}

test "discovery scheduler follows the foreground promoted background 2:1:1 rotation" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    var jobs: [8]io_manager.JobId = undefined;
    for (&jobs, 0..) |*job_id, index| {
        job_id.* = try manager.createJob(null);
        _ = try manager.addTreeRoot(job_id.*, "source", .directory, .{}, null);
        try manager.startDiscovery(job_id.*, "/tmp/source");
        if (index < 4) {
            const root = manager.treeIndex(job_id.*).?.root().?;
            try manager.prioritizeDiscovery(job_id.*, root);
        } else if (index < 6) {
            const root = manager.treeIndex(job_id.*).?.root().?;
            try manager.promoteDiscoverySubtree(job_id.*, root);
        }
    }

    const expected = [_]io_manager.JobId{
        jobs[0], jobs[1], jobs[4], jobs[6],
        jobs[2], jobs[3], jobs[5], jobs[7],
    };
    for (expected) |expected_job| {
        const token = manager.dispatchDiscovery() orelse return error.MissingDiscoveryWork;
        try std.testing.expectEqual(expected_job, token.job_id);
        var batch = try makeDiscoveryBatch(allocator, &.{}, true);
        try std.testing.expect(try manager.completeDiscovery(token, &batch));
    }

    for (jobs) |job_id|
        try std.testing.expect(manager.discoveryComplete(job_id).?);
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "discovery scheduler skips empty priority queues without wasting dispatches" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const promoted_job = try manager.createJob(null);
    const promoted_root = try manager.addTreeRoot(
        promoted_job,
        "promoted",
        .directory,
        .{},
        null,
    );
    try manager.startDiscovery(promoted_job, "/tmp/promoted");
    try manager.promoteDiscoverySubtree(promoted_job, promoted_root);

    const background_job = try manager.createJob(null);
    _ = try manager.addTreeRoot(background_job, "background", .directory, .{}, null);
    try manager.startDiscovery(background_job, "/tmp/background");

    const first = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(promoted_job, first.job_id);
    var first_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(first, &first_batch));

    const second = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(background_job, second.job_id);
    var second_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(second, &second_batch));
    try std.testing.expect(manager.dispatchDiscovery() == null);
}

test "promoting a queued directory changes its priority without duplicating it" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const root_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, root_token.entry_id);
    var root_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "a", .kind = .directory },
        .{ .name = "b", .kind = .directory },
        .{ .name = "c", .kind = .directory },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(root_token, &root_batch));

    const children = manager.treeIndex(job).?.getConst(root).?.children.items;
    const a_id = children[0];
    const b_id = children[1];
    try manager.prioritizeDiscovery(job, b_id);

    const promoted = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(b_id, promoted.entry_id);
    var promoted_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(promoted, &promoted_batch));

    const background = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(a_id, background.entry_id);
    var background_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(background, &background_batch));

    const final_child = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(children[2], final_child.entry_id);
    var final_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(final_child, &final_batch));
    try std.testing.expect(manager.discoveryComplete(job).?);
}

test "promoted subtree descendants inherit promoted priority" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const promoted_job = try manager.createJob(null);
    const root = try manager.addTreeRoot(promoted_job, "source", .directory, .{}, null);
    try manager.startDiscovery(promoted_job, "/tmp/source");
    try manager.promoteDiscoverySubtree(promoted_job, root);

    const background_job = try manager.createJob(null);
    _ = try manager.addTreeRoot(background_job, "other", .directory, .{}, null);
    try manager.startDiscovery(background_job, "/tmp/other");

    const root_token = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(promoted_job, root_token.job_id);
    var root_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "nested", .kind = .directory },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(root_token, &root_batch));

    const background = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(background_job, background.job_id);
    var background_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(background, &background_batch));

    const nested_id = manager.treeIndex(promoted_job).?.getConst(root).?.children.items[0];
    const nested = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(promoted_job, nested.job_id);
    try std.testing.expectEqual(nested_id, nested.entry_id);
    var nested_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(nested, &nested_batch));
}

test "foreground work can run between batches while a background continuation is retained" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.startDiscovery(job, "/tmp/source");

    const root_token = manager.dispatchDiscovery().?;
    var first_batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "b", .kind = .directory },
    }, false);
    try std.testing.expect(try manager.completeDiscovery(root_token, &first_batch));

    const children = manager.treeIndex(job).?.getConst(root).?.children.items;
    const foreground_id = children[0];
    try manager.prioritizeDiscovery(job, foreground_id);

    const foreground = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(foreground_id, foreground.entry_id);
    var foreground_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(foreground, &foreground_batch));

    const resumed = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, resumed.entry_id);
    try std.testing.expect(resumed.generation > root_token.generation);
    var final_root_batch = try makeDiscoveryBatch(allocator, &.{}, true);
    try std.testing.expect(try manager.completeDiscovery(resumed, &final_root_batch));
}

test "large dependency chain dispatches in insertion order" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const operation_count = 10_000;
    const job = try manager.createJob(null);
    const ids = try std.testing.allocator.alloc(io_manager.OperationId, operation_count);
    defer std.testing.allocator.free(ids);

    for (ids, 0..) |*id, index| {
        id.* = try manager.addOperation(job, .copy_file);
        if (index > 0) {
            try manager.addDependency(job, id.*, ids[index - 1]);
        }
    }

    try manager.queueJob(job);

    for (ids) |expected_id| {
        const token = manager.dispatchNext() orelse return error.MissingWork;
        try std.testing.expectEqual(expected_id, token.operation_id);
        try std.testing.expect(manager.completeWork(token, .completed));
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
}

test "failure propagation handles shared descendants in a diamond graph" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addOperation(job, .copy_file);
    const left = try manager.addOperation(job, .copy_file);
    const right = try manager.addOperation(job, .copy_file);
    const join = try manager.addOperation(job, .publish);

    try manager.addDependency(job, left, root);
    try manager.addDependency(job, right, root);
    try manager.addDependency(job, join, left);
    try manager.addDependency(job, join, right);
    try manager.queueJob(job);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(root, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .failed));

    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, left).?);
    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, right).?);
    try std.testing.expectEqual(io_manager.OperationState.skipped, manager.operationState(job, join).?);
    try std.testing.expectEqual(io_manager.JobState.failed, manager.jobState(job).?);
    try std.testing.expect(manager.dispatchNext() == null);
}

test "completing a directory releases all dynamically discovered children" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{},
        null,
    );
    _ = try manager.addEntryOperation(job, root, .create_directory);
    try manager.enableDiscoveredEntryOperations(job);
    try manager.startDiscovery(job, "/tmp/source");
    try manager.queueJob(job);

    // Keep the parent operation running while discovery registers several
    // children that all depend on its destination directory.
    const parent_work = manager.dispatchNext().?;
    try std.testing.expectEqual(
        io_manager.OperationKind.create_directory,
        manager.operationDetails(parent_work).?.kind,
    );
    const discovery_work = manager.dispatchDiscovery().?;
    try std.testing.expectEqual(root, discovery_work.entry_id);

    var batch = try makeDiscoveryBatch(allocator, &.{
        .{ .name = "one.txt", .kind = .regular_file },
        .{ .name = "two.txt", .kind = .regular_file },
        .{ .name = "three.txt", .kind = .regular_file },
        .{ .name = "four.txt", .kind = .regular_file },
    }, true);
    try std.testing.expect(try manager.completeDiscovery(discovery_work, &batch));

    try std.testing.expect(manager.completeWork(parent_work, .completed));

    var completed_children: usize = 0;
    while (manager.dispatchNext()) |child_work| {
        try std.testing.expectEqual(
            io_manager.OperationKind.copy_file,
            manager.operationDetails(child_work).?.kind,
        );
        try std.testing.expect(manager.completeWork(child_work, .completed));
        completed_children += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), completed_children);
    try std.testing.expectEqual(
        io_manager.JobState.completed,
        manager.jobState(job).?,
    );
}

test "priority queues preserve FIFO and yielded work returns to its priority front" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    const first_file = try manager.addOperation(job, .copy_file);
    const second_file = try manager.addOperation(job, .copy_file);
    const first_link = try manager.addOperation(job, .copy_symlink);
    const second_link = try manager.addOperation(job, .copy_symlink);
    const first_directory = try manager.addOperation(job, .create_directory);
    const second_directory = try manager.addOperation(job, .create_directory);
    try manager.queueJob(job);

    const yielded = manager.dispatchNext().?;
    try std.testing.expectEqual(first_directory, yielded.operation_id);
    try std.testing.expect(manager.completeWork(yielded, .yielded));

    const retried = manager.dispatchNext().?;
    try std.testing.expectEqual(first_directory, retried.operation_id);
    try std.testing.expect(manager.completeWork(retried, .completed));

    const directory = manager.dispatchNext().?;
    try std.testing.expectEqual(second_directory, directory.operation_id);
    try std.testing.expect(manager.completeWork(directory, .completed));

    const link_one = manager.dispatchNext().?;
    try std.testing.expectEqual(first_link, link_one.operation_id);
    try std.testing.expect(manager.completeWork(link_one, .completed));
    const link_two = manager.dispatchNext().?;
    try std.testing.expectEqual(second_link, link_two.operation_id);
    try std.testing.expect(manager.completeWork(link_two, .completed));

    const file_one = manager.dispatchNext().?;
    try std.testing.expectEqual(first_file, file_one.operation_id);
    try std.testing.expect(manager.completeWork(file_one, .completed));
    const file_two = manager.dispatchNext().?;
    try std.testing.expectEqual(second_file, file_two.operation_id);
    try std.testing.expect(manager.completeWork(file_two, .completed));

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "flushing operation count tracks phase changes, yields, and completion" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job = try manager.createJob(null);
    _ = try manager.addOperation(job, .copy_file);
    try manager.queueJob(job);

    const first_work = manager.dispatchNext().?;
    try std.testing.expect(manager.completeWork(first_work, .yielded));
    try std.testing.expect(!manager.jobHasFlushingOperation(job));

    try std.testing.expect(manager.recordOperationProgress(
        first_work,
        0,
        100,
        .flushing,
    ));
    try std.testing.expect(manager.jobHasFlushingOperation(job));

    const retry = manager.dispatchNext().?;
    try std.testing.expectEqual(first_work.operation_id, retry.operation_id);
    try std.testing.expect(manager.jobHasFlushingOperation(job));

    try std.testing.expect(manager.completeWork(retry, .completed));
    try std.testing.expect(!manager.jobHasFlushingOperation(job));
}
