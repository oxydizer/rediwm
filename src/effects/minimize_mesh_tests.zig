const std = @import("std");
const geometry = @import("minimize_mesh.zig");
const ribbon = @import("ribbon.zig");

test "minimize sheet preserves its initial window and converges to either screen edge" {
    const source: geometry.Box = .{ .x = -200, .y = 120, .width = 640, .height = 480 };
    for ([_]ribbon.Point{ .{ .x = 40, .y = 900 }, .{ .x = -80, .y = 20 } }) |target| {
        for ([_]@import("config").effects.Quality{ .low, .balanced, .high }) |quality| {
            const initial = geometry.mesh(source, target, 0, .{ .quality = quality });
            for (initial.mesh.vertices[0..initial.mesh.count]) |v| {
                const x = @as(f32, @floatFromInt(initial.x)) + v[0] * @as(f32, @floatFromInt(initial.width));
                const y = @as(f32, @floatFromInt(initial.y)) + v[1] * @as(f32, @floatFromInt(initial.height));
                try std.testing.expectApproxEqAbs(source.x + v[2] * source.width, x, 0.001);
                try std.testing.expectApproxEqAbs(source.y + v[3] * source.height, y, 0.001);
            }
            const final = geometry.mesh(source, target, 0.999, .{ .quality = quality });
            for (final.mesh.vertices[0..final.mesh.count]) |v| {
                try std.testing.expect(v[0] >= 0 and v[0] <= 1 and v[1] >= 0 and v[1] <= 1);
                const x = @as(f32, @floatFromInt(final.x)) + v[0] * @as(f32, @floatFromInt(final.width));
                const y = @as(f32, @floatFromInt(final.y)) + v[1] * @as(f32, @floatFromInt(final.height));
                try std.testing.expectApproxEqAbs(target.x, x, 1);
                try std.testing.expectApproxEqAbs(target.y, y, 1);
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 0), geometry.mesh(source, .{ .x = 0, .y = 900 }, 1, .{}).mesh.count);
}

test "minimize flame pulls the near edge first while retaining the upper body" {
    const source: geometry.Box = .{ .x = 100, .y = 100, .width = 600, .height = 400 };
    const geo = geometry.mesh(source, .{ .x = 200, .y = 900 }, 0.4, .{});
    const v = geo.mesh.vertices;
    const upper_width = (v[1][0] - v[0][0]) * @as(f32, @floatFromInt(geo.width));
    const lower_width = (v[geo.mesh.count - 1][0] - v[geo.mesh.count - 2][0]) * @as(f32, @floatFromInt(geo.width));
    try std.testing.expect(upper_width > 600);
    try std.testing.expect(lower_width < 100);
}
