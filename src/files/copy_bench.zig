//! Opt-in end-to-end benchmarks for the production JobRunner copy path.
//!
//! Set REDIWM_COPY_BENCH_DIR to an existing writable directory on the
//! filesystem to benchmark. Both source and destination trees are created
//! there. The default is /tmp.
//!
//! Timings include JobRunner's manifest/size scan and the actual copy.
//! Workload generation and destination cleanup are outside the timed interval.
//! A warm-up run precedes five measured runs for each profile.

const std = @import("std");
const ops = @import("ops.zig");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

const benchmark_iterations = 5;
const write_buffer_size = 64 * 1024;
const job_timeout_ns: u64 = 10 * 60 * std.time.ns_per_s;

fn sleepOneMs() void {
    const request = c.struct_timespec{
        .tv_sec = 0,
        .tv_nsec = 1_000_000,
    };
    _ = c.nanosleep(&request, null);
}

const ProfileKind = enum {
    small_file_heavy,
    large_file_heavy,
    deep_hierarchy,
    mixed_sizes,
};

const Profile = struct {
    name: []const u8,
    kind: ProfileKind,
};

const profiles = [_]Profile{
    .{ .name = "small_file_heavy", .kind = .small_file_heavy },
    .{ .name = "large_file_heavy", .kind = .large_file_heavy },
    .{ .name = "deep_hierarchy", .kind = .deep_hierarchy },
    .{ .name = "mixed_sizes", .kind = .mixed_sizes },
};

const WorkloadStats = struct {
    files: usize = 0,
    directories: usize = 1,
    total_bytes: u64 = 0,
};

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

fn createDirectory(allocator: Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    if (c.mkdir(path_z, 0o755) != 0) return error.CreateDirectoryFailed;
}

fn writeFile(
    allocator: Allocator,
    path: []const u8,
    size: u64,
    seed: u64,
) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const fd = c.open(
        path_z,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
        @as(c_uint, 0o644),
    );
    if (fd < 0) return error.OpenSourceFileFailed;
    defer _ = c.close(fd);

    var buffer: [write_buffer_size]u8 = undefined;
    var remaining = size;
    var rng = seed | 1;

    while (remaining > 0) {
        const chunk: usize = @intCast(@min(
            remaining,
            @as(u64, buffer.len),
        ));

        // Deterministic high-entropy contents avoid benchmarking an
        // artificially compressible all-zero workload.
        for (buffer[0..chunk]) |*byte| {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            byte.* = @truncate(rng >> 24);
        }

        var written: usize = 0;
        while (written < chunk) {
            const result = c.write(
                fd,
                buffer[written..chunk].ptr,
                chunk - written,
            );
            if (result < 0 and std.posix.errno(result) == .INTR) continue;
            if (result <= 0) return error.WriteSourceFileFailed;
            written += @intCast(result);
        }

        remaining -= @intCast(chunk);
    }
}

fn addFile(
    allocator: Allocator,
    stats: *WorkloadStats,
    directory: []const u8,
    name: []const u8,
    size: u64,
    seed: u64,
) !void {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ directory, name },
    );
    defer allocator.free(path);

    try writeFile(allocator, path, size, seed);
    stats.files += 1;
    stats.total_bytes +|= size;
}

fn createWorkload(
    allocator: Allocator,
    source_root: []const u8,
    kind: ProfileKind,
) !WorkloadStats {
    try createDirectory(allocator, source_root);
    var stats: WorkloadStats = .{};

    switch (kind) {
        .small_file_heavy => {
            // 16 buckets × 128 files × 4 KiB = 8 MiB.
            for (0..16) |bucket_index| {
                const directory = try std.fmt.allocPrint(
                    allocator,
                    "{s}/bucket-{d}",
                    .{ source_root, bucket_index },
                );
                defer allocator.free(directory);
                try createDirectory(allocator, directory);
                stats.directories += 1;

                for (0..128) |file_index| {
                    const index = bucket_index * 128 + file_index;
                    const name = try std.fmt.allocPrint(
                        allocator,
                        "file-{d}.bin",
                        .{index},
                    );
                    defer allocator.free(name);
                    try addFile(
                        allocator,
                        &stats,
                        directory,
                        name,
                        4 * 1024,
                        @intCast(index + 1),
                    );
                }
            }
        },
        .large_file_heavy => {
            // Four large files, 128 MiB total.
            for (0..4) |index| {
                const name = try std.fmt.allocPrint(
                    allocator,
                    "large-{d}.bin",
                    .{index},
                );
                defer allocator.free(name);
                try addFile(
                    allocator,
                    &stats,
                    source_root,
                    name,
                    32 * 1024 * 1024,
                    @intCast(index + 100),
                );
            }
        },
        .deep_hierarchy => {
            // Eight nested directories, with 512 files at the leaf.
            var leaf = try allocator.dupe(u8, source_root);
            defer allocator.free(leaf);

            for (0..8) |depth| {
                const next = try std.fmt.allocPrint(
                    allocator,
                    "{s}/level-{d}",
                    .{ leaf, depth },
                );
                try createDirectory(allocator, next);
                allocator.free(leaf);
                leaf = next;
                stats.directories += 1;
            }

            for (0..512) |index| {
                const name = try std.fmt.allocPrint(
                    allocator,
                    "file-{d}.bin",
                    .{index},
                );
                defer allocator.free(name);
                try addFile(
                    allocator,
                    &stats,
                    leaf,
                    name,
                    64 * 1024,
                    @intCast(index + 200),
                );
            }
        },
        .mixed_sizes => {
            // Eight buckets × 16 files, spanning 4 KiB to 4 MiB.
            const sizes = [_]u64{
                4 * 1024,
                64 * 1024,
                256 * 1024,
                1024 * 1024,
                4 * 1024 * 1024,
            };

            for (0..8) |bucket_index| {
                const directory = try std.fmt.allocPrint(
                    allocator,
                    "{s}/bucket-{d}",
                    .{ source_root, bucket_index },
                );
                defer allocator.free(directory);
                try createDirectory(allocator, directory);
                stats.directories += 1;

                for (0..16) |file_index| {
                    const index = bucket_index * 16 + file_index;
                    const name = try std.fmt.allocPrint(
                        allocator,
                        "file-{d}.bin",
                        .{index},
                    );
                    defer allocator.free(name);
                    try addFile(
                        allocator,
                        &stats,
                        directory,
                        name,
                        sizes[index % sizes.len],
                        @intCast(index + 300),
                    );
                }
            }
        },
    }

    return stats;
}

fn runCopySample(
    allocator: Allocator,
    runner: *ops.JobRunner,
    source_root: []const u8,
    benchmark_root: []const u8,
    profile_name: []const u8,
    iteration: usize,
    expected_bytes: u64,
) !u64 {
    const destination = try std.fmt.allocPrint(
        allocator,
        "{s}/destination-{s}-{d}",
        .{ benchmark_root, profile_name, iteration },
    );
    defer allocator.free(destination);

    try createDirectory(allocator, destination);
    defer ops.deleteRecursive(allocator, destination) catch {};

    const start = monotonicNowNs();
    try runner.start(.copy, &.{source_root}, destination, .skip);

    while (true) {
        const progress = runner.pollProgress();
        if (progress.state == .finished) {
            if (!progress.total_bytes_known or
                progress.total_bytes != expected_bytes)
            {
                return error.InvalidMeasuredTransferSize;
            }
            if (progress.success_count != 1 or
                progress.failed_count != 0 or
                progress.skipped_count != 0)
            {
                return error.CopyJobFailed;
            }
            return monotonicNowNs() - start;
        }

        if (monotonicNowNs() - start > job_timeout_ns) {
            runner.cancel();
            while (runner.pollProgress().state != .finished) {
                sleepOneMs();
            }
            return error.CopyJobTimedOut;
        }

        sleepOneMs();
    }
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

fn emitRow(profile: Profile, stats: WorkloadStats, samples: []const u64) void {
    const median_ns = samples[samples.len / 2];
    const mib_per_second =
        @as(f64, @floatFromInt(stats.total_bytes)) *
        @as(f64, @floatFromInt(std.time.ns_per_s)) /
        @as(f64, @floatFromInt(median_ns)) /
        (1024 * 1024);
    const files_per_second =
        @as(f64, @floatFromInt(stats.files)) *
        @as(f64, @floatFromInt(std.time.ns_per_s)) /
        @as(f64, @floatFromInt(median_ns));

    std.debug.print(
        "BENCH,A,job_copy_e2e,{s},warm_source_cache,{d},{d},{d},{d},{d},{d},{d},{d},{d:.2},{d:.2}\n",
        .{
            profile.name,
            stats.files,
            stats.directories,
            stats.total_bytes,
            ops.copy_buffer_size,
            benchmark_iterations,
            median_ns,
            samples[0],
            samples[samples.len - 1],
            mib_per_second,
            files_per_second,
        },
    );
}

fn benchmarkProfile(
    allocator: Allocator,
    benchmark_root: []const u8,
    profile: Profile,
) !void {
    const source_root = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}-source",
        .{ benchmark_root, profile.name },
    );
    defer allocator.free(source_root);

    const stats = try createWorkload(allocator, source_root, profile.kind);
    var runner = try ops.JobRunner.init(allocator);
    defer runner.deinit();

    // Warm source data and filesystem metadata outside measured samples.
    _ = try runCopySample(
        allocator,
        runner,
        source_root,
        benchmark_root,
        profile.name,
        0,
        stats.total_bytes,
    );

    var samples: [benchmark_iterations]u64 = undefined;
    for (&samples, 0..) |*sample, iteration| {
        sample.* = try runCopySample(
            allocator,
            runner,
            source_root,
            benchmark_root,
            profile.name,
            iteration,
            stats.total_bytes,
        );
    }
    sortSamples(&samples);
    emitRow(profile, stats, &samples);
}

pub fn run(allocator: Allocator) !void {
    const configured_root = c.getenv("REDIWM_COPY_BENCH_DIR");
    const base_path = if (configured_root) |path|
        std.mem.span(path)
    else
        "/tmp";

    var template_buffer: [4096]u8 = undefined;
    const template = try std.fmt.bufPrintSentinel(
        &template_buffer,
        "{s}/rediwm-copy-bench-XXXXXX",
        .{base_path},
        0,
    );
    const root_z = c.mkdtemp(template) orelse return error.TempDirectoryFailed;
    const benchmark_root = std.mem.span(root_z);
    defer ops.deleteRecursive(allocator, benchmark_root) catch {};

    std.debug.print(
        "BENCH,phase,operation,profile,cache_mode,files,directories,total_bytes,buffer_bytes,iterations,median_ns,min_ns,max_ns,median_mib_per_second,median_files_per_second\n",
        .{},
    );

    for (profiles) |profile| {
        try benchmarkProfile(allocator, benchmark_root, profile);
    }
}
