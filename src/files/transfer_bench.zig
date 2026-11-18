//! Opt-in benchmarks for the Files transfer progress and tree model.
//!
//! Output is CSV-shaped and prefixed with "BENCH," so it can be extracted
//! without including Zig's test-runner diagnostics.

const std = @import("std");
const ops = @import("ops.zig");
const projection = @import("transfer_tree.zig");
const tree_state = @import("app_transfer_tree.zig");
const Allocator = std.mem.Allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const benchmark_iterations = 5;
const concurrent_iterations = 3;
const concurrent_polls_per_thread = 10;

const Workload = struct {
    allocator: Allocator,
    runner: *ops.JobRunner,
    directory_paths: std.ArrayList([]u8) = .empty,
    paths: [][]const u8 = &.{},
    results: []?f64 = &.{},
    matched: []bool = &.{},

    fn init(allocator: Allocator, file_count: usize) !Workload {
        const runner = try ops.JobRunner.init(allocator);
        var workload: Workload = .{
            .allocator = allocator,
            .runner = runner,
        };
        errdefer workload.deinit();

        try runner.sources.append(allocator, try allocator.dupe(u8, "/source"));
        try runner.destination_paths.append(
            allocator,
            try allocator.dupe(u8, "/destination"),
        );
        try runner.outcomes.append(allocator, .success);
        try runner.item_bytes.append(allocator, 0);
        try runner.item_transferred_bytes.append(allocator, 0);

        try runner.manifest.append(
            "/source",
            "",
            "/destination",
            0,
            .directory,
            0,
        );

        // Keep directories at roughly 100 files each. This gives the
        // progress lookup benchmark a useful set of visible directory paths.
        const bucket_count = (file_count + 99) / 100;
        for (0..bucket_count) |bucket_index| {
            const relative = try std.fmt.allocPrint(
                allocator,
                "bucket-{d}",
                .{bucket_index},
            );
            defer allocator.free(relative);

            const source = try std.fmt.allocPrint(
                allocator,
                "/source/{s}",
                .{relative},
            );
            defer allocator.free(source);

            const destination = try std.fmt.allocPrint(
                allocator,
                "/destination/{s}",
                .{relative},
            );

            try runner.manifest.append(
                source,
                relative,
                destination,
                0,
                .directory,
                0,
            );
            try workload.directory_paths.append(allocator, destination);

            const first_file = bucket_index * 100;
            const end_file = @min(file_count, first_file + 100);
            for (first_file..end_file) |file_index| {
                const file_relative = try std.fmt.allocPrint(
                    allocator,
                    "{s}/file-{d}.bin",
                    .{ relative, file_index },
                );
                defer allocator.free(file_relative);

                const file_source = try std.fmt.allocPrint(
                    allocator,
                    "/source/{s}",
                    .{file_relative},
                );
                defer allocator.free(file_source);

                const file_destination = try std.fmt.allocPrint(
                    allocator,
                    "/destination/{s}",
                    .{file_relative},
                );
                defer allocator.free(file_destination);

                const size: u64 = 1024 + (file_index % 65536);
                try runner.manifest.append(
                    file_source,
                    file_relative,
                    file_destination,
                    size,
                    .file,
                    0,
                );
            }
        }

        workload.paths = try allocator.alloc(
            []const u8,
            workload.directory_paths.items.len,
        );
        for (workload.directory_paths.items, 0..) |path, index| {
            workload.paths[index] = path;
        }

        workload.results = try allocator.alloc(?f64, workload.paths.len);
        workload.matched = try allocator.alloc(bool, workload.paths.len);

        runner.kind = .copy;
        runner.state = .running;
        return workload;
    }

    fn deinit(self: *Workload) void {
        if (self.paths.len > 0) self.allocator.free(self.paths);
        if (self.results.len > 0) self.allocator.free(self.results);
        if (self.matched.len > 0) self.allocator.free(self.matched);

        for (self.directory_paths.items) |path| {
            self.allocator.free(path);
        }
        self.directory_paths.deinit(self.allocator);
        self.runner.deinit();
    }
};

fn runBatch(workload: *Workload) anyerror!void {
    try workload.runner.progressForPaths(
        workload.paths,
        workload.results,
        workload.matched,
    );
}

fn runIndividual(workload: *Workload) anyerror!void {
    for (workload.paths) |path| {
        _ = workload.runner.progressForPath(path);
    }
}

fn validateProgressResults(workload: *Workload) !void {
    try runBatch(workload);
    for (workload.paths, 0..) |path, index| {
        try std.testing.expect(workload.matched[index]);
        try std.testing.expectEqual(
            workload.results[index],
            workload.runner.progressForPath(path),
        );
    }
}

fn runTreeBuild(workload: *Workload) anyerror!void {
    var tree = try projection.build(
        workload.allocator,
        workload.runner.manifest.entries.items,
    );
    tree.deinit();
}

const TreeContext = struct {
    tree: *const projection.Tree,
    state: *tree_state.State,
};

fn runAggregate(context: *TreeContext) anyerror!void {
    try context.state.recomputeAggregates(
        context.tree,
        "/source/bucket-0/file-0.bin",
        512,
        1024,
    );
}

fn runVisibleCount(context: *TreeContext) anyerror!void {
    std.mem.doNotOptimizeAway(context.state.visibleCount(context.tree));
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

fn measure(context: anytype, comptime operation: anytype) !u64 {
    const start = monotonicNowNs();
    try operation(context);
    return monotonicNowNs() - start;
}

fn sortSamples(samples: []u64) void {
    for (0..samples.len) |i| {
        for (i + 1..samples.len) |j| {
            if (samples[j] < samples[i]) {
                std.mem.swap(u64, &samples[i], &samples[j]);
            }
        }
    }
}

fn collectSamples(
    context: anytype,
    comptime operation: anytype,
    samples: []u64,
) !void {
    // Warm caches and lazy initialization outside the measured samples.
    _ = try measure(context, operation);
    for (samples) |*sample| {
        sample.* = try measure(context, operation);
    }
    sortSamples(samples);
}

fn emitRow(
    phase: []const u8,
    operation: []const u8,
    profile: []const u8,
    files: usize,
    directories: usize,
    jobs: usize,
    polling_threads: usize,
    worker_count: usize,
    iterations: usize,
    operations_per_sample: usize,
    samples: []const u64,
) void {
    const median_ns = samples[samples.len / 2];
    const min_ns = samples[0];
    const max_ns = samples[samples.len - 1];
    const throughput = if (median_ns == 0)
        0
    else
        @as(f64, @floatFromInt(operations_per_sample)) * 1_000_000_000.0 /
            @as(f64, @floatFromInt(median_ns));

    std.debug.print(
        "BENCH,{s},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.2}\n",
        .{
            phase,
            operation,
            profile,
            files,
            directories,
            jobs,
            polling_threads,
            worker_count,
            iterations,
            median_ns,
            min_ns,
            max_ns,
            throughput,
        },
    );
}

fn benchmarkWorkload(workload: *Workload, file_count: usize) !void {
    // Verify both APIs return the same result for every requested directory
    // before comparing their performance.
    try validateProgressResults(workload);

    var tree = try projection.build(
        workload.allocator,
        workload.runner.manifest.entries.items,
    );
    defer tree.deinit();

    var state = tree_state.State.init(workload.allocator);
    defer state.deinit();

    try state.toggleExpanded("/destination");
    for (workload.directory_paths.items) |path| {
        try state.toggleExpanded(path);
    }

    var tree_context = TreeContext{
        .tree = &tree,
        .state = &state,
    };

    var samples: [benchmark_iterations]u64 = undefined;

    try collectSamples(workload, runBatch, &samples);
    emitRow(
        "A",
        "progress_batch",
        "bucketed",
        file_count,
        workload.paths.len,
        1,
        1,
        0,
        benchmark_iterations,
        workload.paths.len,
        &samples,
    );

    try collectSamples(workload, runIndividual, &samples);
    emitRow(
        "A",
        "progress_individual",
        "bucketed",
        file_count,
        workload.paths.len,
        1,
        1,
        0,
        benchmark_iterations,
        workload.paths.len,
        &samples,
    );

    try collectSamples(workload, runTreeBuild, &samples);
    emitRow(
        "A",
        "tree_build",
        "bucketed",
        file_count,
        workload.paths.len,
        1,
        1,
        0,
        benchmark_iterations,
        1,
        &samples,
    );

    try collectSamples(&tree_context, runAggregate, &samples);
    emitRow(
        "A",
        "tree_aggregate",
        "bucketed",
        file_count,
        workload.paths.len,
        1,
        1,
        0,
        benchmark_iterations,
        tree.nodes.items.len,
        &samples,
    );

    try collectSamples(&tree_context, runVisibleCount, &samples);
    emitRow(
        "A",
        "visible_count",
        "bucketed",
        file_count,
        workload.paths.len,
        1,
        1,
        0,
        benchmark_iterations,
        tree.nodes.items.len,
        &samples,
    );
}

const PollThreadContext = struct {
    workload: *Workload,
    iterations: usize,
    failed: bool = false,
};

fn pollThread(context: *PollThreadContext) void {
    for (0..context.iterations) |_| {
        context.workload.runner.progressForPaths(
            context.workload.paths,
            context.workload.results,
            context.workload.matched,
        ) catch {
            context.failed = true;
            return;
        };
    }
}

fn benchmarkConcurrentJobs(allocator: Allocator, job_count: usize) !void {
    var workloads: std.ArrayList(Workload) = .empty;
    defer {
        for (workloads.items) |*workload| workload.deinit();
        workloads.deinit(allocator);
    }

    for (0..job_count) |_| {
        try workloads.append(allocator, try Workload.init(allocator, 1000));
    }

    var contexts = try allocator.alloc(PollThreadContext, job_count);
    defer allocator.free(contexts);
    var threads = try allocator.alloc(?std.Thread, job_count);
    defer allocator.free(threads);

    var samples: [concurrent_iterations]u64 = undefined;
    for (&samples) |*sample| {
        for (0..job_count) |index| {
            contexts[index] = .{
                .workload = &workloads.items[index],
                .iterations = concurrent_polls_per_thread,
            };
            threads[index] = null;
        }

        const start = monotonicNowNs();
        var spawned: usize = 0;
        for (0..job_count) |index| {
            threads[index] = std.Thread.spawn(
                .{},
                pollThread,
                .{&contexts[index]},
            ) catch |err| {
                for (threads[0..spawned]) |thread| {
                    if (thread) |running| running.join();
                }
                return err;
            };
            spawned += 1;
        }

        for (threads) |thread| {
            if (thread) |running| running.join();
        }
        sample.* = monotonicNowNs() - start;

        for (contexts) |context| {
            if (context.failed) return error.ConcurrentBenchmarkFailed;
        }
    }

    sortSamples(&samples);
    emitRow(
        "C",
        "concurrent_batch_poll_e2e",
        "small_file",
        1000,
        workloads.items[0].paths.len,
        job_count,
        job_count,
        0,
        concurrent_polls_per_thread,
        job_count * concurrent_polls_per_thread *
            workloads.items[0].paths.len,
        &samples,
    );
}

test "transfer benchmark emits workload measurements" {
    const allocator = std.testing.allocator;
    const enabled = getenv("REDIWM_RUN_BENCHMARKS") orelse
        return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(enabled), "1")) {
        return error.SkipZigTest;
    }

    std.debug.print(
        "BENCH,phase,operation,profile,files,directories,jobs,polling_threads,worker_count,iterations,median_ns,min_ns,max_ns,operations_per_second\n",
        .{},
    );

    const file_counts = [_]usize{ 100, 1000, 5000, 10000, 50000 };
    for (file_counts) |file_count| {
        {
            var workload = try Workload.init(allocator, file_count);
            defer workload.deinit();
            try benchmarkWorkload(&workload, file_count);
        }
    }

    // These are genuinely concurrent polling threads, each operating on an
    // independent JobRunner. They are not presented as worker-pool results.
    for ([_]usize{ 1, 2, 4, 8 }) |job_count| {
        try benchmarkConcurrentJobs(allocator, job_count);
    }
}
