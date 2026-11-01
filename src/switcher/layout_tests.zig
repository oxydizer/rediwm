const std = @import("std");
const testing = std.testing;
const layout = @import("layout.zig");

test "circular switcher fits usable output and keeps narrow sectors separated" {
    try testing.expectEqual(@as(i32, 720), layout.diameter(1920, 1080));
    try testing.expectEqual(@as(i32, 568), layout.diameter(800, 600));
    try testing.expectEqual(@as(i32, 288), layout.diameter(320, 800));
    try testing.expectEqual(layout.span(1), layout.span(4));
    for ([_]usize{ 1, 4, 5, 8, 32, 256, 10000 }) |count| {
        const slot = 2 * std.math.pi / @as(f64, @floatFromInt(@max(4, count)));
        try testing.expect(layout.span(count) > 0);
        try testing.expect(layout.span(count) < slot);
    }
}

test "exact circular arcs stay within the preview bounds throughout rotation" {
    for ([_]i32{ 260, 320, 568, 720 }) |size| {
        const center = @as(f64, @floatFromInt(size)) / 2;
        for ([_]usize{ 1, 2, 4, 5, 6, 8, 12, 32, 256 }) |count| {
            for (0..3) |depth| {
                for (0..32) |step| {
                    const angle = 2 * std.math.pi * @as(f64, @floatFromInt(step)) / 32;
                    const arc = layout.span(count);
                    const sector = layout.makeSector(size, angle, arc, depth, 0);
                    try testing.expect(sector.width > 0 and sector.height > 0);
                    try testing.expect(sector.x >= 0 and sector.y >= 0);
                    try testing.expect(sector.x + sector.width <= size);
                    try testing.expect(sector.y + sector.height <= size);
                    try testing.expectApproxEqAbs(center, sector.arc.center[0] + @as(f64, @floatFromInt(sector.x)), 1e-8);
                    try testing.expectApproxEqAbs(center, sector.arc.center[1] + @as(f64, @floatFromInt(sector.y)), 1e-8);
                    try testing.expect(sector.arc.radii[0] > 0 and sector.arc.radii[1] > sector.arc.radii[0]);
                    // Sample between the old polygon vertices, including exact
                    // cardinal peaks: none of the true curve may be clipped off.
                    for (0..101) |sample| {
                        const a = angle - arc / 2 + arc * @as(f64, @floatFromInt(sample)) / 100;
                        for (sector.arc.radii) |radius| {
                            const x = sector.arc.center[0] + @sin(a) * radius;
                            const y = sector.arc.center[1] - @cos(a) * radius;
                            try testing.expect(x >= 0.99 and x <= @as(f64, @floatFromInt(sector.width)) - 0.99);
                            try testing.expect(y >= 0.99 and y <= @as(f64, @floatFromInt(sector.height)) - 0.99);
                        }
                    }
                }
            }
        }
    }
}

test "stack offsets remain concentric and stop at two layers" {
    const front = layout.makeSector(720, 0.43, layout.span(5), 0, 0);
    const back = layout.makeSector(720, 0.43, layout.span(5), 2, 0);
    try testing.expectApproxEqAbs(@as(f64, 28), back.arc.radii[0] - front.arc.radii[0], 1e-8);
    try testing.expectApproxEqAbs(@as(f64, 28), back.arc.radii[1] - front.arc.radii[1], 1e-8);
    try testing.expectEqualDeep(back, layout.makeSector(720, 0.43, layout.span(5), 100, 0));
}

test "expand progress widens the stack without moving the front layer" {
    const front = layout.makeSector(720, 0.43, layout.span(5), 0, 1);
    const front_idle = layout.makeSector(720, 0.43, layout.span(5), 0, 0);
    try testing.expectEqualDeep(front_idle, front);
    const back_idle = layout.makeSector(720, 0.43, layout.span(5), 2, 0);
    const back_open = layout.makeSector(720, 0.43, layout.span(5), 2, 1);
    try testing.expectApproxEqAbs(@as(f64, 120), back_open.arc.radii[0] - front.arc.radii[0], 1e-8);
    try testing.expect(back_open.arc.radii[0] - front.arc.radii[0] > back_idle.arc.radii[0] - front_idle.arc.radii[0]);
}

test "radial previews fit the full top edge and crop only below it" {
    const arc = layout.span(4);
    const front = layout.makeSector(720, 0, arc, 0, 0);
    const height = layout.previewHeight(front, 0.2);
    try testing.expectApproxEqAbs(front.arc.radii[1] * arc / 0.2, height, 1e-8);
    const depth = front.arc.radii[1] - front.arc.radii[0];
    // A tall window keeps its header: the whole visible band comes from its
    // first tenth, rather than a centered crop around the source's midpoint.
    try testing.expect(depth / height < 0.1);
    for (0..32) |step| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(step)) / 32;
        const rotated = layout.makeSector(720, angle, arc, 0, 0);
        try testing.expectApproxEqAbs(height, layout.previewHeight(rotated, 0.2), 1e-8);
    }
    // Shallow windows retain their natural height; empty space after their
    // bottom is transparent rather than a repeated final row or vertical stretch.
    try testing.expect(layout.previewHeight(front, 10) < depth);
}
