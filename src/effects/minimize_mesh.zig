//! A sheet pulled from its near edge into a narrow, curved tongue. UVs stay
//! attached to the sheet, so the actual window bends with the flame.
const std = @import("std");
const ribbon = @import("ribbon.zig");
pub const Box = struct { x: f32, y: f32, width: f32, height: f32 };

pub fn mesh(source: Box, target: ribbon.Point, progress: f32, preset: ribbon.Preset) ribbon.Geometry {
    const p = std.math.clamp(progress, 0, 1);
    var result: ribbon.Geometry = .{};
    if (p >= 1) return result;
    result.mesh.edge = 2;
    result.mesh.color = preset.color;
    result.mesh.color[3] *= preset.opacity;
    result.mesh.core_color = preset.core_color;
    result.mesh.core_color[3] *= preset.opacity;
    const above = target.y < source.y + source.height / 2;
    result.mesh.fade = .{ p, if (above) 1 else 0 };
    const rows: usize = switch (preset.quality) {
        .low => 24,
        .balanced => 48,
        .high => 64,
    };
    for (0..rows) |row| {
        const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(rows - 1));
        const uv_y = if (above) 1 - v else v;
        const pull = smooth((p * 1.5 - (1 - v) * 0.58) / 0.92);
        const remaining = 1 - pull;
        const original_y = source.y + source.height * uv_y;
        const y = original_y + (target.y - original_y) * pull;
        const center = source.x + source.width / 2;
        const curl = @sin(pull * 2 * std.math.pi) * @sin(p * std.math.pi) *
            @min(source.width * 0.28, 160) * (0.7 + preset.turbulence);
        const x = center + (target.x - center) * pull + curl;
        // The vertex shader uses this width ratio for perspective-correct UVs.
        const width = source.width * (remaining * remaining + 0.015 * pull * (1 - p));
        for (0..2) |side| {
            const u: f32 = if (side == 0) -0.035 else 1.035;
            result.mesh.vertices[result.mesh.count] = .{ x + (u - 0.5) * width, y, u, uv_y };
            result.mesh.count += 1;
        }
    }
    result.enclose();
    return result;
}

fn smooth(value: f32) f32 {
    const t = std.math.clamp(value, 0, 1);
    return t * t * (3 - 2 * t);
}

test {
    _ = @import("minimize_mesh_tests.zig");
}
