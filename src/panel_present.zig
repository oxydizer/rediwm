// Shared presentation for compositor-drawn overlay panels (start menu,
// control center, power menu): slide offset, scene-buffer opacity, and
// opt-in paint/buffer counters. Content pixels are painted at full opacity
// elsewhere; this file only moves and fades an already-installed buffer.
const std = @import("std");
const wlr = @import("wlroots");

pub const Stats = struct {
    paints: u64 = 0,
    allocated_bytes: u64 = 0,
    reused_bytes: u64 = 0,
    paint_ns: u64 = 0,
};

var paints: u64 = 0;
var allocated_bytes: u64 = 0;
var reused_bytes: u64 = 0;
var paint_ns: u64 = 0;

pub fn reset() void {
    paints = 0;
    allocated_bytes = 0;
    reused_bytes = 0;
    paint_ns = 0;
}

pub fn snapshot() Stats {
    return .{
        .paints = paints,
        .allocated_bytes = allocated_bytes,
        .reused_bytes = reused_bytes,
        .paint_ns = paint_ns,
    };
}

pub fn addAlloc(bytes: u64) void {
    allocated_bytes += bytes;
}

pub fn addReuse(bytes: u64) void {
    reused_bytes += bytes;
}

pub fn addPaint(ns: u64) void {
    paints += 1;
    paint_ns += ns;
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

pub fn slideOffset(t: f32, slide_distance: f32) i32 {
    const clamped = std.math.clamp(t, 0, 1);
    return @intFromFloat(@round((1 - clamped) * slide_distance));
}

/// Positions the panel and applies a premultiplied fade via the scene graph
/// so animation frames do not have to repaint pixels. No-ops when the node
/// already has this position and opacity, so settled panels are not damaged
/// on unrelated output frames.
pub fn applySlide(buffer_node: *wlr.SceneBuffer, box: wlr.Box, t: f32, slide_distance: f32) void {
    const clamped = std.math.clamp(t, 0, 1);
    const x = box.x;
    const y = box.y + slideOffset(clamped, slide_distance);
    if (buffer_node.node.x != x or buffer_node.node.y != y) {
        buffer_node.node.setPosition(x, y);
    }
    if (buffer_node.opacity != clamped) {
        buffer_node.setOpacity(clamped);
    }
}

test "slide offset is full distance at t=0 and zero at t=1" {
    try std.testing.expectEqual(@as(i32, 20), slideOffset(0, 20));
    try std.testing.expectEqual(@as(i32, 0), slideOffset(1, 20));
    try std.testing.expectEqual(@as(i32, 10), slideOffset(0.5, 20));
    try std.testing.expectEqual(@as(i32, 16), slideOffset(-1, 16));
    try std.testing.expectEqual(@as(i32, 0), slideOffset(2, 16));
}

test "counters accumulate alloc, reuse, and paint time independently" {
    reset();
    addAlloc(100);
    addReuse(40);
    addPaint(12);
    addPaint(8);
    const stats = snapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.paints);
    try std.testing.expectEqual(@as(u64, 100), stats.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 40), stats.reused_bytes);
    try std.testing.expectEqual(@as(u64, 20), stats.paint_ns);
    reset();
    try std.testing.expectEqual(@as(u64, 0), snapshot().paints);
}
