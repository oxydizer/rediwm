//! Geometry for circular switcher cards. Angles start at twelve o'clock and
//! increase clockwise. Both curved edges are exact, analytic circular arcs.
const std = @import("std");
const SectorSpec = @import("../scene_sector.zig").Spec;

pub const Sector = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    /// Relative to the bounding box. The circle's center can be outside it.
    arc: SectorSpec,
};

pub fn diameter(width: i32, height: i32) i32 {
    return @min(720, width - 32, height - 32);
}

pub fn span(group_count: usize) f64 {
    const slot = 2 * std.math.pi / @as(f64, @floatFromInt(@max(4, group_count)));
    return slot - @min(0.045, slot * 0.12);
}

/// `progress` is 0 for a group's ordinary idle stack (a thin 14px cascade)
/// rising to 1 while the switcher eases the *selected* group open, so its
/// windows fan out far enough to read individually. Callers pass 0 for any
/// group that is not currently selected.
pub fn makeSector(size: i32, angle: f64, arc: f64, depth: usize, progress: f64) Sector {
    const center = @as(f64, @floatFromInt(size)) / 2;
    const step = 14 + 46 * std.math.clamp(progress, 0, 1);
    const offset = @as(f64, @floatFromInt(@min(depth, 2))) * step;
    const inner = @as(f64, @floatFromInt(size)) * 0.18 + offset;
    const outer = center - 36 + offset;
    const axis: [2]f64 = .{ @sin(angle), -@cos(angle) };
    const half: [2]f64 = .{ @cos(arc / 2), @sin(arc / 2) };
    var left: f64 = std.math.inf(f64);
    var top: f64 = std.math.inf(f64);
    var right: f64 = -std.math.inf(f64);
    var bottom: f64 = -std.math.inf(f64);
    // Exact bounds come from the four arc endpoints and any cardinal extrema
    // inside the angular span. Sampling a polygon would cut off the curve's peak.
    const angles = [_]f64{ angle - arc / 2, angle + arc / 2, 0, std.math.pi / 2.0, std.math.pi, std.math.pi * 1.5 };
    for (angles, 0..) |a, i| {
        const sx = @sin(a);
        const sy = -@cos(a);
        if (i >= 2 and sx * axis[0] + sy * axis[1] < half[0] - 1e-12) continue;
        for ([_]f64{ inner, outer }) |radius| {
            const px = center + sx * radius;
            const py = center + sy * radius;
            left = @min(left, px);
            top = @min(top, py);
            right = @max(right, px);
            bottom = @max(bottom, py);
        }
    }
    const x: i32 = @intFromFloat(@floor(left) - 1);
    const y: i32 = @intFromFloat(@floor(top) - 1);
    const width = @as(i32, @intFromFloat(@ceil(right) + 1)) - x;
    const height = @as(i32, @intFromFloat(@ceil(bottom) + 1)) - y;
    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .arc = .{
            .center = .{ center - @as(f64, @floatFromInt(x)), center - @as(f64, @floatFromInt(y)) },
            .radii = .{ inner, outer },
            .axis = axis,
            .half_angle = half,
        },
    };
}

/// Fit the full window width to the outer arc. Its top starts at that rim;
/// natural-height content extends toward the hub, which may hide its bottom.
/// This stays constant through rotation, unlike an upright bounding-box crop.
pub fn previewHeight(sector: Sector, aspect: f64) f64 {
    const arc = 2 * std.math.atan2(sector.arc.half_angle[1], sector.arc.half_angle[0]);
    return sector.arc.radii[1] * arc / aspect;
}

test {
    _ = @import("layout_tests.zig");
}
