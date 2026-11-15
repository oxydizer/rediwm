const std = @import("std");
const expect = std.testing.expect;
const layout = @import("overview_layout.zig");

test "four windows use two equal rows; five centre two above three" {
    const area: layout.Rect = .{ .x = 1280, .y = -100, .width = 1280, .height = 720 };
    const a = layout.place(4, 0, area, 1000, 800);
    const b = layout.place(4, 1, area, 1000, 800);
    const c = layout.place(4, 2, area, 1000, 800);
    const d = layout.place(4, 3, area, 1000, 800);
    try expect(a.y == b.y and c.y == d.y and a.y < c.y);
    try expect(a.x == c.x and b.x == d.x);
    const p = layout.place(5, 0, area, 1000, 800);
    const q = layout.place(5, 1, area, 1000, 800);
    const r = layout.place(5, 2, area, 1000, 800);
    const s = layout.place(5, 3, area, 1000, 800);
    const t = layout.place(5, 4, area, 1000, 800);
    try expect(p.y == q.y and r.y == s.y and s.y == t.y and p.y < r.y);
    try std.testing.expectApproxEqAbs(area.x + area.width / 2, (p.x + q.x + q.width) / 2, 0.001);
    try expect(p.x > r.x and q.x < t.x);
}

test "mixed aspect previews fit without intersections on small and large outputs" {
    for ([_]f64{ 320, 1280, 2560 }) |width| for (1..65) |count| {
        const area: layout.Rect = .{ .x = -320, .y = 20, .width = width, .height = width * 0.6 };
        for (0..count) |i| {
            const w: f64 = if (i % 2 == 0) 2200 else 240;
            const h: f64 = if (i % 2 == 0) 300 else 1500;
            const a = layout.place(count, i, area, w, h);
            try expect(a.width > 0 and a.height > 0);
            try std.testing.expectApproxEqAbs(w / h, a.width / a.height, 0.0001);
            try expect(a.x >= area.x and a.y >= area.y);
            try expect(a.x + a.width <= area.x + area.width);
            try expect(a.y + a.height <= area.y + area.height + 0.001);
            for (0..i) |j| {
                const b = layout.place(count, j, area, if (j % 2 == 0) 2200 else 240, if (j % 2 == 0) 300 else 1500);
                try expect(a.x + a.width <= b.x or b.x + b.width <= a.x or
                    a.y + a.height <= b.y or b.y + b.height <= a.y);
            }
        }
    };
}
