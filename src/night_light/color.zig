const std = @import("std");

/// Returns the normalized [R, G, B] whitepoint multipliers in 0.0..1.0 for a given
/// color temperature in Kelvin. 6500 K is exactly (1, 1, 1).
pub fn whitepoint(kelvin: u32) [3]f64 {
    if (kelvin == 6500) {
        return .{ 1.0, 1.0, 1.0 };
    }

    const T = @as(f64, @floatFromInt(kelvin));
    var x: f64 = undefined;
    var y: f64 = undefined;

    if (kelvin >= 4000) {
        // CIE daylight (illuminant D) locus
        if (kelvin <= 7000) {
            x = 0.244063 + 0.09911e3 / T + 2.9678e6 / (T * T) - 4.6070e9 / (T * T * T);
        } else {
            x = 0.237040 + 0.24748e3 / T + 1.9018e6 / (T * T) - 2.0064e9 / (T * T * T);
        }
        y = -3.0 * (x * x) + 2.870 * x - 0.275;
    } else if (kelvin <= 2500) {
        // Planckian locus (Kim et al. cubic approximation)
        x = -0.2661239e9 / (T * T * T) - 0.2343589e6 / (T * T) + 0.8776956e3 / T + 0.179910;
        if (kelvin <= 2222) {
            y = -1.1063814 * (x * x * x) - 1.34811020 * (x * x) + 2.18555832 * x - 0.20219683;
        } else {
            y = -0.9549476 * (x * x * x) - 1.37418593 * (x * x) + 2.09137015 * x - 0.16748867;
        }
    } else {
        // 2500 K < kelvin < 4000 K: cosine-weighted blend
        const x_d = 0.244063 + 0.09911e3 / T + 2.9678e6 / (T * T) - 4.6070e9 / (T * T * T);
        const y_d = -3.0 * (x_d * x_d) + 2.870 * x_d - 0.275;

        const x_p = -0.2661239e9 / (T * T * T) - 0.2343589e6 / (T * T) + 0.8776956e3 / T + 0.179910;
        const y_p = -0.9549476 * (x_p * x_p * x_p) - 1.37418593 * (x_p * x_p) + 2.09137015 * x_p - 0.16748867;

        const factor = (4000.0 - T) / 1500.0;
        const w = (std.math.cos(std.math.pi * factor) + 1.0) / 2.0;
        x = x_d * w + x_p * (1.0 - w);
        y = y_d * w + y_p * (1.0 - w);
    }

    // Chromaticity xy to XYZ (Y = 1.0)
    const X = x / y;
    const Y = 1.0;
    const Z = (1.0 - x - y) / y;

    // XYZ to linear sRGB (D65-adapted matrix)
    const r_lin = std.math.clamp(3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z, 0.0, 1.0);
    const g_lin = std.math.clamp(-0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z, 0.0, 1.0);
    const b_lin = std.math.clamp(0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z, 0.0, 1.0);

    // Encode with 2.2 power
    var r_enc = std.math.pow(f64, r_lin, 1.0 / 2.2);
    var g_enc = std.math.pow(f64, g_lin, 1.0 / 2.2);
    var b_enc = std.math.pow(f64, b_lin, 1.0 / 2.2);

    // Normalize so the largest channel is 1.0
    const max_c = @max(r_enc, @max(g_enc, b_enc));
    if (max_c > 0.0) {
        r_enc /= max_c;
        g_enc /= max_c;
        b_enc /= max_c;
    }

    return .{ r_enc, g_enc, b_enc };
}

/// Fills 1D look-up tables (r, g, b) of matching length with entries
/// round(65535 · wp_c · v^(1/gamma)) for encoded input v = i / (n - 1).
pub fn fillLut(r: []u16, g: []u16, b: []u16, wp: [3]f64, gamma: f64) void {
    std.debug.assert(r.len == g.len and g.len == b.len);
    std.debug.assert(r.len >= 2);
    const n = r.len;
    const denom = @as(f64, @floatFromInt(n - 1));
    const inv_gamma = 1.0 / gamma;

    for (0..n) |i| {
        const v = @as(f64, @floatFromInt(i)) / denom;
        const v_pow = if (gamma == 1.0) v else std.math.pow(f64, v, inv_gamma);
        r[i] = @intFromFloat(@round(65535.0 * wp[0] * v_pow));
        g[i] = @intFromFloat(@round(65535.0 * wp[1] * v_pow));
        b[i] = @intFromFloat(@round(65535.0 * wp[2] * v_pow));
    }
}

test "whitepoint: 6500 K is neutral and channels monotonic" {
    const wp6500 = whitepoint(6500);
    try std.testing.expectEqual(@as(f64, 1.0), wp6500[0]);
    try std.testing.expectEqual(@as(f64, 1.0), wp6500[1]);
    try std.testing.expectEqual(@as(f64, 1.0), wp6500[2]);

    // Below 6500 K, red is 1.0 and blue falls monotonically with decreasing T (rises with increasing T)
    var prev_b: f64 = -1.0;
    var t: u32 = 1700;
    while (t <= 6500) : (t += 10) {
        const wp = whitepoint(t);
        try std.testing.expectEqual(@as(f64, 1.0), wp[0]);
        try std.testing.expect(wp[2] >= prev_b);
        prev_b = wp[2];

        if (t + 10 <= 6500) {
            const next_wp = whitepoint(t + 10);
            for (0..3) |ch| {
                const diff = @abs(next_wp[ch] - wp[ch]);
                // Continuity bound: no jump larger than 0.05 per 10 K anywhere
                try std.testing.expect(diff < 0.05);
            }
        }
    }

    // Above 6500 K, blue is 1.0
    t = 6500;
    while (t <= 10000) : (t += 10) {
        const wp = whitepoint(t);
        try std.testing.expectEqual(@as(f64, 1.0), wp[2]);
    }

    // Pinned reference values
    const wp4000 = whitepoint(4000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), wp4000[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.970), wp4000[1], 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 0.727), wp4000[2], 0.005);

    const wp2500 = whitepoint(2500);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), wp2500[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.888), wp2500[1], 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 0.410), wp2500[2], 0.005);

    const wp10000 = whitepoint(10000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.916), wp10000[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), wp10000[1], 0.001);
    try std.testing.expectEqual(@as(f64, 1.0), wp10000[2]);
}

test "LUT generation: sizes 2 and 4096, linear and gamma 2.0" {
    const wp = whitepoint(4000);

    // Size 2
    var r2: [2]u16 = undefined;
    var g2: [2]u16 = undefined;
    var b2: [2]u16 = undefined;
    fillLut(&r2, &g2, &b2, wp, 1.0);
    try std.testing.expectEqual(@as(u16, 0), r2[0]);
    try std.testing.expectEqual(@as(u16, 0), g2[0]);
    try std.testing.expectEqual(@as(u16, 0), b2[0]);
    try std.testing.expectEqual(@as(u16, @intFromFloat(@round(65535.0 * wp[0]))), r2[1]);
    try std.testing.expectEqual(@as(u16, @intFromFloat(@round(65535.0 * wp[1]))), g2[1]);
    try std.testing.expectEqual(@as(u16, @intFromFloat(@round(65535.0 * wp[2]))), b2[1]);

    // Midpoint check with gamma 2.0 on size 3
    var r3: [3]u16 = undefined;
    var g3: [3]u16 = undefined;
    var b3: [3]u16 = undefined;
    fillLut(&r3, &g3, &b3, wp, 2.0);
    // Midpoint v = 0.5; v^(1/2) = sqrt(0.5) ≈ 0.7071
    const expected_mid_r = @as(u16, @intFromFloat(@round(65535.0 * wp[0] * std.math.sqrt(0.5))));
    try std.testing.expectEqual(expected_mid_r, r3[1]);

    // Size 4096
    var r4096: [4096]u16 = undefined;
    var g4096: [4096]u16 = undefined;
    var b4096: [4096]u16 = undefined;
    fillLut(&r4096, &g4096, &b4096, wp, 1.0);
    try std.testing.expectEqual(@as(u16, 0), r4096[0]);
    try std.testing.expectEqual(@as(u16, @intFromFloat(@round(65535.0 * wp[0]))), r4096[4095]);
    try std.testing.expectEqual(@as(u16, @intFromFloat(@round(65535.0 * wp[1]))), g4096[4095]);
    try std.testing.expectEqual(@as(u16, @intFromFloat(@round(65535.0 * wp[2]))), b4096[4095]);
}
