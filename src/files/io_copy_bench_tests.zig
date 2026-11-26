//! The copy path alone, without the service: `io_copy.execute` driven unit by
//! unit on this thread, as a worker would, over three file sets. Measures the
//! per-file cost of the copy itself (buffers, opens, publishing), which the
//! service benchmark mixes with scheduling. Opt-in:
//! `REDIWM_RUN_BENCHMARKS=1 zig build bench-files-copy`.
//!
//! * `REDIWM_COPY_BENCH_SRC`: where the sources go (default `/dev/shm`).
//! * `REDIWM_COPY_BENCH_DST`: where the copies go (default the current
//!   directory). Put them on different filesystem types (tmpfs to ext4, say)
//!   to measure the read/write fallback, or on one to measure
//!   `copy_file_range`; the output names the path taken.
//! * `REDIWM_COPY_BENCH_ROUNDS`: repetitions, best kept (default 3).
const std = @import("std");
const c = @import("c.zig").api;
const copy = @import("io_copy.zig");
const executor = @import("io_executor.zig");

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Set = struct { name: []const u8, count: usize, size: usize };
const sets = [_]Set{
    .{ .name = "small", .count = 10_000, .size = 4 * 1024 },
    .{ .name = "medium", .count = 400, .size = 1024 * 1024 },
    .{ .name = "large", .count = 2, .size = 256 * 1024 * 1024 },
};

fn makeDir(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/rediwm_copy_bench_{s}_{d}", .{ base, name, c.getpid() }, 0);
    if (c.mkdir(path, 0o700) != 0) return error.MkdirFailed;
    return path;
}

fn removeTree(allocator: std.mem.Allocator, path: []const u8) void {
    const argv = [_][]const u8{ "rm", "-rf", path };
    var child = std.process.spawn(std.testing.io, .{ .argv = &argv }) catch return;
    _ = child.wait(std.testing.io) catch {};
    _ = allocator;
}

fn writeFiles(allocator: std.mem.Allocator, dir: []const u8, set: Set) !void {
    const chunk = try allocator.alloc(u8, @min(set.size, 1024 * 1024));
    defer allocator.free(chunk);
    for (chunk, 0..) |*byte, i| byte.* = @truncate(i *% 131);
    for (0..set.count) |i| {
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/f{d}", .{ dir, i }, 0);
        defer allocator.free(path);
        const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        var left = set.size;
        while (left > 0) {
            const n = c.write(fd, chunk.ptr, @min(left, chunk.len));
            if (n <= 0) return error.WriteFailed;
            left -= @intCast(n);
        }
    }
}

/// Copies every file of the set, unit by unit; the copies are deferred-sync,
/// as in a copy job, and the destination's filesystem is synced at the end.
/// The two are timed apart: the sync is the disk's, the copy is ours.
const Timing = struct { copy_ns: u64, sync_ns: u64 };

fn copyAll(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, set: Set, metrics: *executor.CopyMetrics) !Timing {
    const started = nowNs();
    for (0..set.count) |i| {
        const source = try std.fmt.allocPrint(allocator, "{s}/f{d}", .{ src, i });
        defer allocator.free(source);
        const destination = try std.fmt.allocPrint(allocator, "{s}/f{d}", .{ dst, i });
        defer allocator.free(destination);
        var item = executor.WorkItem{
            .token = .{ .job_id = 1, .operation_id = i + 1, .generation = 1 },
            .operation_kind = .copy_file,
            .input = try copy.makeDeferredInput(allocator, source, destination, .{ .job_id = 1, .operation_id = i + 1, .generation = 1 }),
            .profile_enabled = true,
        };
        while (true) {
            const done = copy.execute(allocator, item);
            if (done.copy_metrics) |delta| metrics.add(delta);
            switch (done.outcome) {
                .yielded => item = .{
                    .token = .{ .job_id = 1, .operation_id = i + 1, .generation = done.token.generation + 1 },
                    .operation_kind = done.operation_kind,
                    .input = done.input,
                    .continuation = done.continuation,
                    .profile_enabled = true,
                },
                .completed => {
                    copy.complete(null, done.token, done.outcome, done.result);
                    var input = done.input;
                    input.deinit();
                    break;
                },
                else => return error.CopyFailed,
            }
        }
    }
    const copied = nowNs();
    const dst_z = try allocator.dupeSentinel(u8, dst, 0);
    defer allocator.free(dst_z);
    const fd = c.open(dst_z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd >= 0) {
        _ = c.syncfs(fd);
        _ = c.close(fd);
    }
    return .{ .copy_ns = copied - started, .sync_ns = nowNs() - copied };
}

test "files copy path benchmark" {
    _ = getenv("REDIWM_RUN_BENCHMARKS") orelse return error.SkipZigTest;
    const allocator = std.heap.c_allocator;
    const src_base = getenv("REDIWM_COPY_BENCH_SRC") orelse "/dev/shm";
    const dst_base = getenv("REDIWM_COPY_BENCH_DST") orelse ".";
    const rounds = if (getenv("REDIWM_COPY_BENCH_ROUNDS")) |text| try std.fmt.parseInt(usize, text, 10) else 3;

    for (sets) |set| {
        const src = try makeDir(allocator, src_base, set.name);
        defer {
            removeTree(allocator, src);
            allocator.free(src);
        }
        try writeFiles(allocator, src, set);
        var best: u64 = std.math.maxInt(u64);
        var best_sync: u64 = std.math.maxInt(u64);
        var metrics: executor.CopyMetrics = .{};
        for (0..rounds) |round| {
            const dst = try std.fmt.allocPrint(allocator, "{s}/rediwm_copy_bench_out_{d}_{d}", .{ dst_base, c.getpid(), round });
            defer {
                removeTree(allocator, dst);
                allocator.free(dst);
            }
            const dst_z = try allocator.dupeSentinel(u8, dst, 0);
            defer allocator.free(dst_z);
            if (c.mkdir(dst_z, 0o700) != 0) return error.MkdirFailed;
            metrics = .{};
            const timing = try copyAll(allocator, src, dst, set, &metrics);
            best = @min(best, timing.copy_ns);
            best_sync = @min(best_sync, timing.sync_ns);
        }
        const mib = @as(f64, @floatFromInt(set.count * set.size)) / (1024 * 1024);
        const seconds = @as(f64, @floatFromInt(best)) / std.time.ns_per_s;
        std.debug.print("BENCH,copy,{s},files,{d},MiB,{d:.1},copy_s,{d:.3},sync_s,{d:.3},MiB_per_s,{d:.1},path,{s},read_calls,{d},range_calls,{d},unit_ms,{d},reflink_ms,{d},range_ms,{d},buffered_ms,{d}\n", .{
            set.name,
            set.count,
            mib,
            seconds,
            @as(f64, @floatFromInt(best_sync)) / std.time.ns_per_s,
            mib / seconds,
            if (metrics.buffered_read_calls > 0) "buffered" else "copy_file_range",
            metrics.buffered_read_calls,
            metrics.copy_file_range_calls,
            metrics.elapsed_ns / std.time.ns_per_ms,
            metrics.reflink_ns / std.time.ns_per_ms,
            metrics.copy_file_range_ns / std.time.ns_per_ms,
            metrics.buffered_ns / std.time.ns_per_ms,
        });
    }
}
