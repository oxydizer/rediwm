const std = @import("std");

/// All summary values describe the same bounded window of recent samples.
/// Recording is O(1); sorting only happens when a stats snapshot is requested.
pub const Summary = struct {
    samples: usize = 0,
    total_samples: u64 = 0,
    avg_ms: f64 = 0,
    p50_ms: f64 = 0,
    p95_ms: f64 = 0,
    p99_ms: f64 = 0,
    max_ms: f64 = 0,
};
pub const Window = struct {
    pub const capacity = 512;
    values: [capacity]u64 = @splat(0),
    count: u64 = 0,
    next: usize = 0,

    pub fn record(self: *Window, ns: u64) void {
        self.values[self.next] = ns;
        self.next = (self.next + 1) % capacity;
        self.count +|= 1;
    }

    pub fn summary(self: *const Window) Summary {
        const n: usize = @intCast(@min(self.count, capacity));
        if (n == 0) return .{};
        var sorted: [capacity]u64 = undefined;
        @memcpy(sorted[0..n], self.values[0..n]);
        std.mem.sort(u64, sorted[0..n], {}, std.sort.asc(u64));
        var total: f64 = 0;
        for (sorted[0..n]) |ns| total += @floatFromInt(ns);
        return .{
            .samples = n,
            .total_samples = self.count,
            .avg_ms = total / @as(f64, @floatFromInt(n)) / 1e6,
            .p50_ms = ms(sorted[(n * 50 + 99) / 100 - 1]),
            .p95_ms = ms(sorted[(n * 95 + 99) / 100 - 1]),
            .p99_ms = ms(sorted[(n * 99 + 99) / 100 - 1]),
            .max_ms = ms(sorted[n - 1]),
        };
    }
};
fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub const FrameWork = struct {
    cpu_frame: Summary = .{},
    taskbar_cpu: Summary = .{},
    chrome_cpu: Summary = .{},
    panels_cpu: Summary = .{},
    anim_cpu: Summary = .{},
    projection_cpu: Summary = .{},
    glass_cpu: Summary = .{},
    scene_commit_cpu: Summary = .{},
    gpu_elapsed: Summary = .{},
    gpu_timing_available: bool = false,
    gpu_samples_dropped: u64 = 0,
};

test "duration window uses nearest-rank percentiles and replaces oldest samples" {
    var w: Window = .{};
    try std.testing.expectEqual(@as(usize, 0), w.summary().samples);
    for (1..101) |i| w.record(i * 1_000_000);
    const s = w.summary();
    try std.testing.expectEqual(@as(f64, 50.5), s.avg_ms);
    try std.testing.expectEqual(@as(f64, 50), s.p50_ms);
    try std.testing.expectEqual(@as(f64, 95), s.p95_ms);
    try std.testing.expectEqual(@as(f64, 99), s.p99_ms);
    for (0..Window.capacity) |_| w.record(3_000_000);
    const wrapped = w.summary();
    try std.testing.expectEqual(@as(usize, Window.capacity), wrapped.samples);
    try std.testing.expectEqual(@as(u64, 612), wrapped.total_samples);
    try std.testing.expectEqual(@as(f64, 3), wrapped.avg_ms);
    try std.testing.expectEqual(@as(f64, 3), wrapped.max_ms);
    w = .{};
    try std.testing.expectEqual(@as(u64, 0), w.summary().total_samples);
}
