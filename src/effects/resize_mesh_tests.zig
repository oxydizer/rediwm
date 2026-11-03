const std = @import("std");
const mesh = @import("resize_mesh.zig");
const outline = @import("resize_outline.zig");
const ribbon = @import("ribbon.zig");
const Edges = @import("../resize.zig").Edges;

fn position(geo: ribbon.Geometry, i: usize) ribbon.Point {
    const v = geo.mesh.vertices[i];
    return .{ .x = @as(f32, @floatFromInt(geo.x)) + v[0] * @as(f32, @floatFromInt(geo.width)), .y = @as(f32, @floatFromInt(geo.y)) + v[1] * @as(f32, @floatFromInt(geo.height)) };
}

test "elastic resize fill and glow share a closed boundary at all corners, edges and qualities" {
    const cases = [_]Edges{
        .{ .right = true, .bottom = true }, .{ .left = true, .bottom = true },
        .{ .right = true, .top = true },    .{ .left = true, .top = true },
        .{ .right = true },                 .{ .left = true },
        .{ .top = true },                   .{ .bottom = true },
    };
    for (cases) |edges| for ([_]f32{ -1, 1 }) |direction| {
        const dx: f32 = if (edges.right or edges.left) 100 * direction else 0;
        const dy: f32 = if (edges.bottom or edges.top) 60 * direction else 0;
        const target: mesh.Box = .{ .x = if (edges.left) -dx else 0, .y = if (edges.top) -dy else 0, .width = 400 + dx, .height = 300 + dy };
        for ([_]@import("config").effects.Quality{ .low, .balanced, .high }) |quality| {
            const result = mesh.build(400, 300, target, 12, null, null, .{ .edges = edges, .anchor = .{ .x = 0.25, .y = 0.75 } }, 18, 1, 0, .{ .quality = quality });
            try std.testing.expect(result.fill.mesh.count > 4 and result.fill.mesh.count <= 128);
            try std.testing.expect(result.edge.mesh.count > 4 and result.edge.mesh.count <= result.fill.mesh.count);
            for ([_]ribbon.Geometry{ result.fill, result.edge }) |geo| {
                for (geo.mesh.vertices[0..geo.mesh.count]) |v| {
                    try std.testing.expect(v[0] >= 0 and v[0] <= 1 and v[1] >= 0 and v[1] <= 1);
                }
                for (0..2) |side| for (0..2) |axis|
                    try std.testing.expectApproxEqAbs(geo.mesh.vertices[side][axis], geo.mesh.vertices[geo.mesh.count - 2 + side][axis], 0.0001);
            }
            var i: usize = 0;
            while (i < result.fill.mesh.count) : (i += 2) {
                const fill_edge = position(result.fill, i + 1);
                var joined = false;
                var j: usize = 0;
                while (j < result.edge.mesh.count) : (j += 2) {
                    const a = position(result.edge, j);
                    const b = position(result.edge, j + 1);
                    const from = result.edge.mesh.vertices[j][2];
                    const t = -from / (1 - from);
                    const x = a.x + (b.x - a.x) * t;
                    const y = a.y + (b.y - a.y) * t;
                    if (@abs(fill_edge.x - x) < 0.001 and @abs(fill_edge.y - y) < 0.001) joined = true;
                }
                try std.testing.expect(joined);
                try std.testing.expect(fill_edge.x >= @min(0, target.x) - 0.001 and fill_edge.x <= @max(400, target.x + target.width) + 0.001);
                try std.testing.expect(fill_edge.y >= @min(0, target.y) - 0.001 and fill_edge.y <= @max(300, target.y + target.height) + 0.001);
            }
        }
    };
}

test "corner pull stays attached at the far ends and stretches both adjacent edges" {
    const points = outline.resolve(400, 300, .{ .x = 0, .y = 0, .width = 600, .height = 330 }, 12, null, null, .{ .edges = .{ .right = true, .bottom = true } }, .balanced);
    var side = false;
    var bottom = false;
    var tip = false;
    for (points.current[0..points.len], points.leading[0..points.len]) |p, q| {
        if (p.y <= 12 or p.x <= 12) {
            try std.testing.expectApproxEqAbs(p.x, q.x, 0.001);
            try std.testing.expectApproxEqAbs(p.y, q.y, 0.001);
        }
        if (@abs(p.x - 400) < 0.001 and @abs(p.y - 150) < 0.001) {
            side = true;
            try std.testing.expectApproxEqAbs(@as(f32, 450), q.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 171), q.y, 0.001);
        }
        if (@abs(p.x - 200) < 0.001 and @abs(p.y - 300) < 0.001) {
            bottom = true;
            try std.testing.expectApproxEqAbs(@as(f32, 306), q.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 307.5), q.y, 0.001);
        }
        if (@abs(p.x - 400) < 0.001 and @abs(p.y - 288) < 0.001) {
            tip = true;
            try std.testing.expectApproxEqAbs(@as(f32, 600), q.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 330), q.y, 0.001);
        }
    }
    try std.testing.expect(side and bottom and tip);
}

test "polygon outlines are supported and a caught-up resize has no membrane" {
    const shape = @import("ui").window_shape;
    const spec = (try shape.parse("0 16, 16 0, -0 0, -0 -0, 0 -0")).?;
    const a = shape.resolve(spec, 400, 300, 1);
    const b = shape.resolve(spec, 500, 350, 1);
    const pull: mesh.Pull = .{ .edges = .{ .right = true, .bottom = true } };
    const result = mesh.build(400, 300, .{ .x = 0, .y = 0, .width = 500, .height = 350 }, 12, a, b, pull, 18, 1, 0, .{});
    try std.testing.expect(result.fill.mesh.count > 4 and result.fill.mesh.count <= 128);
    const idle = mesh.build(400, 300, .{ .x = 0, .y = 0, .width = 400, .height = 300 }, 12, null, null, pull, 18, 1, 0, .{});
    try std.testing.expectEqual(@as(u32, 0), idle.fill.mesh.count);
    try std.testing.expectEqual(@as(u32, 0), idle.edge.mesh.count);
}
