const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").api;
const io_manager = @import("io_manager.zig");
const io_tree = @import("io_tree.zig");
const io_discovery = @import("io_discovery.zig");
const io_discovery_executor = @import("io_discovery_executor.zig");
const operation_executor = @import("io_operation_executor.zig");
const platform_fs = @import("platform").fs;

fn allocZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

fn makeTempDir(buffer: []u8) ![]const u8 {
    return makeTempDirAt(buffer, "/tmp");
}

fn makeTempDirAt(buffer: []u8, parent: []const u8) ![]const u8 {
    _ = try std.fmt.bufPrint(
        buffer,
        "{s}/rediwm_io_runtime_XXXXXX\x00",
        .{parent},
    );
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

fn join(
    allocator: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn makeDirectory(path: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    if (c.mkdir(zpath, 0o755) != 0) return error.MkdirFailed;
}

fn makeSymlink(target: []const u8, path: []const u8) !void {
    const allocator = std.testing.allocator;
    const ztarget = try allocZ(allocator, target);
    defer allocator.free(ztarget);
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    if (c.symlink(ztarget, zpath) != 0) return error.SymlinkFailed;
}

fn readLink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    var buffer: [4096]u8 = undefined;
    const count = c.readlink(zpath, &buffer, buffer.len);
    if (count < 0) return error.ReadlinkFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    const fd = c.open(
        zpath,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    const count = c.write(fd, contents.ptr, contents.len);
    if (count != contents.len) return error.WriteFailed;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    const fd = c.open(zpath, c.O_RDONLY | c.O_CLOEXEC, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var buffer: [4096]u8 = undefined;
    const count = c.read(fd, &buffer, buffer.len);
    if (count < 0) return error.ReadFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn cleanup(path: []const u8, directory: bool) void {
    const zpath = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(zpath);
    if (directory) {
        _ = c.rmdir(zpath);
    } else {
        _ = c.unlink(zpath);
    }
}

fn waitForOne(runtime: *operation_executor.Runtime) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = runtime.wakeFd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const rc = std.posix.system.poll(&descriptors, 1, 5_000);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TimedOutWaitingForExecutor;
                _ = runtime.drainWake();
                return;
            },
            .INTR => continue,
            else => return error.ExecutorPollFailed,
        }
    }
}

fn waitForDiscovery(executor: *io_discovery_executor.Executor) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = executor.wakeFd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const rc = std.posix.system.poll(&descriptors, 1, 5_000);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TimedOutWaitingForDiscovery;
                _ = executor.drainWake();
                return;
            },
            .INTR => continue,
            else => return error.DiscoveryPollFailed,
        }
    }
}

fn writeArchiveFixture(path: []const u8) !void {
    const api = @import("c_archive");
    const writer = api.archive_write_new() orelse return error.OutOfMemory;
    defer _ = api.archive_write_free(writer);

    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_set_format_zip(writer));
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    try std.testing.expectEqual(
        @as(c_int, 0),
        api.archive_write_open_filename(writer, zpath),
    );

    const entry = api.archive_entry_new() orelse return error.OutOfMemory;
    defer api.archive_entry_free(entry);
    api.archive_entry_set_pathname(entry, "nested/payload.txt");
    api.archive_entry_set_filetype(entry, c.S_IFREG);
    api.archive_entry_set_perm(entry, 0o644);
    api.archive_entry_set_size(entry, 7);
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_header(writer, entry));
    try std.testing.expectEqual(
        @as(isize, 7),
        api.archive_write_data(writer, "payload", 7),
    );
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_close(writer));
}

fn expectDirectoryEmpty(path: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    const directory = c.opendir(zpath) orelse return error.OpenDirectoryFailed;
    defer _ = c.closedir(directory);

    while (true) {
        const entry = c.readdir(directory) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        return error.DirectoryNotEmpty;
    }
}

test "Manager operations execute directory creation before dependent symlink and file work" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    defer cleanup(source, true);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    defer cleanup(destination_base, true);
    try makeDirectory(source);
    try makeDirectory(destination_base);

    const source_link = try join(allocator, source, "relative-link");
    defer allocator.free(source_link);
    defer cleanup(source_link, false);
    try makeSymlink("../missing/target", source_link);

    const source_file = try join(allocator, source, "payload.txt");
    defer allocator.free(source_file);
    defer cleanup(source_file, false);
    try writeFile(source_file, "executor integration");

    const destination_root = try join(allocator, destination_base, "source");
    defer allocator.free(destination_root);
    defer cleanup(destination_root, true);
    const destination_link = try join(allocator, destination_root, "relative-link");
    defer allocator.free(destination_link);
    defer cleanup(destination_link, false);
    const destination_file = try join(allocator, destination_root, "payload.txt");
    defer allocator.free(destination_file);
    defer cleanup(destination_file, false);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root_id = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .mode = 0o755 },
        null,
    );
    const link_id = try manager.addTreeEntry(
        job,
        root_id,
        "relative-link",
        .symlink,
        .{},
        "../missing/target",
    );
    const file_id = try manager.addTreeEntry(
        job,
        root_id,
        "payload.txt",
        .regular_file,
        .{},
        null,
    );
    try manager.startDiscovery(job, source);
    try manager.setDestinationDirectory(job, destination_base);

    const directory_operation = try manager.addEntryOperation(job, root_id, .create_directory);
    const symlink_operation = try manager.addEntryOperation(job, link_id, .copy_symlink);
    const file_operation = try manager.addEntryOperation(job, file_id, .copy_file);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, directory_operation).?,
    );

    // The parent directory completion unlocks its children. Symlink work
    // has higher scheduler priority than regular-file copying.
    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, symlink_operation).?,
    );

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    // The data-transfer unit yields for the durability flush.
    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, file_operation).?,
    );

    const stored_target = try readLink(allocator, destination_link);
    defer allocator.free(stored_target);
    try std.testing.expectEqualStrings("../missing/target", stored_target);

    const copied_contents = try readFile(allocator, destination_file);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings("executor integration", copied_contents);
}

test "Manager Runtime copies a standalone regular-file root" {
    const allocator = std.testing.allocator;
    const contents = "standalone Manager copy";
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source = try join(allocator, temp, "payload.bin");
    defer allocator.free(source);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try join(allocator, destination_dir, "payload.bin");
    defer allocator.free(destination);
    defer {
        cleanup(destination, false);
        cleanup(source, false);
        cleanup(destination_dir, true);
        cleanup(temp, true);
    }

    try makeDirectory(destination_dir);
    try writeFile(source, contents);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{},
        null,
    );
    try manager.setRootSourcePath(job, root, source);
    try manager.setDestinationDirectory(job, destination_dir);
    const operation_id = try manager.addEntryOperation(job, root, .copy_file);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();
    runtime.setProfilingEnabled(true);

    while (!manager.jobState(job).?.isTerminal()) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    const progress = manager.entryOperationView(job, root).?;
    const expected_bytes: u64 = contents.len;
    try std.testing.expectEqual(expected_bytes, progress.progress_bytes);
    try std.testing.expectEqual(expected_bytes, progress.progress_total_bytes);

    const metrics = manager.operationCopyMetrics(job, operation_id).?;
    const transferred_bytes =
        metrics.reflink_bytes +
        metrics.copy_file_range_bytes +
        metrics.buffered_write_bytes;
    try std.testing.expectEqual(expected_bytes, transferred_bytes);
    try std.testing.expect(metrics.elapsed_ns > 0);

    const copied_contents = try readFile(allocator, destination);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings(contents, copied_contents);
}

test "Manager Runtime extracts archives into owned staging leases" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    const source = try join(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    defer {
        cleanup(source, false);
        cleanup(destination, true);
        cleanup(temp, true);
    }

    try writeArchiveFixture(source);
    try makeDirectory(destination);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = source,
            .staging_parent = destination,
        },
    );
    try manager.setDestinationDirectory(job, destination);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    const token: io_manager.WorkToken = .{
        .job_id = job,
        .operation_id = operation,
        .generation = 1,
    };
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );
    const staging_path = try allocator.dupe(
        u8,
        runtime.archiveStagingPath(token) orelse return error.MissingArchiveStaging,
    );
    defer allocator.free(staging_path);

    const extracted = try join(allocator, staging_path, "nested/payload.txt");
    defer allocator.free(extracted);
    const contents = try readFile(allocator, extracted);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("payload", contents);

    try std.testing.expect(!try runtime.releaseArchiveStaging(token));
    try manager.closeArchivePublication(token);
    try std.testing.expectEqual(@as(?bool, true), manager.archivePublicationReady(token));
    try std.testing.expect(try runtime.releaseArchiveStaging(token));

    const staging_z = try allocZ(allocator, staging_path);
    defer allocator.free(staging_z);
    var staging_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(staging_z, &staging_stat) != 0);
    try std.testing.expect(manager.completeArchivePublication(token));
    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
}

test "Manager Runtime removes failed archive extraction staging" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    const source = try join(allocator, temp, "broken.zip");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    defer {
        cleanup(source, false);
        cleanup(destination, true);
        cleanup(temp, true);
    }

    try writeFile(source, "not an archive");
    try makeDirectory(destination);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = source,
            .staging_parent = destination,
        },
    );
    try manager.setDestinationDirectory(job, destination);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, operation).?,
    );
    try expectDirectoryEmpty(destination);
}

test "Manager Runtime cancels outstanding archive extraction and cleans staging" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    const source = try join(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    defer {
        cleanup(source, false);
        cleanup(destination, true);
        cleanup(temp, true);
    }

    try writeArchiveFixture(source);
    try makeDirectory(destination);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const operation = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = source,
            .staging_parent = destination,
        },
    );
    try manager.setDestinationDirectory(job, destination);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());

    try runtime.cancelJob(job);
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    try std.testing.expectEqual(
        io_manager.OperationState.cancelled,
        manager.operationState(job, operation).?,
    );
    try expectDirectoryEmpty(destination);
}

test "Manager Runtime discards undrained archive results during shutdown" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    const source = try join(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const destination = try join(allocator, temp, "destination");
    defer allocator.free(destination);
    defer {
        cleanup(source, false);
        cleanup(destination, true);
        cleanup(temp, true);
    }

    try writeArchiveFixture(source);
    try makeDirectory(destination);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    _ = try manager.addArchiveOperation(
        job,
        .archive_extract,
        .{
            .source_path = source,
            .staging_parent = destination,
        },
    );
    try manager.setDestinationDirectory(job, destination);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    var runtime_alive = true;
    defer if (runtime_alive) runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);

    // The worker has published its result, but the main thread has not
    // collected it. Pool shutdown must route it through the discard callback.
    runtime.deinit();
    runtime_alive = false;
    try expectDirectoryEmpty(destination);
}

test "Manager Runtime copies a discovered folder incrementally" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const source_nested = try join(allocator, source, "nested");
    defer allocator.free(source_nested);
    const source_deep = try join(allocator, source_nested, "deep");
    defer allocator.free(source_deep);
    const source_top_file = try join(allocator, source, "top.txt");
    defer allocator.free(source_top_file);
    const source_nested_file = try join(allocator, source_nested, "nested.txt");
    defer allocator.free(source_nested_file);
    const source_deep_file = try join(allocator, source_deep, "deep.txt");
    defer allocator.free(source_deep_file);
    const source_link = try join(allocator, source, "shortcut");
    defer allocator.free(source_link);

    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    const destination_root = try join(allocator, destination_base, "source");
    defer allocator.free(destination_root);
    const destination_nested = try join(allocator, destination_root, "nested");
    defer allocator.free(destination_nested);
    const destination_deep = try join(allocator, destination_nested, "deep");
    defer allocator.free(destination_deep);
    const destination_top_file = try join(allocator, destination_root, "top.txt");
    defer allocator.free(destination_top_file);
    const destination_nested_file = try join(allocator, destination_nested, "nested.txt");
    defer allocator.free(destination_nested_file);
    const destination_deep_file = try join(allocator, destination_deep, "deep.txt");
    defer allocator.free(destination_deep_file);
    const destination_link = try join(allocator, destination_root, "shortcut");
    defer allocator.free(destination_link);

    defer {
        cleanup(destination_link, false);
        cleanup(destination_deep_file, false);
        cleanup(destination_nested_file, false);
        cleanup(destination_top_file, false);
        cleanup(destination_deep, true);
        cleanup(destination_nested, true);
        cleanup(destination_root, true);
        cleanup(destination_base, true);
        cleanup(source_link, false);
        cleanup(source_deep_file, false);
        cleanup(source_nested_file, false);
        cleanup(source_top_file, false);
        cleanup(source_deep, true);
        cleanup(source_nested, true);
        cleanup(source, true);
        cleanup(temp, true);
    }

    try makeDirectory(source);
    try makeDirectory(source_nested);
    try makeDirectory(source_deep);
    try makeDirectory(destination_base);
    try writeFile(source_top_file, "top-level payload");
    try writeFile(source_nested_file, "nested payload");
    try writeFile(source_deep_file, "deep payload");
    try makeSymlink("nested/deep/deep.txt", source_link);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source",
        .directory,
        .{ .mode = 0o755 },
        null,
    );
    try manager.setDestinationDirectory(job, destination_base);
    try manager.enableDiscoveredEntryOperations(job);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    try manager.startDiscovery(job, source);
    try manager.queueJob(job);

    var discovery = try io_discovery_executor.Executor.init(
        allocator,
        1,
        1,
        1,
    );
    defer discovery.deinit();
    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 1);
    defer runtime.deinit();

    var iterations: usize = 0;
    while (!manager.jobState(job).?.isTerminal()) : (iterations += 1) {
        if (iterations == 100) return error.FolderCopyDidNotComplete;

        const discovery_submitted = try discovery.dispatchReady(&manager);
        const operations_submitted = try runtime.dispatchReady();

        if (discovery_submitted > 0) {
            try waitForDiscovery(&discovery);
            _ = try discovery.drainCompletions(&manager);
        }

        if (operations_submitted > 0) {
            try waitForOne(&runtime);
            _ = try runtime.drainCompletions();
        }
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expectEqual(true, manager.discoveryComplete(job).?);

    const copied_top = try readFile(allocator, destination_top_file);
    defer allocator.free(copied_top);
    try std.testing.expectEqualStrings("top-level payload", copied_top);

    const copied_nested = try readFile(allocator, destination_nested_file);
    defer allocator.free(copied_nested);
    try std.testing.expectEqualStrings("nested payload", copied_nested);

    const copied_deep = try readFile(allocator, destination_deep_file);
    defer allocator.free(copied_deep);
    try std.testing.expectEqualStrings("deep payload", copied_deep);

    const copied_target = try readLink(allocator, destination_link);
    defer allocator.free(copied_target);
    try std.testing.expectEqualStrings("nested/deep/deep.txt", copied_target);
}

test "Manager Runtime registers directory destination collisions" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source-dir");
    defer allocator.free(source);
    defer cleanup(source, true);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    defer cleanup(destination_base, true);
    const destination = try join(allocator, destination_base, "source-dir");
    defer allocator.free(destination);
    defer cleanup(destination, true);

    try makeDirectory(source);
    try makeDirectory(destination_base);
    try makeDirectory(destination);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source-dir",
        .directory,
        .{ .mode = 0o755 },
        null,
    );
    try manager.setSourceRootPath(job, source);
    try manager.setDestinationDirectory(job, destination_base);
    const operation = try manager.addEntryOperation(job, root, .create_directory);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );
    const conflict = manager.nextConflict() orelse return error.MissingConflict;
    try std.testing.expectEqual(job, conflict.job_id);
    try std.testing.expectEqual(root, conflict.entry_id);
    try std.testing.expectEqual(io_tree.EntryKind.directory, conflict.source_kind);
    try std.testing.expectEqual(io_tree.EntryKind.directory, conflict.destination_kind);
    try std.testing.expectEqualStrings(source, conflict.source_path);
    try std.testing.expectEqualStrings(destination, conflict.destination_path);
}

test "Manager Runtime merges an existing directory before detaching its source" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source-dir");
    defer allocator.free(source);
    defer cleanup(source, true);
    const source_file = try join(allocator, source, "new.txt");
    defer allocator.free(source_file);
    defer cleanup(source_file, false);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    defer cleanup(destination_base, true);
    const destination = try join(allocator, destination_base, "source-dir");
    defer allocator.free(destination);
    defer cleanup(destination, true);
    const preserved_file = try join(allocator, destination, "keep.txt");
    defer allocator.free(preserved_file);
    defer cleanup(preserved_file, false);
    const copied_file = try join(allocator, destination, "new.txt");
    defer allocator.free(copied_file);
    defer cleanup(copied_file, false);

    try makeDirectory(source);
    try makeDirectory(destination_base);
    try makeDirectory(destination);
    try writeFile(source_file, "new source payload");
    try writeFile(preserved_file, "existing destination payload");

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source-dir", .directory, .{}, null);
    const child = try manager.addTreeEntry(
        job,
        root,
        "new.txt",
        .regular_file,
        .{ .size = "new source payload".len },
        null,
    );
    try manager.setRootSourcePath(job, root, source);
    try manager.setDestinationDirectory(job, destination_base);
    const root_create = try manager.addEntryOperation(job, root, .create_directory);
    const root_detach = try manager.addEntryOperation(job, root, .detach_source);
    const child_copy = try manager.addEntryOperation(job, child, .copy_file);
    const child_detach = try manager.addEntryOperation(job, child, .detach_source);
    try manager.addDependency(job, root_detach, child_detach);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, source);
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch: io_discovery.Batch = .{
        .allocator = allocator,
        .complete = true,
    };
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, root_create).?,
    );
    const conflict = manager.nextConflict() orelse return error.MissingConflict;
    try std.testing.expectEqual(io_tree.EntryKind.directory, conflict.source_kind);
    try std.testing.expectEqual(io_tree.EntryKind.directory, conflict.destination_kind);
    try manager.mergeConflict(conflict.id);

    var iterations: usize = 0;
    while (!manager.jobState(job).?.isTerminal()) : (iterations += 1) {
        if (iterations == 100) return error.DirectoryMergeDidNotComplete;
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
        if (manager.operationState(job, child_copy).? != .completed)
            try std.testing.expect(manager.operationState(job, root_detach).? != .running);
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, child_detach).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, root_detach).?,
    );
    const preserved = try readFile(allocator, preserved_file);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("existing destination payload", preserved);
    const copied = try readFile(allocator, copied_file);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("new source payload", copied);

    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    var source_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(source_z, &source_stat) != 0);
}

test "Manager Runtime registers symlink destination collisions" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source-link");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    defer cleanup(destination_base, true);
    const destination = try join(allocator, destination_base, "source-link");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try makeDirectory(destination_base);
    try makeSymlink("../source-target", source);
    try makeSymlink("../existing-target", destination);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source-link",
        .symlink,
        .{},
        "../source-target",
    );
    try manager.setSourceRootPath(job, source);
    try manager.setDestinationDirectory(job, destination_base);
    const operation = try manager.addEntryOperation(job, root, .copy_symlink);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );
    const conflict = manager.nextConflict() orelse return error.MissingConflict;
    try std.testing.expectEqual(job, conflict.job_id);
    try std.testing.expectEqual(root, conflict.entry_id);
    try std.testing.expectEqual(io_tree.EntryKind.symlink, conflict.source_kind);
    try std.testing.expectEqual(io_tree.EntryKind.symlink, conflict.destination_kind);
    try std.testing.expectEqualStrings(source, conflict.source_path);
    try std.testing.expectEqualStrings(destination, conflict.destination_path);
}

test "Manager Runtime moves regular files and symlinks with native rename" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source_file = try join(allocator, temp, "payload.bin");
    defer allocator.free(source_file);
    const source_link = try join(allocator, temp, "shortcut");
    defer allocator.free(source_link);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination_file = try join(allocator, destination_dir, "payload.bin");
    defer allocator.free(destination_file);
    const destination_link = try join(allocator, destination_dir, "shortcut");
    defer allocator.free(destination_link);
    defer {
        cleanup(destination_link, false);
        cleanup(destination_file, false);
        cleanup(destination_dir, true);
        cleanup(source_link, false);
        cleanup(source_file, false);
        cleanup(temp, true);
    }

    try makeDirectory(destination_dir);
    try writeFile(source_file, "native rename payload");
    try makeSymlink("../literal-target", source_link);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const file_root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{},
        null,
    );
    const link_root = try manager.addTreeRoot(
        job,
        "shortcut",
        .symlink,
        .{},
        "../literal-target",
    );
    try manager.setRootSourcePath(job, file_root, source_file);
    try manager.setRootSourcePath(job, link_root, source_link);
    try manager.setDestinationDirectory(job, destination_dir);
    const file_operation = try manager.addEntryOperation(job, file_root, .move_entry);
    const link_operation = try manager.addEntryOperation(job, link_root, .move_entry);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();

    while (!manager.jobState(job).?.isTerminal()) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, file_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, link_operation).?,
    );

    const source_file_z = try allocZ(allocator, source_file);
    defer allocator.free(source_file_z);
    var source_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(source_file_z, &source_stat) != 0);

    const source_link_z = try allocZ(allocator, source_link);
    defer allocator.free(source_link_z);
    try std.testing.expect(c.lstat(source_link_z, &source_stat) != 0);

    const moved_contents = try readFile(allocator, destination_file);
    defer allocator.free(moved_contents);
    try std.testing.expectEqualStrings("native rename payload", moved_contents);

    const moved_target = try readLink(allocator, destination_link);
    defer allocator.free(moved_target);
    try std.testing.expectEqualStrings("../literal-target", moved_target);
}

test "Manager Runtime falls back to copy-and-detach after a real EXDEV rename" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var source_buffer: [256]u8 = undefined;
    const source_dir = try makeTempDir(&source_buffer);
    defer cleanup(source_dir, true);

    if (platform_fs.stat("/dev/shm") == null) return error.SkipZigTest;
    var destination_buffer: [256]u8 = undefined;
    const destination_dir = try makeTempDirAt(&destination_buffer, "/dev/shm");
    defer cleanup(destination_dir, true);

    const source_dir_z = try allocZ(allocator, source_dir);
    defer allocator.free(source_dir_z);
    const destination_dir_z = try allocZ(allocator, destination_dir);
    defer allocator.free(destination_dir_z);

    const source_info = platform_fs.stat(source_dir_z.ptr) orelse
        return error.SourceDirectoryStatFailed;
    const destination_info = platform_fs.stat(destination_dir_z.ptr) orelse
        return error.DestinationDirectoryStatFailed;
    if (source_info.dev == destination_info.dev) return error.SkipZigTest;

    const source_file = try join(allocator, source_dir, "payload.bin");
    defer allocator.free(source_file);
    const source_link = try join(allocator, source_dir, "shortcut");
    defer allocator.free(source_link);
    const destination_file = try join(allocator, destination_dir, "payload.bin");
    defer allocator.free(destination_file);
    const destination_link = try join(allocator, destination_dir, "shortcut");
    defer allocator.free(destination_link);
    defer {
        cleanup(destination_link, false);
        cleanup(destination_file, false);
        cleanup(source_link, false);
        cleanup(source_file, false);
    }

    try writeFile(source_file, "real EXDEV fallback payload");
    try makeSymlink("../literal-target", source_link);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const file_root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{},
        null,
    );
    const link_root = try manager.addTreeRoot(
        job,
        "shortcut",
        .symlink,
        .{},
        "../literal-target",
    );
    try manager.setRootSourcePath(job, file_root, source_file);
    try manager.setRootSourcePath(job, link_root, source_link);
    try manager.setDestinationDirectory(job, destination_dir);
    const file_operation = try manager.addEntryOperation(job, file_root, .move_entry);
    const link_operation = try manager.addEntryOperation(job, link_root, .move_entry);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();

    while (!manager.jobState(job).?.isTerminal()) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, file_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, link_operation).?,
    );

    const source_file_z = try allocZ(allocator, source_file);
    defer allocator.free(source_file_z);
    const source_link_z = try allocZ(allocator, source_link);
    defer allocator.free(source_link_z);
    var source_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(source_file_z, &source_stat) != 0);
    try std.testing.expect(c.lstat(source_link_z, &source_stat) != 0);

    const copied_contents = try readFile(allocator, destination_file);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings("real EXDEV fallback payload", copied_contents);

    const copied_target = try readLink(allocator, destination_link);
    defer allocator.free(copied_target);
    try std.testing.expectEqualStrings("../literal-target", copied_target);
}

test "Manager Runtime waits on move destination collisions without changing either entry" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source = try join(allocator, temp, "source.bin");
    defer allocator.free(source);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try join(allocator, destination_dir, "source.bin");
    defer allocator.free(destination);
    defer {
        cleanup(destination, false);
        cleanup(destination_dir, true);
        cleanup(source, false);
        cleanup(temp, true);
    }

    try makeDirectory(destination_dir);
    try writeFile(source, "source contents");
    try writeFile(destination, "existing contents");

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source.bin",
        .regular_file,
        .{},
        null,
    );
    try manager.setSourceRootPath(job, source);
    try manager.setDestinationDirectory(job, destination_dir);
    const operation = try manager.addEntryOperation(job, root, .move_entry);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );
    const conflict = manager.nextConflict() orelse return error.MissingConflict;
    try std.testing.expectEqual(job, conflict.job_id);
    try std.testing.expectEqual(root, conflict.entry_id);
    try std.testing.expectEqual(io_tree.EntryKind.regular_file, conflict.source_kind);
    try std.testing.expectEqual(io_tree.EntryKind.regular_file, conflict.destination_kind);
    try std.testing.expectEqualStrings(source, conflict.source_path);
    try std.testing.expectEqualStrings(destination, conflict.destination_path);

    const source_contents = try readFile(allocator, source);
    defer allocator.free(source_contents);
    try std.testing.expectEqualStrings("source contents", source_contents);

    const destination_contents = try readFile(allocator, destination);
    defer allocator.free(destination_contents);
    try std.testing.expectEqualStrings("existing contents", destination_contents);
}

test "Manager rejects move operations for directory entries" {
    var manager = io_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "directory",
        .directory,
        .{},
        null,
    );
    try std.testing.expectError(
        error.InvalidEntryOperationKind,
        manager.addEntryOperation(job, root, .move_entry),
    );
}

test "Manager Runtime rebuilds prepared input after a renamed collision" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source.bin");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "source.bin");
    defer allocator.free(destination);
    defer cleanup(destination, false);
    const renamed_destination = try join(allocator, destination_dir, "source-renamed.bin");
    defer allocator.free(renamed_destination);
    defer cleanup(renamed_destination, false);

    try makeDirectory(destination_dir);
    try writeFile(source, "new source contents");
    try writeFile(destination, "pre-existing destination");

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "source.bin",
        .regular_file,
        .{},
        null,
    );
    try manager.setSourceRootPath(job, source);
    try manager.setDestinationDirectory(job, destination_dir);
    const operation = try manager.addEntryOperation(job, root, .copy_file);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    try std.testing.expectEqual(
        io_manager.OperationState.waiting,
        manager.operationState(job, operation).?,
    );

    const conflict = manager.nextConflict() orelse return error.MissingConflict;
    try manager.renameConflict(conflict.id, renamed_destination);

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    // Renaming resolves the conflict; copying then requires its flush unit.
    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, operation).?,
    );

    const original_contents = try readFile(allocator, destination);
    defer allocator.free(original_contents);
    try std.testing.expectEqualStrings("pre-existing destination", original_contents);

    const renamed_contents = try readFile(allocator, renamed_destination);
    defer allocator.free(renamed_contents);
    try std.testing.expectEqualStrings("new source contents", renamed_contents);
}

test "Manager Runtime removes an emptied source directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    const destination = try join(allocator, destination_base, "source");
    defer allocator.free(destination);
    defer {
        cleanup(destination, true);
        cleanup(destination_base, true);
        cleanup(source, true);
        cleanup(temp, true);
    }

    try makeDirectory(source);
    try makeDirectory(destination_base);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.setRootSourcePath(job, root, source);
    try manager.setDestinationDirectory(job, destination_base);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const detach_operation = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, source);
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch: io_discovery.Batch = .{
        .allocator = allocator,
        .complete = true,
    };
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();
    while (!manager.jobState(job).?.isTerminal()) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, detach_operation).?,
    );
    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    var source_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(source_z, &source_stat) != 0);
}

test "Manager Runtime refuses to remove a non-empty source directory" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const source_file = try join(allocator, source, "unexpected.txt");
    defer allocator.free(source_file);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    const destination = try join(allocator, destination_base, "source");
    defer allocator.free(destination);
    defer {
        cleanup(destination, true);
        cleanup(destination_base, true);
        cleanup(source_file, false);
        cleanup(source, true);
        cleanup(temp, true);
    }

    try makeDirectory(source);
    try writeFile(source_file, "must remain");
    try makeDirectory(destination_base);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(job, "source", .directory, .{}, null);
    try manager.setRootSourcePath(job, root, source);
    try manager.setDestinationDirectory(job, destination_base);
    _ = try manager.addEntryOperation(job, root, .create_directory);
    const detach_operation = try manager.addEntryOperation(job, root, .detach_source);
    try manager.enableDiscoveredEntryMoves(job);
    try manager.startDiscovery(job, source);
    try manager.queueJob(job);

    const scan = manager.dispatchDiscovery() orelse return error.MissingRootScan;
    var batch: io_discovery.Batch = .{
        .allocator = allocator,
        .complete = true,
    };
    try std.testing.expect(try manager.completeDiscovery(scan, &batch));

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();
    while (!manager.jobState(job).?.isTerminal()) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, detach_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );
    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    var source_stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.lstat(source_z, &source_stat));
    const contents = try readFile(allocator, source_file);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("must remain", contents);
}

test "Manager Runtime copies and detaches file and symlink roots" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source_file = try join(allocator, temp, "payload.bin");
    defer allocator.free(source_file);
    const source_link = try join(allocator, temp, "shortcut");
    defer allocator.free(source_link);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    const destination_file = try join(allocator, destination_base, "payload.bin");
    defer allocator.free(destination_file);
    const destination_link = try join(allocator, destination_base, "shortcut");
    defer allocator.free(destination_link);
    defer {
        cleanup(destination_link, false);
        cleanup(destination_file, false);
        cleanup(destination_base, true);
        cleanup(source_link, false);
        cleanup(source_file, false);
        cleanup(temp, true);
    }

    try makeDirectory(destination_base);
    try writeFile(source_file, "copy then detach payload");
    try makeSymlink("../literal-target", source_link);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const file_root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{},
        null,
    );
    const link_root = try manager.addTreeRoot(
        job,
        "shortcut",
        .symlink,
        .{},
        "../literal-target",
    );
    try manager.setRootSourcePath(job, file_root, source_file);
    try manager.setRootSourcePath(job, link_root, source_link);
    try manager.setDestinationDirectory(job, destination_base);

    const file_copy = try manager.addEntryOperation(job, file_root, .copy_file);
    const file_detach = try manager.addEntryOperation(job, file_root, .detach_source);
    const link_copy = try manager.addEntryOperation(job, link_root, .copy_symlink);
    const link_detach = try manager.addEntryOperation(job, link_root, .detach_source);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 4);
    defer runtime.deinit();

    while (!manager.jobState(job).?.isTerminal()) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job).?);
    for ([_]io_manager.OperationId{ file_copy, file_detach, link_copy, link_detach }) |operation| {
        try std.testing.expectEqual(
            io_manager.OperationState.completed,
            manager.operationState(job, operation).?,
        );
    }

    const source_file_z = try allocZ(allocator, source_file);
    defer allocator.free(source_file_z);
    const source_link_z = try allocZ(allocator, source_link);
    defer allocator.free(source_link_z);
    var source_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(source_file_z, &source_stat) != 0);
    try std.testing.expect(c.lstat(source_link_z, &source_stat) != 0);

    const copied_contents = try readFile(allocator, destination_file);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings("copy then detach payload", copied_contents);

    const copied_target = try readLink(allocator, destination_link);
    defer allocator.free(copied_target);
    try std.testing.expectEqualStrings("../literal-target", copied_target);
}

test "Manager Runtime preserves a source whose type changes before detach" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);

    const source = try join(allocator, temp, "payload.bin");
    defer allocator.free(source);
    const destination_base = try join(allocator, temp, "destination");
    defer allocator.free(destination_base);
    const destination = try join(allocator, destination_base, "payload.bin");
    defer allocator.free(destination);
    defer {
        cleanup(destination, false);
        cleanup(destination_base, true);
        cleanup(source, false);
        cleanup(temp, true);
    }

    try makeDirectory(destination_base);
    try writeFile(source, "published destination contents");

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job = try manager.createJob(null);
    const root = try manager.addTreeRoot(
        job,
        "payload.bin",
        .regular_file,
        .{},
        null,
    );
    try manager.setRootSourcePath(job, root, source);
    try manager.setDestinationDirectory(job, destination_base);
    const copy_operation = try manager.addEntryOperation(job, root, .copy_file);
    const detach_operation = try manager.addEntryOperation(job, root, .detach_source);
    try manager.queueJob(job);

    var runtime = try operation_executor.Runtime.init(allocator, &manager, 1, 2);
    defer runtime.deinit();

    while (manager.operationState(job, copy_operation).? != .completed) {
        try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
        try waitForOne(&runtime);
        try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());
    }

    // Replace the copied regular file with a symlink before source detach.
    const source_z = try allocZ(allocator, source);
    defer allocator.free(source_z);
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(source_z));
    try makeSymlink("../replacement-target", source);

    try std.testing.expectEqual(@as(usize, 1), try runtime.dispatchReady());
    try waitForOne(&runtime);
    try std.testing.expectEqual(@as(usize, 1), try runtime.drainCompletions());

    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.operationState(job, copy_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.OperationState.failed,
        manager.operationState(job, detach_operation).?,
    );
    try std.testing.expectEqual(
        io_manager.JobState.completed_with_errors,
        manager.jobState(job).?,
    );

    var source_stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.lstat(source_z, &source_stat));
    try std.testing.expect((source_stat.st_mode & c.S_IFMT) == c.S_IFLNK);
    const replacement_target = try readLink(allocator, source);
    defer allocator.free(replacement_target);
    try std.testing.expectEqualStrings("../replacement-target", replacement_target);

    const copied_contents = try readFile(allocator, destination);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings("published destination contents", copied_contents);
}
