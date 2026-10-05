const std = @import("std");
pub const PanModifier = enum { super, super_alt };

pub const AccelProfile = enum {
    flat,
    bezier,
};

pub const AccelCurve = struct {
    pub const lut_size: usize = 256;

    p1: [2]f32,
    p2: [2]f32,
    max_speed: f32,
    lut: [lut_size]f32,

    pub fn init(p1: [2]f32, p2: [2]f32, max_speed: f32) AccelCurve {
        var curve: AccelCurve = .{
            .p1 = p1,
            .p2 = p2,
            .max_speed = if (max_speed > 0 and std.math.isFinite(max_speed)) max_speed else 10.0,
            .lut = undefined,
        };
        curve.computeLut();
        return curve;
    }

    pub fn sampleX(p1_x: f32, p2_x: f32, t: f32) f32 {
        const one_minus_t = 1.0 - t;
        return 3.0 * one_minus_t * one_minus_t * t * p1_x +
            3.0 * one_minus_t * t * t * p2_x +
            t * t * t;
    }

    pub fn sampleY(p1_y: f32, p2_y: f32, t: f32) f32 {
        const one_minus_t = 1.0 - t;
        return 3.0 * one_minus_t * one_minus_t * t * p1_y +
            3.0 * one_minus_t * t * t * p2_y +
            t * t * t;
    }

    pub fn solveT(p1_x: f32, p2_x: f32, target_x: f32) f32 {
        if (target_x <= 0.0) return 0.0;
        if (target_x >= 1.0) return 1.0;

        var t_low: f32 = 0.0;
        var t_high: f32 = 1.0;
        for (0..32) |_| {
            const t_mid = (t_low + t_high) * 0.5;
            const x_mid = sampleX(p1_x, p2_x, t_mid);
            if (x_mid < target_x) {
                t_low = t_mid;
            } else {
                t_high = t_mid;
            }
        }
        return (t_low + t_high) * 0.5;
    }

    pub fn computeLut(self: *AccelCurve) void {
        for (0..lut_size) |i| {
            const target_x = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(lut_size - 1));
            const t = solveT(self.p1[0], self.p2[0], target_x);
            const y = sampleY(self.p1[1], self.p2[1], t);
            self.lut[i] = @max(0.0, y);
        }
    }

    pub fn lookup(self: *const AccelCurve, norm_speed: f32) f32 {
        if (!std.math.isFinite(norm_speed) or norm_speed <= 0.0) {
            return self.lut[0];
        }
        if (norm_speed >= 1.0) {
            return self.lut[lut_size - 1];
        }
        const scaled = norm_speed * @as(f32, @floatFromInt(lut_size - 1));
        const idx: usize = @intFromFloat(scaled);
        if (idx >= lut_size - 1) {
            return self.lut[lut_size - 1];
        }
        const frac = scaled - @as(f32, @floatFromInt(idx));
        return self.lut[idx] * (1.0 - frac) + self.lut[idx + 1] * frac;
    }
};

pub const FocusZoom = enum { keep, boost, camera };

pub const MiniMapPosition = enum { bottom_right, bottom_center, bottom_left };

pub const LidAction = enum {
    /// Turn off the built-in display while another display is on.
    display_off,
    /// Lock, and turn off the built-in display.
    lock,
    /// Lock and suspend. Without another display logind suspends by itself.
    @"suspend",
    /// Leave the built-in display on and inhibit logind lid handling.
    ignore,
};

pub const InputMethod = enum { none, fcitx, ibus };
