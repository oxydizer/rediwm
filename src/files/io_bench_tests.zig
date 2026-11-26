//! S5's measured check: is the UI thread still responsive while the I/O service
//! is busy? Runs the production Service and Coordinator with three windows
//! whose event loop is this thread, under concurrent large copies, a copy of
//! many small files, an archive extraction and, optionally, a copy from a
//! stalled mount. Opt-in: `REDIWM_RUN_BENCHMARKS=1 zig build bench-files-io`.
//!
//! What the UI thread pays for the service is the time spent in its calls
//! (`fetchChanges`, `takeReply`, `trySend`); they never wait (threading §3), so
//! their cost per iteration is the service's share of the frame budget. A
//! request every 100 ms measures how quickly the coordinator and the task pool
//! answer while all of this runs.
//!
//! Environment:
//! * `REDIWM_IO_BENCH_DIR`: where the fixtures and copies go. Use the
//!   filesystem you want to measure; without it a temporary directory is used
//!   and the output says so.
//! * `REDIWM_IO_BENCH_SCALE`: multiplies the fixture sizes (default 1: two
//!   256 MiB files, 10 000 files of 4 KiB, a zip of 5 000 entries).
//! * `REDIWM_IO_BENCH_LIMIT_S`: when to stop waiting and report (default 600
//!   per scale step); jobs still running are reported as such and cancelled.
//! * `REDIWM_IO_BENCH_STALL` and `REDIWM_IO_BENCH_STALL_PID`: a folder on a
//!   FUSE mount and the pid of its daemon (an `sshfs`, say). The daemon is
//!   stopped with SIGSTOP before a copy from that folder is submitted, and
//!   continued with SIGCONT before teardown, so the copy hangs as on a dead
//!   network mount and the run still ends. Two windows copy from it, more
//!   than the service task pool has workers.
//! * `REDIWM_IO_BENCH_STALL_MODE`: `prepare` (default) stops the daemon before
//!   the stalled copies are submitted, so they hang in their prepare task;
//!   `running` submits one stalled copy, waits until it has copied bytes, then
//!   stops the daemon, so it hangs inside the discovery and operation
//!   executors. The folder should be large enough to take a few seconds.
//! * `REDIWM_IO_BENCH_SERIAL_LIMIT`: operations at a time on a spinning or
//!   USB disk (default 0, no limit), to calibrate the limit on one
//!   (worker-pools §4.4). Compare runs with the bench folder on that disk.
//! * `REDIWM_IO_BENCH_LATE_STALL_S`: submit the second stalled copy this many
//!   seconds after the others, once its mount is suspect (10 s), so it waits
//!   for the mount instead of taking a worker.
//! * `REDIWM_IO_BENCH_HOLD_S`: keep running at least this long even when the
//!   other jobs are done, so a stalled job's `waiting_for` (reported after
//!   30 s) shows in its line.
const std = @import("std");
const c = @import("c.zig").api;
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const io_thread_guard = @import("io_thread_guard.zig");
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");

const allocator = std.heap.c_allocator;
const window_count = 3;
const probe_interval_ms = 100;
/// A UI iteration waits at most one 60 Hz frame for the update wake.
const frame_ms = 16;

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

const Fixture = struct {
    root: []u8,
    temporary: bool,
    big: [2][]u8 = undefined,
    small: []u8 = undefined,
    archive: []u8 = undefined,
    big_bytes: u64 = 0,
    small_files: usize = 0,
    archive_entries: usize = 0,

    fn path(self: *const Fixture, name: []const u8) ![]u8 {
        return support.join(allocator, self.root, name);
    }

    fn create(scale: usize) !Fixture {
        var self: Fixture = blk: {
            if (getenv("REDIWM_IO_BENCH_DIR")) |base| {
                if (base.len == 0) return error.InvalidBenchmarkDirectory;
                const template = try std.fmt.allocPrintSentinel(allocator, "{s}/rediwm_io_bench_XXXXXX", .{base}, 0);
                defer allocator.free(template);
                if (c.mkdtemp(template.ptr) == null) return error.CannotCreateBenchmarkDirectory;
                break :blk .{ .root = try allocator.dupe(u8, template), .temporary = false };
            }
            var buffer: [256]u8 = undefined;
            break :blk .{ .root = try allocator.dupe(u8, try support.makeTempDir(&buffer)), .temporary = true };
        };
        errdefer ops.deleteRecursive(allocator, self.root) catch {};

        // Large files: real blocks, not holes, so a copy moves the bytes.
        self.big_bytes = 256 * 1024 * 1024 * @as(u64, scale);
        const chunk = try allocator.alloc(u8, 1024 * 1024);
        defer allocator.free(chunk);
        for (chunk, 0..) |*byte, i| byte.* = @truncate(i *% 2654435761);
        for (&self.big, 0..) |*big, index| {
            big.* = try std.fmt.allocPrint(allocator, "{s}/big-{d}.bin", .{ self.root, index });
            const z = try allocator.dupeSentinel(u8, big.*, 0);
            defer allocator.free(z);
            const fd = c.open(z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o644));
            if (fd < 0) return error.CannotWriteFixture;
            defer _ = c.close(fd);
            var written: u64 = 0;
            while (written < self.big_bytes) : (written += chunk.len) {
                if (c.write(fd, chunk.ptr, chunk.len) != chunk.len) return error.CannotWriteFixture;
            }
        }

        // Many small files in 100 folders.
        self.small = try self.path("small");
        try support.makeDirectory(self.small);
        self.small_files = 10_000 * scale;
        const contents = chunk[0..4096];
        for (0..100) |d| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/d{d:0>3}", .{ self.small, d });
            defer allocator.free(dir);
            try support.makeDirectory(dir);
            for (0..self.small_files / 100) |f| {
                const file = try std.fmt.allocPrint(allocator, "{s}/f{d:0>5}", .{ dir, f });
                defer allocator.free(file);
                try support.writeFile(file, contents);
            }
        }

        // A zip of small entries.
        self.archive = try self.path("archive.zip");
        self.archive_entries = 5_000 * scale;
        try writeZip(self.archive, self.archive_entries, chunk[0..1024]);
        return self;
    }

    fn destroy(self: *Fixture) void {
        ops.deleteRecursive(allocator, self.root) catch {};
        for (self.big) |big| allocator.free(big);
        allocator.free(self.small);
        allocator.free(self.archive);
        allocator.free(self.root);
    }
};

fn writeZip(path: []const u8, entries: usize, contents: []const u8) !void {
    const api = @import("c_archive");
    const writer = api.archive_write_new() orelse return error.OutOfMemory;
    defer _ = api.archive_write_free(writer);
    if (api.archive_write_set_format_zip(writer) != 0) return error.ArchiveWriteFailed;
    const z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(z);
    if (api.archive_write_open_filename(writer, z) != 0) return error.ArchiveWriteFailed;
    for (0..entries) |index| {
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&name_buffer, "dir-{d:0>3}/entry-{d:0>6}.bin", .{ index % 100, index }, 0);
        const entry = api.archive_entry_new() orelse return error.OutOfMemory;
        defer api.archive_entry_free(entry);
        api.archive_entry_set_pathname(entry, name);
        api.archive_entry_set_filetype(entry, c.S_IFREG);
        api.archive_entry_set_perm(entry, 0o644);
        api.archive_entry_set_size(entry, @intCast(contents.len));
        if (api.archive_write_header(writer, entry) != 0) return error.ArchiveWriteFailed;
        if (api.archive_write_data(writer, contents.ptr, contents.len) != @as(isize, @intCast(contents.len)))
            return error.ArchiveWriteFailed;
    }
    if (api.archive_write_close(writer) != 0) return error.ArchiveWriteFailed;
}

const Job = struct {
    name: []const u8,
    tag: u64,
    window: usize,
    stalled: bool = false,
    submitted_ns: u64 = 0,
    record: ?io_service.JobRecord = null,
    ended_ns: u64 = 0,

    fn done(self: *const Job) bool {
        const record = self.record orelse return false;
        return record.removed or record.state.isTerminal();
    }
};

/// One UI iteration's samples, and the request probe's round trips.
const Stats = struct {
    iteration_ns: std.ArrayList(u64) = .empty,
    probe_ms: std.ArrayList(u64) = .empty,
    busy: usize = 0,
    iterations: usize = 0,
    /// Per window: when its fetches started failing with ServiceBusy, and the
    /// longest such stretch. A refused fetch never blocks, but the window shows
    /// stale state until one succeeds.
    refused_since: [window_count]?u64 = @splat(null),
    longest_refused_ns: u64 = 0,
    fetches: usize = 0,
    refused_fetches: usize = 0,

    fn deinit(self: *Stats) void {
        self.iteration_ns.deinit(allocator);
        self.probe_ms.deinit(allocator);
    }
};

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const index: usize = @intFromFloat(@floor(p * @as(f64, @floatFromInt(sorted.len - 1))));
    return sorted[index];
}

fn sendOwned(window: io_service.Handle, command: *io_service.Command) !void {
    support.sendOwned(window, command) catch |err| {
        command.deinitPayload();
        return err;
    };
}

fn submitCopy(window: io_service.Handle, tag: u64, destination: []const u8, sources: []const []const u8) !void {
    var command: io_service.Command = .{
        .kind = .submit_job,
        .submit_tag = tag,
        .payload = try io_service.OwnedPayload.createTransfer(allocator, .copy, destination, sources),
    };
    try sendOwned(window, &command);
}

fn submitExtract(window: io_service.Handle, tag: u64, archive: []const u8, destination: []const u8) !void {
    var command: io_service.Command = .{
        .kind = .submit_job,
        .submit_tag = tag,
        .payload = try io_service.OwnedPayload.createArchive(allocator, .extract, archive, destination, &.{}),
    };
    try sendOwned(window, &command);
}

fn submitJob(job: anytype, window: io_service.Handle, destinations: anytype, fixture: anytype, stall_path: ?[]const u8) !void {
    job.submitted_ns = nowNs();
    switch (job.tag) {
        1 => try submitCopy(window, job.tag, destinations[0], &.{ fixture.big[0], fixture.big[1] }),
        2 => try submitCopy(window, job.tag, destinations[1], &.{fixture.small}),
        3 => try submitExtract(window, job.tag, fixture.archive, destinations[2]),
        4 => try submitCopy(window, job.tag, destinations[3], &.{stall_path.?}),
        5 => try submitCopy(window, job.tag, destinations[4], &.{stall_path.?}),
        else => unreachable,
    }
}

fn stallSignal(signal: c_int) void {
    const pid_text = getenv("REDIWM_IO_BENCH_STALL_PID") orelse return;
    const pid = std.fmt.parseInt(c.pid_t, pid_text, 10) catch return;
    _ = c.kill(pid, signal);
}

test "files io responsiveness benchmark" {
    const enabled = getenv("REDIWM_RUN_BENCHMARKS") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    const scale = if (getenv("REDIWM_IO_BENCH_SCALE")) |text| try std.fmt.parseInt(usize, text, 10) else 1;
    if (scale == 0) return error.InvalidBenchmarkScale;

    const setup_start = nowNs();
    var fixture = try Fixture.create(scale);
    defer fixture.destroy();
    std.debug.print("BENCH,dir,{s},temporary,{}\n", .{ fixture.root, fixture.temporary });
    if (fixture.temporary) std.debug.print(
        "note: REDIWM_IO_BENCH_DIR is not set; this measures the temporary directory's filesystem\n",
        .{},
    );
    std.debug.print("BENCH,setup_s,{d:.1}\n", .{@as(f64, @floatFromInt(nowNs() - setup_start)) / 1e9});

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, std.testing.io, &service);
    // Before any submit, which the coordinator reads through the service's lock.
    if (getenv("REDIWM_IO_BENCH_SERIAL_LIMIT")) |text| coordinator.serial_limit = try std.fmt.parseInt(u32, text, 10);
    defer coordinator.deinit();
    var windows: [window_count]io_service.Handle = undefined;
    for (&windows) |*window| window.* = try service.registerWindow();
    defer for (&windows) |*window| window.close();

    // Destinations, one per job, so nothing conflicts.
    const names = [_][]const u8{ "out-big", "out-small", "out-extract", "out-stall", "out-stall-2" };
    var destinations: [names.len][]u8 = undefined;
    for (names, &destinations) |name, *destination| {
        destination.* = try fixture.path(name);
        try support.makeDirectory(destination.*);
    }
    defer for (destinations) |destination| allocator.free(destination);

    var jobs: std.ArrayList(Job) = .empty;
    defer jobs.deinit(allocator);
    try jobs.append(allocator, .{ .name = "big_copy", .tag = 1, .window = 0 });
    try jobs.append(allocator, .{ .name = "small_copy", .tag = 2, .window = 1 });
    try jobs.append(allocator, .{ .name = "extract", .tag = 3, .window = 1 });
    const stall_path = getenv("REDIWM_IO_BENCH_STALL");
    // Two windows each copy from the dead mount: more stalled prepares than
    // the service task pool has workers.
    if (stall_path != null) {
        try jobs.append(allocator, .{ .name = "stalled_copy", .tag = 4, .window = 2, .stalled = true });
        try jobs.append(allocator, .{ .name = "stalled_copy_2", .tag = 5, .window = 0, .stalled = true });
    }

    // From here this thread is the UI thread: a blocking filesystem call
    // reached through a service call aborts the run.
    io_thread_guard.markCurrent(.ui);
    defer io_thread_guard.markCurrent(.none);

    const stall_running = if (getenv("REDIWM_IO_BENCH_STALL_MODE")) |mode| std.mem.eql(u8, mode, "running") else false;
    defer if (stall_path) |_| stallSignal(c.SIGCONT);
    if (stall_path) |path| {
        if (stall_running) {
            // One stalled copy, started while the mount still answers.
            // A second one comes only late, once its mount is suspect.
            if (getenv("REDIWM_IO_BENCH_LATE_STALL_S") == null) _ = jobs.pop();
            const job = &jobs.items[3];
            job.submitted_ns = nowNs();
            try submitCopy(windows[job.window], job.tag, destinations[3], &.{path});
            const give_up = nowNs() + 60 * std.time.ns_per_s;
            while (nowNs() < give_up) {
                _ = support.waitReadable(service.updateWakeFd(), frame_ms);
                _ = service.drainUpdateWake();
                var out: [16]io_service.JobRecord = undefined;
                const result = windows[job.window].fetchChanges(&out) catch continue;
                for (out[0..result.count]) |record| if (record.submit_tag == job.tag) {
                    job.record = record;
                };
                if (job.record) |record| if (record.state == .running and record.completed_bytes > 0) break;
            } else return error.StalledCopyNeverStarted;
            std.debug.print("BENCH,stall,running,after_bytes,{d}\n", .{job.record.?.completed_bytes});
        }
        stallSignal(c.SIGSTOP);
    }

    const started = nowNs();
    const late_stall_ns: ?u64 = if (getenv("REDIWM_IO_BENCH_LATE_STALL_S")) |text|
        started + try std.fmt.parseInt(u64, text, 10) * std.time.ns_per_s
    else
        null;
    for (jobs.items) |*job| {
        if (job.submitted_ns != 0 or (job.tag == 5 and late_stall_ns != null)) continue;
        try submitJob(job, windows[job.window], &destinations, &fixture, stall_path);
    }

    var stats: Stats = .{};
    defer stats.deinit();
    var probe_sent_ns: ?u64 = null;
    var next_probe_ns = started;
    var probe_tag: u64 = 1000;
    var unanswered_probes: usize = 0;
    const limit_s: u64 = if (getenv("REDIWM_IO_BENCH_LIMIT_S")) |text| try std.fmt.parseInt(u64, text, 10) else 600 * @as(u64, scale);
    const deadline_ns = started + limit_s * std.time.ns_per_s;
    const hold_s: u64 = if (getenv("REDIWM_IO_BENCH_HOLD_S")) |text| try std.fmt.parseInt(u64, text, 10) else 0;
    const hold_ns = started + hold_s * std.time.ns_per_s;
    const probe_paths = [_][]const u8{fixture.root};

    while (true) {
        var finished = true;
        for (jobs.items) |*job| if (!job.stalled and !job.done()) {
            finished = false;
        };
        if ((finished and nowNs() >= hold_ns) or nowNs() > deadline_ns) break;
        if (late_stall_ns) |at| if (nowNs() >= at) for (jobs.items) |*job| {
            if (job.tag == 5 and job.submitted_ns == 0) try submitJob(job, windows[job.window], &destinations, &fixture, stall_path);
        };

        _ = support.waitReadable(service.updateWakeFd(), frame_ms);
        const begin = nowNs();
        _ = service.drainUpdateWake();
        for (&windows, 0..) |window, index| {
            // One buffer per window per iteration, as a Files window reads.
            var out: [16]io_service.JobRecord = undefined;
            stats.fetches += 1;
            if (window.fetchChanges(&out)) |result| {
                if (stats.refused_since[index]) |since| {
                    stats.longest_refused_ns = @max(stats.longest_refused_ns, nowNs() - since);
                    stats.refused_since[index] = null;
                }
                for (out[0..result.count]) |record| {
                    for (jobs.items) |*job| {
                        if (job.window != index or job.tag != record.submit_tag) continue;
                        if (job.record) |old| if (old.revision > record.revision) continue;
                        job.record = record;
                        if (job.ended_ns == 0 and job.done()) job.ended_ns = nowNs();
                    }
                }
            } else |err| switch (err) {
                error.ServiceBusy => {
                    stats.busy += 1;
                    stats.refused_fetches += 1;
                    if (stats.refused_since[index] == null) stats.refused_since[index] = nowNs();
                },
                else => return err,
            }
            if (index == 0) {
                while (window.takeReply() catch blk: {
                    stats.busy += 1;
                    break :blk null;
                }) |reply| {
                    reply.destroy();
                    if (probe_sent_ns) |sent| try stats.probe_ms.append(allocator, (nowNs() - sent) / std.time.ns_per_ms);
                    probe_sent_ns = null;
                }
            }
        }
        // The probe: one request at a time, every 100 ms.
        if (probe_sent_ns == null and begin >= next_probe_ns) {
            probe_tag += 1;
            var command: io_service.Command = .{
                .kind = .request,
                .submit_tag = probe_tag,
                .payload = try io_service.OwnedPayload.createRequest(allocator, .{ .canonical = .{ .paths = &probe_paths } }),
            };
            if (windows[0].trySendOwned(&command)) {
                probe_sent_ns = nowNs();
            } else |err| {
                command.deinitPayload();
                if (err == error.ServiceBusy) stats.busy += 1 else return err;
            }
            next_probe_ns = begin + probe_interval_ms * std.time.ns_per_ms;
        }
        try stats.iteration_ns.append(allocator, nowNs() - begin);
        stats.iterations += 1;
    }
    if (probe_sent_ns != null) unanswered_probes = 1;

    // Report.
    std.mem.sort(u64, stats.iteration_ns.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, stats.probe_ms.items, {}, std.sort.asc(u64));
    const it = stats.iteration_ns.items;
    std.debug.print("BENCH,windows,{d},scale,{d}\n", .{ window_count, scale });
    std.debug.print("BENCH,ui_iterations,{d},service_busy,{d}\n", .{ stats.iterations, stats.busy });
    std.debug.print("BENCH,fetches,{d},refused,{d},longest_refused_ms,{d}\n", .{
        stats.fetches,
        stats.refused_fetches,
        stats.longest_refused_ns / std.time.ns_per_ms,
    });
    std.debug.print("BENCH,ui_service_us,p50,{d},p99,{d},p999,{d},max,{d}\n", .{
        percentile(it, 0.5) / 1000,
        percentile(it, 0.99) / 1000,
        percentile(it, 0.999) / 1000,
        if (it.len > 0) it[it.len - 1] / 1000 else 0,
    });
    const pr = stats.probe_ms.items;
    std.debug.print("BENCH,probe_rtt_ms,count,{d},p50,{d},p99,{d},max,{d},unanswered,{d}\n", .{
        pr.len,
        percentile(pr, 0.5),
        percentile(pr, 0.99),
        if (pr.len > 0) pr[pr.len - 1] else 0,
        unanswered_probes,
    });
    // Reading pool sizes from the test thread is safe: they lock.
    std.debug.print("BENCH,workers,tasks,{d},staging,{d},deletion,{d},discovery,{d},operations,{d}\n", .{
        coordinator.tasks.workerCount(),
        coordinator.staging_tasks.workerCount(),
        coordinator.deletion_pool.workerCount(),
        if (coordinator.runtime.discovery_executor) |*e| e.pool.workerCount() else 0,
        if (coordinator.runtime.operation_executor) |*e| e.executor.pool.workerCount() else 0,
    });
    for (jobs.items) |job| {
        const record = job.record orelse io_service.JobRecord{};
        const end = if (job.ended_ns != 0) job.ended_ns else nowNs();
        const seconds = @as(f64, @floatFromInt(end - job.submitted_ns)) / 1e9;
        const mib = @as(f64, @floatFromInt(record.completed_bytes)) / (1024 * 1024);
        std.debug.print("BENCH,job,{s},state,{s},seconds,{d:.2},MiB,{d:.1},MiB_per_s,{d:.1},items,{d}/{d},waiting_for,{s}\n", .{
            job.name,
            @tagName(record.state),
            seconds,
            mib,
            if (seconds > 0) mib / seconds else 0,
            record.completed_items,
            record.total_items,
            record.waitingFor(),
        });
    }

    // Leave nothing running: cancel what is left, resume a stopped mount,
    // and let the coordinator drain.
    for (jobs.items) |job| if (!job.done()) if (job.record) |record| {
        support.send(windows[job.window], .{ .kind = .cancel_job, .job_id = record.id }) catch {};
    };
}
