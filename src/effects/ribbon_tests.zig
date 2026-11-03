const std = @import("std");
const ribbon = @import("ribbon.zig");

test "ribbons stop at idle, bound history and do not join teleports" {
    var path: ribbon.Path = .{};
    const preset: ribbon.Preset = .{ .lifetime_ms = 400 };
    for (0..100) |i| path.push(.{ .x = @as(f32, @floatFromInt(i)) * 4, .y = 20 }, @intCast(i * 4), preset);
    try std.testing.expect(path.len <= 32);
    const mesh = path.mesh(400, preset, .{ .x = 396, .y = 20 }, 1.5, 0, null);
    try std.testing.expect(mesh.mesh.count >= 4);
    for (mesh.mesh.vertices[0..mesh.mesh.count]) |v| {
        try std.testing.expect(v[0] >= 0 and v[0] <= 1 and v[1] >= 0 and v[1] <= 1);
        try std.testing.expect(v[3] >= 0 and v[3] <= 2);
    }
    path.push(.{ .x = 396, .y = 20 }, 800, preset);
    path.expire(800, preset.lifetime_ms);
    try std.testing.expectEqual(@as(usize, 0), path.len);
    path.push(.{ .x = 400, .y = 20 }, 804, preset);
    path.push(.{ .x = 10000, .y = 20 }, 808, preset);
    try std.testing.expectEqual(@as(usize, 1), path.len);
}

test "trail length stays bounded independently of sample capacity" {
    var path: ribbon.Path = .{};
    const preset: ribbon.Preset = .{ .max_length_px = 40, .lifetime_ms = 400 };
    for (0..30) |i| path.push(.{ .x = @as(f32, @floatFromInt(i)) * 10, .y = 0 }, @intCast(i * 20), preset);
    try std.testing.expectEqual(@as(usize, 5), path.len);
}

test "forks keep their frozen shape and sources during a short stop fade" {
    var path: ribbon.Path = .{};
    const preset: ribbon.Preset = .{};
    path.push(.{ .x = 0, .y = 20 }, 0, preset);
    path.push(.{ .x = 100, .y = 20 }, 20, preset);
    try std.testing.expectEqual(@as(usize, 2), path.len);
    const half: ribbon.Point = .{ .x = -16, .y = 30 };
    const origin: ribbon.Point = .{ .x = 100, .y = 20 };
    const fresh = path.mesh(20, preset, origin, 1.5, 0, half);
    const lingering = path.mesh(220, preset, origin, 1.5, 0, half);
    try std.testing.expect(lingering.mesh.fade[1] >= 0.5);
    try std.testing.expect(lingering.mesh.fade[1] < fresh.mesh.fade[1]);
    // The erasing front must not move the surviving folds or their sources.
    path.expire(469, preset.lifetime_ms);
    const almost_gone = path.mesh(469, preset, origin, 1.5, 0, half);
    for ([_]ribbon.Geometry{ lingering, almost_gone }) |geo| {
        try std.testing.expectEqual(fresh.x, geo.x);
        try std.testing.expectEqual(fresh.y, geo.y);
        try std.testing.expectEqual(fresh.width, geo.width);
        try std.testing.expectEqual(fresh.height, geo.height);
        try std.testing.expectEqualSlices([4]f32, fresh.mesh.vertices[0..fresh.mesh.count], geo.mesh.vertices[0..geo.mesh.count]);
    }
    for ([_]ribbon.Geometry{ fresh, lingering }) |geo| {
        const a = geo.mesh.vertices[geo.mesh.count - 4];
        const b = geo.mesh.vertices[geo.mesh.count - 3];
        for ([_]f32{ -1, 1 }) |side| {
            const t = (1 + side * ribbon.source_across) / 2;
            const x = (@as(f32, @floatFromInt(geo.x)) + (a[0] * (1 - t) + b[0] * t) * @as(f32, @floatFromInt(geo.width))) * 1.5;
            const y = (@as(f32, @floatFromInt(geo.y)) + (a[1] * (1 - t) + b[1] * t) * @as(f32, @floatFromInt(geo.height))) * 1.5;
            try std.testing.expectApproxEqAbs(side * half.x, x, 0.001);
            try std.testing.expectApproxEqAbs(side * half.y, y, 0.001);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), path.mesh(470, preset, origin, 1.5, 0, half).mesh.count);
    path.expire(470, preset.lifetime_ms);
    try std.testing.expectEqual(@as(usize, 0), path.len);
}

test "small drag steps keep folds continuous across history buckets and length limits" {
    for ([_]@import("config").effects.Quality{ .low, .balanced, .high }) |quality| {
        const preset: ribbon.Preset = .{ .max_length_px = 100, .quality = quality };
        var path: ribbon.Path = .{};
        path.push(.{ .x = 0, .y = 20 }, 0, preset);
        path.push(.{ .x = 99, .y = 20 }, 90, preset);
        var previous = path.mesh(90, preset, .{ .x = 0, .y = 0 }, 1, 0, null);
        for (100..120) |x| {
            const now: i64 = @intCast(100 + (x - 100) * 10);
            path.push(.{ .x = @floatFromInt(x), .y = 20 }, now, preset);
            const current = path.mesh(now, preset, .{ .x = 0, .y = 0 }, 1, 0, null);
            try std.testing.expectEqual(previous.mesh.count, current.mesh.count);
            for (previous.mesh.vertices[0..previous.mesh.count], current.mesh.vertices[0..current.mesh.count]) |a, b| {
                const dx = @as(f32, @floatFromInt(current.x - previous.x)) + b[0] * @as(f32, @floatFromInt(current.width)) - a[0] * @as(f32, @floatFromInt(previous.width));
                const dy = @as(f32, @floatFromInt(current.y - previous.y)) + b[1] * @as(f32, @floatFromInt(current.height)) - a[1] * @as(f32, @floatFromInt(previous.height));
                try std.testing.expect(std.math.hypot(dx, dy) < 3);
            }
            previous = current;
        }
    }
}

test "wind ripples independently of drag distance and freezes without an idle jump" {
    const preset: ribbon.Preset = .{};
    const origin: ribbon.Point = .{ .x = 0, .y = 0 };
    var path: ribbon.Path = .{};
    path.push(.{ .x = 0, .y = 20 }, 0, preset);
    path.push(.{ .x = 200, .y = 20 }, 20, preset);
    path.tickFlutter(20, true);
    const first = path.mesh(20, preset, origin, 1, 0, null);
    // Keep the same path to isolate wind from changes to the window position.
    path.tickFlutter(120, true);
    const fluttering = path.mesh(120, preset, origin, 1, 0, null);
    var largest_shift: f32 = 0;
    for (first.mesh.vertices[0..first.mesh.count], fluttering.mesh.vertices[0..fluttering.mesh.count]) |a, b| {
        const dy = @as(f32, @floatFromInt(fluttering.y - first.y)) + b[1] * @as(f32, @floatFromInt(fluttering.height)) - a[1] * @as(f32, @floatFromInt(first.height));
        largest_shift = @max(largest_shift, @abs(dy));
    }
    try std.testing.expect(largest_shift > 4);
    var uninterrupted = path;
    for ([_]i64{ 220, 440 }) |now| {
        path.tickFlutter(now, false);
        const stopped = path.mesh(now, preset, origin, 1, 0, null);
        try expectSameShape(fluttering, stopped);
    }
    // Only the new moving frame contributes time after the pause.
    path.tickFlutter(460, true);
    uninterrupted.tickFlutter(140, true);
    try expectSameShape(path.mesh(460, preset, origin, 1, 0, null), uninterrupted.mesh(140, preset, origin, 1, 0, null));
}

fn expectSameShape(a: ribbon.Geometry, b: ribbon.Geometry) !void {
    try std.testing.expectEqual(a.x, b.x);
    try std.testing.expectEqual(a.y, b.y);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqualSlices([4]f32, a.mesh.vertices[0..a.mesh.count], b.mesh.vertices[0..b.mesh.count]);
}

test "border halo encloses and closes rounded and polygon frames" {
    const border = @import("border.zig");
    const shape = @import("ui").window_shape;
    const outline = (try shape.parse("0 16, 16 0, -0 0, -0 -0, 0 -0")).?;
    const polygon = shape.resolve(outline, 400, 300, 1);
    for ([_]?shape.Resolved{ null, polygon }) |poly| {
        const geo = border.mesh(400, 300, 12, poly, 18, 0.8, .{});
        try std.testing.expectEqual(@as(u32, 1), geo.mesh.edge);
        try std.testing.expect(geo.mesh.count <= geo.mesh.vertices.len);
        try std.testing.expect(geo.x < 0 and geo.y < 0 and geo.width > 400 and geo.height > 300);
        try std.testing.expectEqual(geo.mesh.vertices[0], geo.mesh.vertices[geo.mesh.count - 2]);
        try std.testing.expectEqual(geo.mesh.vertices[1], geo.mesh.vertices[geo.mesh.count - 1]);
        for (geo.mesh.vertices[0..geo.mesh.count]) |v| {
            try std.testing.expect(v[0] >= 0 and v[0] <= 1 and v[1] >= 0 and v[1] <= 1);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), border.mesh(400, 300, 12, null, 18, 0, .{}).mesh.count);
}
