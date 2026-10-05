// Signed-distance helpers for antialiased fills, shared by the compositor's
// window chrome (chrome.zig) and the UI renderer (ui/paint.zig). No
// dependencies, so the Cairo clients can use ui/ too.
const std = @import("std");

/// Signed distance to a filled convex quad (negative inside). Vertices in
/// winding order. IQ's even-odd polygon formula unrolled for 4 sides.
pub fn sdQuad(
    px: f32,
    py: f32,
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    cx: f32,
    cy: f32,
    dx: f32,
    dy: f32,
) f32 {
    const xs = [_]f32{ ax, bx, cx, dx };
    const ys = [_]f32{ ay, by, cy, dy };
    var d = (px - ax) * (px - ax) + (py - ay) * (py - ay);
    var sign: f32 = 1;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const j = if (i == 0) 3 else i - 1;
        const ex = xs[j] - xs[i];
        const ey = ys[j] - ys[i];
        const wx = px - xs[i];
        const wy = py - ys[i];
        const elen = ex * ex + ey * ey;
        const t = if (elen > 0) std.math.clamp((wx * ex + wy * ey) / elen, 0, 1) else 0;
        const qx = wx - ex * t;
        const qy = wy - ey * t;
        d = @min(d, qx * qx + qy * qy);
        const c1 = py >= ys[i];
        const c2 = py < ys[j];
        const c3 = ex * wy > ey * wx;
        if ((c1 and c2 and c3) or (!c1 and !c2 and !c3)) sign = -sign;
    }
    return sign * @sqrt(d);
}

pub inline fn sdRoundedBox(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, radius: f32) f32 {
    const r = @min(radius, @min(w, h) / 2);
    const qx = @abs(px - (x + w / 2)) - (w / 2 - r);
    const qy = @abs(py - (y + h / 2)) - (h / 2 - r);
    const outside_x = @max(qx, 0);
    const outside_y = @max(qy, 0);
    return @min(@max(qx, qy), 0) + @sqrt(outside_x * outside_x + outside_y * outside_y) - r;
}

/// Pixel coverage of a point at signed `distance` from an edge: a one-pixel
/// ramp centred on the edge.
pub inline fn coverage(distance: f32) f32 {
    return @max(0, @min(1, 0.5 - distance));
}
