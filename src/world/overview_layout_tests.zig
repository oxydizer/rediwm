const std = @import("std");
const expect = std.testing.expect;
const layout = @import("overview_layout.zig");

test "four windows use two equal rows; five centre two above three" {
    const area: layout.Rect = .{ .x = 1280, .y = -100, .width = 1280, .height = 720 };
    const a = layout.place(4, 0, area, 1000, 800, 28).frame;
    const b = layout.place(4, 1, area, 1000, 800, 28).frame;
    const c = layout.place(4, 2, area, 1000, 800, 28).frame;
    const d = layout.place(4, 3, area, 1000, 800, 28).frame;
    try expect(a.y == b.y and c.y == d.y and a.y < c.y);
    try expect(a.x == c.x and b.x == d.x);
    const p = layout.place(5, 0, area, 1000, 800, 28).frame;
    const q = layout.place(5, 1, area, 1000, 800, 28).frame;
    const r = layout.place(5, 2, area, 1000, 800, 28).frame;
    const s = layout.place(5, 3, area, 1000, 800, 28).frame;
    const t = layout.place(5, 4, area, 1000, 800, 28).frame;
    try expect(p.y == q.y and r.y == s.y and s.y == t.y and p.y < r.y);
    try std.testing.expectApproxEqAbs(area.x + area.width / 2, (p.x + q.x + q.width) / 2, 0.001);
    try expect(p.x > r.x and q.x < t.x);
}

test "mixed aspect previews and captions fit without intersections on small and large outputs" {
    for ([_]f64{ 320, 1280, 2560 }) |width| for (1..65) |count| {
        const area: layout.Rect = .{ .x = -320, .y = 20, .width = width, .height = width * 0.6 };
        for (0..count) |i| {
            const w: f64 = if (i % 2 == 0) 2200 else 240;
            const h: f64 = if (i % 2 == 0) 300 else 1500;
            const a = layout.place(count, i, area, w, h, 28);
            try expect(a.frame.width > 0 and a.frame.height > 0);
            try std.testing.expectApproxEqAbs(w / h, a.frame.width / a.frame.height, 0.0001);
            try expect(a.frame.x >= area.x and a.frame.y >= area.y);
            try expect(a.frame.x + a.frame.width <= area.x + area.width);
            try expect(a.label.y >= a.frame.y + a.frame.height);
            try expect(a.label.y + a.label.height <= area.y + area.height + 0.001);
            for (0..i) |j| {
                const b = layout.place(count, j, area, if (j % 2 == 0) 2200 else 240, if (j % 2 == 0) 300 else 1500, 28);
                try expect(a.frame.x + a.frame.width <= b.frame.x or b.frame.x + b.frame.width <= a.frame.x or
                    a.frame.y + a.frame.height <= b.frame.y or b.frame.y + b.frame.height <= a.frame.y);
            }
        }
    };
}
