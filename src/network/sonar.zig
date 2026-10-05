//! A small signal map. Bearings are stable decoration, not physical locations;
//! only distance from the centre encodes the network's reported strength.
const std = @import("std");
const ui = @import("ui");
const Straight = @import("../color.zig").Straight;
const Network = @import("manager.zig").Network;

pub const size: f32 = 54;
const centre = size / 2;
const radius: f32 = 27;
const tau: f32 = 2 * std.math.pi;

/// A null phase paints a settled map without a sweep or pulsing echoes.
pub fn paint(r: *ui.paint.Renderer, networks: []const Network, phase: ?f32) void {
    const accent = ui.theme.shellPalette().accent;
    const sweep = (phase orelse 0) * tau - std.math.pi / 2.0;
    for (0..@intCast(r.height)) |iy| {
        const y = (@as(f32, @floatFromInt(iy)) + 0.5) / r.scale - centre;
        for (0..@intCast(r.width)) |ix| {
            const x = (@as(f32, @floatFromInt(ix)) + 0.5) / r.scale - centre;
            const distance = @sqrt(x * x + y * y);
            const edge = std.math.clamp((radius - distance) * r.scale + 0.5, 0, 1);
            if (edge == 0) continue;
            const ring_distance = @min(@abs(distance - radius), @min(@abs(distance - radius * 2 / 3), @abs(distance - radius / 3)));
            const ring = std.math.clamp((0.45 - ring_distance) * r.scale + 0.5, 0, 1);
            const cross = std.math.clamp((0.3 - @min(@abs(x), @abs(y))) * r.scale + 0.5, 0, 1);
            var alpha = 0.025 + ring * 0.32 + cross * 0.075;
            if (phase != null) {
                const age = @mod(sweep - std.math.atan2(y, x), tau);
                const trail = @max(0, 1 - age / 1.25);
                alpha += trail * trail * 0.27;
                // Narrow leading edge, softened in device pixels.
                const beam = std.math.clamp(1 - age * distance * r.scale, 0, 1);
                alpha += beam * 0.35;
            }
            r.pixels[iy * @as(usize, @intCast(r.width)) + ix] = (Straight{
                .r = accent[0],
                .g = accent[1],
                .b = accent[2],
                .a = @min(1, alpha) * edge * accent[3],
            }).argb();
        }
    }
    // The list puts the connected network first, so select by strength here
    // instead of truncating it (a connected network can be the weakest).
    var strongest: [6]*const Network = undefined;
    var count: usize = 0;
    for (networks) |*net| {
        var index: usize = 0;
        while (index < count and strongest[index].strength >= net.strength) : (index += 1) {}
        if (index == strongest.len) continue;
        var end = @min(count, strongest.len - 1);
        while (end > index) : (end -= 1) strongest[end] = strongest[end - 1];
        strongest[index] = net;
        count = @min(count + 1, strongest.len);
    }
    for (strongest[0..count]) |net| {
        // SSID/security survive AP rotation and signal-based list reordering.
        const hash = std.hash.Wyhash.hash(@intFromEnum(net.security), net.ssid.slice());
        const angle = @as(f32, @floatFromInt(hash % 65536)) / 65536 * tau;
        const strength = @as(f32, @floatFromInt(@min(net.strength, 100))) / 100;
        const distance = 7 + (radius - 10) * (1 - strength);
        const x = centre + @cos(angle) * distance;
        const y = centre + @sin(angle) * distance;
        const echo = if (phase != null) @exp(-@mod(sweep - angle, tau) * 1.5) else 0;
        disc(r, x, y, 4.5 + echo, accent, 0.045 + echo * 0.10);
        disc(r, x, y, 2.8, accent, 0.12 + echo * 0.20);
        disc(r, x, y, 1.55 + strength * 0.45, accent, 0.72 + echo * 0.28);
    }
    disc(r, centre, centre, 5, accent, 0.08);
    disc(r, centre, centre, 2.3, accent, 0.95);
}

fn disc(r: *ui.paint.Renderer, x: f32, y: f32, rad: f32, color: [4]f32, alpha: f32) void {
    var tint = color;
    tint[3] *= alpha;
    r.fillRect(x - rad, y - rad, rad * 2, rad * 2, .{ .color = tint, .radius = rad });
}
