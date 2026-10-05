const std = @import("std");
const metrics = @import("frame_metrics.zig");

pub const RecentError = struct {
    time_ms: i64,
    msg: [128]u8,
    len: usize,

    pub fn text(self: *const RecentError) []const u8 {
        return self.msg[0..self.len];
    }
};

pub const Timing = struct {
    fps: f64 = 0,
    frame_time_ms: f64 = 0,
    missed_frames: u64 = 0,
    refresh_hz: f64 = 0,
};

pub const PerformanceStats = struct {
    screenshot_selection: @import("protocol.zig").ScreenshotSelectionStats = .{},
    cpu_frame: metrics.Window = .{},
    taskbar_cpu: metrics.Window = .{},
    chrome_cpu: metrics.Window = .{},
    panels_cpu: metrics.Window = .{},
    anim_cpu: metrics.Window = .{},
    projection_cpu: metrics.Window = .{},
    glass_cpu: metrics.Window = .{},
    scene_commit_cpu: metrics.Window = .{},
    gpu_elapsed: metrics.Window = .{},
    gpu_samples_dropped: u64 = 0,
    generation: u64 = 0,
    output_commits: u64 = 0,
    output_failed_commits: u64 = 0,
    /// Frames whose output commit was skipped because nothing on screen changed.
    output_skipped_commits: u64 = 0,
    titlebar_paints: u64 = 0,
    footer_paints: u64 = 0,
    edge_samples_attempted: u64 = 0,
    edge_samples_succeeded: u64 = 0,
    edge_samples_skipped: u64 = 0,
    edge_sample_ns: u64 = 0,
    panel_paints: u64 = 0,
    panel_allocated_bytes: u64 = 0,
    panel_reused_bytes: u64 = 0,
    icon_cache_hits: u64 = 0,
    icon_cache_misses: u64 = 0,
    icon_decode_ns: u64 = 0,
    icon_decode_count: u64 = 0,
    icon_decoded_bytes: u64 = 0,
    icon_queue_depth_max: u64 = 0,
    taskbar_paints: u64 = 0,
    taskbar_paint_ns: u64 = 0,
    taskbar_raster_pixels: u64 = 0,
    taskbar_clock_frame_requests: u64 = 0,
    taskbar_clock_paints: u64 = 0,
    taskbar_start_paints: u64 = 0,
    taskbar_chip_paints: u64 = 0,
    taskbar_tray_paints: u64 = 0,
    taskbar_hover_paints: u64 = 0,
    taskbar_press_paints: u64 = 0,
    taskbar_audio_paints: u64 = 0,
    desktop: @import("protocol.zig").DesktopStats = .{},
    anim_frames_scheduled: u64 = 0,
    anim_wasted_wakeups: u64 = 0,
    anim_longest_ms: u64 = 0,
    first_commit_ns: u64 = 0,
    last_commit_ns: u64 = 0,
    commit_ns: u64 = 0,
    missed_frames: u64 = 0,
    refresh_mHz: i32 = 0,

    errors_buffer: [16]RecentError = undefined,
    errors_head: usize = 0,
    errors_count: usize = 0,

    pub fn recordError(self: *PerformanceStats, time_ms: i64, msg: []const u8) void {
        const idx = self.errors_head;
        self.errors_head = (self.errors_head + 1) % self.errors_buffer.len;
        if (self.errors_count < self.errors_buffer.len) {
            self.errors_count += 1;
        }

        var entry = &self.errors_buffer[idx];
        entry.time_ms = time_ms;
        const copy_len = @min(msg.len, entry.msg.len);
        @memcpy(entry.msg[0..copy_len], msg[0..copy_len]);
        entry.len = copy_len;
    }

    pub fn reset(self: *PerformanceStats) void {
        self.screenshot_selection = .{};
        self.cpu_frame = .{};
        self.taskbar_cpu = .{};
        self.chrome_cpu = .{};
        self.panels_cpu = .{};
        self.anim_cpu = .{};
        self.projection_cpu = .{};
        self.glass_cpu = .{};
        self.scene_commit_cpu = .{};
        self.gpu_elapsed = .{};
        self.gpu_samples_dropped = 0;
        self.generation +%= 1;
        self.output_commits = 0;
        self.output_failed_commits = 0;
        self.output_skipped_commits = 0;
        self.titlebar_paints = 0;
        self.footer_paints = 0;
        self.edge_samples_attempted = 0;
        self.edge_samples_succeeded = 0;
        self.edge_samples_skipped = 0;
        self.edge_sample_ns = 0;
        self.panel_paints = 0;
        self.panel_allocated_bytes = 0;
        self.panel_reused_bytes = 0;
        self.icon_cache_hits = 0;
        self.icon_cache_misses = 0;
        self.icon_decode_ns = 0;
        self.icon_decode_count = 0;
        self.icon_decoded_bytes = 0;
        self.icon_queue_depth_max = 0;
        self.taskbar_paints = 0;
        self.taskbar_paint_ns = 0;
        self.taskbar_raster_pixels = 0;
        self.taskbar_clock_frame_requests = 0;
        self.taskbar_clock_paints = 0;
        self.taskbar_start_paints = 0;
        self.taskbar_chip_paints = 0;
        self.taskbar_tray_paints = 0;
        self.taskbar_hover_paints = 0;
        self.taskbar_press_paints = 0;
        self.taskbar_audio_paints = 0;
        self.desktop = .{};
        self.anim_frames_scheduled = 0;
        self.anim_wasted_wakeups = 0;
        self.anim_longest_ms = 0;
        self.first_commit_ns = 0;
        self.last_commit_ns = 0;
        self.commit_ns = 0;
        self.missed_frames = 0;
        self.refresh_mHz = 0;
        self.errors_count = 0;
        self.errors_head = 0;
    }

    pub fn frameWork(self: *const PerformanceStats, gpu_available: bool) metrics.FrameWork {
        return .{
            .cpu_frame = self.cpu_frame.summary(),
            .taskbar_cpu = self.taskbar_cpu.summary(),
            .chrome_cpu = self.chrome_cpu.summary(),
            .panels_cpu = self.panels_cpu.summary(),
            .anim_cpu = self.anim_cpu.summary(),
            .projection_cpu = self.projection_cpu.summary(),
            .glass_cpu = self.glass_cpu.summary(),
            .scene_commit_cpu = self.scene_commit_cpu.summary(),
            .gpu_elapsed = self.gpu_elapsed.summary(),
            .gpu_timing_available = gpu_available,
            .gpu_samples_dropped = self.gpu_samples_dropped,
        };
    }

    pub fn timing(self: *const PerformanceStats) Timing {
        return timingFrom(self.output_commits, self.first_commit_ns, self.last_commit_ns, self.missed_frames, self.refresh_mHz);
    }
};

pub var global_stats: PerformanceStats = .{};

pub fn refreshPeriodNs(refresh_mHz: i32) u64 {
    if (refresh_mHz <= 0) return 0;
    return @divTrunc(1_000_000_000_000, @as(u64, @intCast(refresh_mHz)));
}

pub fn timingFrom(commits: u64, first_ns: u64, last_ns: u64, missed: u64, refresh_mHz: i32) Timing {
    var result = Timing{ .missed_frames = missed };
    if (refresh_mHz > 0) {
        result.refresh_hz = @as(f64, @floatFromInt(refresh_mHz)) / 1000.0;
    }
    if (commits >= 2 and last_ns > first_ns) {
        const elapsed_ns = last_ns - first_ns;
        const intervals = commits - 1;
        result.fps = @as(f64, @floatFromInt(intervals)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));
        result.frame_time_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(intervals)) / 1_000_000.0;
    }
    return result;
}

pub fn recordOutputCommit() void {
    recordPresentedFrame(0, 0);
}

pub fn recordPresentedFrame(commit_ns: u64, refresh_mHz: i32) void {
    const now = nowNs();
    if (global_stats.first_commit_ns == 0) global_stats.first_commit_ns = now;
    if (global_stats.last_commit_ns != 0) {
        const dt = now -% global_stats.last_commit_ns;
        const period_ns = refreshPeriodNs(refresh_mHz);
        // Count skipped vsyncs during a presenting burst, not idle gaps.
        if (period_ns > 0 and dt > period_ns + period_ns / 2 and dt < period_ns * 32) {
            global_stats.missed_frames +%= @divTrunc(dt, period_ns) - 1;
        }
    }
    global_stats.last_commit_ns = now;
    global_stats.output_commits +%= 1;
    global_stats.commit_ns +%= commit_ns;
    if (refresh_mHz > 0) global_stats.refresh_mHz = refresh_mHz;
}

pub fn recordFailedCommit() void {
    global_stats.output_failed_commits +%= 1;
}

pub fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    const sec: u64 = @intCast(@max(ts.sec, 0));
    const nsec: u64 = @intCast(@max(ts.nsec, 0));
    return sec *% 1_000_000_000 +% nsec;
}

pub fn recordTitlebarPaint() void {
    global_stats.titlebar_paints +%= 1;
}

pub fn recordFooterPaint() void {
    global_stats.footer_paints +%= 1;
}

pub const TaskbarPaintCause = struct {
    pub const start: u8 = 1 << 0;
    pub const chip: u8 = 1 << 1;
    pub const tray: u8 = 1 << 2;
    pub const clock: u8 = 1 << 3;
    pub const audio: u8 = 1 << 4;
};

pub fn recordTaskbarPaint(paint_ns: u64, raster_pixels: u64, causes: u8) void {
    global_stats.taskbar_paints +%= 1;
    global_stats.taskbar_paint_ns +%= paint_ns;
    global_stats.taskbar_raster_pixels +%= raster_pixels;
    if ((causes & TaskbarPaintCause.start) != 0) global_stats.taskbar_start_paints +%= 1;
    if ((causes & TaskbarPaintCause.chip) != 0) global_stats.taskbar_chip_paints +%= 1;
    if ((causes & TaskbarPaintCause.tray) != 0) global_stats.taskbar_tray_paints +%= 1;
    if ((causes & TaskbarPaintCause.clock) != 0) global_stats.taskbar_clock_paints +%= 1;
    if ((causes & TaskbarPaintCause.audio) != 0) global_stats.taskbar_audio_paints +%= 1;
}

pub fn recordTaskbarHoverPaint() void {
    global_stats.taskbar_hover_paints +%= 1;
}

pub fn recordTaskbarPressPaint() void {
    global_stats.taskbar_press_paints +%= 1;
}

pub fn recordTaskbarAudioPaint() void {
    global_stats.taskbar_audio_paints +%= 1;
}

pub fn recordTaskbarClockFrameRequest() void {
    global_stats.taskbar_clock_frame_requests +%= 1;
}

pub fn recordEdgeSampleAttempt() void {
    global_stats.edge_samples_attempted +%= 1;
}

pub fn recordEdgeSampleSuccess(ns: u64) void {
    global_stats.edge_samples_succeeded +%= 1;
    global_stats.edge_sample_ns +%= ns;
}

pub fn recordEdgeSampleSkip() void {
    global_stats.edge_samples_skipped +%= 1;
}

pub fn recordIconCacheHit() void {
    global_stats.icon_cache_hits +%= 1;
}

pub fn recordIconCacheMiss() void {
    global_stats.icon_cache_misses +%= 1;
}

// `ns` covers theme lookup + rasterization/decode combined (one worker-
// thread job's wall time, see icon_service.zig's `run`), not decode alone —
// icon_theme.zig has no stats dependency of its own, so this is measured
// coarser than "theme-index time" and "decode time" separately.
pub fn recordIconDecode(ns: u64, bytes: u64) void {
    global_stats.icon_decode_ns +%= ns;
    global_stats.icon_decode_count +%= 1;
    global_stats.icon_decoded_bytes +%= bytes;
}

// A watermark (peak queue depth observed), not an instantaneous sample —
// more useful in a periodic stats snapshot than "whatever the depth
// happened to be when polled."
pub fn recordIconQueueDepth(depth: u64) void {
    if (depth > global_stats.icon_queue_depth_max) global_stats.icon_queue_depth_max = depth;
}

test "timingFrom reports 144 Hz from 144 intervals in one second" {
    const t = timingFrom(145, 0, 1_000_000_000, 0, 144_000);
    try std.testing.expectApproxEqAbs(@as(f64, 144.0), t.fps, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 6.944), t.frame_time_ms, 0.01);
    try std.testing.expectEqual(@as(u64, 0), t.missed_frames);
    try std.testing.expectApproxEqAbs(@as(f64, 144.0), t.refresh_hz, 0.01);
}

test "timingFrom is zero with fewer than two commits" {
    const t = timingFrom(1, 0, 1_000_000, 3, 60_000);
    try std.testing.expectEqual(@as(f64, 0), t.fps);
    try std.testing.expectEqual(@as(f64, 0), t.frame_time_ms);
    try std.testing.expectEqual(@as(u64, 3), t.missed_frames);
}

test "refreshPeriodNs matches millihertz refresh" {
    try std.testing.expectEqual(@as(u64, 0), refreshPeriodNs(0));
    try std.testing.expectEqual(@as(u64, 6_944_444), refreshPeriodNs(144_000));
}

test "performance reset clears work windows and advances GPU generation" {
    var s: PerformanceStats = .{};
    s.cpu_frame.record(3_000_000);
    s.taskbar_cpu.record(1_000_000);
    s.chrome_cpu.record(1_000_000);
    s.panels_cpu.record(1_000_000);
    s.anim_cpu.record(200_000);
    s.projection_cpu.record(250_000);
    s.glass_cpu.record(1_000_000);
    s.scene_commit_cpu.record(500_000);
    s.gpu_elapsed.record(2_000_000);
    s.gpu_samples_dropped = 4;
    s.anim_frames_scheduled = 9;
    s.anim_wasted_wakeups = 4;
    s.anim_longest_ms = 250;
    s.reset();
    const work = s.frameWork(false);
    try std.testing.expectEqual(@as(u64, 1), s.generation);
    try std.testing.expectEqual(@as(usize, 0), work.cpu_frame.samples);
    try std.testing.expectEqual(@as(usize, 0), work.taskbar_cpu.samples);
    try std.testing.expectEqual(@as(usize, 0), work.chrome_cpu.samples);
    try std.testing.expectEqual(@as(usize, 0), work.panels_cpu.samples);
    try std.testing.expectEqual(@as(usize, 0), work.anim_cpu.samples);
    try std.testing.expectEqual(@as(usize, 0), work.projection_cpu.samples);
    try std.testing.expectEqual(@as(usize, 0), work.glass_cpu.samples);
    try std.testing.expectEqual(@as(usize, 0), work.scene_commit_cpu.samples);
    try std.testing.expectEqual(@as(usize, 0), work.gpu_elapsed.samples);
    try std.testing.expectEqual(@as(u64, 0), work.gpu_samples_dropped);
    try std.testing.expect(!work.gpu_timing_available);
    try std.testing.expectEqual(@as(u64, 0), s.anim_frames_scheduled);
    try std.testing.expectEqual(@as(u64, 0), s.anim_wasted_wakeups);
    try std.testing.expectEqual(@as(u64, 0), s.anim_longest_ms);
}
